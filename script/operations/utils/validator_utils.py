#!/usr/bin/env python3
"""
validator_utils.py - Reusable utilities for validator operations

This module provides common utilities for:
- Database connections and queries
- Beacon chain API interactions
- Sweep time calculations
- Operator and validator lookups

These utilities can be used by various scripts that need to interact
with the validator database and beacon chain.
"""

import math
import os
import sys
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple

# Load .env file if python-dotenv is available
try:
    from pathlib import Path
    from dotenv import load_dotenv
    # Try loading from current directory, then from script's parent directories
    env_path = Path('.env')
    if not env_path.exists():
        # Try to find .env in parent directories (up to 5 levels)
        script_dir = Path(__file__).resolve().parent
        for _ in range(5):
            script_dir = script_dir.parent
            candidate = script_dir / '.env'
            if candidate.exists():
                env_path = candidate
                break
    load_dotenv(dotenv_path=env_path)
except ImportError:
    pass  # dotenv is optional

try:
    import psycopg2
    from psycopg2.extras import RealDictCursor
except ImportError:
    print("Error: psycopg2 not installed. Run: pip install psycopg2-binary")
    sys.exit(1)

try:
    import requests
except ImportError:
    requests = None


# =============================================================================
# Constants
# =============================================================================

# Beacon Chain Constants
VALIDATORS_PER_SLOT = 16  # Validators processed per slot in withdrawal sweep
SLOTS_PER_EPOCH = 32      # Slots per epoch
SECONDS_PER_SLOT = 12     # Seconds per slot
VALIDATORS_PER_SECOND = VALIDATORS_PER_SLOT / SECONDS_PER_SLOT


# =============================================================================
# Database Utilities
# =============================================================================

def get_db_connection():
    """Get database connection from environment variable."""
    db_url = os.environ.get('VALIDATOR_DB')
    if not db_url:
        raise ValueError("VALIDATOR_DB environment variable not set")
    return psycopg2.connect(db_url)


def load_operators_from_db(conn) -> Tuple[Dict[str, str], Dict[str, str]]:
    """Load operators from address_remapping table."""
    address_to_name = {}
    name_to_address = {}
    
    with conn.cursor() as cur:
        cur.execute('SELECT payee_address, name FROM address_remapping')
        for addr, name in cur.fetchall():
            addr_lower = addr.lower()
            name_lower = name.lower()
            address_to_name[addr_lower] = name
            name_to_address[name_lower] = addr_lower
    
    return address_to_name, name_to_address


def get_operator_address(conn, operator: str) -> Optional[str]:
    """Resolve operator name or address to address."""
    _, name_to_address = load_operators_from_db(conn)
    
    # If it looks like an address, normalize and return
    if operator.startswith('0x') and len(operator) == 42:
        return operator.lower()
    
    # Otherwise, look up by name
    return name_to_address.get(operator.lower())


def list_operators(conn) -> List[Dict]:
    """List all operators with validator counts from etherfi_validators table."""
    address_to_name, _ = load_operators_from_db(conn)
    
    operators = []
    with conn.cursor() as cur:
        # Query using the correct column name: operator
        cur.execute('''
            SELECT 
                operator,
                COUNT(*) AS total_validators
            FROM "etherfi_validators"
            WHERE timestamp = (SELECT MAX(timestamp) FROM "etherfi_validators")
              AND operator IS NOT NULL
              AND status = 'active_ongoing'
            GROUP BY operator
            ORDER BY total_validators DESC
        ''')
        
        for row in cur.fetchall():
            addr = row[0] if row[0] else None
            operators.append({
                'address': addr,
                'name': address_to_name.get(addr, 'Unknown'),
                'total': row[1],
            })
    
    return operators


def query_validators(
    conn,
    operator: str,
    count: int,
    phase_filter: Optional[str] = None
) -> List[Dict]:
    """
    Query validators from etherfi_validators table by node operator.
    
    Args:
        conn: PostgreSQL connection
        operator: Node operator address (normalized lowercase)
        count: Maximum number of validators to return
        phase_filter: Optional phase filter (e.g., 'LIVE', 'EXITED')
    
    Returns:
        List of validator dictionaries
    """
    query = """
        SELECT
            pubkey,
            id,
            withdrawal_credentials,
            phase,
            status,
            index,
            node_address
        FROM "etherfi_validators"
        WHERE timestamp = (SELECT MAX(timestamp) FROM "etherfi_validators")
          AND LOWER(operator) = %s
          AND status LIKE %s
    """

    params = [operator, '%active%']
    
    if phase_filter:
        query += " AND phase = %s"
        params.append(phase_filter)
    
    query += ' ORDER BY id LIMIT %s'
    params.append(count)
    
    validators = []
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(query, params)
        for row in cur.fetchall():
            # Normalize pubkey format
            pubkey = row['pubkey']
            if pubkey and not pubkey.startswith('0x'):
                pubkey = '0x' + pubkey
            
            # Store raw withdrawal credentials (will be converted later)
            withdrawal_creds = row['withdrawal_credentials']
            if withdrawal_creds and not withdrawal_creds.startswith('0x'):
                withdrawal_creds = '0x' + withdrawal_creds
            
            validators.append({
                'id': row['id'],
                'pubkey': pubkey,
                'withdrawal_credentials': withdrawal_creds,
                'etherfi_node': row['node_address'],
                'phase': row['phase'],
                'status': row['status'],
                'index': row['index']
            })
    
    return validators


# =============================================================================
# Beacon Chain Utilities
# =============================================================================

def get_beacon_chain_url() -> str:
    """Get beacon chain API URL from environment or use default."""
    return os.environ.get('BEACON_CHAIN_URL', 'https://beaconcha.in/api/v1')


def fetch_next_withdrawal_index() -> Optional[Dict]:
    """
    Fetch next withdrawal validator index from beacon chain API.

    Returns:
        Dict with currentSweepIndex, currentSlot, lastWithdrawalIndex or None if failed
    """
    if not requests:
        raise ImportError("requests library required for beacon chain API")

    beacon_url = get_beacon_chain_url()

    try:
        # Try beacon API endpoint for latest block
        response = requests.get(f"{beacon_url}/eth/v2/beacon/blocks/head", timeout=30)
        response.raise_for_status()
        data = response.json()

        if data.get('data'):
            block = data['data'].get('message', {})
            slot = int(block.get('slot', 0))

            # Get withdrawals from execution payload
            withdrawals = block.get('body', {}).get('execution_payload', {}).get('withdrawals', [])

            if withdrawals:
                # The last withdrawal's validator_index + 1 gives us the next sweep index
                last_withdrawal = withdrawals[-1]
                next_sweep_index = int(last_withdrawal.get('validator_index', 0)) + 1

                return {
                    'currentSweepIndex': next_sweep_index,
                    'currentSlot': slot,
                    'lastWithdrawalIndex': int(last_withdrawal.get('validator_index', 0))
                }
    except Exception as e:
        print(f"Warning: Failed to fetch withdrawal index: {e}")

    return None


def fetch_validator_count() -> int:
    """
    Fetch total active validator count from beacon chain.

    Returns:
        Total validator count
    """
    if not requests:
        raise ImportError("requests library required for beacon chain API")

    beacon_url = get_beacon_chain_url()

    try:
        # Try to get validator count from beacon API
        response = requests.get(f"{beacon_url}/eth/v1/beacon/states/head/validators?status=active_ongoing",
                               headers={'Accept': 'application/json'}, timeout=30)

        if response.ok:
            data = response.json()
            if data.get('data'):
                return len(data['data'])
    except Exception as e:
        print(f"Warning: Failed to fetch validator count: {e}")

    # Fallback to approximate count
    return 1200000


def fetch_beacon_state() -> Dict:
    """
    Fetch current beacon chain state including next_withdrawal_validator_index.

    Returns:
        Dict containing beacon state data
    """
    if not requests:
        raise ImportError("requests library required for beacon chain API")

    # Try the new withdrawal index method first
    sweep_data = fetch_next_withdrawal_index()
    validator_count = fetch_validator_count()

    if sweep_data:
        return {
            'next_withdrawal_validator_index': sweep_data['currentSweepIndex'],
            'validator_count': validator_count,
            'epoch': 0,  # Not available from this method
            'slot': sweep_data.get('currentSlot'),
            'last_withdrawal_index': sweep_data.get('lastWithdrawalIndex')
        }

    # Fallback to original method
    beacon_url = get_beacon_chain_url()

    try:
        response = requests.get(f"{beacon_url}/epoch/latest", timeout=30)
        response.raise_for_status()
        data = response.json()

        if 'data' in data and len(data['data']) > 0:
            epoch_data = data['data'][0]
            return {
                'next_withdrawal_validator_index': epoch_data.get('nextwithdrawalvalidatorindex', 0),
                'validator_count': validator_count,
                'epoch': epoch_data.get('epoch', 0)
            }
    except Exception as e:
        print(f"Warning: Failed to fetch from beaconcha.in: {e}")

    # Fallback: Try direct beacon node API if available
    beacon_node_url = os.environ.get('BEACON_NODE_URL')
    if beacon_node_url:
        try:
            response = requests.get(f"{beacon_node_url}/eth/v1/beacon/states/head", timeout=30)
            response.raise_for_status()
            data = response.json()

            state = data.get('data', {})
            next_withdrawal_index = state.get('next_withdrawal_validator_index', 0)

            return {
                'next_withdrawal_validator_index': next_withdrawal_index,
                'validator_count': validator_count,
                'epoch': state.get('epoch', 0)
            }
        except Exception as e:
            print(f"Warning: Failed to fetch from beacon node: {e}")

    raise ValueError("Could not fetch beacon chain state from any source")


# =============================================================================
# Sweep Time Calculations
# =============================================================================

def calculate_sweep_time(validator_index: int, current_sweep_index: int, total_validators: int) -> Dict:
    """
    Calculate sweep time for a validator using the JavaScript algorithm.

    Args:
        validator_index: The validator's index
        current_sweep_index: Current next_withdrawal_validator_index
        total_validators: Total active validators

    Returns:
        Dict with position, slots, seconds until sweep, and estimated time
    """
    # Calculate position in queue
    if validator_index >= current_sweep_index:
        # Validator is ahead in current sweep cycle
        position_in_queue = validator_index - current_sweep_index
    else:
        # Validator was already passed, will be swept in next cycle
        position_in_queue = (total_validators - current_sweep_index) + validator_index

    # Calculate time until sweep
    slots_until_sweep = math.ceil(position_in_queue / VALIDATORS_PER_SLOT)
    seconds_until_sweep = slots_until_sweep * SECONDS_PER_SLOT

    estimated_sweep_time = datetime.now() + timedelta(seconds=seconds_until_sweep)

    return {
        'positionInQueue': position_in_queue,
        'slotsUntilSweep': slots_until_sweep,
        'secondsUntilSweep': seconds_until_sweep,
        'estimatedSweepTime': estimated_sweep_time
    }


def format_duration(seconds: float) -> str:
    """Format duration in seconds to human readable string."""
    days = int(seconds // 86400)
    hours = int((seconds % 86400) // 3600)
    minutes = int((seconds % 3600) // 60)

    if days > 0:
        return f"{days}d {hours}h {minutes}m"
    elif hours > 0:
        return f"{hours}h {minutes}m"
    else:
        return f"{minutes}m"


# =============================================================================
# Validator Consolidation Status Checking
# =============================================================================

def check_validators_consolidation_status_batch(
    pubkeys: List[str],
    beacon_api: str = "https://beaconcha.in/api/v1",
    max_retries: int = 3
) -> Dict[str, Optional[bool]]:
    """
    Check consolidation status for multiple validators using batch API request.
    
    Args:
        pubkeys: List of validator public keys (with or without 0x prefix)
        beacon_api: Beacon chain API base URL
        max_retries: Maximum number of retry attempts
    
    Returns:
        Dictionary mapping pubkey -> True (consolidated), False (not consolidated), or None (unknown)
    """
    if not pubkeys or not requests:
        return {pk: None for pk in pubkeys}
    
    # Clean pubkeys (remove 0x prefix)
    pubkeys_clean = [pk[2:] if pk.startswith('0x') else pk for pk in pubkeys]
    
    # Join pubkeys with commas for batch request
    pubkeys_str = ','.join(pubkeys_clean)
    
    result = {pk: None for pk in pubkeys}  # Initialize all as None
    
    for attempt in range(max_retries):
        try:
            # Batch API endpoint: /validator/{pubkey1},{pubkey2},...
            url = f"{beacon_api}/validator/{pubkeys_str}"
            response = requests.get(url, timeout=30)  # Longer timeout for batch
            response.raise_for_status()
            data = response.json()
            
            if data.get('status') == 'OK' and 'data' in data:
                # Handle both single and batch responses
                validator_data_list = data['data']
                if not isinstance(validator_data_list, list):
                    validator_data_list = [validator_data_list]
                
                # Map results back to pubkeys
                for validator_data in validator_data_list:
                    validator_pubkey = validator_data.get('pubkey', '')
                    if not validator_pubkey:
                        continue
                    
                    # Normalize pubkey for matching (remove 0x, lowercase)
                    validator_pubkey_normalized = validator_pubkey.lower().replace('0x', '')
                    
                    # Find matching original pubkey
                    matching_pubkey = None
                    for pk in pubkeys:
                        pk_normalized = pk.lower().replace('0x', '')
                        if validator_pubkey_normalized == pk_normalized:
                            matching_pubkey = pk
                            break
                    
                    if matching_pubkey:
                        withdrawal_creds = validator_data.get('withdrawalcredentials', '')
                        if withdrawal_creds:
                            # Check first byte: 0x01 = traditional, 0x02 = auto-compounding (consolidated)
                            if withdrawal_creds.startswith('0x02'):
                                result[matching_pubkey] = True  # Already consolidated
                            elif withdrawal_creds.startswith('0x01'):
                                result[matching_pubkey] = False  # Not consolidated
                            else:
                                result[matching_pubkey] = None  # Unexpected format
            
            return result
            
        except Exception as e:
            # Network/API error - retry with backoff
            if attempt < max_retries - 1:
                time.sleep(0.5 * (attempt + 1))  # Exponential backoff
                continue
            # After max retries, return None for all (safer)
            return result
    
    return result


def filter_consolidated_validators(
    validators: List[Dict],
    exclude_consolidated: bool = True,
    beacon_api: str = "https://beaconcha.in/api/v1",
    show_progress: bool = True,
    batch_size: int = 100
) -> Tuple[List[Dict], List[Dict]]:
    """
    Filter out validators that are already consolidated (0x02) using batch API requests.
    
    Args:
        validators: List of validator dictionaries
        exclude_consolidated: If True, exclude consolidated validators
        beacon_api: Beacon chain API base URL
        show_progress: Show progress messages
        batch_size: Number of validators to check per API request (max 100)
    
    Returns:
        Tuple of (filtered_validators, consolidated_validators)
    """
    if not exclude_consolidated:
        return validators, []
    
    if not requests:
        print("Warning: requests library not installed, skipping beacon chain check")
        return validators, []
    
    # Limit batch size to API maximum
    batch_size = min(batch_size, 100)
    
    filtered = []
    consolidated = []
    unknown = []
    
    # Extract pubkeys for batch checking
    validator_pubkeys = []
    validator_map = {}  # Map pubkey -> validator dict
    
    for validator in validators:
        pubkey = validator.get('pubkey', '')
        if not pubkey:
            continue
        validator_pubkeys.append(pubkey)
        validator_map[pubkey] = validator
    
    # Process in batches
    total_batches = (len(validator_pubkeys) + batch_size - 1) // batch_size
    
    for batch_idx in range(total_batches):
        start_idx = batch_idx * batch_size
        end_idx = min(start_idx + batch_size, len(validator_pubkeys))
        batch_pubkeys = validator_pubkeys[start_idx:end_idx]
        
        if show_progress:
            print(f"  Checking batch {batch_idx + 1}/{total_batches} ({end_idx}/{len(validator_pubkeys)} validators)...", end='\r', flush=True)
        
        # Check batch
        batch_results = check_validators_consolidation_status_batch(
            batch_pubkeys,
            beacon_api=beacon_api
        )
        
        # Process results
        for pubkey in batch_pubkeys:
            validator = validator_map[pubkey]
            is_consolidated = batch_results.get(pubkey)
            
            if is_consolidated is True:
                # Already consolidated - exclude it
                consolidated.append(validator)
            elif is_consolidated is False:
                # Not consolidated - include it
                filtered.append(validator)
            else:
                # Unknown status - include it (assume not consolidated)
                filtered.append(validator)
                unknown.append(validator)
        
    
    if show_progress:
        print(f"  Checked {len(validator_pubkeys)} validators in {total_batches} batches" + " " * 20)  # Clear progress line
        if unknown:
            print(f"  Warning: {len(unknown)} validators had unknown consolidation status (included anyway)")
    
    return filtered, consolidated


# =============================================================================
# Validator Queue Distribution
# =============================================================================

def spread_validators_across_queue(sorted_results: List[Dict], interval_hours: int = 6) -> Dict:
    """
    Spread validators across the withdrawal queue at fixed intervals.

    Args:
        sorted_results: Results sorted by sweep time (ascending)
        interval_hours: Interval between buckets (default 6 hours)

    Returns:
        Dict with buckets and summary
    """
    interval_seconds = interval_hours * 3600

    if not sorted_results:
        return {'buckets': [], 'summary': {}}

    # Find the first validator's sweep time as the starting point
    first_sweep_seconds = sorted_results[0]['secondsUntilSweep']
    last_sweep_seconds = sorted_results[-1]['secondsUntilSweep']

    # Calculate how many buckets we need
    total_duration = last_sweep_seconds - first_sweep_seconds
    num_buckets = math.ceil(total_duration / interval_seconds) + 1

    print(f"\nCreating {num_buckets} buckets at {interval_hours}-hour intervals...")

    # Initialize buckets with target times
    buckets = []
    for i in range(num_buckets):
        target_seconds = first_sweep_seconds + (i * interval_seconds)
        buckets.append({
            'bucketIndex': i,
            'targetSweepTimeSeconds': target_seconds,
            'targetSweepTimeFormatted': format_duration(target_seconds),
            'estimatedSweepTime': (datetime.now() + timedelta(seconds=target_seconds)).isoformat(),
            'validators': [],
            'byNodeAddress': {}
        })

    # Assign each validator to the nearest bucket
    for validator in sorted_results:
        # Find the bucket whose target time is closest
        time_since_first = validator['secondsUntilSweep'] - first_sweep_seconds
        bucket_index = round(time_since_first / interval_seconds)
        clamped_index = max(0, min(bucket_index, len(buckets) - 1))

        bucket = buckets[clamped_index]
        bucket['validators'].append(validator)

        # Group by node address within bucket
        node_addr = validator.get('nodeAddress', validator.get('etherfi_node', 'unknown'))
        if node_addr not in bucket['byNodeAddress']:
            bucket['byNodeAddress'][node_addr] = []
        bucket['byNodeAddress'][node_addr].append(validator)

    # Process buckets and add stats
    processed_buckets = []
    for bucket in buckets:
        validator_count = len(bucket['validators'])
        node_count = len(bucket['byNodeAddress'])

        if validator_count > 0:  # Only include non-empty buckets
            processed_buckets.append({
                'bucketIndex': bucket['bucketIndex'],
                'targetSweepTimeSeconds': bucket['targetSweepTimeSeconds'],
                'targetSweepTimeFormatted': bucket['targetSweepTimeFormatted'],
                'estimatedSweepTime': bucket['estimatedSweepTime'],
                'validatorCount': validator_count,
                'nodeAddressCount': node_count,
                'validators': bucket['validators'],
                'byNodeAddress': bucket['byNodeAddress']
            })

    # Create summary
    summary = {
        'totalValidators': len(sorted_results),
        'intervalHours': interval_hours,
        'totalBuckets': len(processed_buckets),
        'firstSweepTime': format_duration(first_sweep_seconds),
        'lastSweepTime': format_duration(last_sweep_seconds),
        'totalQueueDuration': format_duration(total_duration),
        'bucketsOverview': [
            {
                'bucket': b['bucketIndex'],
                'time': b['targetSweepTimeFormatted'],
                'validators': b['validatorCount'],
                'nodes': b['nodeAddressCount']
            }
            for b in processed_buckets
        ]
    }

    return {'buckets': processed_buckets, 'summary': summary}


def pick_representative_validators(buckets: List[Dict]) -> Dict:
    """
    Pick one representative validator per bucket (closest to target time)
    for display/analysis purposes. Note: Final selection uses round-robin
    distribution across all buckets for better coverage.

    Args:
        buckets: List of bucket dictionaries

    Returns:
        Dict with representatives and byNodeAddress grouping
    """
    representatives = []

    for bucket in buckets:
        if not bucket['validators']:
            continue

        # Find the validator closest to the bucket's target time
        target_time = bucket['targetSweepTimeSeconds']
        closest = bucket['validators'][0]
        min_diff = abs(closest['secondsUntilSweep'] - target_time)

        for validator in bucket['validators']:
            diff = abs(validator['secondsUntilSweep'] - target_time)
            if diff < min_diff:
                min_diff = diff
                closest = validator

        representatives.append({
            'bucketIndex': bucket['bucketIndex'],
            'targetTime': bucket['targetSweepTimeFormatted'],
            'validator': closest
        })

    # Group representatives by node address
    by_node = {}
    for rep in representatives:
        node_addr = rep['validator'].get('nodeAddress', rep['validator'].get('etherfi_node', 'unknown'))
        if node_addr not in by_node:
            by_node[node_addr] = []
        by_node[node_addr].append(rep)

    return {'representatives': representatives, 'byNodeAddress': by_node}

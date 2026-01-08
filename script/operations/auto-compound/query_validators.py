#!/usr/bin/env python3
"""
query_validators.py - Query validators from database for auto-compounding

This script queries the EtherFi validator database to find validators
that need to be converted from 0x01 to 0x02 (auto-compounding) credentials.

It also checks the beacon chain API to filter out validators that are
already consolidated (have 0x02 credentials).

Features:
- Bucket-based selection: Groups validators by expected withdrawal time
- Round-robin distribution: Ensures even coverage across withdrawal timeline
- EigenPod grouping: Prepares validators for consolidation by withdrawal credentials

Usage:
    python3 script/operations/auto-compound/query_validators.py --list-operators
    python3 script/operations/auto-compound/query_validators.py --operator "Validation Cloud" --count 50
    python3 script/operations/auto-compound/query_validators.py --operator-address 0x123... --count 100 --include-consolidated --bucket-hours 6

Examples:
    # Get 50 validators distributed across withdrawal time buckets
    python3 query_validators.py --operator "Validation Cloud" --count 50

    # Use 12-hour bucket intervals for finer time distribution
    python3 query_validators.py --operator "Validation Cloud" --count 50 --bucket-hours 12

Environment Variables:
    VALIDATOR_DB: PostgreSQL connection string for validator database

Output:
    JSON file with validator data suitable for AutoCompound.s.sol
    Validators are distributed across withdrawal time buckets for optimal consolidation
"""

import argparse
import json
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


def get_db_connection():
    """Get database connection from environment variable."""
    db_url = os.environ.get('VALIDATOR_DB')
    if not db_url:
        raise ValueError("VALIDATOR_DB environment variable not set")
    return psycopg2.connect(db_url)


# Beacon Chain Constants
VALIDATORS_PER_SLOT = 16  # Validators processed per slot in withdrawal sweep
SLOTS_PER_EPOCH = 32      # Slots per epoch
SECONDS_PER_SLOT = 12     # Seconds per slot
VALIDATORS_PER_SECOND = VALIDATORS_PER_SLOT / SECONDS_PER_SLOT


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

    from datetime import datetime
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


def spread_validators_across_queue(sorted_results: List[Dict], interval_hours: int = 6) -> Dict:
    """
    Spread validators across the withdrawal queue at fixed intervals.

    Args:
        sorted_results: Results sorted by sweep time (ascending)
        interval_hours: Interval between buckets (default 6 hours)

    Returns:
        Dict with buckets and summary
    """
    from datetime import datetime

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


def load_operators_from_db(conn) -> Tuple[Dict[str, str], Dict[str, str]]:
    """Load operators from OperatorMetadata table."""
    address_to_name = {}
    name_to_address = {}
    
    with conn.cursor() as cur:
        cur.execute('SELECT "operatorAdress", "operatorName" FROM "OperatorMetadata"')
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
    """List all operators with validator counts from MainnetValidators table."""
    address_to_name, _ = load_operators_from_db(conn)
    
    operators = []
    with conn.cursor() as cur:
        # Query using the correct column name: node_operator
        # Count restaked validators (the ones we care about for consolidation)
        cur.execute('''
            SELECT 
                LOWER(node_operator) as operator_addr,
                COUNT(*) as total_validators,
                COUNT(*) FILTER (WHERE restaked = true) as restaked_count
            FROM "MainnetValidators"
            WHERE node_operator IS NOT NULL
            AND status != 'exited'
            GROUP BY LOWER(node_operator)
            ORDER BY total_validators DESC
        ''')
        
        for row in cur.fetchall():
            addr = row[0] if row[0] else None
            operators.append({
                'address': addr,
                'name': address_to_name.get(addr, 'Unknown'),
                'total': row[1],
                'restaked': row[2]
            })
    
    return operators


def query_validators(
    conn,
    operator_address: str,
    count: int,
    restaked_only: bool = True,
    phase_filter: Optional[str] = None
) -> List[Dict]:
    """
    Query validators from MainnetValidators table by node operator.
    
    Args:
        conn: PostgreSQL connection
        operator_address: Node operator address (normalized lowercase)
        count: Maximum number of validators to return
        restaked_only: Only return restaked validators (default: True)
        phase_filter: Optional phase filter (e.g., 'LIVE', 'EXITED')
    
    Returns:
        List of validator dictionaries
    """
    query = """
        SELECT
            pubkey,
            etherfi_id as id,
            beacon_withdrawal_credentials as withdrawal_credentials,
            restaked,
            phase,
            status,
            beacon_index as index,
            etherfi_node_contract
        FROM "MainnetValidators"
        WHERE LOWER(node_operator) = %s
        AND status LIKE %s
    """

    params = [operator_address.lower(), '%active%']
    
    if restaked_only:
        query += " AND restaked = true"
    
    if phase_filter:
        query += " AND phase = %s"
        params.append(phase_filter)
    
    query += ' ORDER BY etherfi_id LIMIT %s'
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
                'etherfi_node': row['etherfi_node_contract'],
                'phase': row['phase'],
                'status': row['status'],
                'restaked': row['restaked'],
                'index': row['index']
            })
    
    return validators


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


def convert_to_output_format(validators: List[Dict]) -> List[Dict]:
    """
    Convert database validator records to output JSON format.
    
    Converts the EigenPod address to full 32-byte withdrawal credentials format.
    """
    result = []
    for validator in validators:
        pubkey = validator['pubkey']

        # Convert withdrawal credentials from EigenPod address to full format
        # Database stores: EigenPod address (20 bytes)
        # We need: 0x01 + 11 zero bytes + 20 byte EigenPod address (32 bytes total)
        withdrawal_creds = validator.get('withdrawal_credentials')
        if withdrawal_creds and withdrawal_creds.strip():
            # If it's just an address (42 chars = 0x + 40 hex), convert to full format
            if len(withdrawal_creds) == 42:
                addr_part = withdrawal_creds[2:]  # Remove 0x prefix
                # Format as withdrawal credentials: 0x01 + 22 zeros + address
                withdrawal_creds = '0x01' + '0' * 22 + addr_part
        else:
            # This should not happen after our filtering, but handle gracefully
            withdrawal_creds = None

        result.append({
            'id': validator['id'],
            'pubkey': pubkey,
            'withdrawal_credentials': withdrawal_creds,
            'etherfi_node': validator['etherfi_node'],
            'status': validator['status'],
            'index': validator['index']
        })

    return result


def write_output(validators: List[Dict], output_file: str, operator_name: str):
    """Write validators to JSON file."""
    output = convert_to_output_format(validators)
    
    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2)
    
    print(f"\nWrote {len(validators)} validators to {output_file}")
    print(f"Operator: {operator_name}")

    # Group by withdrawal credentials to show EigenPod distribution
    wc_groups = {}
    ungrouped_validators = []

    for v in validators:
        wc = v.get('withdrawal_credentials')
        if wc and wc.strip():  # Check if withdrawal_credentials exists and is not empty
            wc_groups[wc] = wc_groups.get(wc, 0) + 1
        else:
            ungrouped_validators.append(v)

    total_grouped = sum(wc_groups.values())
    print(f"\nEigenPod Analysis:")
    print(f"  Total validators: {len(validators)}")
    print(f"  Grouped into EigenPods: {total_grouped}")
    print(f"  Ungrouped (no withdrawal credentials): {len(ungrouped_validators)}")
    print(f"  Number of EigenPods: {len(wc_groups)}")

    if len(wc_groups) > 1:
        print("\nEigenPod distribution:")
        for wc, count in sorted(wc_groups.items(), key=lambda x: x[1], reverse=True)[:5]:
            print(f"  {wc}: {count} validators")
        if len(wc_groups) > 5:
            remaining = sum(count for wc, count in sorted(wc_groups.items(), key=lambda x: x[1], reverse=True)[5:])
            print(f"  ... and {remaining} validators in {len(wc_groups) - 5} other EigenPods")

    if ungrouped_validators:
        print(f"\n⚠️  WARNING: {len(ungrouped_validators)} validators have no withdrawal credentials:")
        for v in ungrouped_validators[:5]:  # Show first 5
            pubkey_short = v.get('pubkey', 'unknown')[:10] + '...' if v.get('pubkey') else 'unknown'
            print(f"  - Validator {v.get('id', 'unknown')} ({pubkey_short})")
        if len(ungrouped_validators) > 5:
            print(f"  ... and {len(ungrouped_validators) - 5} more")

        print(f"\nThese validators cannot be processed by the AutoCompound contract!")
        print(f"Consider excluding them or fixing their withdrawal credentials.")
    
    # Print next steps
    print(f"\n=== Next Steps ===")
    print(f"Run the AutoCompound script to generate Gnosis Safe transactions:")
    print(f"The script will group validators by EigenPod and create separate consolidation")
    print(f"transactions for each withdrawal credential group.")
    print(f"")
    print(f"  JSON_FILE={os.path.basename(output_file)} forge script \\")
    print(f"    script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \\")
    print(f"    --fork-url $MAINNET_RPC_URL -vvvv")


def main():
    parser = argparse.ArgumentParser(
        description='Query validators from database for auto-compounding'
    )
    parser.add_argument(
        '--operator',
        help='Operator name (e.g., "Validation Cloud")'
    )
    parser.add_argument(
        '--operator-address',
        help='Operator address (e.g., 0x123...)'
    )
    parser.add_argument(
        '--count',
        type=int,
        default=50,
        help='Number of validators to query (default: 50)'
    )
    parser.add_argument(
        '--output',
        default='validators.json',
        help='Output JSON file (default: validators.json)'
    )
    parser.add_argument(
        '--list-operators',
        action='store_true',
        help='List all operators with validator counts'
    )
    parser.add_argument(
        '--include-non-restaked',
        action='store_true',
        help='Include validators that are not restaked (default: only restaked)'
    )
    parser.add_argument(
        '--include-consolidated',
        action='store_true',
        help='Include validators that are already consolidated (0x02). Default: exclude them'
    )
    parser.add_argument(
        '--phase',
        choices=['LIVE', 'EXITED', 'FULLY_WITHDRAWN', 'WAITING_FOR_APPROVAL', 'READY_FOR_DEPOSIT'],
        help='Filter validators by phase (optional)'
    )
    parser.add_argument(
        '--beacon-api',
        default='https://beaconcha.in/api/v1',
        help='Beacon chain API base URL (default: https://beaconcha.in/api/v1)'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Show detailed information about filtered validators'
    )
    parser.add_argument(
        '--use-sweep-bucketing',
        action='store_true',
        default=True,
        help='Enable sweep-time-aware bucketing for balanced distribution across withdrawal queue'
    )
    parser.add_argument(
        '--bucket-hours',
        type=int,
        default=6,
        help='Bucket size in hours for sweep time distribution (default: 6)'
    )
    
    args = parser.parse_args()

    # Validate bucket-hours argument
    if args.bucket_hours <= 0:
        print(f"Error: --bucket-hours must be a positive integer, got {args.bucket_hours}")
        print("Bucket hours must be greater than 0 to avoid division by zero errors.")
        sys.exit(1)

    try:
        conn = get_db_connection()
    except ValueError as e:
        print(f"Error: {e}")
        print("Set VALIDATOR_DB environment variable to your PostgreSQL connection string")
        sys.exit(1)
    except Exception as e:
        print(f"Database connection error: {e}")
        sys.exit(1)
    
    try:
        if args.list_operators:
            operators = list_operators(conn)
            print("\n=== Operators ===")
            print(f"{'Name':<30} {'Address':<44} {'Total':>8} {'Restaked':>10}")
            print("-" * 95)
            for op in operators:
                addr_display = op['address'] if op['address'] else 'N/A'
                print(f"{op['name']:<30} {addr_display:<44} {op['total']:>8} {op['restaked']:>10}")
            return
        
        # Resolve operator
        if args.operator_address:
            operator_address = args.operator_address.lower()
            address_to_name, _ = load_operators_from_db(conn)
            operator_name = address_to_name.get(operator_address, 'Unknown')
        elif args.operator:
            operator_address = get_operator_address(conn, args.operator)
            if not operator_address:
                print(f"Error: Operator '{args.operator}' not found")
                print("Use --list-operators to see available operators")
                sys.exit(1)
            operator_name = args.operator
        else:
            print("Error: Must specify --operator or --operator-address")
            parser.print_help()
            sys.exit(1)
        
        restaked_only = not args.include_non_restaked
        
        # Query all validators for the operator, then filter and limit after
        # This ensures we get exactly the right number of non-consolidated validators
        MAX_VALIDATORS_QUERY = 100000
        query_count = MAX_VALIDATORS_QUERY if not args.include_consolidated else args.count
        
        print(f"Querying validators for {operator_name} ({operator_address})")
        print(f"  Target count: {args.count}")
        print(f"  Restaked only: {restaked_only}")
        if args.phase:
            print(f"  Phase filter: {args.phase}")
        
        validators = query_validators(
            conn,
            operator_address,
            query_count,
            restaked_only=restaked_only,
            phase_filter=args.phase
        )
        
        if not validators:
            print(f"No validators found matching criteria")
            sys.exit(1)
        
        print(f"  Found {len(validators)} validators from database")
        
        # Filter out already consolidated validators (0x02) if needed
        if not args.include_consolidated:
            print(f"\nChecking consolidation status on beacon chain...")
            print("(This may take a while for large validator sets)")
            
            filtered_validators, consolidated_validators = filter_consolidated_validators(
                validators,
                exclude_consolidated=True,
                beacon_api=args.beacon_api,
                show_progress=True
            )
            
            print(f"\nFiltered results:")
            print(f"  Already consolidated (0x02): {len(consolidated_validators)}")
            print(f"  Need consolidation (0x01): {len(filtered_validators)}")
            
            if consolidated_validators and args.verbose:
                print("\nConsolidated validators (skipped):")
                for v in consolidated_validators[:10]:
                    print(f"  - ID {v.get('id')}: {v.get('pubkey', '')[:20]}...")
                if len(consolidated_validators) > 10:
                    print(f"  ... and {len(consolidated_validators) - 10} more")
            
            # Apply sweep-time-aware bucketing if enabled
            if args.use_sweep_bucketing:
                print(f"\nApplying sweep-time-aware bucketing ({args.bucket_hours}h intervals)...")

                try:
                    # Fetch beacon chain state for sweep calculations
                    beacon_state = fetch_beacon_state()
                    sweep_index = beacon_state['next_withdrawal_validator_index']
                    total_validators = beacon_state['validator_count']

                    print(f"  Sweep index: {sweep_index:,}")
                    print(f"  Total validators: {total_validators:,}")

                    # Calculate sweep times for all validators
                    print("  Calculating sweep times...")
                    sweep_results = []
                    excluded_count = 0
                    for validator in filtered_validators:
                        validator_index = validator.get('index')
                        if validator_index is not None:
                            sweep_info = calculate_sweep_time(validator_index, sweep_index, total_validators)
                            sweep_results.append({
                                'pubkey': validator['pubkey'],
                                'validatorIndex': validator['id'],  # Use id as validatorIndex for compatibility
                                'nodeAddress': validator.get('etherfi_node', 'unknown'),
                                'balance': '0.00',  # Not available in current data
                                'secondsUntilSweep': sweep_info['secondsUntilSweep'],
                                'estimatedSweepTime': sweep_info['estimatedSweepTime'],
                                'positionInQueue': sweep_info['positionInQueue'],
                                # Include original validator data
                                **validator
                            })
                        else:
                            excluded_count += 1

                    # Sort by sweep time
                    sweep_results.sort(key=lambda x: x['secondsUntilSweep'])

                    print(f"  ✓ Calculated sweep times for {len(sweep_results)} validators")

                    # Warn about excluded validators
                    if excluded_count > 0:
                        print(f"  ⚠ Warning: {excluded_count} validators excluded due to missing beacon index")
                        print("    This may happen when validators haven't been indexed on the beacon chain yet")

                    # Spread validators across queue
                    bucket_result = spread_validators_across_queue(sweep_results, args.bucket_hours)
                    buckets = bucket_result['buckets']
                    summary = bucket_result['summary']

                    # Display bucket overview
                    print(f"\nSweep time bucket overview:")
                    print("-" * 60)
                    print(f"{'Bucket':<6} {'Target Time':<14} {'Validators':<12} {'Node Addrs'}")
                    print("-" * 60)
                    for bucket_info in summary['bucketsOverview'][:10]:  # Show first 10
                        print(f"{bucket_info['bucket']:<6} {bucket_info['time']:<14} {bucket_info['validators']:<12} {bucket_info['nodes']}")

                    if len(summary['bucketsOverview']) > 10:
                        print(f"... and {len(summary['bucketsOverview']) - 10} more buckets")

                    # Distribute validator selection across all buckets
                    selected_validators = []

                    # Collect validators from each bucket and sort by proximity to target time
                    bucket_validators = []
                    for bucket in buckets:
                        bucket_vals = bucket['validators'][:]
                        # Sort by proximity to target sweep time
                        target_time = bucket['targetSweepTimeSeconds']
                        bucket_vals.sort(key=lambda v: abs(v.get('secondsUntilSweep', 0) - target_time))
                        bucket_validators.append(bucket_vals)

                    # Round-robin selection across buckets until we reach target count
                    bucket_count = len(bucket_validators)
                    bucket_selection_counts = [0] * bucket_count

                    if bucket_count > 0:
                        round_num = 0

                        while len(selected_validators) < args.count:
                            added_this_round = 0

                            for bucket_idx in range(bucket_count):
                                if len(selected_validators) >= args.count:
                                    break

                                bucket_vals = bucket_validators[bucket_idx]
                                if round_num < len(bucket_vals):
                                    validator = bucket_vals[round_num]
                                    if validator not in selected_validators:
                                        selected_validators.append(validator)
                                        bucket_selection_counts[bucket_idx] += 1
                                        added_this_round += 1

                            # If no validators were added this round, we've exhausted all buckets
                            if added_this_round == 0:
                                break

                            round_num += 1

                    validators = selected_validators

                    print(f"\nSelected {len(validators)} validators distributed across {len(buckets)} buckets:")
                    for i, bucket in enumerate(buckets):
                        if bucket_selection_counts[i] > 0:
                            print(f"  Bucket {bucket['bucketIndex']} ({bucket['targetSweepTimeFormatted']}): {bucket_selection_counts[i]} validators")

                    if len(validators) < args.count:
                        print(f"Warning: Only selected {len(validators)} validators (requested {args.count})")
                        print("This may happen when buckets have limited validators available or some validators were excluded")

                except Exception as e:
                    print(f"Warning: Failed to apply sweep bucketing: {e}")
                    print("Falling back to standard selection...")
                    # Fallback to regular selection
                    if len(filtered_validators) >= args.count:
                        validators = filtered_validators[:args.count]
                    else:
                        validators = filtered_validators
            else:
                # Take only the requested number (original logic)
                if len(filtered_validators) >= args.count:
                    validators = filtered_validators[:args.count]
                else:
                    validators = filtered_validators

            if len(validators) == 0:
                print("\nError: No validators need consolidation (all are already consolidated)")
                sys.exit(1)

        else:
            validators = validators[:args.count]

        # Filter out validators without proper withdrawal credentials
        # These cannot be processed by the AutoCompound contract
        valid_validators = []
        invalid_validators = []

        for v in validators:
            wc = v.get('withdrawal_credentials')
            if wc and wc.strip() and len(wc.strip()) > 0:
                # Additional check: ensure it's a valid EigenPod address format
                if wc.startswith('0x') and len(wc) == 42:  # Standard Ethereum address format
                    valid_validators.append(v)
                else:
                    invalid_validators.append(v)
            else:
                invalid_validators.append(v)

        if invalid_validators:
            print(f"\n⚠️  FILTERING: {len(invalid_validators)} validators excluded due to invalid/missing withdrawal credentials:")
            for v in invalid_validators[:3]:  # Show first 3
                pubkey_short = v.get('pubkey', 'unknown')[:10] + '...' if v.get('pubkey') else 'unknown'
                wc = v.get('withdrawal_credentials', 'None')
                print(f"  - Validator {v.get('id', 'unknown')} ({pubkey_short}): WC={wc}")
            if len(invalid_validators) > 3:
                print(f"  ... and {len(invalid_validators) - 3} more")

            print(f"\n✓ Proceeding with {len(valid_validators)} validators that have valid withdrawal credentials")

        validators = valid_validators

        if len(validators) == 0:
            print("\n❌ ERROR: No validators remaining after filtering out those without valid withdrawal credentials")
            print("This suggests a data integrity issue - please check the validator database")
            sys.exit(1)

        write_output(validators, args.output, operator_name)
        
    finally:
        conn.close()


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
query_validators.py - Query validators from database for auto-compounding

This script queries the EtherFi validator database to find validators
that need to be converted from 0x01 to 0x02 (auto-compounding) credentials.

It also checks the beacon chain API to filter out validators that are
already consolidated (have 0x02 credentials).

Usage:
    python3 script/operations/auto-compound/query_validators.py --list-operators
    python3 script/operations/auto-compound/query_validators.py --operator "Validation Cloud" --count 50
    python3 script/operations/auto-compound/query_validators.py --operator-address 0x123... --count 100 --include-consolidated

Environment Variables:
    VALIDATOR_DB: PostgreSQL connection string for validator database

Output:
    JSON file with validator data suitable for AutoCompound.s.sol
"""

import argparse
import json
import os
import sys
import time
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
        withdrawal_creds = validator['withdrawal_credentials']
        if withdrawal_creds:
            # If it's just an address (42 chars = 0x + 40 hex), convert to full format
            if len(withdrawal_creds) == 42:
                addr_part = withdrawal_creds[2:]  # Remove 0x prefix
                # Format as withdrawal credentials: 0x01 + 22 zeros + address
                withdrawal_creds = '0x01' + '0' * 22 + addr_part
        
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
    for v in validators:
        wc = v['withdrawal_credentials']
        wc_groups[wc] = wc_groups.get(wc, 0) + 1
    
    print(f"\nValidators grouped into {len(wc_groups)} EigenPod(s)")
    if len(wc_groups) > 1:
        print("Note: Validators belong to multiple EigenPods:")
        for wc, count in sorted(wc_groups.items(), key=lambda x: x[1], reverse=True)[:5]:
            print(f"  {wc}: {count} validators")
    
    # Print next steps
    print(f"\n=== Next Steps ===")
    print(f"Run the AutoCompound script to generate Gnosis Safe transactions:")
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
    
    args = parser.parse_args()
    
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
            
            # Take only the requested number
            if len(filtered_validators) >= args.count:
                validators = filtered_validators[:args.count]
            else:
                validators = filtered_validators
                if len(validators) == 0:
                    print("\nError: No validators need consolidation (all are already consolidated)")
                    sys.exit(1)
                print(f"\nWarning: Only found {len(validators)} non-consolidated validators (requested {args.count})")
        else:
            validators = validators[:args.count]
        
        write_output(validators, args.output, operator_name)
        
    finally:
        conn.close()


if __name__ == '__main__':
    main()

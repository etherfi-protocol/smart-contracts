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
import os
import sys
from pathlib import Path
from typing import Dict, List

# Add utils directory to path for imports
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'utils'))

# Import reusable utilities
from validator_utils import (
    get_db_connection,
    load_operators_from_db,
    get_operator_address,
    list_operators,
    query_validators,
    fetch_beacon_state,
    calculate_sweep_time,
    format_duration,
    filter_consolidated_validators,
    spread_validators_across_queue,
    pick_representative_validators,
)


# =============================================================================
# Compounding-Specific Functions
# =============================================================================

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
            operator = args.operator_address.lower()
            address_to_name, _ = load_operators_from_db(conn)
            operator_name = address_to_name.get(operator, 'Unknown')
        elif args.operator:
            operator = get_operator_address(conn, args.operator)
            if not operator:
                print(f"Error: Operator '{args.operator}' not found")
                print("Use --list-operators to see available operators")
                sys.exit(1)
            operator_name = args.operator
        else:
            print("Error: Must specify --operator or --operator-address")
            parser.print_help()
            sys.exit(1)
        
        # Query all validators for the operator, then filter and limit after
        # This ensures we get exactly the right number of non-consolidated validators
        MAX_VALIDATORS_QUERY = 100000
        query_count = MAX_VALIDATORS_QUERY if not args.include_consolidated else args.count
        
        print(f"Querying validators for {operator_name} ({operator})")
        print(f"  Target count: {args.count}")
        if args.phase:
            print(f"  Phase filter: {args.phase}")
        
        validators = query_validators(
            conn,
            operator,
            query_count,
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
                # Additional check: ensure it's a valid withdrawal credentials format
                # Accept both EigenPod address (42 chars: 0x + 40 hex) and full withdrawal credentials (66 chars: 0x + 64 hex)
                if wc.startswith('0x') and (len(wc) == 42 or len(wc) == 66):
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

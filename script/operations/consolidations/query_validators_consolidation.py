#!/usr/bin/env python3
"""
query_validators_consolidation.py - Query and select validators for consolidation

This script queries the EtherFi validator database to find validators for consolidation.
It selects target validators distributed across the withdrawal sweep queue, then assigns
source validators from matching withdrawal credential groups.

Features:
- Multi-target selection: Targets are auto-selected across sweep queue buckets
- Withdrawal credential grouping: Sources must match target's withdrawal credentials
- Balance overflow prevention: Targets won't exceed max_target_balance post-consolidation
- Sweep queue distribution: Ensures consolidations are spread across the withdrawal timeline

Usage:
    python3 query_validators_consolidation.py --list-operators
    python3 query_validators_consolidation.py --operator "Validation Cloud" --count 50
    python3 query_validators_consolidation.py --operator "Infstones" --count 100 --bucket-hours 6 --max-target-balance 2016

Examples:
    # Get 50 source validators distributed across targets in different sweep buckets
    python3 query_validators_consolidation.py --operator "Validation Cloud" --count 50

    # Use custom max target balance and bucket interval
    python3 query_validators_consolidation.py --operator "Validation Cloud" --count 50 --max-target-balance 1984 --bucket-hours 12

Environment Variables:
    VALIDATOR_DB: PostgreSQL connection string for validator database
    BEACON_CHAIN_URL: Beacon chain API URL (default: https://beaconcha.in/api/v1)

Output:
    JSON file with consolidation plan suitable for ConsolidateToTarget.s.sol
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Add the parent directory to sys.path to enable absolute imports
parent_dir = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(parent_dir))

from utils.validator_utils import (
    get_db_connection,
    load_operators_from_db,
    get_operator_address,
    list_operators,
    query_validators,
    fetch_beacon_state,
    fetch_validator_details_batch,
    calculate_sweep_time,
    filter_consolidated_validators,
    spread_validators_across_queue,
)


# =============================================================================
# Constants
# =============================================================================

MAX_EFFECTIVE_BALANCE = 2048  # ETH - Protocol max for compounding validators
DEFAULT_MAX_TARGET_BALANCE = 1900 # ETH 
DEFAULT_SOURCE_BALANCE = 32  # ETH - Standard validator balance
DEFAULT_BUCKET_HOURS = 6
BATCH_SIZE=58 # max number of validators that can be consolidated into a target in one transaction


# =============================================================================
# Withdrawal Credential Utilities
# =============================================================================

def extract_wc_address(withdrawal_credentials: str) -> Optional[str]:
    """
    Extract the 20-byte address from withdrawal credentials.
    
    Withdrawal credentials format:
    - Full format (66 chars): 0x01 + 22 zero chars + 40-char address
    - Address only (42 chars): 0x + 40-char address
    
    Returns:
        Lowercase address string (40 hex chars without 0x prefix) or None
    """
    if not withdrawal_credentials:
        return None
    
    wc = withdrawal_credentials.lower().strip()
    
    # Full format: 0x01 + 22 zeros + 40-char address (66 chars total)
    if len(wc) == 66:
        return wc[-40:]  # Last 40 hex chars = 20 bytes
    
    # Address only format (42 chars)
    if len(wc) == 42 and wc.startswith('0x'):
        return wc[2:]  # Remove 0x prefix
    
    return None


def group_by_withdrawal_credentials(validators: List[Dict]) -> Dict[str, List[Dict]]:
    """
    Group validators by their withdrawal credential address (EigenPod).
    
    Args:
        validators: List of validator dictionaries
    
    Returns:
        Dictionary mapping WC address -> list of validators
    """
    groups = {}
    ungrouped = []
    
    for v in validators:
        wc_address = extract_wc_address(v.get('withdrawal_credentials'))
        if wc_address:
            if wc_address not in groups:
                groups[wc_address] = []
            groups[wc_address].append(v)
        else:
            ungrouped.append(v)
    
    if ungrouped:
        print(f"  ⚠ Warning: {len(ungrouped)} validators have no withdrawal credentials (skipped)")
    
    return groups


def is_consolidated_credentials(withdrawal_credentials: str) -> bool:
    """Check if withdrawal credentials indicate 0x02 (consolidated) type."""
    if not withdrawal_credentials:
        return False
    return withdrawal_credentials.lower().startswith('0x02')


def format_full_withdrawal_credentials(wc_address: str, prefix: str = '01') -> str:
    """
    Format address as full 32-byte withdrawal credentials.
    
    Args:
        wc_address: 40-char hex address (without 0x prefix)
        prefix: Credential type prefix ('01' or '02')
    
    Returns:
        Full 66-char withdrawal credentials string
    """
    return f'0x{prefix}' + '0' * 22 + wc_address.lower()


# =============================================================================
# Balance & Capacity Calculations
# =============================================================================

def get_validator_balance_eth(validator: Dict) -> float:
    """
    Get validator balance in ETH.
    
    Tries multiple field names to accommodate different data sources.
    """
    # Try various balance field names
    for field in ['balance', 'balance_eth', 'effectivebalance', 'effective_balance']:
        if field in validator:
            bal = validator[field]
            if isinstance(bal, (int, float)):
                # If balance is in gwei, convert to ETH
                if bal > 10000:  # Likely gwei
                    return bal / 1e9
                return float(bal)
            try:
                bal_float = float(bal)
                if bal_float > 10000:
                    return bal_float / 1e9
                return bal_float
            except (ValueError, TypeError):
                continue
    
    # For source validators (0x01), missing balance is expected from DB and
    # DEFAULT_SOURCE_BALANCE is the intended planning assumption.
    # For existing 0x02 targets, missing balance must fail fast.
    if validator.get('_is_existing_target'):
        pubkey = validator.get('pubkey', '')
        short_pubkey = f"{pubkey[:14]}...{pubkey[-10:]}" if pubkey else "<unknown>"
        raise ValueError(
            "Missing beacon balance for existing 0x02 target "
            f"{short_pubkey}"
        )

    return DEFAULT_SOURCE_BALANCE

def calculate_consolidation_capacity(
    target_balance_eth: float,
    max_target_balance: float = DEFAULT_MAX_TARGET_BALANCE,
    source_balance: float = DEFAULT_SOURCE_BALANCE
) -> int:
    """
    Calculate how many source validators can consolidate into a target.
    
    Args:
        target_balance_eth: Current target balance in ETH
        max_target_balance: Maximum allowed post-consolidation balance
        source_balance: Expected source validator balance (default 32 ETH)
    
    Returns:
        Number of 32 ETH validators that can consolidate into target
    """
    remaining_capacity = max_target_balance - target_balance_eth
    return max(0, int(remaining_capacity // source_balance))


# =============================================================================
# Target Selection Logic
# =============================================================================

def select_targets_from_buckets(
    wc_groups: Dict[str, List[Dict]],
    buckets: List[Dict],
    max_target_balance: float,
    prefer_consolidated: bool = True
) -> Dict[str, Dict]:
    """
    Select target validators distributed across sweep queue buckets.
    
    For each withdrawal credential group, selects one target validator
    preferring those in different sweep queue buckets to maximize distribution.
    
    Args:
        wc_groups: Validators grouped by withdrawal credential address
        buckets: Sweep time buckets from spread_validators_across_queue
        max_target_balance: Maximum allowed post-consolidation balance
        prefer_consolidated: Prefer existing 0x02 validators as targets
    
    Returns:
        Dictionary mapping WC address -> selected target validator info
    """
    targets = {}
    bucket_usage = {b['bucketIndex']: 0 for b in buckets}
    
    # Build validator -> bucket mapping
    validator_to_bucket = {}
    for bucket in buckets:
        for v in bucket.get('validators', []):
            pubkey = v.get('pubkey', '')
            if pubkey:
                validator_to_bucket[pubkey.lower()] = bucket['bucketIndex']
    
    for wc_address, validators in wc_groups.items():
        if not validators:
            continue
        
        # Sort validators by preference:
        # 1. Already consolidated (0x02) - can still receive consolidations
        # 2. Lower bucket usage (spread across queue)
        # 3. Lower balance (more capacity)
        
        def target_score(v):
            is_02 = is_consolidated_credentials(v.get('beacon_withdrawal_credentials', v.get('withdrawal_credentials', '')))
            bucket_idx = validator_to_bucket.get(v.get('pubkey', '').lower(), 999)
            bucket_count = bucket_usage.get(bucket_idx, 0)
            balance = get_validator_balance_eth(v)
            
            # Score: (prefer 0x02, lower bucket usage, lower balance)
            return (
                0 if (is_02 and prefer_consolidated) else 1,
                bucket_count,
                balance
            )
        
        sorted_validators = sorted(validators, key=target_score)
        
        # Select first validator that has capacity
        for candidate in sorted_validators:
            balance = get_validator_balance_eth(candidate)
            capacity = calculate_consolidation_capacity(balance, max_target_balance)
            
            if capacity > 0:
                bucket_idx = validator_to_bucket.get(candidate.get('pubkey', '').lower(), 0)
                bucket_usage[bucket_idx] = bucket_usage.get(bucket_idx, 0) + 1
                
                targets[wc_address] = {
                    'validator': candidate,
                    'balance_eth': balance,
                    'capacity': capacity,
                    'bucket_index': bucket_idx
                }
                break
    
    return targets


# =============================================================================
# Consolidation Planning
# =============================================================================

def create_consolidation_plan(
    validators: List[Dict],
    count: int,
    max_target_balance: float,
    bucket_hours: int,
    existing_targets: List[Dict] = None
) -> Dict:
    """
    Create a consolidation plan with targets and sources.
    
    Args:
        validators: All eligible 0x01 validators (can be targets or sources)
        count: Number of source validators to consolidate
        max_target_balance: Maximum ETH balance for targets
        bucket_hours: Bucket interval for sweep queue distribution
        existing_targets: Existing 0x02 validators with capacity (target-only, never sources).
                         Must have 'balance_eth' populated from beacon chain.

    Returns:
        Consolidation plan dictionary
    """
    if existing_targets is None:
        existing_targets = []

    print(f"\n=== Creating Consolidation Plan ===")
    print(f"  Target count: {count} source validators")
    print(f"  Max target balance: {max_target_balance} ETH")
    print(f"  Bucket interval: {bucket_hours}h")
    if existing_targets:
        print(f"  Existing 0x02 targets with capacity: {len(existing_targets)}")

    # Step 1: Group validators by withdrawal credentials
    print(f"\nStep 1: Grouping by withdrawal credentials...")
    wc_groups = group_by_withdrawal_credentials(validators)
    print(f"  Found {len(wc_groups)} unique EigenPods (from 0x01 validators)")

    # Mark existing 0x02 targets so they are never used as sources
    for v in existing_targets:
        v['_is_existing_target'] = True

    # Group existing targets by WC and merge into wc_groups
    existing_target_groups = group_by_withdrawal_credentials(existing_targets)
    existing_target_wc_count = 0
    for wc_address, targets in existing_target_groups.items():
        if wc_address in wc_groups:
            wc_groups[wc_address].extend(targets)
        else:
            # 0x02 targets in pods that have no 0x01 sources - skip these
            # (nothing to consolidate into them from this operator's 0x01 pool)
            pass
        existing_target_wc_count += 1
    if existing_targets:
        print(f"  Added {len(existing_targets)} existing 0x02 targets across {existing_target_wc_count} EigenPods")

    for wc, vals in sorted(wc_groups.items(), key=lambda x: len(x[1]), reverse=True)[:5]:
        source_count_in_group = sum(1 for v in vals if not v.get('_is_existing_target'))
        target_count_in_group = sum(1 for v in vals if v.get('_is_existing_target'))
        extra = f" (+{target_count_in_group} existing 0x02)" if target_count_in_group else ""
        print(f"    {wc[:10]}...{wc[-6:]}: {source_count_in_group} validators{extra}")
    if len(wc_groups) > 5:
        print(f"    ... and {len(wc_groups) - 5} more EigenPods")
    
    # Step 2: Calculate sweep times and create buckets
    print(f"\nStep 2: Calculating sweep times...")
    try:
        beacon_state = fetch_beacon_state()
        sweep_index = beacon_state['next_withdrawal_validator_index']
        total_validators = beacon_state['validator_count']
        print(f"  Sweep index: {sweep_index:,}")
        print(f"  Total validators: {total_validators:,}")
    except Exception as e:
        print(f"  ⚠ Warning: Failed to fetch beacon state: {e}")
        print(f"  Using default values...")
        sweep_index = 0
        total_validators = 1200000

    # Add sweep time info to all validators (0x01 + existing 0x02 targets)
    all_validators = list(validators) + list(existing_targets)
    all_with_sweep = []
    for v in all_validators:
        validator_index = v.get('index')
        if validator_index is not None:
            sweep_info = calculate_sweep_time(validator_index, sweep_index, total_validators)
            v_with_sweep = {**v, **sweep_info}
            all_with_sweep.append(v_with_sweep)
    
    all_with_sweep.sort(key=lambda x: x.get('secondsUntilSweep', 0))
    print(f"  Calculated sweep times for {len(all_with_sweep)} validators")
    
    # Create buckets
    if all_with_sweep:
        bucket_result = spread_validators_across_queue(all_with_sweep, bucket_hours)
        buckets = bucket_result.get('buckets', [])
    else:
        buckets = []
    
    # Step 3: Select targets distributed across sweep queue buckets
    print(f"\nStep 3: Selecting targets from across withdrawal queue...")

    # Re-group validators with sweep info by WC
    wc_groups_with_sweep = {}
    for v in all_with_sweep:
        wc_address = extract_wc_address(v.get('withdrawal_credentials'))
        if wc_address:
            if wc_address not in wc_groups_with_sweep:
                wc_groups_with_sweep[wc_address] = []
            wc_groups_with_sweep[wc_address].append(v)

    # Use select_targets_from_buckets to pick targets spread across the withdrawal queue
    # (0x02 validators are preferred via prefer_consolidated=True)
    selected_targets = select_targets_from_buckets(
        wc_groups_with_sweep,
        buckets,
        max_target_balance,
        prefer_consolidated=True
    )
    print(f"  Selected {len(selected_targets)} targets across {len(buckets)} buckets")

    # Step 4: Create consolidation batches using the selected targets
    # Rules: 
    # - Each target is used only ONCE across all consolidation requests
    # - post_consolidation_balance_eth must never exceed max_target_balance
    # - If more sources remain after using a target, select a new target from remaining validators
    print(f"\nStep 4: Creating consolidation batches...")

    consolidations = []
    total_sources = 0
    used_target_pubkeys = set()  # Track used targets to prevent reuse

    # Build validator -> bucket mapping for selecting new targets
    validator_to_bucket = {}
    for bucket in buckets:
        for v in bucket.get('validators', []):
            pubkey = v.get('pubkey', '')
            if pubkey:
                validator_to_bucket[pubkey.lower()] = bucket['bucketIndex']

    # Process each WC group
    for wc_address, target_info in selected_targets.items():
        if total_sources >= count:
            break

        # Get all validators in this WC group
        wc_validators = wc_groups_with_sweep.get(wc_address, [])

        # Need at least 1 source (non-existing-target) + 1 target
        source_candidates = [v for v in wc_validators if not v.get('_is_existing_target')]
        if not source_candidates:
            continue

        # Sort: prefer existing 0x02 targets first (already consolidated, no linking needed),
        # then by balance (lowest first = more capacity)
        available_validators = sorted(wc_validators, key=lambda v: (
            0 if v.get('_is_existing_target') else 1,
            get_validator_balance_eth(v)
        ))

        # Keep consolidating until we run out of source validators or hit count
        # Need at least 1 source (non-existing-target) and 1 target candidate
        while total_sources < count and \
              any(not v.get('_is_existing_target') for v in available_validators) and \
              len(available_validators) >= 2:
            # Select a target from available validators (not yet used)
            target = None
            target_idx = None
            for idx, candidate in enumerate(available_validators):
                candidate_pubkey = candidate.get('pubkey', '').lower()
                if candidate_pubkey not in used_target_pubkeys:
                    candidate_balance = get_validator_balance_eth(candidate)
                    candidate_capacity = calculate_consolidation_capacity(candidate_balance, max_target_balance)
                    if candidate_capacity > 0:
                        target = candidate
                        target_idx = idx
                        break

            if target is None:
                break  # No valid target available in this WC group

            target_pubkey = target.get('pubkey', '').lower()
            target_balance = get_validator_balance_eth(target)
            bucket_idx = validator_to_bucket.get(target_pubkey, 0)

            # Mark target as used
            used_target_pubkeys.add(target_pubkey)

            # Get sources (all validators except the target, excluding existing 0x02 targets)
            sources_pool = [v for i, v in enumerate(available_validators)
                           if i != target_idx and not v.get('_is_existing_target')]

            # Select sources that fit within max_target_balance limit
            batch_sources = []
            running_balance = target_balance
            batch_limit = BATCH_SIZE - 1  # Reserve 1 slot for target

            for source in sources_pool:
                if len(batch_sources) >= batch_limit:
                    break
                if total_sources + len(batch_sources) >= count:
                    break

                source_balance = get_validator_balance_eth(source)
                new_balance = running_balance + source_balance

                # Only add source if it doesn't exceed max_target_balance
                if new_balance <= max_target_balance:
                    batch_sources.append(source)
                    running_balance = new_balance

            if not batch_sources:
                # Remove target from available and try next
                available_validators = [v for v in available_validators if v.get('pubkey', '').lower() != target_pubkey]
                continue

            # Build sources list with target as first element
            sources = [target] + batch_sources
            post_balance = running_balance

            # Calculate source total (includes target balance for reporting)
            source_total = sum(get_validator_balance_eth(s) for s in sources)

            consolidations.append({
                'target': target,
                'target_balance_eth': target_balance,
                'sources': sources,
                'source_total_eth': source_total,
                'post_consolidation_balance_eth': post_balance,
                'bucket_index': bucket_idx,
                'wc_address': wc_address
            })

            total_sources += len(batch_sources)

            # Remove used validators (target + sources) from available pool
            used_pubkeys = {s.get('pubkey', '').lower() for s in sources}
            available_validators = [v for v in available_validators if v.get('pubkey', '').lower() not in used_pubkeys]

    print(f"  Created {len(consolidations)} consolidation batches")
    print(f"  Total sources to consolidate: {total_sources}")
    print(f"  Unique targets used: {len(used_target_pubkeys)}")
    
    # Step 5: Validate the plan
    print(f"\nStep 5: Validating consolidation plan...")
    validation = validate_consolidation_plan(consolidations, max_target_balance)
    
    # Step 6: Generate summary with bucket distribution info
    bucket_distribution = {}
    for c in consolidations:
        bucket_key = f"bucket_{c['bucket_index']}"
        bucket_distribution[bucket_key] = bucket_distribution.get(bucket_key, 0) + 1
    
    existing_0x02_targets_used = sum(
        1 for c in consolidations if c['target'].get('_is_existing_target')
    )
    summary = {
        'total_targets': len(consolidations),
        'total_sources': sum(len(c['sources']) for c in consolidations),
        'total_eth_consolidated': sum(c['source_total_eth'] for c in consolidations),
        'existing_0x02_targets_used': existing_0x02_targets_used,
        'bucket_distribution': bucket_distribution,
        'withdrawal_credential_groups': len(set(c['wc_address'] for c in consolidations))
    }
    
    return {
        'consolidations': consolidations,
        'summary': summary,
        'validation': validation
    }


def validate_consolidation_plan(consolidations: List[Dict], max_target_balance: float) -> Dict:
    """
    Validate the consolidation plan for safety.

    Checks:
    1. All source validators share credentials with their target
    2. No target exceeds max balance post-consolidation
    3. No duplicate pubkeys across all consolidations
    4. Target in each batch is the first source (sources[0])
    """
    all_credentials_matched = True
    all_targets_under_capacity = True
    all_targets_are_first_source = True
    errors = []

    all_pubkeys = set()  # Track all pubkeys to prevent duplicates

    for c in consolidations:
        target_wc = extract_wc_address(c['target'].get('withdrawal_credentials'))
        target_pubkey = c['target'].get('pubkey', '').lower()

        # Check that target is the first source in the batch
        if c['sources'] and c['sources'][0].get('pubkey', '').lower() != target_pubkey:
            all_targets_are_first_source = False
            errors.append(f"Target {target_pubkey[:20]}... is not the first source in its batch")

        # Check post-consolidation balance
        if c['post_consolidation_balance_eth'] > max_target_balance:
            all_targets_under_capacity = False
            errors.append(f"Target {target_pubkey[:20]}... exceeds max balance: {c['post_consolidation_balance_eth']:.2f} ETH")

        # Check target pubkey uniqueness
        if target_pubkey in all_pubkeys:
            errors.append(f"Duplicate target pubkey: {target_pubkey[:20]}...")
        all_pubkeys.add(target_pubkey)

        for i, source in enumerate(c['sources']):
            source_wc = extract_wc_address(source.get('withdrawal_credentials'))
            source_pubkey = source.get('pubkey', '').lower()

            # Check credential match
            if source_wc != target_wc:
                all_credentials_matched = False
                errors.append(f"Source {source_pubkey[:20]}... WC mismatch with target")

            # Check for duplicates across all pubkeys (allow target to be sources[0])
            if source_pubkey in all_pubkeys and not (i == 0 and source_pubkey == target_pubkey):
                errors.append(f"Duplicate pubkey: {source_pubkey[:20]}...")
            all_pubkeys.add(source_pubkey)
    
    # Calculate sweep distribution score (0-1, higher is better)
    if consolidations:
        unique_buckets = len(set(c['bucket_index'] for c in consolidations))
        sweep_distribution_score = min(1.0, unique_buckets / len(consolidations))
    else:
        sweep_distribution_score = 0.0
    
    validation = {
        'all_credentials_matched': all_credentials_matched,
        'all_targets_under_capacity': all_targets_under_capacity,
        'all_targets_are_first_source': all_targets_are_first_source,
        'sweep_distribution_score': round(sweep_distribution_score, 2),
        'no_duplicate_pubkeys': len(errors) == 0 or not any('Duplicate' in e for e in errors),
        'errors': errors if errors else None
    }

    # Print validation results
    print(f"  ✓ Credentials matched: {validation['all_credentials_matched']}")
    print(f"  ✓ Targets under capacity: {validation['all_targets_under_capacity']}")
    print(f"  ✓ Targets are first source: {validation['all_targets_are_first_source']}")
    print(f"  ✓ Sweep distribution score: {validation['sweep_distribution_score']}")
    
    if errors:
        print(f"  ⚠ Validation errors:")
        for e in errors[:5]:
            print(f"    - {e}")
        if len(errors) > 5:
            print(f"    ... and {len(errors) - 5} more")
    
    return validation


# =============================================================================
# Output Generation
# =============================================================================

def convert_to_output_format(plan: Dict) -> Dict:
    """
    Convert consolidation plan to JSON output format for Solidity script.
    
    Output format is designed to be compatible with ValidatorHelpers.parseValidatorsFromJson()
    which expects each validator to have: pubkey, id, withdrawal_credentials
    """
    consolidations_output = []
    
    for c in plan['consolidations']:
        target = c['target']
        wc_address = c['wc_address']
        full_wc = format_full_withdrawal_credentials(wc_address)
        
        target_output = {
            'pubkey': target.get('pubkey', ''),
            'validator_index': target.get('index'),
            'id': target.get('id'),
            'current_balance_eth': c['target_balance_eth'],
            'is_existing_0x02': bool(target.get('_is_existing_target')),
            'withdrawal_credentials': full_wc,
            'sweep_bucket': f"bucket_{c['bucket_index']}"
        }
        
        sources_output = []
        for source in c['sources']:
            sources_output.append({
                'pubkey': source.get('pubkey', ''),
                'validator_index': source.get('index'),
                'id': source.get('id'),
                'balance_eth': get_validator_balance_eth(source),
                # Include withdrawal_credentials for ValidatorHelpers compatibility
                'withdrawal_credentials': full_wc
            })
        
        consolidations_output.append({
            'target': target_output,
            'sources': sources_output,
            'source_count': len(sources_output),
            'post_consolidation_balance_eth': c['post_consolidation_balance_eth']
        })
    
    return {
        'num_consolidations': len(consolidations_output),
        'consolidations': consolidations_output,
        'summary': plan['summary'],
        'validation': plan['validation'],
        'generated_at': datetime.now().isoformat()
    }


def write_targets_json(plan: Dict, output_dir: str) -> str:
    """
    Write a separate targets.json file with target validator info for linking.
    
    Contains: validatorId, pubkey, estimated sweep time, bucket index
    Used by ConsolidateToTarget.s.sol for linking validators.
    """
    targets_output = []
    seen_pubkeys = set()  # Deduplicate targets (same target may appear in multiple consolidations)
    
    for c in plan['consolidations']:
        target = c['target']
        pubkey = target.get('pubkey', '')
        
        # Skip duplicates (target may be used across multiple consolidation batches)
        if pubkey.lower() in seen_pubkeys:
            continue
        seen_pubkeys.add(pubkey.lower())
        
        targets_output.append({
            'id': target.get('id'),
            'pubkey': pubkey,
            'validator_index': target.get('index'),
            'estimated_sweep_seconds': target.get('secondsUntilSweep'),
            'estimated_sweep_time': target.get('estimatedSweepTime'),
            'bucket_index': c['bucket_index'],
            'current_balance_eth': c['target_balance_eth'],
            'withdrawal_credentials': format_full_withdrawal_credentials(c['wc_address'])
        })
    
    # Sort by bucket index for easier review
    targets_output.sort(key=lambda x: (x['bucket_index'], x.get('estimated_sweep_seconds', 0)))
    
    targets_file = os.path.join(output_dir, 'targets.json')
    with open(targets_file, 'w') as f:
        json.dump(targets_output, f, indent=2, default=str)
    
    return targets_file


def write_output(plan: Dict, output_file: str, operator_name: str):
    """Write consolidation plan to JSON file."""
    output = convert_to_output_format(plan)
    
    # Get output directory for targets.json
    output_dir = os.path.dirname(output_file) or '.'
    
    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2, default=str)
    
    # Write separate targets.json file
    targets_file = write_targets_json(plan, output_dir)
    
    print(f"\n=== Output Written ===")
    print(f"Consolidation data: {output_file}")
    print(f"Targets file: {targets_file}")
    print(f"Operator: {operator_name}")
    print(f"Total targets: {plan['summary']['total_targets']}")
    print(f"Total sources: {plan['summary']['total_sources']}")
    print(f"Total ETH to consolidate: {plan['summary']['total_eth_consolidated']:.2f}")
    
    # Print bucket distribution
    print(f"\nBucket distribution:")
    for bucket, count in sorted(plan['summary']['bucket_distribution'].items()):
        print(f"  {bucket}: {count} targets")
    
    # Print next steps
    print(f"\n=== Next Steps ===")
    print(f"Run the ConsolidateToTarget script with this data:")
    print(f"")
    print(f"  CONSOLIDATION_DATA={os.path.basename(output_file)} TARGETS_DATA={os.path.basename(targets_file)} \\")
    print(f"    forge script script/operations/consolidations/ConsolidateToTarget.s.sol:ConsolidateToTarget \\")
    print(f"    --fork-url $MAINNET_RPC_URL -vvvv")


# =============================================================================
# Main Entry Point
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Query validators from database for consolidation',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List all operators
  python3 query_validators_consolidation.py --list-operators

  # Get 50 source validators for consolidation
  python3 query_validators_consolidation.py --operator "Validation Cloud" --count 50

  # Custom max target balance and bucket interval
  python3 query_validators_consolidation.py --operator "Infstones" --count 100 \\
    --max-target-balance 1984 --bucket-hours 12

  # Dry run to preview plan without writing output
  python3 query_validators_consolidation.py --operator "Validation Cloud" --count 50 --dry-run
        """
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
        default=0,
        help='Number of source validators to consolidate (default: 0 = use all available)'
    )
    parser.add_argument(
        '--bucket-hours',
        type=int,
        default=DEFAULT_BUCKET_HOURS,
        help=f'Bucket size in hours for sweep time distribution (default: {DEFAULT_BUCKET_HOURS})'
    )
    parser.add_argument(
        '--max-target-balance',
        type=float,
        default=DEFAULT_MAX_TARGET_BALANCE,
        help=f'Maximum ETH balance allowed on target post-consolidation (default: {DEFAULT_MAX_TARGET_BALANCE})'
    )
    parser.add_argument(
        '--output',
        default='consolidation-data.json',
        help='Output JSON file (default: consolidation-data.json)'
    )
    parser.add_argument(
        '--list-operators',
        action='store_true',
        help='List all operators with validator counts'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Preview consolidation plan without writing output file'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Show detailed information'
    )
    parser.add_argument(
        '--beacon-api',
        default='https://beaconcha.in/api/v1',
        help='Beacon chain API base URL (default: https://beaconcha.in/api/v1)'
    )
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.bucket_hours <= 0:
        print(f"Error: --bucket-hours must be a positive integer, got {args.bucket_hours}")
        sys.exit(1)
    
    if args.max_target_balance > MAX_EFFECTIVE_BALANCE:
        print(f"Error: --max-target-balance cannot exceed {MAX_EFFECTIVE_BALANCE} ETH (protocol max)")
        sys.exit(1)
    
    if args.max_target_balance < DEFAULT_SOURCE_BALANCE * 2:
        print(f"Error: --max-target-balance must be at least {DEFAULT_SOURCE_BALANCE * 2} ETH")
        sys.exit(1)
    
    # Connect to database
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
            print(f"{'Name':<30} {'Address':<44} {'Total':>8}")
            print("-" * 85)
            for op in operators:
                addr_display = op['address'] if op['address'] else 'N/A'
                print(f"{op['name']:<30} {addr_display:<44} {op['total']:>8}")
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
        
        # Query validators - get more than needed to allow for filtering
        MAX_VALIDATORS_QUERY = 100000
        
        print(f"\n=== Querying Validators ===")
        print(f"Operator: {operator_name} ({operator_address})")
        print(f"Target source count: {args.count if args.count > 0 else 'all available'}")
        print(f"Max target balance: {args.max_target_balance} ETH")
        
        validators = query_validators(
            conn,
            operator_address,
            MAX_VALIDATORS_QUERY
        )
        
        if not validators:
            print(f"No validators found matching criteria")
            sys.exit(1)
        
        print(f"Found {len(validators)} validators from database")
        
        # Filter out already consolidated validators (we want 0x01 -> 0x02)
        print(f"\nChecking consolidation status on beacon chain...")
        filtered_validators, consolidated_validators = filter_consolidated_validators(
            validators,
            exclude_consolidated=True,
            beacon_api=args.beacon_api,
            show_progress=True
        )
        
        print(f"\nFiltered results:")
        print(f"  Already consolidated (0x02): {len(consolidated_validators)}")
        print(f"  Need consolidation (0x01): {len(filtered_validators)}")

        if len(filtered_validators) == 0:
            print("\nError: No validators need consolidation (all are already 0x02)")
            sys.exit(1)

        # Fetch beacon chain balances for existing 0x02 validators to use as targets
        existing_targets = []
        if consolidated_validators:
            print(f"\nFetching beacon chain balances for {len(consolidated_validators)} existing 0x02 validators...")
            consolidated_pubkeys = [v.get('pubkey', '') for v in consolidated_validators if v.get('pubkey')]
            beacon_details = fetch_validator_details_batch(consolidated_pubkeys, beacon_api=args.beacon_api)
            missing_balance_pubkeys = []

            for v in consolidated_validators:
                pubkey = v.get('pubkey', '')
                details = beacon_details.get(pubkey, {})
                is_consolidated = details.get('is_consolidated')
                balance_eth = details.get('balance_eth')

                # Strict mode: existing 0x02 targets must have resolvable beacon balances.
                if not details or is_consolidated is None or balance_eth is None:
                    missing_balance_pubkeys.append(pubkey)
                    continue

                if balance_eth > 0 and balance_eth < args.max_target_balance:
                    capacity = calculate_consolidation_capacity(balance_eth, args.max_target_balance)
                    if capacity > 0:
                        v['balance_eth'] = balance_eth
                        # Use beacon withdrawal credentials (already 0x02)
                        if details.get('beacon_withdrawal_credentials'):
                            v['beacon_withdrawal_credentials'] = details['beacon_withdrawal_credentials']
                        existing_targets.append(v)

            if missing_balance_pubkeys:
                print("\nError: Missing beacon balance for existing 0x02 validator targets.")
                print("Failed pubkeys:")
                for pk in missing_balance_pubkeys[:20]:
                    print(f"  - {pk}")
                if len(missing_balance_pubkeys) > 20:
                    print(f"  ... and {len(missing_balance_pubkeys) - 20} more")
                print("Aborting to avoid using fallback/default balances for existing 0x02 targets.")
                sys.exit(1)

            print(f"  0x02 validators with capacity (balance < {args.max_target_balance} ETH): {len(existing_targets)}")
            if existing_targets:
                total_capacity = sum(
                    calculate_consolidation_capacity(v['balance_eth'], args.max_target_balance)
                    for v in existing_targets
                )
                print(f"  Total additional capacity: ~{total_capacity} source validators")

        # Use all available validators if count is 0 (default)
        # Note: Use filtered_validators count (0x01 validators) not raw validators count
        source_count = args.count if args.count > 0 else len(filtered_validators)
        print(f"\nUsing source count: {source_count}")

        # Create consolidation plan
        plan = create_consolidation_plan(
            filtered_validators,
            source_count,
            args.max_target_balance,
            args.bucket_hours,
            existing_targets=existing_targets
        )
        
        if plan['summary']['total_sources'] == 0:
            print("\nError: Could not create any consolidations")
            print("This may happen if all validators are already targets or at capacity")
            sys.exit(1)
        
        # Check for validation errors
        if plan['validation'].get('errors'):
            print("\n⚠ WARNING: Validation errors found!")
            print("Review the plan carefully before proceeding.")
        
        # Write output or just preview
        if args.dry_run:
            print("\n=== DRY RUN - Plan Preview ===")
            output = convert_to_output_format(plan)
            print(json.dumps(output, indent=2, default=str))
            print("\n(Use without --dry-run to write to file)")
        else:
            write_output(plan, args.output, operator_name)
        
    finally:
        conn.close()


if __name__ == '__main__':
    main()

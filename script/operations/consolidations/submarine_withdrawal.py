#!/usr/bin/env python3
"""
submarine_withdrawal.py - Plan a large ETH withdrawal via validator consolidation

Withdraws a large amount of ETH by consolidating many validators within one or more
EigenPods into target validators. The excess above 2048 ETH per target gets automatically
swept by the beacon chain's withdrawal mechanism.

If a single EigenPod doesn't have enough ETH, the script splits across multiple pods,
starting from the largest and descending.

Key design:
  - Target validator is always vals[0] in every consolidation transaction
  - The first consolidation request in each tx is a self-consolidation (src=target, dst=target)
  - This auto-compounds 0x01 -> 0x02 if needed, with no separate step or waiting
  - Linking is done once for all validators

Usage:
    python3 submarine_withdrawal.py --operator "Cosmostation" --amount 10000
    python3 submarine_withdrawal.py --operator "Cosmostation" --amount 10000 --dry-run
    python3 submarine_withdrawal.py --list-operators

Environment Variables:
    VALIDATOR_DB: PostgreSQL connection string for validator database
    BEACON_CHAIN_URL: Beacon chain API URL (default: https://beaconcha.in/api/v1)
"""

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Add parent directory to sys.path for absolute imports
parent_dir = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(parent_dir))

from utils.validator_utils import (
    get_db_connection,
    get_operator_address,
    list_operators,
    query_validators,
    fetch_validator_details_batch,
)

from query_validators_consolidation import (
    extract_wc_address,
    group_by_withdrawal_credentials,
    is_consolidated_credentials,
    format_full_withdrawal_credentials,
    get_validator_balance_eth,
)

from generate_gnosis_txns import (
    generate_consolidation_calldata,
    encode_link_legacy_validators,
    normalize_pubkey,
    encode_address,
    encode_uint256,
    ETHERFI_NODES_MANAGER,
    ADMIN_EOA,
    DEFAULT_CHAIN_ID,
)


# =============================================================================
# Constants
# =============================================================================

MAX_EFFECTIVE_BALANCE = 2048  # ETH - protocol max for compounding validators
DEFAULT_SOURCE_BALANCE = 32   # ETH - standard validator balance
DEFAULT_BATCH_SIZE = 150      # validators per tx (including target at [0])
DEFAULT_FEE = 1               # wei per consolidation request
MIN_WITHDRAWAL_AMOUNT = 32    # ETH - minimum sensible withdrawal
MAX_VALIDATORS_QUERY = 100000


# =============================================================================
# Pod Evaluation
# =============================================================================

def get_balance(v: Dict) -> float:
    """Get a validator's balance, preferring beacon data."""
    return v.get('beacon_balance_eth', get_validator_balance_eth(v))


def evaluate_pod(wc_address: str, validators: List[Dict]) -> Dict:
    """
    Evaluate an EigenPod's capacity for submarine withdrawal.

    Returns a dict with pod stats and the best target candidate.
    Always returns a result (even for pods with < 2 validators).
    """
    total_eth = sum(get_balance(v) for v in validators)

    # Separate 0x02 and 0x01 validators
    consolidated = [v for v in validators if v.get('is_consolidated') is True]
    unconsolidated = [v for v in validators if v.get('is_consolidated') is not True]

    # Select target: prefer 0x02 with highest balance, else 0x01 with highest balance
    target = None
    is_target_0x02 = False
    if consolidated:
        consolidated.sort(key=get_balance, reverse=True)
        target = consolidated[0]
        is_target_0x02 = True
    elif unconsolidated:
        unconsolidated.sort(key=get_balance, reverse=True)
        target = unconsolidated[0]

    target_balance = get_balance(target) if target else 0
    available_sources = len(validators) - 1 if target else 0

    # Max withdrawal if we consolidate ALL sources into this target
    max_withdrawal = max(0, target_balance + available_sources * DEFAULT_SOURCE_BALANCE - MAX_EFFECTIVE_BALANCE)

    return {
        'wc_address': wc_address,
        'total_validators': len(validators),
        'total_eth': total_eth,
        'consolidated_count': len(consolidated),
        'unconsolidated_count': len([v for v in validators if v.get('is_consolidated') is False]),
        'target': target,
        'target_balance_eth': target_balance,
        'is_target_0x02': is_target_0x02,
        'available_sources': available_sources,
        'max_withdrawal_eth': max_withdrawal,
    }


def display_eigenpods_table(evaluations: List[Dict]):
    """Always print a table of all EigenPods for the operator."""
    # Sort by total ETH descending
    sorted_evals = sorted(evaluations, key=lambda e: e['total_eth'], reverse=True)

    print(f"\n  {'#':<4} {'EigenPod Address':<44} {'Vals':>6} {'0x02':>6} {'Total ETH':>12} {'Max Withdraw':>14}")
    print(f"  {'-' * 90}")

    total_vals = 0
    total_eth = 0
    total_max = 0
    for i, e in enumerate(sorted_evals, start=1):
        wc_addr = f"0x{e['wc_address']}"
        total_vals += e['total_validators']
        total_eth += e['total_eth']
        total_max += e['max_withdrawal_eth']
        print(f"  {i:<4} {wc_addr:<44} {e['total_validators']:>6} {e['consolidated_count']:>6} {e['total_eth']:>10,.0f} ETH {e['max_withdrawal_eth']:>12,.0f} ETH")

    print(f"  {'-' * 90}")
    print(f"  {'':4} {'TOTAL':<44} {total_vals:>6} {'':>6} {total_eth:>10,.0f} ETH {total_max:>12,.0f} ETH")


# =============================================================================
# Multi-Pod Selection
# =============================================================================

def select_pods_for_withdrawal(
    evaluations: List[Dict],
    wc_groups: Dict[str, List[Dict]],
    amount_eth: float,
) -> Tuple[List[Dict], float]:
    """
    Select one or more EigenPods to cover the requested withdrawal amount.

    Greedy approach: pick pods with the most max_withdrawal_eth first, descending.
    For the last pod, only use as many sources as needed.

    Returns:
        Tuple of (list of pod_selections, total_withdrawal_eth)
        Each pod_selection has: pod_eval, target, sources, withdrawal_eth, post_consolidation_eth
    """
    # Sort by max_withdrawal_eth descending
    candidates = [e for e in evaluations if e['max_withdrawal_eth'] > 0 and e['target'] is not None]
    candidates.sort(key=lambda e: e['max_withdrawal_eth'], reverse=True)

    selections = []
    remaining = amount_eth

    for pod_eval in candidates:
        if remaining <= 0:
            break

        wc_address = pod_eval['wc_address']
        pod_validators = wc_groups[wc_address]
        target = pod_eval['target']
        target_balance = pod_eval['target_balance_eth']

        # How many sources needed to cover the remaining amount (or all available)
        num_sources_needed = math.ceil((remaining + MAX_EFFECTIVE_BALANCE - target_balance) / DEFAULT_SOURCE_BALANCE)
        num_sources = min(num_sources_needed, pod_eval['available_sources'])

        # Select sources
        sources = select_sources(pod_validators, target, num_sources)
        actual_num_sources = len(sources)

        post_consolidation = target_balance + actual_num_sources * DEFAULT_SOURCE_BALANCE
        withdrawal = post_consolidation - MAX_EFFECTIVE_BALANCE

        selections.append({
            'pod_eval': pod_eval,
            'target': target,
            'sources': sources,
            'num_sources': actual_num_sources,
            'post_consolidation_eth': post_consolidation,
            'withdrawal_eth': withdrawal,
        })

        remaining -= withdrawal

    total_withdrawal = sum(s['withdrawal_eth'] for s in selections)
    return selections, total_withdrawal


def select_sources(
    pod_validators: List[Dict],
    target: Dict,
    num_sources: int,
) -> List[Dict]:
    """Select source validators from the pod (excluding target), lowest balance first."""
    target_pubkey = target.get('pubkey', '').lower()
    sources = [v for v in pod_validators if v.get('pubkey', '').lower() != target_pubkey]
    sources.sort(key=get_balance)
    return sources[:num_sources]


# =============================================================================
# Transaction Generation
# =============================================================================

def generate_consolidation_batches(
    target: Dict,
    sources: List[Dict],
    batch_size: int,
    fee_per_request: int,
    tx_start_index: int = 1,
) -> List[Dict]:
    """
    Generate consolidation transaction batches for one pod.

    Each batch has target as vals[0] (self-consolidation) + source validators.
    tx_start_index controls the numbering for multi-pod output.

    Returns:
        List of transaction dicts.
    """
    target_pubkey = target.get('pubkey', '')
    actual_sources_per_batch = batch_size - 1

    batches = []
    for i in range(0, len(sources), actual_sources_per_batch):
        batch_sources = sources[i:i + actual_sources_per_batch]
        batch_pubkeys = [target_pubkey] + [s.get('pubkey', '') for s in batch_sources]
        calldata = generate_consolidation_calldata(batch_pubkeys, target_pubkey)
        total_value = fee_per_request * len(batch_pubkeys)

        batches.append({
            'to': ETHERFI_NODES_MANAGER,
            'value': str(total_value),
            'data': calldata,
            'num_validators': len(batch_pubkeys),
            'num_sources': len(batch_sources),
            'target_pubkey': target_pubkey,
            'tx_index': tx_start_index + len(batches),
        })

    return batches


def collect_src0_ids_and_pubkeys(
    selections: List[Dict],
) -> Tuple[List[int], List[bytes]]:
    """Collect src[0] (== target) validator IDs and pubkeys for linking. One per pod."""
    seen_ids = set()
    seen_pubkeys = set()
    ids = []
    pubkeys = []

    for sel in selections:
        t = sel['target']
        vid = t.get('id')
        vpk = t.get('pubkey', '')
        pk_lower = vpk.lower()
        if vid is not None and vpk and vid not in seen_ids and pk_lower not in seen_pubkeys:
            seen_ids.add(vid)
            seen_pubkeys.add(pk_lower)
            ids.append(vid)
            pubkeys.append(normalize_pubkey(vpk))

    return ids, pubkeys


def compute_pubkey_hash(pubkey_hex: str) -> str:
    """Compute the SSZ validator pubkey hash: sha256(pubkey || 16_zero_bytes)."""
    pk = pubkey_hex[2:] if pubkey_hex.startswith('0x') else pubkey_hex
    pubkey_bytes = bytes.fromhex(pk)
    h = hashlib.sha256(pubkey_bytes + b'\x00' * 16).digest()
    return '0x' + h.hex()


def is_pubkey_linked(pubkey_hex: str, rpc_url: str) -> bool:
    """Check if a validator pubkey is already linked on-chain via etherFiNodeFromPubkeyHash."""
    pubkey_hash = compute_pubkey_hash(pubkey_hex)
    try:
        result = subprocess.run(
            ['cast', 'call', ETHERFI_NODES_MANAGER,
             'etherFiNodeFromPubkeyHash(bytes32)(address)',
             pubkey_hash,
             '--rpc-url', rpc_url],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            print(f"    Warning: Could not check linking status for {pubkey_hex[:20]}...")
            return False
        address = result.stdout.strip()
        return address != '0x0000000000000000000000000000000000000000'
    except Exception:
        return False


def filter_unlinked_validators(
    ids: List[int],
    pubkeys: List[bytes],
    rpc_url: str,
) -> Tuple[List[int], List[bytes]]:
    """Filter out already-linked validators, returning only those that need linking."""
    if not ids:
        return ids, pubkeys

    unlinked_ids = []
    unlinked_pubkeys = []

    for vid, pk_bytes in zip(ids, pubkeys):
        pk_hex = '0x' + pk_bytes.hex()
        linked = is_pubkey_linked(pk_hex, rpc_url)
        if linked:
            print(f"    Target {pk_hex[:20]}... (id={vid}) already linked, skipping")
        else:
            print(f"    Target {pk_hex[:20]}... (id={vid}) not linked, will include")
            unlinked_ids.append(vid)
            unlinked_pubkeys.append(pk_bytes)

    return unlinked_ids, unlinked_pubkeys


# =============================================================================
# Output Generation
# =============================================================================

def write_consolidation_data(
    selections: List[Dict],
    output_dir: str,
) -> str:
    """Write consolidation-data.json with one entry per pod."""
    consolidations = []
    total_sources = 0
    total_eth = 0

    for sel in selections:
        target = sel['target']
        sources = sel['sources']
        wc_address = sel['pod_eval']['wc_address']
        full_wc = format_full_withdrawal_credentials(wc_address)

        target_output = {
            'pubkey': target.get('pubkey', ''),
            'validator_index': target.get('index') or target.get('validator_index'),
            'id': target.get('id'),
            'current_balance_eth': get_balance(target),
            'withdrawal_credentials': full_wc,
        }

        # sources[0] = target for self-consolidation
        sources_output = [{
            'pubkey': target.get('pubkey', ''),
            'validator_index': target.get('index') or target.get('validator_index'),
            'id': target.get('id'),
            'balance_eth': get_balance(target),
            'withdrawal_credentials': full_wc,
        }]
        for source in sources:
            sources_output.append({
                'pubkey': source.get('pubkey', ''),
                'validator_index': source.get('index') or source.get('validator_index'),
                'id': source.get('id'),
                'balance_eth': get_balance(source),
                'withdrawal_credentials': full_wc,
            })

        consolidations.append({
            'target': target_output,
            'sources': sources_output,
            'post_consolidation_balance_eth': sel['post_consolidation_eth'],
            'withdrawal_amount_gwei': int(round(sel['withdrawal_eth'] * 1e9)),
        })

        total_sources += len(sources_output)
        total_eth += sel['post_consolidation_eth']

    output = {
        'consolidations': consolidations,
        'summary': {
            'total_targets': len(selections),
            'total_sources': total_sources,
            'total_eth_consolidated': total_eth,
            'withdrawal_credential_groups': len(selections),
        },
        'generated_at': datetime.now().isoformat(),
    }

    filepath = os.path.join(output_dir, 'consolidation-data.json')
    with open(filepath, 'w') as f:
        json.dump(output, f, indent=2, default=str)
    return filepath


def write_linking_transaction(
    validator_ids: List[int],
    pubkeys: List[bytes],
    chain_id: int,
    from_address: str,
    output_dir: str,
) -> Optional[str]:
    """Generate link-validators.json with a single batched linkLegacyValidatorIds call."""
    if not validator_ids or not pubkeys:
        return None

    print(f"\n  Generating linking transaction for {len(validator_ids)} src[0] validator(s)...")

    # Batch all validators into a single linkLegacyValidatorIds(uint256[],bytes[]) call
    link_calldata = encode_link_legacy_validators(validator_ids, pubkeys)

    tx_data = {
        "chainId": str(chain_id),
        "from": from_address,
        "transactions": [{
            "to": ETHERFI_NODES_MANAGER,
            "value": "0",
            "data": "0x" + link_calldata.hex(),
            "description": f"Link {len(validator_ids)} validator(s): ids={validator_ids}",
        }],
        "description": f"Link {len(validator_ids)} src[0] validator(s) via ADMIN_EOA",
    }

    filepath = os.path.join(output_dir, "link-validators.json")
    with open(filepath, 'w') as f:
        json.dump(tx_data, f, indent=2)
    print(f"  Written: link-validators.json")
    return filepath


def write_transaction_files(
    all_batches: List[Dict],
    output_dir: str,
    chain_id: int = DEFAULT_CHAIN_ID,
    from_address: str = ADMIN_EOA,
) -> List[str]:
    """Write each consolidation batch as a raw transaction JSON file for direct EOA execution."""
    written = []
    for batch in all_batches:
        idx = batch['tx_index']
        tx_data = {
            "chainId": str(chain_id),
            "from": from_address,
            "transactions": [{
                "to": batch['to'],
                "value": batch['value'],
                "data": batch['data'],
            }],
            "metadata": {
                "target_pubkey": batch['target_pubkey'],
                "num_validators": batch['num_validators'],
            },
            "description": f"Submarine Consolidation Batch {idx}: {batch['num_sources']} sources into target (vals[0])",
        }
        filename = f"consolidation-txns-{idx}.json"
        filepath = os.path.join(output_dir, filename)
        with open(filepath, 'w') as f:
            json.dump(tx_data, f, indent=2)
        written.append(filepath)
    return written


def write_submarine_plan(
    selections: List[Dict],
    all_batches: List[Dict],
    amount_eth: float,
    total_withdrawal: float,
    operator_name: str,
    output_dir: str,
    needs_linking: bool,
) -> str:
    """Write submarine-plan.json with full plan metadata."""
    pods_info = []
    for sel in selections:
        pe = sel['pod_eval']
        t = sel['target']
        pods_info.append({
            'eigenpod': f"0x{pe['wc_address']}",
            'target_pubkey': t.get('pubkey', ''),
            'target_id': t.get('id'),
            'target_balance_eth': pe['target_balance_eth'],
            'is_target_0x02': pe['is_target_0x02'],
            'num_sources': sel['num_sources'],
            'post_consolidation_eth': sel['post_consolidation_eth'],
            'withdrawal_eth': sel['withdrawal_eth'],
        })

    num_batches = len(all_batches)
    plan = {
        'type': 'submarine_withdrawal',
        'operator': operator_name,
        'requested_amount_eth': amount_eth,
        'total_withdrawal_eth': total_withdrawal,
        'num_pods_used': len(selections),
        'pods': pods_info,
        'transactions': {
            'linking': 1 if needs_linking else 0,
            'consolidation': num_batches,
            'queue_withdrawals': len(selections),
            'total': (1 if needs_linking else 0) + num_batches + len(selections),
        },
        'consolidation': {
            'total_sources': sum(s['num_sources'] for s in selections),
            'num_transactions': num_batches,
        },
        'files': {
            'link_validators': 'link-validators.json' if needs_linking else None,
            'consolidation_txns': [f'consolidation-txns-{b["tx_index"]}.json' for b in all_batches],
            'queue_withdrawals': 'post-sweep/queue-withdrawals.json',
        },
        'execution_order': [],
        'generated_at': datetime.now().isoformat(),
    }

    step = 1
    if needs_linking:
        plan['execution_order'].append(f"{step}. Execute link-validators.json from ADMIN_EOA")
        step += 1
    for b in all_batches:
        plan['execution_order'].append(f"{step}. Execute consolidation-txns-{b['tx_index']}.json from ADMIN_EOA")
        step += 1
    plan['execution_order'].append(f"{step}. Wait for beacon chain consolidation + sweep (excess above 2048 ETH is auto-withdrawn)")
    step += 1
    plan['execution_order'].append(f"{step}. Execute queue-withdrawals.json from ADMIN_EOA (queueETHWithdrawal for each pod)")
    step += 1
    plan['execution_order'].append(f"{step}. Wait for EigenLayer withdrawal delay, then completeQueuedETHWithdrawals")

    filepath = os.path.join(output_dir, 'submarine-plan.json')
    with open(filepath, 'w') as f:
        json.dump(plan, f, indent=2, default=str)
    return filepath


# =============================================================================
# Queue ETH Withdrawal Transaction Generation
# =============================================================================

QUEUE_ETH_WITHDRAWAL_SELECTOR = "03f49be8"  # queueETHWithdrawal(address,uint256)


def get_node_address(validator_id: int, rpc_url: str) -> Optional[str]:
    """Resolve EtherFi node address from a legacy validator ID via on-chain query.

    Uses etherfiNodeAddress(uint256) which works for legacy IDs without linking.
    """
    try:
        result = subprocess.run(
            ['cast', 'call', ETHERFI_NODES_MANAGER,
             'etherfiNodeAddress(uint256)(address)',
             str(validator_id),
             '--rpc-url', rpc_url],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            print(f"    Warning: Could not resolve node for validator id={validator_id}")
            return None
        address = result.stdout.strip()
        if address == '0x0000000000000000000000000000000000000000':
            print(f"    Warning: Node address is zero for validator id={validator_id}")
            return None
        return address
    except Exception:
        return None


def encode_queue_eth_withdrawal(node_address: str, amount_wei: int) -> str:
    """Encode queueETHWithdrawal(address,uint256) calldata."""
    selector = bytes.fromhex(QUEUE_ETH_WITHDRAWAL_SELECTOR)
    params = encode_address(node_address) + encode_uint256(amount_wei)
    return "0x" + (selector + params).hex()


def write_queue_withdrawal_transactions(
    selections: List[Dict],
    output_dir: str,
    chain_id: int,
    from_address: str,
    rpc_url: str,
) -> Optional[str]:
    """
    Generate queue-withdrawals.json with queueETHWithdrawal calls for each pod.

    Each pod selection has a target pubkey and withdrawal_eth amount.
    Resolves node addresses on-chain and encodes calldata.
    All calls are bundled into a single transaction file for gas efficiency.
    """
    if not rpc_url:
        print("  Warning: MAINNET_RPC_URL not set, writing queue-withdrawals metadata only")

    transactions = []
    for sel in selections:
        target = sel['target']
        target_pubkey = target.get('pubkey', '')
        target_id = target.get('id')
        withdrawal_eth = sel['withdrawal_eth']
        withdrawal_gwei = int(round(withdrawal_eth * 1e9))
        withdrawal_wei = withdrawal_gwei * (10 ** 9)

        node_address = None
        if rpc_url and target_id is not None:
            node_address = get_node_address(target_id, rpc_url)
            if node_address:
                print(f"    Target id={target_id} -> node {node_address}")

        tx_entry = {
            "target_pubkey": target_pubkey,
            "target_id": target_id,
            "withdrawal_amount_gwei": withdrawal_gwei,
            "withdrawal_amount_eth": withdrawal_eth,
            "node_address": node_address,
            "to": ETHERFI_NODES_MANAGER,
            "value": "0",
        }

        if node_address:
            tx_entry["data"] = encode_queue_eth_withdrawal(node_address, withdrawal_wei)
        else:
            tx_entry["data"] = "0x"
            tx_entry["requires_resolution"] = True

        transactions.append(tx_entry)

    tx_data = {
        "chainId": str(chain_id),
        "from": from_address,
        "transactions": transactions,
        "description": f"Queue ETH withdrawals for {len(transactions)} pod(s) after beacon chain consolidation + sweep",
    }

    # Write to post-sweep/ subdirectory to avoid simulate.py auto-discovery
    post_sweep_dir = os.path.join(output_dir, "post-sweep")
    os.makedirs(post_sweep_dir, exist_ok=True)
    filepath = os.path.join(post_sweep_dir, "queue-withdrawals.json")
    with open(filepath, 'w') as f:
        json.dump(tx_data, f, indent=2)
    print(f"  Written: post-sweep/queue-withdrawals.json ({len(transactions)} withdrawal(s))")
    return filepath


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Plan a large ETH withdrawal via submarine consolidation',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List operators
  python3 submarine_withdrawal.py --list-operators

  # Preview plan for 10k ETH withdrawal
  python3 submarine_withdrawal.py --operator "Cosmostation" --amount 10000 --dry-run

  # Generate all transaction files
  python3 submarine_withdrawal.py --operator "Cosmostation" --amount 10000

  # Custom batch size and output directory
  python3 submarine_withdrawal.py --operator "Cosmostation" --amount 10000 --batch-size 100 --output-dir ./my-txns
        """
    )
    parser.add_argument('--operator', help='Operator name (e.g., "Cosmostation")')
    parser.add_argument('--amount', type=float, help='ETH amount to withdraw')
    parser.add_argument('--output-dir', help='Output directory (auto-generated if omitted)')
    parser.add_argument('--batch-size', type=int, default=DEFAULT_BATCH_SIZE,
                        help=f'Validators per tx including target at [0] (default: {DEFAULT_BATCH_SIZE})')
    parser.add_argument('--fee', type=int, default=DEFAULT_FEE,
                        help=f'Fee per consolidation request in wei (default: {DEFAULT_FEE})')
    parser.add_argument('--dry-run', action='store_true', help='Preview plan without writing files')
    parser.add_argument('--list-operators', action='store_true', help='List available operators')
    parser.add_argument('--beacon-api', default='https://beaconcha.in/api/v1',
                        help='Beacon chain API base URL')

    args = parser.parse_args()

    # Validate
    if not args.list_operators and not args.operator:
        print("Error: --operator is required (or use --list-operators)")
        parser.print_help()
        sys.exit(1)

    if not args.list_operators and not args.amount:
        print("Error: --amount is required")
        parser.print_help()
        sys.exit(1)

    if args.amount and args.amount < MIN_WITHDRAWAL_AMOUNT:
        print(f"Error: --amount must be at least {MIN_WITHDRAWAL_AMOUNT} ETH")
        sys.exit(1)

    # Connect to DB
    try:
        conn = get_db_connection()
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)

    try:
        # List operators
        if args.list_operators:
            operators = list_operators(conn)
            print(f"\n{'Name':<30} {'Address':<44} {'Validators':>10}")
            print("-" * 88)
            for op in operators:
                addr = op['address'] or 'N/A'
                print(f"{op['name']:<30} {addr:<44} {op['total']:>10}")
            return

        # Resolve operator
        operator_address = get_operator_address(conn, args.operator)
        if not operator_address:
            print(f"Error: Operator '{args.operator}' not found")
            print("Use --list-operators to see available operators")
            sys.exit(1)

        print(f"\n{'=' * 60}")
        print(f"SUBMARINE WITHDRAWAL PLANNER")
        print(f"{'=' * 60}")
        print(f"Operator:        {args.operator} ({operator_address})")
        print(f"Target amount:   {args.amount:,.0f} ETH")
        print(f"Batch size:      {args.batch_size}")
        print(f"Fee/request:     {args.fee} wei")
        print()

        # ================================================================
        # Step 1: Query validators
        # ================================================================
        print("Step 1: Querying validators from database...")
        validators = query_validators(conn, operator_address, MAX_VALIDATORS_QUERY)
        if not validators:
            print("Error: No validators found for this operator")
            sys.exit(1)
        print(f"  Found {len(validators)} validators")

        # ================================================================
        # Step 2: Fetch beacon chain details (balance + consolidation status)
        # ================================================================
        print("\nStep 2: Fetching beacon chain details (balance + status)...")
        pubkeys = [v.get('pubkey', '') for v in validators if v.get('pubkey')]
        details = fetch_validator_details_batch(pubkeys, beacon_api=args.beacon_api)

        for v in validators:
            pk = v.get('pubkey', '')
            if pk in details:
                d = details[pk]
                v['beacon_balance_eth'] = d['balance_eth']
                v['is_consolidated'] = d['is_consolidated']
                v['beacon_withdrawal_credentials'] = d['beacon_withdrawal_credentials']
                if d['validator_index'] is not None:
                    v['validator_index'] = d['validator_index']

        consolidated_count = sum(1 for v in validators if v.get('is_consolidated') is True)
        unconsolidated_count = sum(1 for v in validators if v.get('is_consolidated') is False)
        unknown_count = len(validators) - consolidated_count - unconsolidated_count
        print(f"  0x02 (consolidated):     {consolidated_count}")
        print(f"  0x01 (unconsolidated):   {unconsolidated_count}")
        if unknown_count > 0:
            print(f"  Unknown status:          {unknown_count}")

        # ================================================================
        # Step 3: Group by EigenPod and display table
        # ================================================================
        print("\nStep 3: Grouping by EigenPod (withdrawal credentials)...")
        wc_groups = group_by_withdrawal_credentials(validators)
        print(f"  Found {len(wc_groups)} unique EigenPods")

        # Evaluate all pods
        evaluations = []
        for wc_address, pod_validators in wc_groups.items():
            evaluations.append(evaluate_pod(wc_address, pod_validators))

        # Always print the full pod table
        display_eigenpods_table(evaluations)

        # ================================================================
        # Step 4: Select pods for withdrawal
        # ================================================================
        print(f"\nStep 4: Selecting EigenPods for {args.amount:,.0f} ETH withdrawal...")

        total_max = sum(e['max_withdrawal_eth'] for e in evaluations)
        if total_max < args.amount:
            print(f"\n  Error: Total max withdrawal across ALL pods is {total_max:,.0f} ETH")
            print(f"  Requested: {args.amount:,.0f} ETH")
            print(f"  The operator does not have enough validators.")
            sys.exit(1)

        selections, total_withdrawal = select_pods_for_withdrawal(evaluations, wc_groups, args.amount)

        if not selections:
            print("  Error: Could not select any pods for withdrawal")
            sys.exit(1)

        # ================================================================
        # Step 5: Print plan summary
        # ================================================================
        actual_sources_per_batch = args.batch_size - 1
        total_sources = sum(s['num_sources'] for s in selections)
        total_batches = sum(math.ceil(s['num_sources'] / actual_sources_per_batch) for s in selections)

        print(f"\n{'=' * 60}")
        print(f"SUBMARINE WITHDRAWAL PLAN")
        print(f"{'=' * 60}")
        print(f"Pods used:                   {len(selections)}")
        print(f"Total sources:               {total_sources}")
        print(f"Total transactions:          {total_batches}")
        print(f"Requested amount:            {args.amount:,.0f} ETH")
        print(f"Total auto-withdrawal:       {total_withdrawal:,.2f} ETH")
        surplus = total_withdrawal - args.amount
        if surplus > 0:
            print(f"Surplus over requested:      {surplus:,.2f} ETH")

        for i, sel in enumerate(selections, start=1):
            pe = sel['pod_eval']
            t = sel['target']
            pod_batches = math.ceil(sel['num_sources'] / actual_sources_per_batch)
            print(f"\n  Pod {i}: 0x{pe['wc_address']}")
            print(f"    Target pubkey:           {t.get('pubkey', '')[:20]}...")
            print(f"    Target ID:               {t.get('id')}")
            print(f"    Target balance:          {pe['target_balance_eth']:.2f} ETH")
            print(f"    Target is 0x02:          {'Yes' if pe['is_target_0x02'] else 'No (auto-compound via vals[0])'}")
            print(f"    Sources:                 {sel['num_sources']}")
            print(f"    Post-consolidation:      {sel['post_consolidation_eth']:,.2f} ETH")
            print(f"    Auto-withdrawal:         {sel['withdrawal_eth']:,.2f} ETH")
            print(f"    Transactions:            {pod_batches}")

        if args.dry_run:
            print(f"\n(Dry run - no files written)")
            return

        # ================================================================
        # Step 6: Generate output files
        # ================================================================
        print(f"\nStep 6: Generating output files...")

        if args.output_dir:
            output_dir = args.output_dir
        else:
            script_dir = Path(__file__).resolve().parent
            timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
            operator_slug = args.operator.replace(' ', '_').lower()
            output_dir = str(script_dir / 'txns' / f"{operator_slug}_submarine_{int(args.amount)}eth_{timestamp}")

        os.makedirs(output_dir, exist_ok=True)

        # 6a: consolidation-data.json
        write_consolidation_data(selections, output_dir)
        print(f"  Written: consolidation-data.json")

        # 6b: link-validators.json (only link src[0] per batch, i.e. the target pubkey per pod)
        all_ids, all_pubkeys = collect_src0_ids_and_pubkeys(selections)
        chain_id = int(os.environ.get('CHAIN_ID', DEFAULT_CHAIN_ID))
        admin_address = os.environ.get('ADMIN_ADDRESS', ADMIN_EOA)
        rpc_url = os.environ.get('MAINNET_RPC_URL', '')

        needs_linking = False
        if all_ids:
            print(f"\n  Checking on-chain linking status for {len(all_ids)} src[0] validator(s)...")
            if rpc_url:
                all_ids, all_pubkeys = filter_unlinked_validators(all_ids, all_pubkeys, rpc_url)
            else:
                print("    Warning: MAINNET_RPC_URL not set, skipping on-chain link check")

        if all_ids:
            link_file = write_linking_transaction(
                all_ids, all_pubkeys, chain_id, admin_address, output_dir,
            )
            needs_linking = link_file is not None
        else:
            print("  All src[0] validators already linked, no linking transaction needed.")

        # 6c: consolidation-txns-N.json (sequentially numbered across all pods)
        all_batches = []
        tx_index = 1
        for sel in selections:
            batches = generate_consolidation_batches(
                sel['target'], sel['sources'], args.batch_size, args.fee, tx_start_index=tx_index,
            )
            all_batches.extend(batches)
            tx_index += len(batches)

        tx_files = write_transaction_files(all_batches, output_dir, chain_id, admin_address)
        for f in tx_files:
            print(f"  Written: {os.path.basename(f)}")

        # 6d: queue-withdrawals.json (queueETHWithdrawal per pod)
        write_queue_withdrawal_transactions(
            selections, output_dir, chain_id, admin_address, rpc_url,
        )

        # 6e: submarine-plan.json
        write_submarine_plan(
            selections, all_batches, args.amount, total_withdrawal,
            args.operator, output_dir, needs_linking,
        )
        print(f"  Written: submarine-plan.json")

        # ================================================================
        # Summary
        # ================================================================
        print(f"\n{'=' * 60}")
        print(f"OUTPUT COMPLETE")
        print(f"{'=' * 60}")
        print(f"Directory: {output_dir}")
        print(f"\nExecution order:")
        step = 1
        if needs_linking:
            print(f"  {step}. Execute link-validators.json from ADMIN_EOA")
            step += 1
        for b in all_batches:
            print(f"  {step}. Execute consolidation-txns-{b['tx_index']}.json from ADMIN_EOA")
            step += 1
        print(f"  {step}. Wait for beacon chain consolidation + sweep")
        step += 1
        print(f"  {step}. Execute queue-withdrawals.json from ADMIN_EOA (queueETHWithdrawal)")
        step += 1
        print(f"  {step}. Wait for EigenLayer withdrawal delay, then completeQueuedETHWithdrawals")
        print()
        total_requests = sum(b['num_validators'] for b in all_batches)
        print(f"Each consolidation request costs {args.fee} wei.")
        print(f"Total requests: {total_requests} ({total_requests * args.fee / 1e18:.18f} ETH in fees)")
        total_withdrawal_eth = sum(s['withdrawal_eth'] for s in selections)
        print(f"Total ETH to queue for withdrawal: {total_withdrawal_eth:,.2f} ETH across {len(selections)} pod(s)")
        print()

    finally:
        conn.close()


if __name__ == '__main__':
    main()

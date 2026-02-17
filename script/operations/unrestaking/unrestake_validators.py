#!/usr/bin/env python3
"""
unrestake_validators.py - Unrestake validators for an operator

Queues ETH withdrawals from EigenPods for a given operator, accounting for
any pending withdrawal roots already queued on-chain.

Flow:
  1. Query operator's pods and total balances from the DB
  2. Check pending withdrawals on each node via DelegationManager
  3. Compute available (unrestakable) ETH per pod
  4. Greedily select pods to fulfill the requested amount
  5. Generate queueETHWithdrawal transaction files

Usage:
    python3 unrestake_validators.py --operator "Cosmostation" --amount 1000
    python3 unrestake_validators.py --operator "Cosmostation" --amount 1000 --dry-run
    python3 unrestake_validators.py --list-operators

Environment Variables:
    VALIDATOR_DB: PostgreSQL connection string for validator database
    MAINNET_RPC_URL: Ethereum mainnet RPC URL (required for pending withdrawal checks)
"""

import argparse
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
)

from consolidations.generate_gnosis_txns import (
    encode_address,
    encode_uint256,
    ETHERFI_NODES_MANAGER,
    ADMIN_EOA,
    DEFAULT_CHAIN_ID,
)


# =============================================================================
# Constants
# =============================================================================

DELEGATION_MANAGER = "0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A"
QUEUE_ETH_WITHDRAWAL_SELECTOR = "03f49be8"
MIN_WITHDRAWAL_AMOUNT = 32  # ETH


# =============================================================================
# Database Queries
# =============================================================================

def query_operator_pods(
    conn,
    operator_address: str,
) -> List[Dict]:
    """Query pods and their total balances for an operator.

    Returns list of dicts with node_address, eigenpod, validator_count,
    total_balance_eth.
    """
    query = """
        SELECT
            node_address,
            '0x' || RIGHT(withdrawal_credentials, 40) AS eigenpod,
            COUNT(*) AS validator_count,
            SUM(balance) AS total_balance_wei,
            SUM(balance) / 1e18 AS total_balance_eth
        FROM etherfi_validators
        WHERE timestamp = (
            SELECT MAX(timestamp) FROM etherfi_validators
        )
          AND status = 'active_ongoing'
          AND operator = %s
        GROUP BY node_address, withdrawal_credentials
        ORDER BY total_balance_eth DESC
    """
    pods = []
    with conn.cursor() as cur:
        cur.execute(query, (operator_address,))
        for row in cur.fetchall():
            pods.append({
                'node_address': row[0],
                'eigenpod': row[1],
                'validator_count': row[2],
                'total_balance_wei': int(row[3]) if row[3] else 0,
                'total_balance_eth': float(row[4]) if row[4] else 0.0,
            })
    return pods


# =============================================================================
# On-chain Pending Withdrawal Queries
# =============================================================================

def get_pending_withdrawal_eth(
    node_address: str,
    rpc_url: str,
) -> float:
    """Query pending (queued) withdrawal ETH for a node.

    Calls getQueuedWithdrawals(address) on DelegationManager without a
    return-type annotation so cast returns raw ABI hex. We then decode
    only the uint256[][] (second return element) to avoid double-counting
    shares that also appear inside each Withdrawal struct.
    """
    try:
        result = subprocess.run(
            [
                'cast', 'call', DELEGATION_MANAGER,
                'getQueuedWithdrawals(address)',
                node_address,
                '--rpc-url', rpc_url,
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            print(
                f"    Warning: getQueuedWithdrawals failed for "
                f"{node_address}: {result.stderr.strip()}"
            )
            return 0.0

        raw_hex = result.stdout.strip()
        if not raw_hex or raw_hex == '0x':
            return 0.0

        return _decode_shares_from_raw(raw_hex)
    except subprocess.TimeoutExpired:
        print(
            f"    Warning: Timeout querying pending withdrawals "
            f"for {node_address}"
        )
        return 0.0
    except Exception as e:
        print(
            f"    Warning: Exception querying pending withdrawals "
            f"for {node_address}: {e}"
        )
        return 0.0


def _decode_shares_from_raw(raw_hex: str) -> float:
    """Decode uint256[][] shares from getQueuedWithdrawals ABI output.

    Return type is (Withdrawal[], uint256[][]). We extract only the
    second element to avoid double-counting shares that also appear
    inside each Withdrawal struct.

    ABI layout of the top-level tuple:
      word 0: offset to Withdrawal[] encoding
      word 1: offset to uint256[][] encoding
    """
    hex_str = raw_hex[2:] if raw_hex.startswith('0x') else raw_hex
    if len(hex_str) < 128:
        return 0.0

    data = bytes.fromhex(hex_str)

    # Offset to uint256[][] (second tuple element)
    shares_offset = int.from_bytes(data[32:64], 'big')
    if shares_offset + 32 > len(data):
        return 0.0

    num_withdrawals = int.from_bytes(
        data[shares_offset:shares_offset + 32], 'big',
    )
    if num_withdrawals == 0:
        return 0.0

    head_start = shares_offset + 32
    total_shares_wei = 0

    for i in range(num_withdrawals):
        offset_pos = head_start + i * 32
        if offset_pos + 32 > len(data):
            break

        inner_offset = int.from_bytes(
            data[offset_pos:offset_pos + 32], 'big',
        )
        inner_pos = head_start + inner_offset
        if inner_pos + 32 > len(data):
            break

        inner_count = int.from_bytes(
            data[inner_pos:inner_pos + 32], 'big',
        )

        for j in range(inner_count):
            val_pos = inner_pos + 32 + j * 32
            if val_pos + 32 > len(data):
                break
            val = int.from_bytes(
                data[val_pos:val_pos + 32], 'big',
            )
            total_shares_wei += val

    return total_shares_wei / 1e18


# =============================================================================
# Pod Evaluation
# =============================================================================

def evaluate_pods(
    pods: List[Dict],
    rpc_url: str,
) -> List[Dict]:
    """Enrich pods with pending withdrawal data and available ETH."""
    for pod in pods:
        node = pod['node_address']
        if rpc_url and node:
            pending = get_pending_withdrawal_eth(node, rpc_url)
        else:
            pending = 0.0

        pod['pending_withdrawal_eth'] = pending
        pod['available_eth'] = max(
            0.0,
            pod['total_balance_eth'] - pending,
        )

    return pods


def display_pods_table(pods: List[Dict]):
    """Print a table of all EigenPods for the operator."""
    print(
        f"\n  {'#':<4} {'Node Address':<44} "
        f"{'Vals':>6} {'Total ETH':>12} "
        f"{'Pending':>12} {'Available':>12}"
    )
    print(f"  {'-' * 94}")

    total_vals = 0
    total_eth = 0.0
    total_pending = 0.0
    total_available = 0.0

    for i, pod in enumerate(pods, start=1):
        node = pod['node_address'] or 'N/A'
        total_vals += pod['validator_count']
        total_eth += pod['total_balance_eth']
        total_pending += pod['pending_withdrawal_eth']
        total_available += pod['available_eth']

        print(
            f"  {i:<4} {node:<44} "
            f"{pod['validator_count']:>6} "
            f"{pod['total_balance_eth']:>10,.0f} ETH "
            f"{pod['pending_withdrawal_eth']:>10,.0f} ETH "
            f"{pod['available_eth']:>10,.0f} ETH"
        )

    print(f"  {'-' * 94}")
    print(
        f"  {'':4} {'TOTAL':<44} "
        f"{total_vals:>6} "
        f"{total_eth:>10,.0f} ETH "
        f"{total_pending:>10,.0f} ETH "
        f"{total_available:>10,.0f} ETH"
    )


# =============================================================================
# Pod Selection
# =============================================================================

def select_pods(
    pods: List[Dict],
    amount_eth: float,
    whole_eth: bool = False,
) -> Tuple[List[Dict], float]:
    """Select pods to cover the requested unrestake amount.

    Greedy: sort by available_eth descending, take from each pod until
    the requested amount is fulfilled.

    Args:
        whole_eth: If True, floor each pod's withdrawal to whole ETH.
            Used with --amount 0 to avoid fractional withdrawals.

    Returns (selected_pods_with_withdrawal_amount, total_withdrawal_eth).
    """
    candidates = [p for p in pods if p['available_eth'] > 0]
    candidates.sort(key=lambda p: p['available_eth'], reverse=True)

    selections = []
    remaining = amount_eth

    for pod in candidates:
        if remaining <= 0:
            break

        withdrawal = min(pod['available_eth'], remaining)
        if whole_eth:
            withdrawal = math.floor(withdrawal)
        if withdrawal <= 0:
            continue
        selections.append({
            **pod,
            'withdrawal_eth': withdrawal,
        })
        remaining -= withdrawal

    total = sum(s['withdrawal_eth'] for s in selections)
    return selections, total


# =============================================================================
# Transaction Generation
# =============================================================================

def encode_queue_eth_withdrawal(
    node_address: str,
    amount_wei: int,
) -> str:
    """Encode queueETHWithdrawal(address,uint256) calldata."""
    selector = bytes.fromhex(QUEUE_ETH_WITHDRAWAL_SELECTOR)
    params = encode_address(node_address) + encode_uint256(amount_wei)
    return "0x" + (selector + params).hex()


def write_transactions(
    selections: List[Dict],
    output_dir: str,
    chain_id: int,
    from_address: str,
) -> Optional[str]:
    """Write queue-withdrawals.json with queueETHWithdrawal calls."""
    transactions = []
    for sel in selections:
        node_address = sel['node_address']
        withdrawal_eth = sel['withdrawal_eth']
        withdrawal_gwei = int(withdrawal_eth * 1e9)
        withdrawal_wei = withdrawal_gwei * (10 ** 9)

        tx_entry = {
            "node_address": node_address,
            "eigenpod": sel['eigenpod'],
            "withdrawal_amount_gwei": withdrawal_gwei,
            "withdrawal_amount_eth": withdrawal_gwei / 1e9,
            "to": ETHERFI_NODES_MANAGER,
            "value": "0",
            "data": encode_queue_eth_withdrawal(
                node_address, withdrawal_wei
            ),
        }
        transactions.append(tx_entry)

    tx_data = {
        "chainId": str(chain_id),
        "from": from_address,
        "transactions": transactions,
        "description": (
            f"Queue ETH withdrawals for "
            f"{len(transactions)} pod(s)"
        ),
    }

    filepath = os.path.join(output_dir, "queue-withdrawals.json")
    with open(filepath, 'w') as f:
        json.dump(tx_data, f, indent=2)
    print(
        f"  Written: queue-withdrawals.json "
        f"({len(transactions)} withdrawal(s))"
    )
    return filepath


def write_plan(
    selections: List[Dict],
    amount_eth: float,
    total_withdrawal: float,
    operator_name: str,
    output_dir: str,
) -> str:
    """Write unrestake-plan.json with plan metadata."""
    pods_info = []
    for sel in selections:
        pods_info.append({
            'node_address': sel['node_address'],
            'eigenpod': sel['eigenpod'],
            'validator_count': sel['validator_count'],
            'total_balance_eth': sel['total_balance_eth'],
            'pending_withdrawal_eth': sel['pending_withdrawal_eth'],
            'available_eth': sel['available_eth'],
            'withdrawal_eth': sel['withdrawal_eth'],
        })

    plan = {
        'type': 'unrestake_withdrawal',
        'operator': operator_name,
        'requested_amount_eth': amount_eth,
        'total_withdrawal_eth': total_withdrawal,
        'num_pods_used': len(selections),
        'pods': pods_info,
        'transactions': {
            'queue_withdrawals': len(selections),
            'total': len(selections),
        },
        'files': {
            'queue_withdrawals': 'queue-withdrawals.json',
        },
        'execution_order': [
            "1. Execute queue-withdrawals.json from ADMIN_EOA "
            "(queueETHWithdrawal)",
            "2. Wait for EigenLayer withdrawal delay, "
            "then completeQueuedETHWithdrawals",
        ],
        'generated_at': datetime.now().isoformat(),
    }

    filepath = os.path.join(output_dir, 'unrestake-plan.json')
    with open(filepath, 'w') as f:
        json.dump(plan, f, indent=2, default=str)
    return filepath


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Unrestake validators for an operator',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List operators
  python3 unrestake_validators.py --list-operators

  # Preview plan (no files written)
  python3 unrestake_validators.py --operator "Cosmostation" --amount 1000 --dry-run

  # Generate transaction files
  python3 unrestake_validators.py --operator "Cosmostation" --amount 1000
        """
    )
    parser.add_argument(
        '--operator',
        help='Operator name or address',
    )
    parser.add_argument(
        '--amount',
        type=float,
        help='ETH amount to unrestake (0 to unrestake all available)',
    )
    parser.add_argument(
        '--output-dir',
        help='Output directory (auto-generated if omitted)',
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Preview plan without writing files',
    )
    parser.add_argument(
        '--list-operators',
        action='store_true',
        help='List available operators',
    )

    args = parser.parse_args()

    if not args.list_operators and not args.operator:
        print("Error: --operator is required (or use --list-operators)")
        parser.print_help()
        sys.exit(1)

    if not args.list_operators and args.amount is None:
        print("Error: --amount is required (use 0 to unrestake all)")
        parser.print_help()
        sys.exit(1)

    if args.amount and args.amount < MIN_WITHDRAWAL_AMOUNT:
        print(
            f"Error: --amount must be at least "
            f"{MIN_WITHDRAWAL_AMOUNT} ETH (or 0 to unrestake all)"
        )
        sys.exit(1)

    try:
        conn = get_db_connection()
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)

    try:
        # List operators
        if args.list_operators:
            operators = list_operators(conn)
            print(
                f"\n{'Name':<30} {'Address':<44} "
                f"{'Validators':>10}"
            )
            print("-" * 88)
            for op in operators:
                addr = op['address'] or 'N/A'
                print(
                    f"{op['name']:<30} {addr:<44} "
                    f"{op['total']:>10}"
                )
            return

        # Resolve operator
        operator_address = get_operator_address(conn, args.operator)
        if not operator_address:
            print(f"Error: Operator '{args.operator}' not found")
            print("Use --list-operators to see available operators")
            sys.exit(1)

        print(f"\n{'=' * 60}")
        print("UNRESTAKE VALIDATORS")
        print(f"{'=' * 60}")
        print(f"Operator:        {args.operator} ({operator_address})")
        if args.amount == 0:
            print("Target amount:   ALL (unrestake everything available)")
        else:
            print(f"Target amount:   {args.amount:,.0f} ETH")
        print()

        # ==============================================================
        # Step 1: Query pods from DB
        # ==============================================================
        print("Step 1: Querying pods from database...")
        pods = query_operator_pods(conn, operator_address)
        if not pods:
            print("Error: No pods found for this operator")
            sys.exit(1)
        total_balance = sum(p['total_balance_eth'] for p in pods)
        total_validators = sum(p['validator_count'] for p in pods)
        print(
            f"  Found {len(pods)} pod(s), "
            f"{total_validators} validators, "
            f"{total_balance:,.0f} ETH total"
        )

        # ==============================================================
        # Step 2: Check pending withdrawals
        # ==============================================================
        rpc_url = os.environ.get('MAINNET_RPC_URL', '')
        if rpc_url:
            print(
                "\nStep 2: Checking pending withdrawals on-chain..."
            )
        else:
            print(
                "\nStep 2: Skipping pending withdrawal check "
                "(MAINNET_RPC_URL not set)"
            )

        pods = evaluate_pods(pods, rpc_url)

        # Display table
        display_pods_table(pods)

        # ==============================================================
        # Step 3: Check capacity and resolve amount=0
        # ==============================================================
        total_available = sum(p['available_eth'] for p in pods)
        target_amount = args.amount

        if target_amount == 0:
            target_amount = total_available
            print(
                f"\n  Unrestaking ALL available: "
                f"{total_available:,.0f} ETH"
            )
        elif total_available < target_amount:
            print(
                f"\n  Error: Total available across all pods is "
                f"{total_available:,.0f} ETH"
            )
            print(f"  Requested: {target_amount:,.0f} ETH")
            total_pending = sum(
                p['pending_withdrawal_eth'] for p in pods
            )
            if total_pending > 0:
                print(
                    f"  Already pending: {total_pending:,.0f} ETH"
                )
            sys.exit(1)

        if total_available <= 0:
            print("\n  Error: No available ETH to unrestake")
            sys.exit(1)

        # ==============================================================
        # Step 4: Select pods
        # ==============================================================
        print(
            f"\nStep 3: Selecting pods for "
            f"{target_amount:,.0f} ETH unrestake..."
        )
        selections, total_withdrawal = select_pods(
            pods, target_amount,
            whole_eth=(args.amount == 0),
        )

        if not selections:
            print("  Error: Could not select any pods")
            sys.exit(1)

        # ==============================================================
        # Step 5: Print plan
        # ==============================================================
        print(f"\n{'=' * 60}")
        print("UNRESTAKE PLAN")
        print(f"{'=' * 60}")
        print(f"Pods used:               {len(selections)}")
        if args.amount == 0:
            print("Requested amount:        ALL")
        else:
            print(
                f"Requested amount:        {target_amount:,.0f} ETH"
            )
        print(f"Total withdrawal:        {total_withdrawal:,.2f} ETH")
        if args.amount != 0:
            surplus = total_withdrawal - target_amount
            if surplus > 0:
                print(
                    f"Surplus over requested:  {surplus:,.2f} ETH"
                )

        for i, sel in enumerate(selections, start=1):
            print(f"\n  Pod {i}: {sel['node_address']}")
            print(f"    EigenPod:            {sel['eigenpod']}")
            print(f"    Validators:          {sel['validator_count']}")
            print(
                f"    Total balance:       "
                f"{sel['total_balance_eth']:,.2f} ETH"
            )
            print(
                f"    Pending withdrawals: "
                f"{sel['pending_withdrawal_eth']:,.2f} ETH"
            )
            print(
                f"    Available:           "
                f"{sel['available_eth']:,.2f} ETH"
            )
            print(
                f"    Withdrawal amount:   "
                f"{sel['withdrawal_eth']:,.2f} ETH"
            )

        if args.dry_run:
            print("\n(Dry run - no files written)")
            return

        # ==============================================================
        # Step 6: Generate output files
        # ==============================================================
        print(f"\nStep 4: Generating output files...")

        if args.output_dir:
            output_dir = args.output_dir
        else:
            script_dir = Path(__file__).resolve().parent
            timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
            operator_slug = (
                args.operator.replace(' ', '_').lower()
            )
            if args.amount == 0:
                amount_slug = "all"
            else:
                amount_slug = f"{int(target_amount)}eth"
            output_dir = str(
                script_dir / 'txns'
                / f"{operator_slug}_unrestake"
                  f"_{amount_slug}_{timestamp}"
            )

        os.makedirs(output_dir, exist_ok=True)

        chain_id = int(
            os.environ.get('CHAIN_ID', DEFAULT_CHAIN_ID)
        )
        admin_address = os.environ.get(
            'ADMIN_ADDRESS', ADMIN_EOA
        )

        write_transactions(
            selections, output_dir, chain_id, admin_address,
        )

        write_plan(
            selections, target_amount, total_withdrawal,
            args.operator, output_dir,
        )
        print("  Written: unrestake-plan.json")

        # Summary
        print(f"\n{'=' * 60}")
        print("OUTPUT COMPLETE")
        print(f"{'=' * 60}")
        print(f"Directory: {output_dir}")
        print(f"\nExecution order:")
        print(
            "  1. Execute queue-withdrawals.json from ADMIN_EOA "
            "(queueETHWithdrawal)"
        )
        print(
            "  2. Wait for EigenLayer withdrawal delay, "
            "then completeQueuedETHWithdrawals"
        )
        print()
        print(
            f"Total ETH to queue for withdrawal: "
            f"{total_withdrawal:,.2f} ETH "
            f"across {len(selections)} pod(s)"
        )
        print()

    finally:
        conn.close()


if __name__ == '__main__':
    main()

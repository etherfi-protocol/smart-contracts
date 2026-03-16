#!/usr/bin/env python3
"""
compare_tvl.py - Compare Chainlink-reported TVL vs LiquidityPool.getTotalPooledEther()

Strategy:
1. Use getRoundData() on the Chainlink proxy to iterate through the last 30 days of rounds
2. Use the updatedAt timestamp from each round to find the exact block via binary search
3. Call LiquidityPool.getTotalPooledEther() at each of those blocks
4. Compare the two values
"""

import os
import sys
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path

try:
    from dotenv import load_dotenv
    env_path = Path('.env')
    if not env_path.exists():
        script_dir = Path(__file__).resolve().parent
        for _ in range(5):
            script_dir = script_dir.parent
            candidate = script_dir / '.env'
            if candidate.exists():
                env_path = candidate
                break
    load_dotenv(dotenv_path=env_path)
except ImportError:
    pass

try:
    from web3 import Web3
except ImportError:
    print("Error: web3 not installed. Run: pip install web3")
    sys.exit(1)

# --- Config ---
CHAINLINK_TVL_PROXY = "0xC8cd82067eA907EA4af81b625d2bB653E21b5156"
LIQUIDITY_POOL = "0x308861A430be4cce5502d0A12724771Fc6DaF216"

CHAINLINK_PROXY_ABI = json.loads("""[
    {
        "inputs": [],
        "name": "latestRoundData",
        "outputs": [
            {"name": "roundId", "type": "uint80"},
            {"name": "answer", "type": "int256"},
            {"name": "startedAt", "type": "uint256"},
            {"name": "updatedAt", "type": "uint256"},
            {"name": "answeredInRound", "type": "uint80"}
        ],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [{"name": "_roundId", "type": "uint80"}],
        "name": "getRoundData",
        "outputs": [
            {"name": "roundId", "type": "uint80"},
            {"name": "answer", "type": "int256"},
            {"name": "startedAt", "type": "uint256"},
            {"name": "updatedAt", "type": "uint256"},
            {"name": "answeredInRound", "type": "uint80"}
        ],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [],
        "name": "aggregator",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function"
    }
]""")

LIQUIDITY_POOL_ABI = json.loads("""[
    {
        "inputs": [],
        "name": "getTotalPooledEther",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    }
]""")


def find_block_by_timestamp(w3, target_ts, lo_hint=None, hi_hint=None):
    """Binary search to find the first block with timestamp >= target_ts."""
    lo = lo_hint if lo_hint else 18_000_000
    hi = hi_hint if hi_hint else w3.eth.block_number

    # Ensure lo block is before target
    lo_block = w3.eth.get_block(lo)
    if lo_block["timestamp"] >= target_ts:
        return lo

    while lo < hi:
        mid = (lo + hi) // 2
        block = w3.eth.get_block(mid)
        if block["timestamp"] < target_ts:
            lo = mid + 1
        else:
            hi = mid

    return lo


def main():
    rpc_url = os.environ.get("MAINNET_RPC_URL")
    if not rpc_url:
        print("Error: MAINNET_RPC_URL environment variable not set")
        sys.exit(1)

    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        print("Error: Cannot connect to RPC")
        sys.exit(1)

    chainlink = w3.eth.contract(
        address=Web3.to_checksum_address(CHAINLINK_TVL_PROXY),
        abi=CHAINLINK_PROXY_ABI,
    )
    liquidity_pool = w3.eth.contract(
        address=Web3.to_checksum_address(LIQUIDITY_POOL),
        abi=LIQUIDITY_POOL_ABI,
    )

    # Get decimals
    decimals = chainlink.functions.decimals().call()
    aggregator_addr = chainlink.functions.aggregator().call()
    print(f"Chainlink feed decimals: {decimals}")
    print(f"Underlying aggregator: {aggregator_addr}")

    # Get latest round info
    latest_round = chainlink.functions.latestRoundData().call()
    latest_round_id = latest_round[0]
    phase_id = latest_round_id >> 64
    latest_agg_round = latest_round_id & 0xFFFFFFFFFFFFFFFF
    print(f"Latest round: phase={phase_id}, aggRound={latest_agg_round}")
    print(f"Latest answer: {latest_round[1] / 10**decimals:,.4f} ETH")
    print(f"Latest updatedAt: {datetime.fromtimestamp(latest_round[3], tz=timezone.utc)}")
    print()

    # Determine cutoff: 30 days ago
    cutoff_ts = int((datetime.now(timezone.utc) - timedelta(days=30)).timestamp())
    print(f"Cutoff: {datetime.fromtimestamp(cutoff_ts, tz=timezone.utc)}")

    # Collect rounds from latest going back 30 days
    rounds = []
    agg_round = latest_agg_round
    while agg_round > 0:
        round_id = (phase_id << 64) | agg_round
        try:
            data = chainlink.functions.getRoundData(round_id).call()
        except Exception:
            break
        updated_at = data[3]
        if updated_at < cutoff_ts:
            break
        rounds.append({
            "round_id": round_id,
            "agg_round": agg_round,
            "answer": data[1],
            "updated_at": updated_at,
        })
        agg_round -= 1

    rounds.reverse()  # chronological order
    print(f"Found {len(rounds)} rounds in the past 30 days")
    print()

    # Find block numbers for each round using binary search on timestamps
    print("Finding block numbers for each round via timestamp binary search...")
    current_block = w3.eth.block_number

    # Use a reasonable lower bound for the search
    first_ts = rounds[0]["updated_at"] if rounds else cutoff_ts
    # Estimate: ~12 sec/block, go back from current block
    seconds_back = current_block * 12 - (first_ts - 1600000000)
    lo_hint = max(1, current_block - (current_block - int(first_ts / 12)) // 1)
    # Simpler: just estimate ~7200 blocks/day, 31 days back from current
    lo_hint = max(1, current_block - 7200 * 35)

    prev_block = lo_hint
    for r in rounds:
        block_num = find_block_by_timestamp(w3, r["updated_at"], lo_hint=prev_block, hi_hint=current_block)
        r["block_number"] = block_num
        prev_block = block_num  # next search starts from here
        # Verify: check if this block or the one before has the exact timestamp
        block_data = w3.eth.get_block(block_num)
        r["block_timestamp"] = block_data["timestamp"]

    print("Done.\n")

    # Print comparison table
    header = f"{'Date (UTC)':<22} {'Block':<12} {'Chainlink TVL (ETH)':>22}   {'Pool TVL (ETH)':>22}   {'Diff (ETH)':>14}   {'Diff %':>10}"
    print(header)
    print("-" * len(header))

    results = []
    for r in rounds:
        block_number = r["block_number"]
        chainlink_tvl = r["answer"] / 10**decimals
        date_str = datetime.fromtimestamp(r["updated_at"], tz=timezone.utc).strftime("%Y-%m-%d %H:%M")

        # Get LiquidityPool TVL at the same block
        try:
            pool_tvl_raw = liquidity_pool.functions.getTotalPooledEther().call(
                block_identifier=block_number
            )
            pool_tvl = pool_tvl_raw / 10**18
        except Exception as e:
            pool_tvl = None

        diff = None
        diff_pct = None
        if pool_tvl is not None:
            diff = pool_tvl - chainlink_tvl
            if chainlink_tvl != 0:
                diff_pct = (diff / chainlink_tvl) * 100

        results.append({
            "date": date_str,
            "block": block_number,
            "chainlink_tvl_eth": chainlink_tvl,
            "pool_tvl_eth": pool_tvl,
            "diff_eth": diff,
            "diff_pct": diff_pct,
        })

        pool_str = f"{pool_tvl:,.4f}" if pool_tvl is not None else "ERROR"
        diff_str = f"{diff:,.4f}" if diff is not None else "N/A"
        pct_str = f"{diff_pct:+.4f}%" if diff_pct is not None else "N/A"

        print(f"{date_str:<22} {block_number:<12} {chainlink_tvl:>22,.4f}   {pool_str:>22}   {diff_str:>14}   {pct_str:>10}")

    # Summary stats
    print()
    print("=" * len(header))
    diffs = [r["diff_pct"] for r in results if r["diff_pct"] is not None]
    abs_diffs = [r["diff_eth"] for r in results if r["diff_eth"] is not None]
    if diffs:
        print(f"Average diff:  {sum(diffs)/len(diffs):+.4f}%  ({sum(abs_diffs)/len(abs_diffs):+,.4f} ETH)")
        print(f"Max diff:      {max(diffs):+.4f}%  ({max(abs_diffs):+,.4f} ETH)")
        print(f"Min diff:      {min(diffs):+.4f}%  ({min(abs_diffs):+,.4f} ETH)")

    # Save to JSON
    output_path = Path(__file__).resolve().parent / "tvl_comparison.json"
    with open(output_path, "w") as f:
        json.dump(results, f, indent=2, default=str)
    print(f"\nResults saved to {output_path}")


if __name__ == "__main__":
    main()

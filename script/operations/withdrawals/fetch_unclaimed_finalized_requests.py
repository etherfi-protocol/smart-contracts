#!/usr/bin/env python3
"""
Fetch every WithdrawRequestNFT request id that is finalized but not yet claimed.

A request is claimable (post security-upgrade, where claims are permissionless) iff:
  - requestId <= lastFinalizedRequestId   (finalized)
  - ownerOf(requestId) does not revert    (NFT not burned => not claimed/seized-and-burned)
  - getRequest(requestId).isValid         (invalidated requests revert on claim)

Outputs:
  unclaimed_finalized_requests.csv   one row per request (id, owner, amount, valid, owner_is_contract)
  claim_batches.json                 claimable ids chunked for batchClaimWithdraw(uint256[])

Usage:
  MAINNET_RPC_URL=... python3 fetch_unclaimed_finalized_requests.py [--batch-size 500] [--chunk-size 50]

Run this at execution time (right before/after the upgrade lands) — lastFinalizedRequestId
and the claimed set move with mainnet state.

Note for the claim run: a single blacklisted or ETH-rejecting recipient reverts an entire
batchClaimWithdraw call. Owners flagged owner_is_contract=True are the risky ones — claim
those individually, or route per-id claimWithdraw calls through Multicall3 aggregate3 with
allowFailure=true so one bad recipient can't block the flush.
"""

import argparse
import csv
import json
import os
import sys

from eth_abi import decode, encode
from web3 import Web3

WITHDRAW_REQUEST_NFT = "0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"

SEL_OWNER_OF = Web3.keccak(text="ownerOf(uint256)")[:4]
SEL_GET_REQUEST = Web3.keccak(text="getRequest(uint256)")[:4]
SEL_AGGREGATE3 = Web3.keccak(text="aggregate3((address,bool,bytes)[])")[:4]


def multicall(w3, calls):
    """calls: list of (target, calldata). Returns list of (success, returndata)."""
    payload = SEL_AGGREGATE3 + encode(
        ["(address,bool,bytes)[]"],
        [[(target, True, data) for target, data in calls]],
    )
    raw = w3.eth.call({"to": MULTICALL3, "data": payload})
    return decode(["(bool,bytes)[]"], raw)[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch-size", type=int, default=500, help="request ids per multicall")
    parser.add_argument("--chunk-size", type=int, default=50, help="ids per batchClaimWithdraw chunk")
    parser.add_argument("--out-dir", default=os.path.dirname(os.path.abspath(__file__)))
    args = parser.parse_args()

    rpc = os.environ.get("MAINNET_RPC_URL")
    if not rpc:
        sys.exit("MAINNET_RPC_URL not set")
    w3 = Web3(Web3.HTTPProvider(rpc))

    block = w3.eth.block_number
    nft = WITHDRAW_REQUEST_NFT

    def read_uint32(sig):
        raw = w3.eth.call({"to": nft, "data": Web3.keccak(text=sig)[:4]})
        return decode(["uint32"], raw)[0]

    next_request_id = read_uint32("nextRequestId()")
    last_finalized = read_uint32("lastFinalizedRequestId()")
    print(f"block={block} nextRequestId={next_request_id} lastFinalizedRequestId={last_finalized}")

    unclaimed = []  # (id, owner, amountOfEEth, shareOfEEth, isValid)
    ids = list(range(1, last_finalized + 1))
    for start in range(0, len(ids), args.batch_size):
        batch = ids[start : start + args.batch_size]
        calls = []
        for i in batch:
            arg = encode(["uint256"], [i])
            calls.append((nft, SEL_OWNER_OF + arg))
            calls.append((nft, SEL_GET_REQUEST + arg))
        results = multicall(w3, calls)
        for j, i in enumerate(batch):
            owner_ok, owner_raw = results[2 * j]
            if not owner_ok:  # burned => already claimed (or seized+burned)
                continue
            owner = decode(["address"], owner_raw)[0]
            _, req_raw = results[2 * j + 1]
            amount, share, is_valid, _fee = decode(["uint96", "uint96", "bool", "uint32"], req_raw)
            unclaimed.append((i, Web3.to_checksum_address(owner), amount, share, is_valid))
        done = min(start + args.batch_size, len(ids))
        print(f"\rscanned {done}/{len(ids)} ids, unclaimed so far: {len(unclaimed)}", end="", flush=True)
    print()

    # Flag contract recipients: they can revert on ETH receive and brick a whole claim batch.
    owners = sorted({o for _, o, _, _, _ in unclaimed})
    is_contract = {}
    for start in range(0, len(owners), 200):
        for o in owners[start : start + 200]:
            is_contract[o] = len(w3.eth.get_code(o)) > 0
        print(f"\rcode-checked {min(start + 200, len(owners))}/{len(owners)} owners", end="", flush=True)
    print()

    csv_path = os.path.join(args.out_dir, "unclaimed_finalized_requests.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["requestId", "owner", "amountOfEEth_wei", "amountOfEEth_ether", "shareOfEEth_wei", "isValid", "owner_is_contract"])
        for i, owner, amount, share, is_valid in unclaimed:
            writer.writerow([i, owner, amount, f"{amount / 1e18:.6f}", share, is_valid, is_contract[owner]])

    claimable = [(i, o, a) for i, o, a, _, v in unclaimed if v]
    invalid = [(i, o, a) for i, o, a, _, v in unclaimed if not v]
    eoa_ids = [i for i, o, _ in claimable if not is_contract[o]]
    contract_ids = [i for i, o, _ in claimable if is_contract[o]]

    batches_path = os.path.join(args.out_dir, "claim_batches.json")
    with open(batches_path, "w") as f:
        json.dump(
            {
                "block": block,
                "lastFinalizedRequestId": last_finalized,
                "totalClaimableEth": f"{sum(a for _, _, a in claimable) / 1e18:.6f}",
                "batchClaimWithdraw_chunks_eoa_owners": [
                    eoa_ids[k : k + args.chunk_size] for k in range(0, len(eoa_ids), args.chunk_size)
                ],
                "claim_individually_contract_owners": contract_ids,
                "excluded_invalid_requests": [i for i, _, _ in invalid],
            },
            f,
            indent=2,
        )

    total_eth = sum(a for _, _, a in claimable) / 1e18
    print(f"\nfinalized+unclaimed: {len(unclaimed)}  (valid/claimable: {len(claimable)}, invalid: {len(invalid)})")
    print(f"claimable ETH (sum of amountOfEEth): {total_eth:,.4f}")
    print(f"contract-owned claimable ids (claim individually): {len(contract_ids)}")
    print(f"wrote {csv_path}")
    print(f"wrote {batches_path}")


if __name__ == "__main__":
    main()

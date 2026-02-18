#!/usr/bin/env python3
"""
Broadcast consolidation transactions from an existing consolidation-data.json.

Features:
  - Broadcast-only flow (no dry-run mode)
  - Optional linking step via --linking-file (Gnosis tx JSON)
  - Sends consolidation transactions with fixed 15,000,000 gas limit
  - Reads MAINNET_RPC_URL and PRIVATE_KEY from project .env / environment
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

from generate_gnosis_txns import ETHERFI_NODES_MANAGER, generate_consolidation_calldata


DEFAULT_BATCH_SIZE = 58
CONSOLIDATION_GAS_LIMIT = 15_000_000
TX_DELAY_SECONDS = 5
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


def load_dotenv_if_present(project_root: Path) -> None:
    def strip_inline_comment(raw_value: str) -> str:
        in_single = False
        in_double = False
        out_chars: List[str] = []
        for ch in raw_value:
            if ch == "'" and not in_double:
                in_single = not in_single
                out_chars.append(ch)
                continue
            if ch == '"' and not in_single:
                in_double = not in_double
                out_chars.append(ch)
                continue
            if ch == "#" and not in_single and not in_double:
                break
            out_chars.append(ch)
        return "".join(out_chars).strip()

    env_file = project_root / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = strip_inline_comment(value).strip().strip("'").strip('"')
        os.environ.setdefault(key, value)


def run_cmd(cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"{' '.join(cmd)} failed: {msg}")
    return proc


def parse_int_hex_or_decimal(value: str) -> int:
    v = value.strip()
    if v.startswith("0x"):
        return int(v, 16)
    return int(v, 10)


def parse_tx_hash_from_send_output(out: str) -> Optional[str]:
    if not out:
        return None
    try:
        data = json.loads(out)
        if isinstance(data, dict):
            tx_hash = data.get("transactionHash") or data.get("hash")
            if isinstance(tx_hash, str) and tx_hash.startswith("0x"):
                return tx_hash
    except json.JSONDecodeError:
        pass
    for token in out.replace('"', " ").replace(",", " ").split():
        if token.startswith("0x") and len(token) == 66:
            return token
    return None


def wait_for_receipt(rpc_url: str, tx_hash: str, timeout_seconds: int = 900) -> Dict:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        proc = run_cmd(["cast", "receipt", tx_hash, "--rpc-url", rpc_url, "--json"], check=False)
        if proc.returncode == 0 and proc.stdout:
            try:
                receipt = json.loads(proc.stdout)
                if isinstance(receipt, dict) and receipt.get("status") is not None:
                    return receipt
            except json.JSONDecodeError:
                pass
        time.sleep(2)
    raise RuntimeError(f"timeout waiting for receipt: {tx_hash}")


def cast_call(rpc_url: str, to: str, signature: str, *args: str) -> str:
    proc = run_cmd(["cast", "call", to, signature, *args, "--rpc-url", rpc_url])
    return (proc.stdout or "").strip()


def cast_send_raw(
    rpc_url: str,
    to: str,
    private_key: str,
    data: str,
    value_wei: int = 0,
    gas_limit: Optional[int] = None,
) -> str:
    cmd = [
        "cast",
        "send",
        to,
        data,
        "--rpc-url",
        rpc_url,
        "--private-key",
        private_key,
        "--json",
        "--value",
        str(value_wei),
    ]
    if gas_limit is not None:
        cmd.extend(["--gas-limit", str(gas_limit)])

    proc = run_cmd(cmd)
    tx_hash = parse_tx_hash_from_send_output((proc.stdout or "").strip())
    if not tx_hash:
        raise RuntimeError(f"failed to parse tx hash from cast send output: {(proc.stdout or '').strip()}")
    return tx_hash


def normalize_hex_bytes(value: str) -> str:
    v = value.strip()
    if not v.startswith("0x"):
        v = "0x" + v
    return v.lower()


def split_batches(items: List[Dict], batch_size: int) -> List[List[Dict]]:
    return [items[i : i + batch_size] for i in range(0, len(items), batch_size)]


def pubkey_hash(rpc_url: str, pubkey: str) -> str:
    return cast_call(
        rpc_url,
        ETHERFI_NODES_MANAGER,
        "calculateValidatorPubkeyHash(bytes)(bytes32)",
        normalize_hex_bytes(pubkey),
    )


def node_from_pubkey_hash(rpc_url: str, pk_hash: str) -> str:
    return cast_call(
        rpc_url,
        ETHERFI_NODES_MANAGER,
        "etherFiNodeFromPubkeyHash(bytes32)(address)",
        pk_hash,
    )


def get_eigenpod_for_target(rpc_url: str, target_pubkey: str) -> str:
    pk_hash = pubkey_hash(rpc_url, target_pubkey)
    node = node_from_pubkey_hash(rpc_url, pk_hash)
    if node.lower() == ZERO_ADDRESS.lower():
        raise RuntimeError(
            f"target pubkey is not linked: {target_pubkey}. "
            "Provide --linking-file (and ensure it succeeds) before consolidations."
        )
    return cast_call(rpc_url, node, "getEigenPod()(address)")


def get_consolidation_fee_wei(rpc_url: str, target_pubkey: str) -> int:
    pod = get_eigenpod_for_target(rpc_url, target_pubkey)
    fee = cast_call(rpc_url, pod, "getConsolidationRequestFee()(uint256)")
    return parse_int_hex_or_decimal(fee)


def get_signer_address(private_key: str) -> str:
    proc = run_cmd(["cast", "wallet", "address", "--private-key", private_key])
    return (proc.stdout or "").strip()


def broadcast_linking_file(rpc_url: str, private_key: str, linking_file: Path) -> None:
    if not linking_file.exists():
        raise RuntimeError(f"linking file not found: {linking_file}")
    payload = json.loads(linking_file.read_text())
    txs = payload.get("transactions", [])
    if not txs:
        raise RuntimeError(f"no transactions found in linking file: {linking_file}")

    print(f"Broadcasting linking tx file: {linking_file}")
    for idx, tx in enumerate(txs, start=1):
        to = tx.get("to")
        data = tx.get("data")
        value = int(tx.get("value", "0"))
        if not to or not data:
            raise RuntimeError(f"invalid tx at index {idx} in linking file")
        tx_hash = cast_send_raw(rpc_url, to, private_key, data, value_wei=value)
        receipt = wait_for_receipt(rpc_url, tx_hash)
        status = parse_int_hex_or_decimal(str(receipt.get("status")))
        if status != 1:
            raise RuntimeError(f"linking tx failed: {tx_hash}")
        print(f"  ✓ linking tx {idx}/{len(txs)} confirmed: {tx_hash}")
        time.sleep(TX_DELAY_SECONDS)


def broadcast_consolidations(
    rpc_url: str,
    private_key: str,
    consolidation_data_file: Path,
    batch_size: int,
) -> None:
    data = json.loads(consolidation_data_file.read_text())
    consolidations = data.get("consolidations", [])
    total_sources = sum(len(c.get("sources", [])) for c in consolidations)

    print(f"Targets: {len(consolidations)}")
    print(f"Sources: {total_sources}")
    print(f"Batch size: {batch_size}")
    print(f"Gas limit per consolidation tx: {CONSOLIDATION_GAS_LIMIT}")
    print("")

    tx_count = 0
    for target_idx, c in enumerate(consolidations, start=1):
        target = c.get("target", {})
        target_pubkey = target.get("pubkey")
        sources = c.get("sources", [])
        if not target_pubkey or not sources:
            continue

        source_batches = split_batches(sources, batch_size)
        print(f"Target {target_idx}/{len(consolidations)}: {len(sources)} sources, {len(source_batches)} batch(es)")

        for batch_idx, batch in enumerate(source_batches, start=1):
            batch_pubkeys = [normalize_hex_bytes(s["pubkey"]) for s in batch if s.get("pubkey")]
            if not batch_pubkeys:
                continue

            fee_per_request = get_consolidation_fee_wei(rpc_url, target_pubkey)
            value_wei = fee_per_request * len(batch_pubkeys)
            calldata = generate_consolidation_calldata(batch_pubkeys, normalize_hex_bytes(target_pubkey))

            tx_hash = cast_send_raw(
                rpc_url,
                ETHERFI_NODES_MANAGER,
                private_key,
                calldata,
                value_wei=value_wei,
                gas_limit=CONSOLIDATION_GAS_LIMIT,
            )
            receipt = wait_for_receipt(rpc_url, tx_hash)
            status = parse_int_hex_or_decimal(str(receipt.get("status")))
            if status != 1:
                raise RuntimeError(f"consolidation tx failed: {tx_hash}")

            tx_count += 1
            print(
                f"  ✓ tx {tx_count} (target {target_idx}, batch {batch_idx}, "
                f"fee {fee_per_request}, value {value_wei}) {tx_hash}"
            )
            time.sleep(TX_DELAY_SECONDS)

    print("")
    print(f"Completed. Total consolidation txs broadcast: {tx_count}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Broadcast consolidation txs from consolidation-data.json")
    parser.add_argument("--input", required=True, help="Path to consolidation-data.json")
    parser.add_argument(
        "--linking-file",
        help="Optional path to linking tx JSON (e.g. link-validators.json). If provided, sent before consolidations.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Consolidations per tx (default: {DEFAULT_BATCH_SIZE})",
    )
    return parser.parse_args()


def ensure_tools_available() -> None:
    for tool in ("cast", "python3"):
        proc = run_cmd(["which", tool], check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"required tool not found: {tool}")


def main() -> None:
    args = parse_args()

    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent.parent.parent
    load_dotenv_if_present(project_root)

    input_file = Path(args.input).resolve()
    if not input_file.exists():
        raise RuntimeError(f"input file not found: {input_file}")
    linking_file = Path(args.linking_file).resolve() if args.linking_file else None

    rpc_url = os.environ.get("MAINNET_RPC_URL", "").strip()
    private_key = os.environ.get("PRIVATE_KEY", "").strip()
    if not rpc_url:
        raise RuntimeError("MAINNET_RPC_URL not set in env/.env")
    if not private_key:
        raise RuntimeError("PRIVATE_KEY not set in env/.env")

    ensure_tools_available()

    signer = get_signer_address(private_key)
    print("")
    print("=== SEND CONSOLIDATIONS FROM JSON ===")
    print(f"Input:            {input_file}")
    print(f"Linking file:     {linking_file if linking_file else 'none'}")
    print(f"Broadcaster:      {signer}")
    print("")

    if linking_file:
        broadcast_linking_file(rpc_url, private_key, linking_file)
        print("")

    broadcast_consolidations(rpc_url, private_key, input_file, args.batch_size)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""
Python-first consolidation runner.

This mirrors the main CLI surface of run-consolidation.sh, but avoids heavy
JSON parsing in Solidity. It:
  1) Builds consolidation-data.json (via query_validators_consolidation.py)
  2) Parses consolidation data in Python
  3) Generates transaction JSON files
  4) Optionally broadcasts immediately on mainnet using cast send
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from generate_gnosis_txns import (
    ADMIN_EOA,
    ETHERFI_NODES_MANAGER,
    encode_link_legacy_validators,
    generate_consolidation_calldata,
    generate_gnosis_tx_json,
)


DEFAULT_BUCKET_HOURS = 6
DEFAULT_MAX_TARGET_BALANCE = 1900.0
DEFAULT_BATCH_SIZE = 58
DEFAULT_CHAIN_ID = 1
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
QUEUE_ETH_WITHDRAWAL_SELECTOR = "0x96d373e5"  # queueETHWithdrawal(address,uint256)


@dataclass
class Config:
    operator: str
    count: int
    bucket_hours: int
    max_target_balance: float
    batch_size: int
    dry_run: bool
    skip_simulate: bool
    skip_forge_sim: bool
    verbose: bool
    mainnet: bool
    project_root: Path
    script_dir: Path
    output_dir: Path
    mainnet_rpc_url: str
    validator_db: str
    private_key: Optional[str]
    chain_id: int
    admin_address: str


def load_dotenv_if_present(project_root: Path) -> None:
    env_file = project_root / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        os.environ.setdefault(key, value)


def run_cmd(
    cmd: List[str],
    *,
    check: bool = True,
    capture_output: bool = True,
    cwd: Optional[Path] = None,
) -> subprocess.CompletedProcess:
    if cwd is None:
        cwd = Path.cwd()
    if capture_output:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    else:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            check=False,
        )
    if check and proc.returncode != 0:
        stderr = proc.stderr.strip() if proc.stderr else ""
        stdout = proc.stdout.strip() if proc.stdout else ""
        detail = stderr or stdout or "command failed"
        raise RuntimeError(f"{' '.join(cmd)} failed: {detail}")
    return proc


def cast_call(rpc_url: str, to: str, signature: str, *args: str) -> str:
    cmd = ["cast", "call", to, signature, *args, "--rpc-url", rpc_url]
    proc = run_cmd(cmd)
    return (proc.stdout or "").strip()


def cast_calldata(signature: str, *args: str) -> str:
    cmd = ["cast", "calldata", signature, *args]
    proc = run_cmd(cmd)
    return (proc.stdout or "").strip()


def cast_send_raw(
    rpc_url: str,
    to: str,
    private_key: str,
    data: str,
    value_wei: int = 0,
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
    proc = run_cmd(cmd)
    out = (proc.stdout or "").strip()
    tx_hash = parse_tx_hash_from_send_output(out)
    if not tx_hash:
        raise RuntimeError(f"failed to parse tx hash from cast send output: {out}")
    return tx_hash


def parse_tx_hash_from_send_output(out: str) -> Optional[str]:
    if not out:
        return None
    # cast --json prints a JSON object; keep parsing conservative.
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


def wait_for_receipt(rpc_url: str, tx_hash: str, timeout_seconds: int = 600) -> Dict:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        proc = run_cmd(
            ["cast", "receipt", tx_hash, "--rpc-url", rpc_url, "--json"],
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            try:
                receipt = json.loads(proc.stdout)
                if isinstance(receipt, dict) and receipt.get("status") is not None:
                    return receipt
            except json.JSONDecodeError:
                pass
        time.sleep(2)
    raise RuntimeError(f"timeout waiting for receipt: {tx_hash}")


def normalize_hex_bytes(value: str) -> str:
    v = value.strip()
    if not v.startswith("0x"):
        v = "0x" + v
    return v.lower()


def parse_int_hex_or_decimal(value: str) -> int:
    v = value.strip()
    if v.startswith("0x"):
        return int(v, 16)
    return int(v, 10)


def get_signer_address(private_key: str) -> str:
    proc = run_cmd(["cast", "wallet", "address", "--private-key", private_key])
    return (proc.stdout or "").strip()


def count_sources(consolidations: List[Dict]) -> int:
    return sum(len(c.get("sources", [])) for c in consolidations)


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


def is_linked(rpc_url: str, pubkey: str) -> bool:
    pk_hash = pubkey_hash(rpc_url, pubkey)
    node = node_from_pubkey_hash(rpc_url, pk_hash)
    return node.lower() != ZERO_ADDRESS.lower()


def extract_address_from_withdrawal_credentials(withdrawal_credentials: str) -> Optional[str]:
    wc = withdrawal_credentials.strip().lower()
    if not wc:
        return None
    if wc.startswith("0x"):
        wc = wc[2:]
    # full 32-byte withdrawal credentials: 1-byte prefix + 11-byte zero padding + 20-byte address
    if len(wc) == 64:
        addr = wc[-40:]
    elif len(wc) == 40:
        addr = wc
    else:
        return None
    return "0x" + addr


def get_eigenpod_for_target(rpc_url: str, target_pubkey: str, target: Dict, allow_unlinked_fallback: bool) -> str:
    pk_hash = pubkey_hash(rpc_url, target_pubkey)
    node = node_from_pubkey_hash(rpc_url, pk_hash)

    if node.lower() != ZERO_ADDRESS.lower():
        return cast_call(rpc_url, node, "getEigenPod()(address)")

    if allow_unlinked_fallback:
        # In file-generation mode we do not mutate fork state with a linking transaction.
        # Use withdrawal credentials as the EigenPod address for fee lookup.
        wc = target.get("withdrawal_credentials", "")
        pod = extract_address_from_withdrawal_credentials(wc)
        if pod:
            return pod

    raise RuntimeError(f"target pubkey not linked: {target_pubkey}")


def get_consolidation_fee_wei(rpc_url: str, target_pubkey: str, target: Dict, allow_unlinked_fallback: bool) -> int:
    pod = get_eigenpod_for_target(rpc_url, target_pubkey, target, allow_unlinked_fallback)
    fee = cast_call(rpc_url, pod, "getConsolidationRequestFee()(uint256)")
    return parse_int_hex_or_decimal(fee)


def write_json_file(path: Path, content: Dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(content, indent=2) + "\n")


def build_gnosis_single_tx_json(chain_id: int, safe_address: str, to: str, value: int, data: str) -> Dict:
    raw = generate_gnosis_tx_json(
        [{"to": to, "value": str(value), "data": data}],
        chain_id,
        safe_address,
    )
    return json.loads(raw)


def build_linking_payload(
    cfg: Config,
    consolidations: List[Dict],
) -> Tuple[List[int], List[str], Optional[str]]:
    unlinked_ids: List[int] = []
    unlinked_pubkeys: List[str] = []
    seen_ids = set()

    for c in consolidations:
        target = c.get("target", {})
        target_id = target.get("id")
        target_pubkey = target.get("pubkey")
        if target_id is not None and target_pubkey:
            if not is_linked(cfg.mainnet_rpc_url, target_pubkey) and target_id not in seen_ids:
                seen_ids.add(target_id)
                unlinked_ids.append(int(target_id))
                unlinked_pubkeys.append(normalize_hex_bytes(target_pubkey))

        sources = c.get("sources", [])
        num_batches = (len(sources) + cfg.batch_size - 1) // cfg.batch_size
        for batch_idx in range(num_batches):
            first_idx = batch_idx * cfg.batch_size
            if first_idx >= len(sources):
                continue
            source = sources[first_idx]
            source_id = source.get("id")
            source_pubkey = source.get("pubkey")
            if source_id is None or not source_pubkey:
                continue
            if source_id in seen_ids:
                continue
            if not is_linked(cfg.mainnet_rpc_url, source_pubkey):
                seen_ids.add(source_id)
                unlinked_ids.append(int(source_id))
                unlinked_pubkeys.append(normalize_hex_bytes(source_pubkey))

    if not unlinked_ids:
        return unlinked_ids, unlinked_pubkeys, None

    pubkeys_as_bytes = [bytes.fromhex(pk[2:]) for pk in unlinked_pubkeys]
    calldata = "0x" + encode_link_legacy_validators(unlinked_ids, pubkeys_as_bytes).hex()
    return unlinked_ids, unlinked_pubkeys, calldata


def maybe_broadcast_linking(cfg: Config, calldata: str) -> str:
    if not cfg.private_key:
        raise RuntimeError("PRIVATE_KEY required for --mainnet")
    tx_hash = cast_send_raw(
        cfg.mainnet_rpc_url,
        ETHERFI_NODES_MANAGER,
        cfg.private_key,
        calldata,
        value_wei=0,
    )
    receipt = wait_for_receipt(cfg.mainnet_rpc_url, tx_hash)
    status = parse_int_hex_or_decimal(str(receipt.get("status")))
    if status != 1:
        raise RuntimeError(f"linking tx failed: {tx_hash}")
    return tx_hash


def split_batches(items: List[Dict], batch_size: int) -> List[List[Dict]]:
    return [items[i : i + batch_size] for i in range(0, len(items), batch_size)]


def generate_or_broadcast_consolidations(cfg: Config, consolidations: List[Dict]) -> int:
    tx_count = 0
    for idx, c in enumerate(consolidations, start=1):
        target = c.get("target", {})
        target_pubkey = target.get("pubkey")
        sources = c.get("sources", [])
        if not target_pubkey or not sources:
            continue

        source_batches = split_batches(sources, cfg.batch_size)
        if cfg.verbose:
            print(f"Processing target {idx}/{len(consolidations)} with {len(sources)} sources ({len(source_batches)} batches)")

        for batch_idx, batch in enumerate(source_batches, start=1):
            batch_pubkeys = [normalize_hex_bytes(s["pubkey"]) for s in batch if s.get("pubkey")]
            if not batch_pubkeys:
                continue

            fee_per_request = get_consolidation_fee_wei(
                cfg.mainnet_rpc_url,
                target_pubkey,
                target,
                allow_unlinked_fallback=not cfg.mainnet,
            )
            value_wei = fee_per_request * len(batch_pubkeys)
            calldata = generate_consolidation_calldata(batch_pubkeys, normalize_hex_bytes(target_pubkey))

            tx_count += 1
            if cfg.mainnet:
                if not cfg.private_key:
                    raise RuntimeError("PRIVATE_KEY required for --mainnet")
                tx_hash = cast_send_raw(
                    cfg.mainnet_rpc_url,
                    ETHERFI_NODES_MANAGER,
                    cfg.private_key,
                    calldata,
                    value_wei=value_wei,
                )
                receipt = wait_for_receipt(cfg.mainnet_rpc_url, tx_hash)
                status = parse_int_hex_or_decimal(str(receipt.get("status")))
                if status != 1:
                    raise RuntimeError(f"consolidation tx failed: {tx_hash}")
                print(
                    f"  Broadcast tx {tx_count} (target {idx}, batch {batch_idx}, fee {fee_per_request}, value {value_wei}) -> {tx_hash}"
                )
            else:
                tx_json = build_gnosis_single_tx_json(
                    cfg.chain_id,
                    cfg.admin_address,
                    ETHERFI_NODES_MANAGER,
                    value_wei,
                    calldata,
                )
                out_file = cfg.output_dir / f"consolidation-txns-{tx_count}.json"
                write_json_file(out_file, tx_json)
                if cfg.verbose:
                    print(
                        f"  Written consolidation-txns-{tx_count}.json "
                        f"(target {idx}, batch {batch_idx}, fee {fee_per_request}, value {value_wei})"
                    )
    return tx_count


def generate_or_broadcast_queue_withdrawals(cfg: Config, consolidations: List[Dict]) -> int:
    withdrawals: List[Tuple[str, int]] = []
    for c in consolidations:
        withdrawal_gwei = c.get("withdrawal_amount_gwei", 0)
        if not withdrawal_gwei:
            continue
        target_pubkey = c.get("target", {}).get("pubkey")
        if not target_pubkey:
            continue
        pk_hash = pubkey_hash(cfg.mainnet_rpc_url, target_pubkey)
        node = node_from_pubkey_hash(cfg.mainnet_rpc_url, pk_hash)
        if node.lower() == ZERO_ADDRESS.lower():
            raise RuntimeError(f"target pubkey not linked for queue-withdrawal: {target_pubkey}")
        withdrawals.append((node, int(withdrawal_gwei) * 10**9))

    if not withdrawals:
        if cfg.verbose:
            print("No queue-withdrawals to process")
        return 0

    if cfg.mainnet:
        if not cfg.private_key:
            raise RuntimeError("PRIVATE_KEY required for --mainnet")
        sent = 0
        for node, amount_wei in withdrawals:
            calldata = cast_calldata("queueETHWithdrawal(address,uint256)", node, str(amount_wei))
            tx_hash = cast_send_raw(
                cfg.mainnet_rpc_url,
                ETHERFI_NODES_MANAGER,
                cfg.private_key,
                calldata,
                value_wei=0,
            )
            receipt = wait_for_receipt(cfg.mainnet_rpc_url, tx_hash)
            status = parse_int_hex_or_decimal(str(receipt.get("status")))
            if status != 1:
                raise RuntimeError(f"queueETHWithdrawal failed: {tx_hash}")
            sent += 1
            print(f"  Broadcast queue-withdrawal {sent}/{len(withdrawals)} -> {tx_hash}")
        return sent

    txs: List[Dict] = []
    for node, amount_wei in withdrawals:
        calldata = cast_calldata("queueETHWithdrawal(address,uint256)", node, str(amount_wei))
        txs.append({"to": ETHERFI_NODES_MANAGER, "value": "0", "data": calldata})

    raw = generate_gnosis_tx_json(txs, cfg.chain_id, cfg.admin_address)
    parsed = json.loads(raw)
    out_file = cfg.output_dir / "post-sweep" / "queue-withdrawals.json"
    write_json_file(out_file, parsed)
    return len(withdrawals)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Python-first validator consolidation workflow")
    parser.add_argument("--operator", required=True, help="Operator name")
    parser.add_argument("--count", type=int, default=0, help="Number of source validators to consolidate (0 = all)")
    parser.add_argument("--bucket-hours", type=int, default=DEFAULT_BUCKET_HOURS, help="Sweep queue bucket hours")
    parser.add_argument(
        "--max-target-balance",
        type=float,
        default=DEFAULT_MAX_TARGET_BALANCE,
        help="Maximum ETH balance allowed on target post-consolidation",
    )
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE, help="Consolidations per transaction")
    parser.add_argument("--dry-run", action="store_true", help="Only produce consolidation-data.json")
    parser.add_argument("--skip-simulate", action="store_true", help="Skip Tenderly simulation (not integrated in Python runner)")
    parser.add_argument(
        "--skip-forge-sim",
        action="store_true",
        help="Compatibility flag. Python runner does not execute forge simulation.",
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--mainnet", action="store_true", help="Broadcast transactions on mainnet via cast send")
    return parser.parse_args()


def make_config(args: argparse.Namespace) -> Config:
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent.parent.parent
    load_dotenv_if_present(project_root)

    mainnet_rpc_url = os.environ.get("MAINNET_RPC_URL", "").strip()
    validator_db = os.environ.get("VALIDATOR_DB", "").strip()
    private_key = os.environ.get("PRIVATE_KEY", "").strip() or None
    chain_id = int(os.environ.get("CHAIN_ID", str(DEFAULT_CHAIN_ID)))
    admin_address = os.environ.get("ADMIN_ADDRESS", ADMIN_EOA)

    if not mainnet_rpc_url:
        raise RuntimeError("MAINNET_RPC_URL environment variable not set")
    if not validator_db:
        raise RuntimeError("VALIDATOR_DB environment variable not set")
    if args.mainnet and not private_key:
        raise RuntimeError("PRIVATE_KEY environment variable not set (required for --mainnet)")

    timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    operator_slug = args.operator.replace(" ", "_").lower()
    output_dir = script_dir / "txns" / f"{operator_slug}_consolidation_{args.count}_{timestamp}"
    output_dir.mkdir(parents=True, exist_ok=True)

    return Config(
        operator=args.operator,
        count=args.count,
        bucket_hours=args.bucket_hours,
        max_target_balance=args.max_target_balance,
        batch_size=args.batch_size,
        dry_run=args.dry_run,
        skip_simulate=args.skip_simulate,
        skip_forge_sim=args.skip_forge_sim,
        verbose=args.verbose,
        mainnet=args.mainnet,
        project_root=project_root,
        script_dir=script_dir,
        output_dir=output_dir,
        mainnet_rpc_url=mainnet_rpc_url,
        validator_db=validator_db,
        private_key=private_key,
        chain_id=chain_id,
        admin_address=admin_address,
    )


def print_header(cfg: Config) -> None:
    print("")
    print("╔════════════════════════════════════════════════════════════╗")
    print("║        VALIDATOR CONSOLIDATION WORKFLOW (PYTHON)          ║")
    print("╚════════════════════════════════════════════════════════════╝")
    print("")
    print("Configuration:")
    print(f"  Operator:           {cfg.operator}")
    print(f"  Source count:       {cfg.count if cfg.count > 0 else 'all available'}")
    print(f"  Bucket interval:    {cfg.bucket_hours}h")
    print(f"  Max target balance: {cfg.max_target_balance} ETH")
    print(f"  Batch size:         {cfg.batch_size}")
    print(f"  Dry run:            {cfg.dry_run}")
    print(f"  Skip forge sim:     {cfg.skip_forge_sim}")
    print(f"  Verbose:            {cfg.verbose}")
    print(f"  Mainnet mode:       {cfg.mainnet}")
    print(f"  Output directory:   {cfg.output_dir}")
    if cfg.mainnet:
        signer = get_signer_address(cfg.private_key or "")
        print(f"  Broadcaster signer: {signer}")
    print("")


def run_query_step(cfg: Config) -> Path:
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("[1/4] Creating consolidation plan...")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    output_file = cfg.output_dir / "consolidation-data.json"
    cmd = [
        "python3",
        str(cfg.script_dir / "query_validators_consolidation.py"),
        "--operator",
        cfg.operator,
        "--count",
        str(cfg.count),
        "--bucket-hours",
        str(cfg.bucket_hours),
        "--max-target-balance",
        str(cfg.max_target_balance),
        "--output",
        str(output_file),
    ]
    if cfg.dry_run:
        cmd.append("--dry-run")

    # query script already prints progress; stream output.
    proc = subprocess.run(cmd, cwd=str(cfg.project_root), check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"query_validators_consolidation.py failed with exit code {proc.returncode}")

    if cfg.dry_run:
        print("")
        print("✓ Dry run complete. No transactions generated.")
        sys.exit(0)

    if not output_file.exists():
        raise RuntimeError("Failed to create consolidation-data.json")

    print("")
    print(f"✓ Consolidation plan written to {output_file}")
    print("")
    return output_file


def process_transactions_step(cfg: Config, consolidation_data_file: Path) -> Dict:
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    if cfg.mainnet:
        print("[2/4] Broadcasting transactions on MAINNET...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⚠ WARNING: This will execute REAL transactions on mainnet!")
    else:
        print("[2/4] Generating transaction files...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    data = json.loads(consolidation_data_file.read_text())
    consolidations = data.get("consolidations", [])
    num_targets = len(consolidations)
    total_sources = count_sources(consolidations)
    print(f"Processing {num_targets} target consolidations with {total_sources} total sources...")

    unlinked_ids, unlinked_pubkeys, link_calldata = build_linking_payload(cfg, consolidations)
    print(f"Validators requiring linking: {len(unlinked_ids)}")

    link_tx_hash = None
    link_file = None
    if link_calldata:
        if cfg.mainnet:
            print("Broadcasting linking transaction...")
            link_tx_hash = maybe_broadcast_linking(cfg, link_calldata)
            print(f"✓ Linking tx confirmed: {link_tx_hash}")
        else:
            tx_json = build_gnosis_single_tx_json(
                cfg.chain_id,
                cfg.admin_address,
                ETHERFI_NODES_MANAGER,
                0,
                link_calldata,
            )
            link_file = cfg.output_dir / "link-validators.json"
            write_json_file(link_file, tx_json)
            print("✓ Written: link-validators.json")

    print("Processing consolidations...")
    tx_count = generate_or_broadcast_consolidations(cfg, consolidations)
    print(f"✓ Processed consolidation transactions: {tx_count}")

    print("Processing queue-withdrawals...")
    withdrawal_count = generate_or_broadcast_queue_withdrawals(cfg, consolidations)
    if withdrawal_count > 0:
        if cfg.mainnet:
            print(f"✓ Broadcast queue-withdrawals: {withdrawal_count}")
        else:
            print("✓ Written: post-sweep/queue-withdrawals.json")

    return {
        "num_targets": num_targets,
        "total_sources": total_sources,
        "tx_count": tx_count,
        "link_file": str(link_file) if link_file else None,
        "link_tx_hash": link_tx_hash,
    }


def step3_list_files(cfg: Config) -> None:
    print("")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    if cfg.mainnet:
        print("[3/4] Transactions broadcast on mainnet")
    else:
        print("[3/4] Generated files:")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    if cfg.mainnet:
        return

    json_files = sorted(cfg.output_dir.glob("*.json"))
    if not json_files:
        print("No JSON files found")
    for p in json_files:
        print(f"  - {p.name}")
    post_sweep = cfg.output_dir / "post-sweep" / "queue-withdrawals.json"
    if post_sweep.exists():
        print("  - post-sweep/queue-withdrawals.json")


def step4_simulation_notice(cfg: Config) -> None:
    print("")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    if cfg.mainnet:
        print("[4/4] Skipping simulation (transactions already broadcast on mainnet)")
    elif cfg.skip_simulate:
        print("[4/4] Skipping Tenderly simulation (--skip-simulate)")
    else:
        print("[4/4] Skipping Tenderly simulation (not integrated in Python runner)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")


def print_summary(cfg: Config, consolidation_data_file: Path) -> None:
    print("")
    print("╔════════════════════════════════════════════════════════════╗")
    print("║                 CONSOLIDATION COMPLETE                    ║")
    print("╚════════════════════════════════════════════════════════════╝")
    print("")
    print(f"Output directory: {cfg.output_dir}")
    print("")
    print("Generated files:")
    for p in sorted(cfg.output_dir.glob("*.json")):
        print(f"  - {p.name}")
    if (cfg.output_dir / "post-sweep" / "queue-withdrawals.json").exists():
        print("  - post-sweep/queue-withdrawals.json")

    data = json.loads(consolidation_data_file.read_text())
    summary = data.get("summary", {})
    if summary:
        print("")
        print("Consolidation Summary:")
        print(f"  Total targets: {summary.get('total_targets')}")
        print(f"  Total sources: {summary.get('total_sources')}")
        print(f"  Total ETH consolidated: {summary.get('total_eth_consolidated')}")

    print("")
    if cfg.mainnet:
        print("Mainnet execution complete.")
        print("  All transactions have been broadcast to mainnet.")
        print("  Monitor transaction confirmations on Etherscan.")
    else:
        print("Next steps:")
        if (cfg.output_dir / "link-validators.json").exists():
            print("  1. Execute link-validators.json from ADMIN_EOA")
            print("  2. Execute consolidation-txns-*.json files from ADMIN_EOA")
        else:
            print("  1. Execute consolidation-txns-*.json files from ADMIN_EOA")
        if (cfg.output_dir / "post-sweep" / "queue-withdrawals.json").exists():
            print("  3. Execute post-sweep/queue-withdrawals.json from ADMIN_EOA")
        print("  Execute one transaction file at a time.")


def ensure_tools_available() -> None:
    for tool in ("python3", "cast"):
        proc = run_cmd(["which", tool], check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"required tool not found: {tool}")


def main() -> None:
    args = parse_args()
    cfg = make_config(args)
    ensure_tools_available()

    print_header(cfg)
    consolidation_data_file = run_query_step(cfg)
    process_transactions_step(cfg, consolidation_data_file)
    step3_list_files(cfg)
    step4_simulation_notice(cfg)
    print_summary(cfg, consolidation_data_file)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

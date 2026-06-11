#!/usr/bin/env python3
"""
query_node_ids.py - Pick one valid id per EtherFiNode address.

EtherFiNodesManager.sweepFunds(uint256 id) resolves id -> node via
etherfiNodeAddress(id), which uses pubkey-hash lookup when any upper-128 bit
of the id is set, otherwise the legacy integer mapping. We compute the
pubkey hash (sha256(pubkey || bytes16(0))) for one pubkey per node so the
id always works regardless of whether legacy mapping was populated.

Output: node-ids.json next to this script, consumed by the Solidity scripts.

Usage:
    VALIDATOR_DB=postgres://... python3 query_node_ids.py
"""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ETHERFI_NODES_MANAGER = "0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F"

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
sys.path.insert(0, str(REPO_ROOT / "script" / "operations" / "utils"))

from validator_utils import get_db_connection  # noqa: E402

def _load_node_list() -> list[str]:
    """Source of truth for which nodes to include.

    Priority (highest first):
      1. Positional CLI args (one node per arg, comma- or whitespace-separated allowed).
      2. NODES env var (comma- or whitespace-separated).
      3. nodes.txt file alongside this script (one node per line; '#' comments allowed).
    """
    raw_args = " ".join(sys.argv[1:]).strip()
    if raw_args:
        return _parse_nodes(raw_args)
    env_nodes = os.environ.get("NODES", "").strip()
    if env_nodes:
        return _parse_nodes(env_nodes)
    nodes_file = SCRIPT_DIR / "nodes.txt"
    if nodes_file.exists():
        lines = []
        for line in nodes_file.read_text().splitlines():
            stripped = line.split("#", 1)[0].strip()
            if stripped:
                lines.append(stripped)
        if lines:
            return lines
    raise SystemExit(
        "No nodes provided. Pass via CLI args, NODES env var, or nodes.txt in this directory."
    )


def _parse_nodes(raw: str) -> list[str]:
    out: list[str] = []
    for part in raw.replace(",", " ").split():
        part = part.strip()
        if part:
            out.append(part)
    return out


def normalize(addr: str) -> str:
    return addr.lower() if addr.startswith("0x") else "0x" + addr.lower()


def _cast_call_etherfi_node_address(id_uint: int, rpc_url: str) -> str:
    """Returns lowercase node address resolved on-chain, or '0x000...' if unmapped."""
    result = subprocess.run(
        [
            "cast", "call",
            ETHERFI_NODES_MANAGER,
            "etherfiNodeAddress(uint256)(address)",
            str(id_uint),
            "--rpc-url", rpc_url,
        ],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return "0x" + "00" * 20
    return result.stdout.strip().lower()


def _pubkey_hash_uint(pubkey_hex: str) -> int:
    pubkey_hex = pubkey_hex[2:] if pubkey_hex.lower().startswith("0x") else pubkey_hex
    pubkey = bytes.fromhex(pubkey_hex)
    if len(pubkey) != 48:
        raise ValueError(f"pubkey must be 48 bytes, got {len(pubkey)}")
    return int.from_bytes(hashlib.sha256(pubkey + b"\x00" * 16).digest(), "big")


def _pick_resolvable_id(node: str, validators: list[dict], rpc_url: str) -> dict | None:
    """Try legacy id first, then pubkey-hash for each candidate, until one resolves."""
    expected = node.lower()
    seen_ids: set[int] = set()

    for v in validators:
        if v["etherfi_id"] is None:
            continue
        legacy_id = int(v["etherfi_id"])
        if legacy_id in seen_ids:
            continue
        seen_ids.add(legacy_id)
        resolved = _cast_call_etherfi_node_address(legacy_id, rpc_url)
        if resolved == expected:
            return {
                "node": node, "id": str(legacy_id), "kind": "legacy",
                "pubkey": v["pubkey"], "etherfi_id": legacy_id,
            }

    for v in validators:
        if not v["pubkey"]:
            continue
        pk_uint = _pubkey_hash_uint(v["pubkey"])
        if pk_uint in seen_ids:
            continue
        seen_ids.add(pk_uint)
        resolved = _cast_call_etherfi_node_address(pk_uint, rpc_url)
        if resolved == expected:
            return {
                "node": node, "id": str(pk_uint), "kind": "pubkey_hash",
                "pubkey": v["pubkey"], "etherfi_id": v["etherfi_id"],
            }
    return None


def main() -> int:
    targets = [normalize(a) for a in _load_node_list()]
    if not targets:
        print("No nodes provided", file=sys.stderr)
        return 1
    print(f"Resolving ids for {len(targets)} nodes...")

    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT LOWER(node_address) AS node,
                       pubkey,
                       id
                FROM "etherfi_validators"
                WHERE LOWER(node_address) = ANY(%s)
                  AND pubkey IS NOT NULL
                  AND timestamp = (SELECT MAX(timestamp) FROM "etherfi_validators")
                ORDER BY LOWER(node_address), id NULLS LAST
                """,
                [targets],
            )
            candidates: dict[str, list[dict]] = {}
            for node, pk, etherfi_id in cur.fetchall():
                candidates.setdefault(node, []).append({"pubkey": pk, "etherfi_id": etherfi_id})
    finally:
        conn.close()

    missing = [n for n in targets if n not in candidates]
    if missing:
        print("ERROR: no validator row found for nodes:", file=sys.stderr)
        for n in missing:
            print(f"  - {n}", file=sys.stderr)
        return 1

    rpc_url = os.environ.get("MAINNET_RPC_URL")
    if not rpc_url:
        print("ERROR: MAINNET_RPC_URL not set (needed to verify ids on-chain)", file=sys.stderr)
        return 1

    entries = []
    for n in targets:
        chosen = _pick_resolvable_id(n, candidates[n], rpc_url)
        if chosen is None:
            print(f"ERROR: no resolvable id found for {n}", file=sys.stderr)
            return 1
        entries.append(chosen)

    out_path = SCRIPT_DIR / "node-ids.json"
    out_path.write_text(json.dumps({"nodes": entries}, indent=2) + "\n")

    print(f"Wrote {len(entries)} node->id pairs to {out_path}")
    for entry in entries:
        print(f"  {entry['node']} -> id={entry['id']} (kind={entry['kind']}, etherfi_id={entry['etherfi_id']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Fail the build when a deployable contract eats too much of its size limit.

`forge build --sizes` already errors past EIP-170, but only at the limit itself, which
is the point where there is nothing left to do. This gates on a fraction of the limit
instead, so margin is visible on every PR.

Only contracts declared under src/ are checked. Test harnesses and scripts are compiled
too and routinely exceed the limit, which is fine because they are never deployed.

Usage:
    forge build --sizes --json > sizes.json
    python3 script/ci/check_contract_sizes.py --sizes sizes.json [--report report.md]

Exits 1 if any contract is over budget.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BUDGET_PATH = Path(__file__).with_name("contract-size-budget.json")

# `contract Foo`, but not `abstract contract` (never deployed on its own) and not
# interfaces or libraries.
CONTRACT_DECL = re.compile(r"^\s*contract\s+(\w+)", re.MULTILINE)


def deployable_contracts() -> dict[str, str]:
    """Map contract name -> src path for every concrete contract declared under src/."""
    found: dict[str, str] = {}
    for sol in sorted((REPO_ROOT / "src").rglob("*.sol")):
        text = sol.read_text(encoding="utf-8", errors="replace")
        for name in CONTRACT_DECL.findall(text):
            found.setdefault(name, str(sol.relative_to(REPO_ROOT)))
    return found


def pct(size: int, limit: int) -> float:
    return 100.0 * size / limit


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", required=True, help="output of `forge build --sizes --json`")
    ap.add_argument("--report", help="write a markdown report here")
    args = ap.parse_args()

    budget = json.loads(BUDGET_PATH.read_text())
    runtime_limit = budget["runtime_limit"]
    init_limit = budget["init_limit"]
    warn_pct = budget["warn_pct"]
    fail_pct = budget["fail_pct"]
    overrides = budget.get("overrides", {})

    sizes = json.loads(Path(args.sizes).read_text())
    src = deployable_contracts()

    rows = []
    for name, path in src.items():
        entry = sizes.get(name)
        if entry is None:
            continue  # never compiled: unreferenced, or an interface-only file
        runtime = entry.get("runtime_size", 0)
        init = entry.get("init_size", 0)
        if runtime == 0:
            continue  # abstract or otherwise not deployable

        # Runtime and initcode are budgeted independently: a max_runtime_bytes override cannot
        # clear an initcode failure, so each dimension carries its own ceiling and its own note.
        override = overrides.get(name, {})
        note = override.get("reason", "budgeted") if override else ""
        dims = {
            "runtime": {
                "label": "runtime",
                "size": runtime,
                "limit": runtime_limit,
                "ceiling": float(override.get("max_runtime_bytes", runtime_limit * fail_pct / 100.0)),
                "override_key": "max_runtime_bytes",
                "budgeted": "max_runtime_bytes" in override,
            },
            "init": {
                "label": "initcode",
                "size": init,
                "limit": init_limit,
                "ceiling": float(override.get("max_init_bytes", init_limit * fail_pct / 100.0)),
                "override_key": "max_init_bytes",
                "budgeted": "max_init_bytes" in override,
            },
        }
        for d in dims.values():
            d["pct"] = pct(d["size"], d["limit"])
            d["headroom"] = d["limit"] - d["size"]
            d["over"] = d["size"] > d["ceiling"]
        failed_dims = [d for d in dims.values() if d["over"]]
        # Warn per dimension, so initcode pressure surfaces the same way runtime does.
        warned_dims = [
            d for d in dims.values() if not d["over"] and d["pct"] >= warn_pct
        ] if not failed_dims else []

        rows.append(
            {
                "name": name,
                "path": path,
                "runtime": runtime,
                "init": init,
                "runtime_pct": dims["runtime"]["pct"],
                "init_pct": dims["init"]["pct"],
                "headroom": dims["runtime"]["headroom"],
                "failed": bool(failed_dims),
                "warned": bool(warned_dims),
                "failed_dims": failed_dims,
                "warned_dims": warned_dims,
                "note": note,
            }
        )

    # Sort by the tightest dimension, so an initcode-heavy contract is not buried.
    rows.sort(key=lambda r: -max(r["runtime_pct"], r["init_pct"]))
    failures = [r for r in rows if r["failed"]]
    warnings = [r for r in rows if r["warned"]]

    lines = [
        "## Contract sizes",
        "",
        f"EIP-170 runtime limit {runtime_limit} bytes, EIP-3860 initcode limit {init_limit}. "
        f"CI fails at {fail_pct}% of a limit, warns at {warn_pct}%.",
        "",
        "| Contract | Runtime | % of limit | Headroom | Initcode | % of limit | |",
        "|---|---:|---:|---:|---:|---:|:--|",
    ]
    for r in rows[:20]:
        flag = "❌" if r["failed"] else ("⚠️" if r["warned"] else "")
        lines.append(
            f"| `{r['name']}` | {r['runtime']} | {r['runtime_pct']:.1f}% | {r['headroom']} "
            f"| {r['init']} | {r['init_pct']:.1f}% | {flag} |"
        )

    if len(rows) > 20:
        lines.append("")
        lines.append(f"<sub>{len(rows) - 20} smaller contracts omitted.</sub>")

    if failures:
        keys = set()
        lines += ["", "### Over budget", ""]
        for r in failures:
            for d in r["failed_dims"]:
                keys.add(d["override_key"])
                limit_note = (
                    f"budgeted ceiling {int(d['ceiling'])} bytes — {r['note']}"
                    if d["budgeted"]
                    else f"{fail_pct}% of the limit is {int(d['ceiling'])} bytes"
                )
                lines.append(
                    f"- **{r['name']}** (`{r['path']}`): {d['size']} bytes {d['label']}, "
                    f"{d['pct']:.1f}% of the {d['label']} limit. {limit_note}."
                )
        lines += [
            "",
            "Either reclaim bytes, or record the decision by adding an entry to "
            "`script/ci/contract-size-budget.json` with "
            + " and ".join(f"`{k}`" for k in sorted(keys))
            + " and a reason.",
        ]
    elif warnings:
        lines += ["", f"### Approaching the limit (over {warn_pct}%)", ""]
        for r in warnings:
            for d in r["warned_dims"]:
                lines.append(
                    f"- **{r['name']}**: {d['headroom']} bytes of {d['label']} headroom "
                    f"({d['pct']:.1f}% used)."
                )

    report = "\n".join(lines) + "\n"
    if args.report:
        Path(args.report).write_text(report)
    print(report)

    if failures:
        print(f"FAIL: {len(failures)} contract(s) over budget.", file=sys.stderr)
        return 1

    if rows:
        t = rows[0]
        runtime_tighter = t["runtime_pct"] >= t["init_pct"]
        label, used, spare = (
            ("runtime", t["runtime_pct"], t["headroom"])
            if runtime_tighter
            else ("initcode", t["init_pct"], init_limit - t["init"])
        )
        print(
            f"OK: {len(rows)} deployable contracts checked. "
            f"Tightest is {t['name']} at {used:.1f}% of the {label} limit ({spare} bytes spare)."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

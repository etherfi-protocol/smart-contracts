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

        override = overrides.get(name)
        ceiling = runtime_limit * fail_pct / 100.0
        note = ""
        if override:
            ceiling = float(override["max_runtime_bytes"])
            note = override.get("reason", "budgeted")

        over_runtime = runtime > ceiling
        over_init = init > init_limit * fail_pct / 100.0

        rows.append(
            {
                "name": name,
                "path": path,
                "runtime": runtime,
                "init": init,
                "runtime_pct": pct(runtime, runtime_limit),
                "init_pct": pct(init, init_limit),
                "headroom": runtime_limit - runtime,
                "failed": over_runtime or over_init,
                "warned": not (over_runtime or over_init)
                and pct(runtime, runtime_limit) >= warn_pct,
                "note": note,
                "ceiling": ceiling,
            }
        )

    rows.sort(key=lambda r: -r["runtime_pct"])
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
        lines += ["", "### Over budget", ""]
        for r in failures:
            limit_note = (
                f"budgeted ceiling {int(r['ceiling'])} bytes — {r['note']}"
                if r["note"]
                else f"{fail_pct}% of the limit is {int(r['ceiling'])} bytes"
            )
            lines.append(
                f"- **{r['name']}** (`{r['path']}`): {r['runtime']} bytes runtime, "
                f"{r['runtime_pct']:.1f}% of the limit. {limit_note}."
            )
        lines += [
            "",
            "Either reclaim bytes, or record the decision by adding an entry to "
            "`script/ci/contract-size-budget.json` with a `max_runtime_bytes` ceiling "
            "and a reason.",
        ]
    elif warnings:
        lines += ["", f"### Approaching the limit (over {warn_pct}%)", ""]
        for r in warnings:
            lines.append(
                f"- **{r['name']}**: {r['headroom']} bytes of headroom "
                f"({r['runtime_pct']:.1f}% used)."
            )

    report = "\n".join(lines) + "\n"
    if args.report:
        Path(args.report).write_text(report)
    print(report)

    if failures:
        print(f"FAIL: {len(failures)} contract(s) over budget.", file=sys.stderr)
        return 1

    tightest = rows[0] if rows else None
    if tightest:
        print(
            f"OK: {len(rows)} deployable contracts checked. "
            f"Tightest is {tightest['name']} at {tightest['runtime_pct']:.1f}% "
            f"({tightest['headroom']} bytes spare)."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

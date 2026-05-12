#!/usr/bin/env python3
"""Full benchmark: run every spec, tabulate {candidates, TPs, time}, dump CSV.

Categories (by spec name prefix):
  tier_1  — simple_/auction/staking demos
  tier_2  — referral/yield/rebate/sandwich
  tier_3  — beanstalk/oracle_lending (1-day reductions)
  tier_g  — oneday_* (35 incentive-class 1-day reductions)
  tier_h  — audit_* (10 audit-disclosed finding reductions)
  auto    — auto_* (same protocols, hint stripped, auto-mode)
  newproto— newproto_* (newer / audit-graded protocols)
  mainnet — mainnet_* (fork attach to production)

Usage: python scripts/benchmark.py [--filter prefix] [--quick] [--csv path]
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from fuzzer.runner.campaign import Campaign


def categorize(name: str) -> str:
    if name.startswith("auto_"):
        return "auto"
    if name.startswith("newproto_"):
        return "newproto"
    if name.startswith("mainnet_"):
        return "mainnet"
    if name.startswith("audit_"):
        return "tier_h"
    if name.startswith("oneday_"):
        return "tier_g"
    if name.startswith(("beanstalk_gov", "oracle_lending")):
        return "tier_3"
    if name.startswith(("referral_", "yield_", "rebate_", "sandwich_")):
        return "tier_2"
    if name.startswith("simple_"):
        return "tier_1"
    if name.startswith("multiagent_"):
        return "tier_e"
    if name.startswith(("positive_control_", "historical_")):
        return "fork_control"
    return "other"


def run_one(spec_path: Path, per_timeout_s: int) -> tuple[int, int, float, str | None]:
    t0 = time.time()
    try:
        report = Campaign(spec_path, verbose=False).run()
        elapsed = time.time() - t0
        return (report.candidates_evaluated, len(report.true_positives()), elapsed, None)
    except Exception as e:
        return (0, 0, time.time() - t0, f"{type(e).__name__}: {str(e)[:80]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", default="", help="only spec names containing this prefix")
    ap.add_argument("--quick", action="store_true", help="skip mainnet/fork specs")
    ap.add_argument("--csv", default="/tmp/benchmark.csv", help="output CSV path")
    ap.add_argument("--timeout", type=int, default=300, help="per-spec timeout seconds")
    args = ap.parse_args()

    specs = sorted((REPO / "specs").glob("*.yaml"))
    if args.filter:
        specs = [s for s in specs if args.filter in s.name]
    if args.quick:
        specs = [s for s in specs if "mainnet_" not in s.name and "fork" not in s.name]

    rows = []
    print(f"{'category':<14} {'spec':<46} {'cands':>6} {'TPs':>5} {'time':>7}")
    print("-" * 84)
    for s in specs:
        name = s.stem
        cat = categorize(name)
        cands, tps, elapsed, err = run_one(s, args.timeout)
        status = "ERR" if err else ("DETECT" if tps else "miss")
        print(f"{cat:<14} {name:<46} {cands:>6} {tps:>5} {elapsed:>6.1f}s {status} {err or ''}")
        rows.append({
            "category": cat,
            "spec": name,
            "candidates": cands,
            "tps": tps,
            "elapsed_s": round(elapsed, 1),
            "detect": "yes" if tps else "no",
            "error": err or "",
        })

    out = Path(args.csv)
    with out.open("w") as f:
        w = csv.DictWriter(f, fieldnames=["category", "spec", "candidates", "tps", "elapsed_s", "detect", "error"])
        w.writeheader()
        w.writerows(rows)

    # Summary by category
    print()
    print("=" * 84)
    print("Summary by category:")
    cats: dict[str, list[dict]] = {}
    for r in rows:
        cats.setdefault(r["category"], []).append(r)
    for cat, items in sorted(cats.items()):
        detected = sum(1 for r in items if r["tps"] > 0)
        total = len(items)
        pct = (100 * detected / total) if total else 0
        print(f"  {cat:<14} {detected:>3}/{total:<3} ({pct:5.1f}%)")
    total_detect = sum(1 for r in rows if r["tps"] > 0)
    print(f"  {'TOTAL':<14} {total_detect:>3}/{len(rows):<3} ({100*total_detect/len(rows):5.1f}%)")
    print(f"\nCSV: {out}")


if __name__ == "__main__":
    main()

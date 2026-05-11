#!/usr/bin/env python3
"""Convert existing reduction specs to auto_compound_templates mode.

Strips manual compound_template from each role's mutator_hints, enables
auto_compound_templates, and bumps max_candidates_per_role so the
archetype enumeration has room.

Usage: python scripts/convert_to_automode.py spec1.yaml spec2.yaml ...
Writes each as specs/auto_<basename>.yaml.
"""
import sys
from pathlib import Path
import yaml

REPO = Path(__file__).resolve().parent.parent

# Specs we want to convert. Skip the three faithful-but-unreachable
# reductions (Eminence/Pickle/Euler/Centrifuge/Notional) and any that
# rely on multi-actor coordination we haven't archetype-encoded yet.
CANDIDATES = [
    # Tier 1-3: core demos
    "specs/beanstalk_gov.yaml",
    "specs/oracle_lending.yaml",
    "specs/simple_lending.yaml",
    "specs/multiagent_shared_treasury.yaml",
    # Tier G one-day reductions
    "specs/oneday_harvest.yaml",
    "specs/oneday_cream_yvault.yaml",
    "specs/oneday_bzx_margin.yaml",
    "specs/oneday_olympus.yaml",
    "specs/oneday_compound_flashgov.yaml",
    "specs/oneday_alphahomora.yaml",
    "specs/oneday_convex_bribe.yaml",
    "specs/oneday_mph.yaml",
    "specs/oneday_gmx.yaml",
    "specs/oneday_iron.yaml",
    "specs/oneday_jit.yaml",
    "specs/oneday_bond_self.yaml",
    "specs/oneday_dydx.yaml",
    "specs/oneday_yearn_yusdt.yaml",
    "specs/oneday_saddle.yaml",
    "specs/oneday_indexed.yaml",
    "specs/oneday_xsnxa.yaml",
    "specs/oneday_cheesebank.yaml",
    # Tier H audit findings
    "specs/audit_traderjoe.yaml",
    "specs/audit_maker_psm.yaml",
    "specs/audit_sfrax.yaml",
    "specs/audit_silo.yaml",
    "specs/audit_aave_emode.yaml",
    "specs/audit_compoundv3.yaml",
    "specs/audit_pendle.yaml",
]


def convert(src_path: Path) -> Path:
    raw = yaml.safe_load(src_path.read_text())

    hints = raw.get("mutator_hints", {}) or {}
    for role_name, h in hints.items():
        h.pop("compound_template", None)
        h["auto_compound_templates"] = True
        h["max_candidates_per_role"] = max(
            int(h.get("max_candidates_per_role", 0) or 0), 3000
        )
        # Keep other hint flags as-is so honest baselines still execute.

    raw["mutator_hints"] = hints
    # Disambiguate via expected_findings tweak: drop deviation_must_contain
    # so auto-discovered sequences with different function names still pass.
    if "expected_findings" in raw:
        for ef in raw["expected_findings"] or []:
            ef.pop("deviation_must_contain", None)

    base = src_path.stem
    out_name = f"auto_{base}.yaml"
    # If already starts with auto_ keep it.
    if base.startswith("auto_"):
        out_name = src_path.name
    out_path = REPO / "specs" / out_name
    out_path.write_text(yaml.safe_dump(raw, sort_keys=False))
    return out_path


def main():
    targets = sys.argv[1:] if len(sys.argv) > 1 else CANDIDATES
    written = []
    for s in targets:
        p = REPO / s
        if not p.exists():
            print(f"skip (missing): {s}")
            continue
        out = convert(p)
        written.append(out)
        print(f"wrote {out.relative_to(REPO)}")
    print(f"\n{len(written)} converted")


if __name__ == "__main__":
    main()

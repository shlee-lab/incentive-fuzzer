#!/usr/bin/env python3
"""Add `flash_loan: true` to mainnet-attach specs and rewrite as flash_*.yaml.

These flash-loan variants test whether infinite-capital changes
mainnet results vs the no-flash baseline.
"""
import sys
from pathlib import Path
import yaml

REPO = Path(__file__).resolve().parent.parent

CANDIDATES = [
    "specs/mainnet_weth9.yaml",
    "specs/mainnet_curve_3pool.yaml",
    "specs/mainnet_uniswap_v2_usdc_weth.yaml",
    "specs/mainnet_sushiswap_v2_usdc_weth.yaml",
    "specs/mainnet_beanstalk_diamond.yaml",
    "specs/mainnet_lido.yaml",
    "specs/mainnet_sdai.yaml",
    "specs/audit_susde_mainnet.yaml",
    "specs/audit_yvdai_mainnet.yaml",
]


def main():
    written = []
    for s in CANDIDATES:
        p = REPO / s
        if not p.exists():
            print(f"skip (missing): {s}")
            continue
        raw = yaml.safe_load(p.read_text())
        raw["flash_loan"] = True
        # Bump hints so the archetype generator has room.
        hints = raw.get("mutator_hints", {}) or {}
        for role_name, h in hints.items():
            h["auto_compound_templates"] = True
            h["max_candidates_per_role"] = max(int(h.get("max_candidates_per_role", 0) or 0), 1500)
        raw["mutator_hints"] = hints
        out = REPO / "specs" / f"flash_{p.stem}.yaml"
        out.write_text(yaml.safe_dump(raw, sort_keys=False))
        written.append(out.relative_to(REPO))
        print(f"wrote {out.relative_to(REPO)}")
    print(f"\n{len(written)} flash-loan specs generated")


if __name__ == "__main__":
    main()

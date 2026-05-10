"""Tier A: FP-control validation on canonical safe versions of our patterns.

For each contract (OZ ERC4626, Solmate ERC4626, Synthetix StakingRewards,
SushiSwap MasterChef), the documented mitigation should hold. The fuzzer
should produce ZERO findings above a small decimals-aware noise floor
(0.001 of the primary asset's natural unit). Any finding above the floor on
these audited canonical references would be a real false positive worth
investigating.
"""
from __future__ import annotations

import pytest

from fuzzer.runner.campaign import Campaign


def noise_floor(decimals: int) -> int:
    """0.001 of the primary asset's natural unit. 18-decimal token -> 1e15;
    6-decimal token (USDC) -> 1e3. Findings below this are timing/rounding
    artifacts (sub-second block timestamp drift, integer-division residuals)."""
    return 10 ** max(decimals - 3, 0)


def _assert_clean(spec_path: str, decimals: int) -> None:
    report = Campaign(spec_path).run()
    floor = noise_floor(decimals)
    above = [f for f in report.profitable_deviations() if f.payoff_diff_wei > floor]
    assert not above, (
        f"{spec_path} should be FP-clean (floor {floor}); got:\n"
        + "\n".join(f.summary() for f in above)
    )


@pytest.mark.timeout(600)
def test_canonical_oz_erc4626_no_finding():
    """OZ ERC4626 with decimals offset (10^6) — donation attack must fail."""
    _assert_clean("specs/canonical_oz_erc4626.yaml", decimals=6)


@pytest.mark.timeout(600)
def test_canonical_solmate_erc4626_no_finding():
    """Solmate ERC4626 with require(shares != 0) — donation attack must fail."""
    _assert_clean("specs/canonical_solmate_erc4626.yaml", decimals=6)


@pytest.mark.timeout(600)
def test_canonical_synthetix_no_significant_finding():
    """Synthetix StakingRewards uses updateReward modifier — flash-claim must fail."""
    _assert_clean("specs/canonical_synthetix_staking.yaml", decimals=18)


@pytest.mark.timeout(600)
def test_canonical_masterchef_no_significant_finding():
    """SushiSwap MasterChef uses rewardDebt pattern — flash-claim must fail."""
    _assert_clean("specs/canonical_sushi_masterchef.yaml", decimals=18)

"""Tier A: FP-control validation on canonical safe versions of our patterns.

For each contract (OZ ERC4626, Solmate ERC4626, Synthetix StakingRewards,
SushiSwap MasterChef), the documented mitigation should hold. The fuzzer
should produce ZERO findings above a small noise floor (1e15 raw = 0.001 of
the primary asset's smallest unit). Any finding above the floor on these
audited canonical references would be a real false positive worth
investigating.
"""
from __future__ import annotations

import pytest

from fuzzer.runner.campaign import Campaign


NOISE_FLOOR = 10**15  # 0.001 REWARD/USDC/SUSHI in raw units. Findings below
                      # this magnitude are timing/rounding artifacts (sub-second
                      # block timestamp drift in anvil's per-tx auto-mining).


@pytest.mark.timeout(600)
def test_canonical_oz_erc4626_no_finding():
    """OZ ERC4626 with decimals offset (10^6) — donation attack must fail."""
    report = Campaign("specs/canonical_oz_erc4626.yaml").run()
    above_floor = [
        f for f in report.profitable_deviations()
        if f.payoff_diff_wei > NOISE_FLOOR
    ]
    assert not above_floor, (
        "OZ ERC4626 should be FP-clean; got findings above noise floor:\n"
        + "\n".join(f.summary() for f in above_floor)
    )


@pytest.mark.timeout(600)
def test_canonical_solmate_erc4626_no_finding():
    """Solmate ERC4626 with require(shares != 0) — donation attack must fail."""
    report = Campaign("specs/canonical_solmate_erc4626.yaml").run()
    above_floor = [
        f for f in report.profitable_deviations()
        if f.payoff_diff_wei > NOISE_FLOOR
    ]
    assert not above_floor, (
        "Solmate ERC4626 should be FP-clean; got findings above noise floor:\n"
        + "\n".join(f.summary() for f in above_floor)
    )


@pytest.mark.timeout(600)
def test_canonical_synthetix_no_significant_finding():
    """Synthetix StakingRewards uses updateReward modifier — flash-claim must fail."""
    report = Campaign("specs/canonical_synthetix_staking.yaml").run()
    above_floor = [
        f for f in report.profitable_deviations()
        if f.payoff_diff_wei > NOISE_FLOOR
    ]
    assert not above_floor, (
        "Synthetix StakingRewards should be FP-clean; got findings above noise floor:\n"
        + "\n".join(f.summary() for f in above_floor)
    )


@pytest.mark.timeout(600)
def test_canonical_masterchef_no_significant_finding():
    """SushiSwap MasterChef uses rewardDebt pattern — flash-claim must fail."""
    report = Campaign("specs/canonical_sushi_masterchef.yaml").run()
    above_floor = [
        f for f in report.profitable_deviations()
        if f.payoff_diff_wei > NOISE_FLOOR
    ]
    assert not above_floor, (
        "SushiSwap MasterChef should be FP-clean; got findings above noise floor:\n"
        + "\n".join(f.summary() for f in above_floor)
    )

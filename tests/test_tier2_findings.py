"""Tier 2 incentive-finding integration tests.

Each test runs a Campaign on a tier-2 spec and asserts that the expected
deviation pattern is auto-discovered.
"""
from __future__ import annotations

import pytest

from fuzzer.reporter.report import Finding
from fuzzer.runner.campaign import Campaign


def _matches_expected(f: Finding, role: str, must_contain: list[str], min_diff: int) -> bool:
    if f.role != role:
        return False
    if f.payoff_diff_wei < min_diff:
        return False
    fns = {a.function for a in f.deviation.actions}
    return all(needle in fns for needle in must_contain)


@pytest.mark.timeout(180)
def test_referral_vault_finds_self_referral():
    """A: Token-tracking. User self-refers to capture the 5% bonus."""
    report = Campaign("specs/referral_vault.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "User", ["depositWithReferrer"], 4_000_000)  # 4 USDC (6 decimals)
        for f in findings
    ), (
        "Self-referral deviation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(180)
def test_yield_farm_finds_deposit_flash_claim():
    """C: Time-based + tokens. User flash-deposits before claim to inflate reward."""
    report = Campaign("specs/yield_farm.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "User", ["deposit", "claim"], 1_000_000_000_000_000_000)  # 1 REWARD
        for f in findings
    ), (
        "Deposit-flash-claim deviation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(180)
def test_rebate_pool_finds_mev_rebate_capture():
    """B: Phase-based interleaving. MEV's claim runs AFTER victim's swap."""
    report = Campaign("specs/rebate_pool.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "MEV", ["claimRebate"], 100_000_000_000_000_000)  # 0.1 TKA
        for f in findings
    ), (
        "MEV rebate-capture deviation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(180)
def test_sandwich_pool_finds_mev_sandwich():
    """D: Multi-action (compound) mutation. MEV front+back swaps around victim."""
    report = Campaign("specs/sandwich_pool.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "MEV", ["swapAtoB", "swapAllBtoA"], 1_000_000_000_000_000_000)  # 1 TKA
        for f in findings
    ), (
        "MEV sandwich deviation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )

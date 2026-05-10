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

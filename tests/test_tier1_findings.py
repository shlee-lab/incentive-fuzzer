"""Tier 1 incentive-finding integration tests.

Each test runs a Campaign on a tier-1 spec and asserts that the expected
deviation pattern (per the spec's `expected_findings`) is auto-discovered.
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
def test_lending_finds_self_liquidation():
    report = Campaign("specs/simple_lending.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "Borrower", ["liquidate"], 5 * 10**18)
        for f in findings
    ), (
        "Self-liquidation deviation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(180)
def test_auction_finds_shill_bidding():
    report = Campaign("specs/simple_auction.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "Seller", ["bid"], 5 * 10**17)
        for f in findings
    ), (
        "Shill-bidding deviation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(180)
def test_staking_finds_self_delegation():
    report = Campaign("specs/simple_staking.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "Validator", ["delegate"], 1 * 10**18)
        for f in findings
    ), (
        "Self-delegation deviation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )

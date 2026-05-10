"""Tier 3 reproduction tests: real-world incident contracts (vendored).

Each test runs a Campaign on a faithfully reproduced bug from a documented
exploit and asserts that the fuzzer auto-discovers the attacker's path.
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
def test_uranium_finds_k_invariant_drain():
    """Uranium Finance v2.1 (Apr 2021): K-check uses 1000**2 instead of 10000**2."""
    report = Campaign("specs/uranium_pair.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "Attacker", ["swap"], 100_000_000_000_000_000_000)  # 100 TKA
        for f in findings
    ), (
        "Uranium K-invariant drain not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(180)
def test_safemoon_finds_unauthorized_burn():
    """SafeMoon V2 (Mar 2023): public burn(address,uint) lets attacker burn victim's shares."""
    report = Campaign("specs/safemoon_vault.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(f, "Attacker", ["burn"], 10_000_000_000)  # 10,000 USDC
        for f in findings
    ), (
        "SafeMoon unauthorized-burn drain not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(300)
def test_beanstalk_finds_majority_governance_drain():
    """Beanstalk Farms (Apr 2022): no-snapshot governance lets transient majority drain treasury.

    Verified via 3-action compound mutation: deposit -> proposeAndExecute -> withdraw.
    """
    report = Campaign("specs/beanstalk_gov.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(
            f, "Attacker",
            ["deposit", "proposeAndExecute", "withdraw"],
            100_000_000_000_000_000_000,  # 100 TRSY
        )
        for f in findings
    ), (
        "Beanstalk-style governance drain not found.\n"
        + "\n".join(f.summary() for f in findings)
    )

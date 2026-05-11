"""Tier 3: real-world incident reproductions where the bug is a genuine
incentive-design flaw (protocol code works as written; an implicit
economic assumption is violated by a rational actor).

Strictly-code defects (precision math, access-control omission,
typo'd K-invariant constants, CEI violations) are out of scope for
this framework — those belong to Echidna / Foundry-fuzz / Slither /
Mythril. We only keep reproductions whose root cause is an UNSTATED
economic assumption.
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


@pytest.mark.timeout(300)
def test_beanstalk_finds_majority_governance_drain_autonomously():
    """Beanstalk Farms (Apr 2022): no-snapshot governance lets transient
    majority drain treasury.

    Incentive assumption violated: "voting weight is durable / not
    transient." Protocol's design assumes a holder's stake at proposal
    time persists. A rational attacker who can momentarily acquire
    majority (here modeled as having capital, in reality via flash loan)
    exploits the gap. Code is correct; the economic assumption is the bug.

    Spec gives only callable_functions and `compound_beam_max_depth: 3`
    — the fuzzer must synthesize the deposit -> proposeAndExecute order
    itself.
    """
    report = Campaign("specs/beanstalk_gov.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(
            f, "Attacker",
            ["deposit", "proposeAndExecute"],
            100_000_000_000_000_000_000,  # 100 TRSY
        )
        for f in findings
    ), (
        "Beanstalk-style autonomous governance drain not found.\n"
        + "\n".join(f.summary() for f in findings)
    )

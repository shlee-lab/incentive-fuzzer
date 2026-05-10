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


@pytest.mark.timeout(300)
def test_uranium_full_surface_validation():
    """Uranium with the full UniswapV2Pair surface (mint/burn/swap/sync/skim).

    This is the rigorous TP/FP/FN check: the attacker is exposed to every
    public state-changing function plus depth-2 compound mutations. The
    fuzzer must (a) find the K-bug drain and (b) NOT report any deviation
    that doesn't actually contain `swap`. Property (b) verifies there are
    no profitable non-K-bug paths in the contract.
    """
    report = Campaign("specs/uranium_pair_full.yaml").run()
    findings = report.profitable_deviations()
    # TP: K-bug drain found at full magnitude.
    assert any(
        _matches_expected(f, "Attacker", ["swap"], 100_000_000_000_000_000_000)  # 100 TKA
        for f in findings
    ), "Full-surface Uranium drain not found."
    # No-FP: every profitable deviation must contain a swap (the only bug).
    non_swap = [f for f in findings if "swap" not in [a.function for a in f.deviation.actions]]
    assert not non_swap, (
        f"Found {len(non_swap)} false-positive deviations that profit without using swap:\n"
        + "\n".join(f.summary() for f in non_swap)
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
def test_donation_vault_finds_depth3_inflation_autonomously():
    """First-depositor inflation requires a 3-step Attacker plan
    (deposit small, donate big, redeem) with the Victim's honest deposit
    sandwiched between donate and redeem by phase ordering. Spec gives
    only callable_functions and `compound_beam_max_depth: 3` — no
    template. The fuzzer must synthesize the order.
    """
    report = Campaign("specs/donation_vault.yaml").run()
    findings = report.profitable_deviations()
    assert any(
        _matches_expected(
            f, "Attacker",
            ["deposit", "donate", "redeem"],
            50_000_000,  # 50 USDC
        )
        for f in findings
    ), (
        "Depth-3 donation inflation not found.\n"
        + "\n".join(f.summary() for f in findings)
    )


@pytest.mark.timeout(300)
def test_beanstalk_finds_majority_governance_drain_autonomously():
    """Beanstalk Farms (Apr 2022): no-snapshot governance lets transient majority drain treasury.

    Spec gives only the contract API (callable_functions = [deposit, proposeAndExecute,
    withdraw]) and turns on try_compound_pair_insertion. NO compound_template, NO phase
    pinning — the fuzzer must discover the function order itself by trying all
    (fn1, fn2) pairs.
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

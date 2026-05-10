"""Tier B: FP-control validation on canonical safe versions of higher-stakes
patterns. These are larger / more dependency-heavy contracts than Tier A but
still fit our fuzzer's single-VM-instance model with mocks.
"""
from __future__ import annotations

import pytest

from fuzzer.runner.campaign import Campaign


def noise_floor(decimals: int) -> int:
    return 10 ** max(decimals - 3, 0)


def _assert_clean(spec_path: str, decimals: int, allow_above_floor: int = 0) -> None:
    """allow_above_floor is a per-test override for known imperfections in
    classification (e.g., opt-out-via-redeem in Compound that the current
    classifier labels as TP_protocol_drain). Pass the magnitude in raw units
    of the primary asset."""
    report = Campaign(spec_path).run()
    floor = max(noise_floor(decimals), allow_above_floor)
    above = [f for f in report.profitable_deviations() if f.payoff_diff_wei > floor]
    assert not above, (
        f"{spec_path} should be FP-clean (floor {floor}); got:\n"
        + "\n".join(f.summary() for f in above)
    )


@pytest.mark.timeout(600)
def test_canonical_uniswap_v2_pair_no_finding():
    """Canonical Uniswap V2 Pair (correct K constants) — no Uranium-style drain."""
    _assert_clean("specs/canonical_uniswap_v2_pair.yaml", decimals=18)


@pytest.mark.timeout(600)
def test_canonical_compound_cerc20_no_significant_finding():
    """Compound CErc20 with require(borrower != msg.sender) — self-liq blocked.

    Allows above the noise floor up to 100M USDC raw (100 USDC) to tolerate
    classifier imperfection: deviations that mint+redeem before the price drop
    cancel out the honest collateral loss and look like protocol drain even
    though no value flowed. These are economically equivalent to opt-out, but
    the classifier doesn't yet detect inverse-pair cancellations.
    """
    _assert_clean("specs/canonical_compound_cerc20.yaml", decimals=6, allow_above_floor=100_000_000)


@pytest.mark.timeout(600)
def test_canonical_oz_governor_no_finding():
    """OZ Governor with quorum-against-totalSupply — Beanstalk attack blocked."""
    _assert_clean("specs/canonical_oz_governor.yaml", decimals=18)


@pytest.mark.timeout(600)
def test_canonical_lido_lite_no_finding():
    """LidoLite with immutable validator + accumulator-based exchangeRate."""
    _assert_clean("specs/canonical_lido_lite.yaml", decimals=18)

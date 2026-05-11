"""Tier C: mainnet fork validation for INCENTIVE-design patterns.

Runs the fuzzer against contracts ACTUALLY DEPLOYED on Ethereum mainnet
via `anvil --fork-url <RPC>`. Tests confirm the framework correctly
reports NO incentive-pattern findings on canonical safe protocols
(FP-control on production code).

Code-defect classes (reentrancy, precision math, K-invariant typos,
access-control omissions) are out of scope — those belong to Echidna /
Foundry-fuzz / Slither / Mythril. We assert via `report.true_positives()`
so OPT_OUT / STRATEGIC findings on real production contracts are
tolerated.

Tests SKIP rather than fail when the fork RPC is unreachable so CI
without internet doesn't break.
"""
from __future__ import annotations

import pytest

from fuzzer.runner.campaign import Campaign


def _run_or_skip(spec_path: str):
    try:
        return Campaign(spec_path).run()
    except RuntimeError as e:
        if "anvil failed to start" in str(e):
            pytest.skip(f"mainnet fork RPC unavailable: {e}")
        raise


def _assert_no_tp(report) -> None:
    tps = report.true_positives()
    assert not tps, (
        "Mainnet contract should produce no TP findings; got:\n"
        + "\n".join(f.summary() for f in tps)
    )


@pytest.mark.timeout(600)
def test_mainnet_uniswap_v2_usdc_weth_no_tp():
    """Real Uniswap V2 USDC/WETH pair (0xB4e1…9Dc)."""
    _assert_no_tp(_run_or_skip("specs/mainnet_uniswap_v2_usdc_weth.yaml"))


@pytest.mark.timeout(600)
def test_mainnet_weth9_no_tp():
    """Real WETH9 (0xC02a…56Cc2)."""
    _assert_no_tp(_run_or_skip("specs/mainnet_weth9.yaml"))


@pytest.mark.timeout(600)
def test_mainnet_sushiswap_v2_usdc_weth_no_tp():
    """Real Sushiswap V2 USDC/WETH (0x397F…ACa0)."""
    _assert_no_tp(_run_or_skip("specs/mainnet_sushiswap_v2_usdc_weth.yaml"))


@pytest.mark.timeout(600)
def test_mainnet_curve_3pool_no_tp():
    """Real Curve 3pool (0xbEbc…1C7)."""
    _assert_no_tp(_run_or_skip("specs/mainnet_curve_3pool.yaml"))


@pytest.mark.timeout(1800)
def test_mainnet_lido_no_tp():
    """Real Lido stETH (0xae7a…fE84)."""
    _assert_no_tp(_run_or_skip("specs/mainnet_lido.yaml"))


@pytest.mark.timeout(2400)
def test_mainnet_sdai_no_tp():
    """Real sDAI (0x83F2…BEeA)."""
    _assert_no_tp(_run_or_skip("specs/mainnet_sdai.yaml"))


@pytest.mark.timeout(600)
def test_positive_control_beanstalk_on_fork():
    """POSITIVE CONTROL: incentive-design bug discovered through fork-mode.

    Same BeanstalkGov reproduction (no-snapshot governance allows
    transient majority to drain treasury — an incentive-economic
    assumption violation) deployed atop a real mainnet fork. Validates
    every fork-mode codepath preserves the framework's ability to detect
    incentive bugs. If this assertion fails, fork mode has a silent
    regression and the no-TP results on real mainnet contracts may be
    artifacts rather than genuine FP-clean outcomes.
    """
    report = _run_or_skip("specs/positive_control_beanstalk_on_fork.yaml")
    tps = report.true_positives()
    assert tps, (
        "POSITIVE CONTROL FAILED: BeanstalkGov on fork should yield TPs "
        "(deposit -> proposeAndExecute drains treasury). Got 0 TPs."
    )

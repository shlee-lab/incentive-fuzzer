"""Tier C: mainnet fork validation.

Runs the fuzzer against contracts ACTUALLY DEPLOYED on Ethereum mainnet,
via `anvil --fork-url <RPC>`. Replaces our vendored ports with the real
on-chain bytecode and state.

These tests REQUIRE network access. RPC URL is read from environment
(spec uses ${ALCHEMY_ETH_RPC} et al). If the RPC is unreachable, the
simulator fails to initialize anvil; we treat that as a SKIP rather
than a hard failure so CI without internet doesn't break.

We assert NO TRUE-POSITIVE findings (TP_value_transfer or
TP_protocol_drain). OPT_OUT / STRATEGIC findings are tolerated — those
indicate the role chose not to participate or used the protocol's own
callable functions in a non-honest but legal way, not an exploit of
its invariants.
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
    """Real WETH9 (0xC02a…56Cc2). Canonical wrapper."""
    _assert_no_tp(_run_or_skip("specs/mainnet_weth9.yaml"))


@pytest.mark.timeout(600)
def test_mainnet_sushiswap_v2_usdc_weth_no_tp():
    """Real Sushiswap V2 USDC/WETH (0x397F…ACa0) — UniV2 fork."""
    _assert_no_tp(_run_or_skip("specs/mainnet_sushiswap_v2_usdc_weth.yaml"))


@pytest.mark.timeout(600)
def test_mainnet_curve_3pool_no_tp():
    """Real Curve 3pool (0xbEbc…1C7) — DAI/USDC/USDT stable swap (Vyper)."""
    _assert_no_tp(_run_or_skip("specs/mainnet_curve_3pool.yaml"))


@pytest.mark.timeout(120)
def test_positive_control_weth_storage_inject():
    """POSITIVE CONTROL #2 — proves fuzzer finds exploits in REAL mainnet
    bytecode when state allows.

    Attaches to real WETH9 (0xC02a…56Cc2) and injects 1000 WETH into
    Attacker's `balanceOf` slot via anvil_setStorageAt. Fuzzer must
    discover that `withdraw(1000)` converts the injected WETH into real
    ETH from WETH9's actual ~3M ETH pool. Proves: real on-chain
    bytecode + injected state → fuzzer finds the drain.
    """
    report = _run_or_skip("specs/positive_control_weth_storage_inject.yaml")
    tps = report.true_positives()
    assert tps, "Storage-injection drain not found — real-contract path broken?"
    assert max(f.payoff_diff_wei for f in tps) > 100 * 10**18, (
        "Drain magnitude below 100 ETH — fork-mode balance reads may be off."
    )


@pytest.mark.timeout(600)
def test_positive_control_donation_depth3_on_fork():
    """POSITIVE CONTROL #3 — depth-3 multi-step discovery via beam search
    through fork mode. Same DonationVault inflation attack as Tier 3,
    but deployed atop a mainnet fork session. Proves compound mutation
    + coverage-novelty scoring survives fork."""
    report = _run_or_skip("specs/positive_control_donation_on_fork.yaml")
    tps = report.true_positives()
    assert tps, "Depth-3 donation drain not found through fork."
    matching = [
        f for f in tps
        if {"deposit", "donate", "redeem"} <= {a.function for a in f.deviation.actions}
    ]
    assert matching, "TP findings exist but none match the expected attack sequence."


@pytest.mark.timeout(120)
def test_positive_control_buggy_contract_on_fork():
    """POSITIVE CONTROL — proves fork mode preserves bug-finding.

    Deploys our known-buggy UraniumPair (Tier 3-A's reproduction of the
    Uranium Finance K-invariant typo) ON TOP of a forked mainnet anvil
    session. Goes through every fork-mode codepath: env-var URL
    expansion, fresh-address generation, anvil_impersonateAccount.

    If this assertion fails, fork mode has a silent regression — and
    that means the 0-TP results we report on real mainnet contracts may
    be artifacts, not genuine "no bug" outcomes. If it passes, fork
    infra is exonerated and the mainnet 0-TPs reflect real protocol
    safety.
    """
    report = _run_or_skip("specs/positive_control_uranium_on_fork.yaml")
    tps = report.true_positives()
    assert tps, (
        "POSITIVE CONTROL FAILED: fork-mode UraniumPair should still "
        "yield TP findings (~990 TKA drain). Got 0 TPs — fork mode may "
        "be suppressing discovery. Re-run Tier 3 specs without fork to "
        "isolate."
    )
    # Drain should be at the full ~990 TKA magnitude.
    assert max(f.payoff_diff_wei for f in tps) > 100 * 10**18, (
        "Drain magnitude below expected ~990 TKA; fork mode may be "
        "altering reserves or balance reads."
    )


@pytest.mark.timeout(1800)
def test_mainnet_lido_no_tp():
    """Real Lido stETH (0xae7a…fE84). Depth-3 beam search.

    Heaviest test in this suite (~17 min on Alchemy free tier) — proxy
    contract with substantial state-read fan-out per call. Verifies the
    framework handles deeper compound mutations on a real production
    proxy contract.
    """
    _assert_no_tp(_run_or_skip("specs/mainnet_lido.yaml"))

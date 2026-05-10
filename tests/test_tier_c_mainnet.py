"""Tier C: mainnet fork validation.

Runs the fuzzer against contracts ACTUALLY DEPLOYED on Ethereum mainnet,
via `anvil --fork-url <public RPC>`. Replaces our vendored ports with the
real on-chain bytecode and state.

These tests REQUIRE network access. Public RPCs (publicnode.com) typically
retain only the most recent ~128 blocks, so the fork uses "latest" rather
than a pinned historical block. If the RPC is unreachable, the simulator
fails to initialize anvil; we treat that as a SKIP rather than a hard
failure so CI without internet doesn't break.
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


@pytest.mark.timeout(600)
def test_mainnet_uniswap_v2_usdc_weth_no_finding():
    """Real Uniswap V2 USDC/WETH pair (0xB4e1…9Dc)."""
    report = _run_or_skip("specs/mainnet_uniswap_v2_usdc_weth.yaml")
    fs = report.profitable_deviations()
    assert not fs, (
        f"Mainnet Uniswap V2 USDC/WETH should be FP-clean; got:\n"
        + "\n".join(f.summary() for f in fs)
    )


@pytest.mark.timeout(600)
def test_mainnet_weth9_no_finding():
    """Real WETH9 (0xC02a…56Cc2). Canonical wrapper, ~30 LOC; no exploits."""
    report = _run_or_skip("specs/mainnet_weth9.yaml")
    fs = report.profitable_deviations()
    assert not fs, (
        f"Mainnet WETH9 should be FP-clean; got:\n"
        + "\n".join(f.summary() for f in fs)
    )


@pytest.mark.timeout(600)
def test_mainnet_sushiswap_v2_usdc_weth_no_finding():
    """Real Sushiswap V2 USDC/WETH (0x397F…ACa0) — UniV2 fork."""
    report = _run_or_skip("specs/mainnet_sushiswap_v2_usdc_weth.yaml")
    fs = report.profitable_deviations()
    assert not fs, (
        f"Mainnet Sushiswap V2 should be FP-clean; got:\n"
        + "\n".join(f.summary() for f in fs)
    )


@pytest.mark.timeout(600)
def test_mainnet_curve_3pool_no_finding():
    """Real Curve 3pool (0xbEbc…1C7) — DAI/USDC/USDT stable swap (Vyper).

    Different invariant math than Uniswap V2 (sum + product). Validates
    framework handles non-constant-product AMMs at the ABI level.
    """
    report = _run_or_skip("specs/mainnet_curve_3pool.yaml")
    fs = report.profitable_deviations()
    assert not fs, (
        f"Mainnet Curve 3pool should be FP-clean; got:\n"
        + "\n".join(f.summary() for f in fs)
    )

#!/usr/bin/env python3
"""Sweep a list of mainnet protocol addresses through the fuzzer.

Loads ALCHEMY_ETH_RPC from environment (source .env.local first).
Writes a temp spec per target, runs Campaign, tabulates results.

Targets are grouped by ABI family — all Uniswap V2 forks share the same
ABI, all ERC4626 vaults share the same standardized ABI, etc. so we can
reuse one ABI port across many contracts.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
import traceback
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from fuzzer.runner.campaign import Campaign


def _v2_pair_spec(label: str, address: str, rpc_env: str = "ALCHEMY_ETH_RPC") -> str:
    return f"""contract: targets/tier_b_canonical/UniswapV2Pair.sol
contract_name: UniswapV2Pair
contract_address: "{address}"
fork:
  url: "${{{rpc_env}}}"

roles:
  - name: Attacker
    initial_eth_wei: 10_000_000_000_000_000_000
    primary_asset: ETH
    callable_functions: [swap, sync, skim]

honest_strategies:
  Attacker:
    actions: []

mutator_hints:
  Attacker:
    try_self_targeting: false
    try_skip_actions: false
    try_action_insertion: true
    try_numeric_mutation: false
    max_candidates_per_role: 30

expected_findings: []
"""


def _curve_spec(label: str, address: str, rpc_env: str = "ALCHEMY_ETH_RPC") -> str:
    return f"""contract: targets/tier_c_mainnet/Curve3Pool.sol
contract_name: Curve3Pool
contract_address: "{address}"
fork:
  url: "${{{rpc_env}}}"

roles:
  - name: Attacker
    initial_eth_wei: 10_000_000_000_000_000_000
    primary_asset: ETH
    callable_functions: [exchange, remove_liquidity_one_coin]

honest_strategies:
  Attacker:
    actions: []

mutator_hints:
  Attacker:
    try_self_targeting: false
    try_skip_actions: false
    try_action_insertion: true
    try_numeric_mutation: false
    max_candidates_per_role: 30

expected_findings: []
"""


def _erc4626_spec(label: str, address: str, rpc_env: str = "ALCHEMY_ETH_RPC") -> str:
    return f"""contract: targets/tier_c_mainnet/IERC4626.sol
contract_name: IERC4626
contract_address: "{address}"
fork:
  url: "${{{rpc_env}}}"

roles:
  - name: Attacker
    initial_eth_wei: 10_000_000_000_000_000_000
    primary_asset: ETH
    callable_functions: [deposit, redeem, withdraw, mint]

honest_strategies:
  Attacker:
    actions: []

mutator_hints:
  Attacker:
    try_self_targeting: false
    try_skip_actions: false
    try_action_insertion: true
    try_numeric_mutation: false
    max_candidates_per_role: 30

expected_findings: []
"""


TARGETS = [
    # ============== Ethereum mainnet ==============
    # Uniswap V2 pairs
    ("v2", "ETH:UniV2_USDT_WETH",  "0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852", "ETH"),
    ("v2", "ETH:UniV2_DAI_WETH",   "0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11", "ETH"),
    ("v2", "ETH:UniV2_WBTC_WETH",  "0xBb2b8038a1640196FbE3e38816F3e67Cba72D940", "ETH"),
    ("v2", "ETH:UniV2_LINK_WETH",  "0xa2107FA5B38d9bbd2C461D6EDf11B11A50F6b974", "ETH"),
    ("v2", "ETH:UniV2_AAVE_WETH",  "0xDFC14d2Af169B0D36C4EFF567Ada9b2E0CAE044f", "ETH"),
    ("v2", "ETH:UniV2_UNI_WETH",   "0xd3d2E2692501A5c9Ca623199D38826e513033a17", "ETH"),
    ("v2", "ETH:UniV2_MKR_WETH",   "0xC2aDdA861F89bBB333c90c492cB837741916A225", "ETH"),
    ("v2", "ETH:UniV2_COMP_WETH",  "0xCFfDdeD873554F362Ac02f8Fb1f02E5ada10516f", "ETH"),
    ("v2", "ETH:UniV2_PEPE_WETH",  "0xA43fe16908251ee70EF74718545e4FE6C5cCEc9f", "ETH"),
    ("v2", "ETH:UniV2_LDO_WETH",   "0xC558F600B34A5f69dD2f0D06Cb8A88d829B7420a", "ETH"),
    # Sushiswap V2 pairs
    ("v2", "ETH:Sushi_USDT_WETH",  "0x06da0fd433C1A5d7a4faa01111c044910A184553", "ETH"),
    ("v2", "ETH:Sushi_DAI_WETH",   "0xC3D03e4F041Fd4cD388c549Ee2A29a9E5075882f", "ETH"),
    ("v2", "ETH:Sushi_WBTC_WETH",  "0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58", "ETH"),
    ("v2", "ETH:Sushi_LINK_WETH",  "0xC40D16476380e4037e6b1A2594cAF6a6cc8Da967", "ETH"),
    # Curve pools
    ("curve", "ETH:Curve_alUSD-3CRV", "0x43b4FdFD4Ff969587185cDB6f0BD875c5Fc83f8c", "ETH"),
    ("curve", "ETH:Curve_FRAX-3CRV",  "0xd632f22692FaC7611d2AA1C0D552930D43CAEd3B", "ETH"),
    ("curve", "ETH:Curve_LUSD-3CRV",  "0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA", "ETH"),
    ("curve", "ETH:Curve_MIM-3CRV",   "0x5a6A4D54456819380173272A5E8E9B9904BdF41B", "ETH"),
    ("curve", "ETH:Curve_sUSD-3CRV",  "0xEB16Ae0052ed37f479f7fe63849198Df1765a733", "ETH"),
    # ERC4626 vaults
    ("erc4626", "ETH:wstETH",  "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0", "ETH"),
    ("erc4626", "ETH:sfrxETH", "0xac3E018457B222d93114458476f3E3416Abbe38F", "ETH"),

    # ============== Arbitrum ==============
    # Sushiswap V2 pairs on Arbitrum
    ("v2", "ARB:Sushi_WETH_USDC",  "0x905dfCD5649217c42684f23958568e533C711Aa3", "ARB"),
    ("v2", "ARB:Sushi_WETH_USDT",  "0xCB0E5bFa72bBb4d16AB5aA0c60601c438F04b4ad", "ARB"),
    # Camelot V2 (UniV2 fork on Arbitrum)
    ("v2", "ARB:Camelot_USDC_WETH","0x84652bb2539513BAf36e225c930Fdd8eaa63CE27", "ARB"),

    # ============== Base ==============
    # Aerodrome / Uniswap V2 on Base (some are V2-style)
    ("v2", "BASE:UniV2_WETH_USDC", "0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C", "BASE"),

    # ============== Optimism ==============
    ("v2", "OP:Velo_WETH_USDC",    "0x79c912FEF520be002c2B6e57EC4324e260f38E50", "OP"),
]


RPC_ENV = {
    "ETH":  "ALCHEMY_ETH_RPC",
    "ARB":  "ALCHEMY_ARB_RPC",
    "BASE": "ALCHEMY_BASE_RPC",
    "OP":   "ALCHEMY_OP_RPC",
}


SPEC_BUILDERS = {
    "v2": _v2_pair_spec,
    "curve": _curve_spec,
    "erc4626": _erc4626_spec,
}


def main():
    if not os.environ.get("ALCHEMY_ETH_RPC"):
        print("ERROR: source .env.local first", file=sys.stderr)
        return 2

    print(f"{'label':<32} {'kind':<8} {'cands':>6} {'TP':>4} {'time':>8}")
    print("-" * 70)
    for kind, label, addr, chain in TARGETS:
        rpc_env = RPC_ENV[chain]
        if not os.environ.get(rpc_env):
            print(f"{label:<32} {kind:<8} SKIP   ({rpc_env} not set)")
            continue
        spec_text = SPEC_BUILDERS[kind](label, addr, rpc_env)
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml", delete=False, dir=str(REPO / "specs")
        ) as f:
            f.write(spec_text)
            spec_path = f.name
        t0 = time.time()
        try:
            r = Campaign(spec_path).run()
            tps = len(r.true_positives())
            elapsed = time.time() - t0
            print(f"{label:<32} {kind:<8} {r.candidates_evaluated:>6} {tps:>4} {elapsed:>7.1f}s")
            if tps:
                for f in r.true_positives()[:3]:
                    actions = " -> ".join(a.function for a in f.deviation.actions)
                    print(f"    [{f.label.value}] +{f.payoff_diff_wei/1e18:.4f}  ({actions})")
        except Exception as e:
            elapsed = time.time() - t0
            print(f"{label:<32} {kind:<8} ERROR  {elapsed:>7.1f}s  {str(e)[:50]}")
        finally:
            try:
                os.unlink(spec_path)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main() or 0)

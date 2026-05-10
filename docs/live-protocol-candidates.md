# Live Protocol Candidates for Fuzzer Validation

This document lists 10 currently-deployed contracts/protocols against which our
fuzzer can be run, prioritized by **pattern fit**, **portability to our
framework**, and **educational/research value**. The goal is not finding
zero-days — it's:

1. **No-FP validation**: confirm the fuzzer doesn't report bogus findings on
   audited production code.
2. **Reproduction-pattern validation**: re-discover known historical issues in
   canonical or forked versions.
3. **Pattern-fit check**: confirm our 12 reproductions cover the right shape of
   problems before applying to less-audited code.

## Scoring rubric

Each candidate is scored 1-5 on five axes:

- **Pattern fit** — does one of our 12 reproductions match this contract's shape?
- **Portability** — single contract / ERC20-or-ETH only / Solidity 0.6+? (5 = trivial)
- **Source access** — verified on Etherscan or open on GitHub?
- **TVL / impact** — meaningful deployment so the test has weight?
- **Educational value** — does it match a known historical incident family?

Total /25; higher = test sooner.

---

## Tier A — test first (easy, high value)

### 1. OpenZeppelin ERC4626 reference (`contracts/token/ERC20/extensions/ERC4626.sol`)
- **Pattern fit**: 5 — exact match to `DonationVault` (vault with deposit/redeem/donate-via-transfer).
- **Portability**: 5 — single contract, OZ uses Solidity 0.8. Framework runs as-is.
- **Source access**: 5 — github.com/OpenZeppelin/openzeppelin-contracts.
- **TVL/impact**: 4 — used by hundreds of vaults; OZ's reference is the de facto canonical.
- **Educational**: 5 — first-depositor inflation is THE classic vault attack.
- **Total: 24/25.** Expected outcome: **NO finding** (OZ added a `_decimalsOffset()` virtual that subclasses override to add "dead shares" mitigation). Running on the reference verifies our fuzzer doesn't false-positive on the standard mitigation.
- **Why first**: trivial port + maximally meaningful FP check.

### 2. Solmate ERC4626 (`src/mixins/ERC4626.sol`)
- **Pattern fit**: 5 — same vault pattern as OZ.
- **Portability**: 5 — single contract, no dependencies beyond ERC20.
- **Source access**: 5 — github.com/transmissions11/solmate.
- **TVL/impact**: 4 — used by Yearn v3, others.
- **Educational**: 5 — Solmate's version does **not** have the OZ decimals-offset defense. Test should re-discover the inflation attack.
- **Total: 24/25.** Expected outcome: **TP** (depth-3 attack found, equivalent to our `donation_vault.yaml`).
- **Why second**: same setup as #1, but yields a finding — direct comparison of mitigated vs unmitigated reference.

### 3. SushiSwap MasterChef v1 (`MasterChef.sol`)
- **Pattern fit**: 5 — direct match to `YieldFarm` (deposit-flash-claim time bug).
- **Portability**: 4 — single contract + SUSHI ERC20 + LP token mocks.
- **Source access**: 5 — github.com/sushiswap/sushiswap.
- **TVL/impact**: 5 — historically billions; many forks still active.
- **Educational**: 5 — has the "deposit doesn't update pending rewards" pattern that we modeled. Already caused issues in MasterChef forks.
- **Total: 24/25.** Expected outcome: **TP** for early forks; potentially mitigated in current MasterChefV2.

### 4. Synthetix `StakingRewards.sol`
- **Pattern fit**: 4 — staking + reward token, similar to `YieldFarm` but uses `lastTimeRewardApplicable()` and `rewardPerToken` accumulators (no per-user lastUpdate).
- **Portability**: 5 — single contract, well-isolated, used as reference everywhere.
- **Source access**: 5 — github.com/Synthetixio/synthetix.
- **TVL/impact**: 4 — pattern used by hundreds of forks.
- **Educational**: 5 — the canonical fix for the deposit-flash-claim bug; testing it validates our fuzzer on the reference fix.
- **Total: 23/25.** Expected outcome: **NO finding** (correctly accumulates rewards). FP check.

---

## Tier B — moderate effort, significant value

### 5. Uniswap V2 Pair (`UniswapV2Pair.sol`)
- **Pattern fit**: 5 — exact shape of `UraniumPairFull`.
- **Portability**: 4 — single contract, Solidity 0.5.16 (need version pin or port to 0.8 like our repro).
- **Source access**: 5 — github.com/Uniswap/v2-core.
- **TVL/impact**: 5 — de facto canonical AMM, used by every Uniswap V2 fork.
- **Educational**: 4 — well-audited; should NOT have the K typo. Verifies our Uranium repro distinguishes the bug from the canonical correct version.
- **Total: 23/25.** Expected outcome: **NO finding** (K check uses `1000**2` consistently with `1000` multiplier — typo absent). Strong FP control.

### 6. Compound V2 `CErc20` + minimal `Comptroller` mock
- **Pattern fit**: 5 — direct match to `SimpleLending` (deposit/borrow/liquidate, with the role-separation question).
- **Portability**: 3 — depends on Comptroller for `liquidationIncentive`, oracle for prices. Mock both.
- **Source access**: 5 — github.com/compound-finance/compound-protocol.
- **TVL/impact**: 5 — original lending market design; current Compound v3 still uses this lineage.
- **Educational**: 5 — Compound has had close-call liquidation bugs. Self-liquidation has been studied in forks (some allowed it).
- **Total: 23/25.** Expected outcome: **likely NO finding** on canonical CErc20 (proper Comptroller checks); potential **TP** on simplified or fork variants.

### 7. Lido `Lido.sol` + `WithdrawalQueueERC721`
- **Pattern fit**: 4 — match to `SimpleStaking` family (validator/delegator economics).
- **Portability**: 3 — depends on `StakingRouter`, oracles, withdrawal queue. Mock heavily or run against a fork.
- **Source access**: 5 — github.com/lidofinance/lido-dao.
- **TVL/impact**: 5 — largest liquid-staking protocol on Ethereum.
- **Educational**: 4 — staking-reward distribution math is non-trivial; good stress test.
- **Total: 21/25.** Expected outcome: **NO finding** on the well-audited paths; useful as a complexity stress test for the fuzzer.

### 8. Curve V1 stable-swap pool (`StableSwap.vy` ported / `pools/3pool/StableSwap3Pool.vy` for source)
- **Pattern fit**: 4 — AMM, but uses Curve invariant (sum + product) not constant product. Different math.
- **Portability**: 2 — written in Vyper; would need port to Solidity or extension to Vyper compilation. Multi-asset (3 tokens), tests our cross-asset utility.
- **Source access**: 5 — github.com/curvefi/curve-contract.
- **TVL/impact**: 5 — billions in stable swaps.
- **Educational**: 4 — read-only reentrancy in `get_virtual_price` (May 2023) is a known issue family.
- **Total: 20/25.** Expected outcome: depends on what subset is ported.

---

## Tier C — harder, niche, but worth it

### 9. OpenZeppelin Governor suite (`Governor`, `GovernorVotes`, `GovernorTimelock`)
- **Pattern fit**: 5 — direct match to `BeanstalkGov` (proposal + vote + execute). OZ adds snapshot, timelock, quorum modules.
- **Portability**: 3 — multi-contract: Governor + ERC20Votes + Timelock. All single-purpose, can be wired together.
- **Source access**: 5.
- **TVL/impact**: 4 — used by Compound, Uniswap, many DAOs.
- **Educational**: 5 — testing the OZ Governor verifies that the snapshot/timelock combo defeats our Beanstalk-style attack autonomously.
- **Total: 22/25.** Expected outcome: **NO finding** (snapshot at proposal block prevents flash-borrow voting). FP control on a critical pattern.

### 10. Sudoswap `LSSVMPair` (NFT AMM, ERC721 ⇄ ETH)
- **Pattern fit**: 3 — auction/AMM hybrid; partial match to `SimpleAuction` and `SandwichPool`.
- **Portability**: 3 — needs ERC721 mock (we currently only support ERC20). Single Pair contract isolated.
- **Source access**: 5 — github.com/sudoswap.
- **TVL/impact**: 3 — niche but established NFT trading venue.
- **Educational**: 4 — would require extending our framework to ERC721; demonstrates portability of our pattern catalogue beyond ERC20 / ETH.
- **Total: 18/25.** Expected outcome: framework infra extension first, then test.

---

## Prioritized order

1. **OZ ERC4626** — trivial port, FP control on canonical safe vault.
2. **Solmate ERC4626** — TP repro on unmitigated reference.
3. **SushiSwap MasterChef v1** — TP repro on the canonical farming bug pattern.
4. **Synthetix StakingRewards** — FP control on canonical reward accumulator.
5. **Uniswap V2 Pair** — FP control on canonical AMM.
6. **Compound V2 CErc20 (with mocks)** — TP/FP on canonical lending.
7. **OZ Governor suite** — FP control on canonical governance.
8. **Lido Lido.sol** — complexity stress test.
9. **Curve V1 stable pool** — different invariant math, may surface limits.
10. **Sudoswap LSSVMPair** — NFT extension demand, framework evolution.

## What we learn from each

- **Tier A (1-4)**: by week 1, run all four. We learn whether our fuzzer
  cleanly distinguishes canonical mitigations (OZ ERC4626 / Synthetix) from
  unmitigated references (Solmate / MasterChef). If both groups give expected
  results, the fuzzer is reliable on common DeFi primitives.
- **Tier B (5-7)**: spec/mock work needed but each addresses an unsolved
  validation question — does our framework match the expected behavior of
  audited mainnet code?
- **Tier C (8-10)**: framework extension (Vyper, ERC721) needed; longer-term
  roadmap items.

## Caveats

- **Mainnet fork required for Lido / Compound** when state matters (price
  oracles, accumulated rewards). `anvil --fork-url` already supported by our
  simulator; just needs an RPC URL.
- **Old Solidity versions** (Uniswap V2 = 0.5.16, MasterChef = 0.6.x) may
  require either porting to 0.8 (already done for our Uranium repro) or
  configuring `foundry.toml` to use the right `solc` version.
- **No zero-day intent**: every protocol listed has been audited multiple
  times; running our fuzzer adds defense-in-depth verification on
  patterns we've already modeled. Findings would constitute private
  responsible-disclosure material, not public posts.

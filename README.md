# incentive-fuzzer

A fuzzer that searches for **incentive-design vulnerabilities** in
Solidity protocols. Given a contract plus role/utility/honest-strategy
specs, it auto-discovers rational deviations where some role profits
beyond honest behavior because the protocol's *implicit economic
assumption* — typically about role separation, time-snapshot durability,
or external-context invariance — isn't enforced.

## Scope (and what's out of scope)

**In scope** — incentive-design flaws. The code works as written; an
unstated economic assumption is violated by a rational actor:

  - role-separation assumptions ("Borrower ≠ Liquidator", "Seller ≠ Bidder")
  - voting-weight durability ("majority at execute time ≠ flash-borrowed")
  - mempool/ordering privilege ("no trader has pre-execution information")
  - reward-distribution-target assumptions ("rebate goes to LPs")
  - referral / sourcing assumptions ("referrer ≠ depositor")

**Out of scope** — code defects:

  - reentrancy / CEI violations
  - precision/overflow/integer math bugs
  - access-control omissions
  - typos in invariant constants
  - storage-layout collisions

Code defects belong to **Echidna / Foundry-fuzz / Slither / Mythril /
Halmos**. We model only the orthogonal "everything compiles and runs
correctly, but rational actors break the protocol's economic intent" class.

## Status

### Bug-class detection on synthetic / reduction targets

| Spec                                         | Incentive assumption violated      | Found by fuzzer       | Diff           |
|----------------------------------------------|------------------------------------|-----------------------|----------------|
| `specs/simple_lending.yaml`                  | Borrower ≠ Liquidator              | self-liquidate        | +40 ETH        |
| `specs/simple_auction.yaml`                  | Seller ≠ Bidder                    | shill-bid self        | +98 ETH        |
| `specs/simple_staking.yaml`                  | Validator ≠ Delegator              | self-delegate         | +99 ETH        |
| `specs/referral_vault.yaml`                  | User ≠ Referrer                    | self-refer            | +5 USDC        |
| `specs/yield_farm.yaml`                      | Stake-time is finite per deposit   | flash deposit         | +86 REWARD     |
| `specs/rebate_pool.yaml`                     | Fee rebate goes to LPs             | MEV claim             | +0.3 TKA       |
| `specs/sandwich_pool.yaml`                   | No pre-tx information privilege    | sandwich              | +85 TKA        |
| `specs/beanstalk_gov.yaml`                   | Voting weight is durable           | governance drain      | drains TRSY    |
| `specs/oracle_lending.yaml`                  | Spot price is non-manipulable      | deposit → pump → borrow | +30,000 STBL |
| `specs/multiagent_shared_treasury.yaml`      | All agents passive                 | iterated best-response converges to first-mover claim | +100 ETH |

`beanstalk_gov.yaml` is a reduction of the April 2022 Beanstalk Farms
attack (~$182M). `oracle_lending.yaml` is a reduction of the Mango Markets
(~$117M) / Cream Finance (~$130M) / Inverse Finance (~$15M) class.
`multiagent_shared_treasury.yaml` exercises **iterated best response** —
each agent re-optimizes against the others' current strategy until a fixed
point is reached.

### Honest result on mainnet code

We attached the fuzzer to **57 production mainnet contracts** across
Ethereum / Arbitrum / Base / Optimism (Uniswap V2, Sushi, Velo, Camelot,
Aerodrome pairs; Curve 3pool / tricrypto / crvUSD / steth-eth metapools;
ERC4626 vaults including wstETH, sfrxETH, sUSDe, sFRAX, Yearn v3,
Etherfi weETH, MetaMorpho, Spark sUSDS, Renzo, KelpDAO; WETH9; the real
Beanstalk Diamond `0xC1E0…624C5` at block 14602789 pre-attack; Lido stETH;
sDAI). ~1,400 candidates evaluated total. **TPs found: 0.**

This is a deliberate, documented limitation. Generic mutators cannot
autonomously synthesize protocol-specific multi-step payloads
(`diamondCut` BIP bytes, Curve metapool manipulation through specific
imbalance ratios, flash-loan provider routing, etc.). Real-world
incentive zero-day discovery requires either compound-template hints
that already encode the attack shape, or protocol-specific payload
encoders. We position this tool as a **design-time guardrail for new
protocols**, not a mainnet zero-day finder.

### Echidna baseline comparison

On the same `BeanstalkGov` reduction:

| | Incentive fuzzer | Echidna |
|---|---|---|
| Budget | 650 candidates, depth ≤ 3 | 100,113 calls, seqLen 50, 4 workers |
| Wall time | ~5 s | ~75 s |
| Properties | utility(deviation) > utility(honest) | 4 state invariants (conservation, balance, bound) |
| Findings | **4 TP_protocol_drain** | **0** (all invariants pass) |

The bug is not a state-predicate violation. After the attack
`totalStake == sum(stake[*])` still holds; `voteToken.balanceOf(gov)`
matches; treasury balance is ≤ initial. Echidna cannot express
"attacker's utility delta vs the honest strategy" as a pure-state
predicate. See `comparison/echidna/RESULTS.md` for details and
reproduction.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -e .
forge build
```

Requires Foundry (`forge`, `anvil`) on PATH and Python 3.11+.

For mainnet fork tests, set `ALCHEMY_ETH_RPC` (and optionally the Arb /
Base / OP variants) in `.env.local` (gitignored).

## Run

A campaign on a single spec:

```bash
.venv/bin/python -m fuzzer.runner.campaign specs/simple_lending.yaml
```

The full validation suite:

```bash
.venv/bin/python -m pytest tests/
```

Multi-chain mainnet sweep:

```bash
source .env.local && .venv/bin/python scripts/mainnet_sweep.py
```

## Spec format

```yaml
contract: targets/.../YourContract.sol
contract_name: YourContract
deploy_value_wei: <wei sent on deploy>
deploy_args: [ ... "@RoleName" / "@@TokenName" address sentinels resolve at runtime ... ]

tokens:                      # ERC20s deployed via MockERC20
  - name: USDC
    decimals: 6
    initial_balances:
      RoleA: 1000_000000

setup_calls:                 # admin-initiated post-deployment setup
  - { function: fundRewards, args: { amount: 100_000000 } }
  - { function: USDC.transfer, args: { to: "@@self", amount: 1000_000000 } }

roles:
  - name: RoleA
    initial_eth_wei: <wei>
    primary_asset: USDC      # asset used for honest-vs-deviation comparison
    callable_functions: [fn1, fn2, "USDC.transfer"]   # cross-contract supported
    default_phase: 1         # explicit phase for interleaving across roles

honest_strategies:
  RoleA:
    actions:
      - { function: fn1, args: { value_wei: ..., arg_wei: ... }, phase: 1 }
      - { function: simulate_price_drop, args: { factor: 0.7 } }    # pseudo-action
      - { function: advance_time, args: { seconds: 86400 } }

mutator_hints:
  RoleA:
    try_self_targeting: true             # rewrite @Other addrs to @Self
    try_skip_actions: true               # drop one honest action
    try_action_insertion: true           # insert one callable
    try_compound_pair_insertion: true    # insert two actions at distinct phases
    compound_beam_max_depth: 3           # autonomous depth-N beam search
    compound_beam_width: 15
    max_candidates_per_role: 600         # hard budget cap

fork:                                     # optional — attach to a real chain
  url: "${ALCHEMY_ETH_RPC}"
contract_address: "0x..."                # required when forking

expected_findings:
  - role: RoleA
    deviation_must_contain: [fn2]
    payoff_higher_than_honest: true
    min_payoff_diff_wei: <wei threshold>
```

## How discovery works

For each role:

1. **Single-action mutations**: drop / skip / self-target / insert each
   honest action.
2. **Compound depth-N (beam search)**: extend each top-K stem by every
   possible action; score by primary-asset profit, or by total
   |asset-delta| novelty if not yet profitable. Top-K kept per depth.
3. **Coverage-guided pruning**: per-candidate executed-function set,
   beam scoring boosted by novel-function-execution count vs honest.
4. **Cross-contract synthesis**: `Token.fn` / `@@self` sentinels in
   `callable_functions` let the mutator donate / transfer through any
   deployed ERC20.

After every profitable deviation, a **classifier** labels it:

  - `TP_value_transfer` — another role's primary asset dropped vs honest
  - `TP_protocol_drain` — main contract's primary asset dropped
  - `STRATEGIC` — uses only own callables, no harm done elsewhere
  - `OPT_OUT` — deviation is a strict subset of honest (no exploit)

Tests assert via `report.true_positives()` so OPT_OUT / STRATEGIC are
tolerated as legitimate rational behavior, not flagged as bugs.

## Adding a new protocol

1. Solidity contract under `targets/.../YourContract.sol`. Include a
   header naming the **incentive assumption** you suspect is unenforced.
2. Spec under `specs/your_spec.yaml`.
3. Test under `tests/test_*.py` asserting a finding pattern.

For mainnet attach (fork mode), point `contract_address` at the real
deployment and set `fork.url` to your RPC env-var.

## Files

```
fuzzer/
  core/
    role.py             Role
    strategy.py         Action, Strategy
    utility.py          eth_balance_change
    spec.py             YAML spec → typed objects
    simulator.py        Anvil + web3 simulator (deploy & fork modes)
  mutator/
    strategy_mutator.py 4 mutation kinds + compound_template
  runner/
    campaign.py         Campaign.run() with beam search + budget
  reporter/
    report.py           Finding (classified), CampaignReport
targets/
  tier1_trivial/        SimpleLending / SimpleAuction / SimpleStaking
  tier2_realistic/      ReferralVault / YieldFarm / RebatePool / SandwichPool
  tier3_reproductions/  BeanstalkGov (governance-vote durability)
  tier_a_canonical/     OZ-ERC4626 / Solmate-ERC4626 / SynthetixStakingRewards / SushiMasterChef
  tier_b_canonical/     UniswapV2Pair / CompoundCErc20 / OZGovernor / LidoLite
  tier_c_mainnet/       WETH9 / Curve3Pool / IERC4626 / Lido / BeanstalkDiamond (ABI ports for fork attach)
  tier_e_multiagent/    SharedTreasury (iterated best-response equilibrium)
  tier_f_oracle/        OracleLending (spot-price oracle manipulation)
specs/                  matching .yaml per target
comparison/
  echidna/              Side-by-side baseline: same code, different fuzzer mode (see RESULTS.md)
tests/
  test_tier1_findings.py     incentive bugs in toy protocols
  test_tier2_findings.py     incentive bugs in realistic mocks
  test_tier3_findings.py     incentive bugs from real incidents
  test_tier_a_canonical.py   FP-control on canonical safe versions
  test_tier_b_canonical.py   FP-control on higher-stakes safe versions
  test_tier_c_mainnet.py     FP-control on real mainnet, plus fork positive control
scripts/
  mainnet_sweep.py     multi-chain breadth sweep over 50+ addresses
docs/
  live-protocol-candidates.md  prioritized list of candidate test targets
```

## Citing / paper positioning

The contribution this codebase backs is:

1. **A new bug-class formalization**: incentive-design vulnerabilities as
   *utility-delta over multi-step deviations*, distinct from
   state-invariant violations.
2. **An automatic search procedure** (compound depth-N beam search with
   coverage novelty + multi-asset utility) that reliably surfaces
   instances of this class on reductions of real exploits (Beanstalk,
   Mango/Cream-class oracle manipulation, role-separation).
3. **Multi-agent extension** (`agent_type: best_response`) that detects
   equilibrium divergence from the protocol designer's assumed strategy
   profile — orthogonal to single-agent fuzzing.
4. **An honest empirical limit**: on production mainnet contracts, the
   generic mutator does not autonomously synthesize the protocol-specific
   payloads required for known attack classes. We document this rather
   than hide it.

The right comparison is **not** "did you find more zero-days than tool X"
but "what class of bug can you *express* and *detect*". The Echidna
baseline (`comparison/echidna/`) demonstrates the class boundary
concretely on a shared target.

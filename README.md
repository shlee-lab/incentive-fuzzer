# incentive-fuzzer

A fuzzer that searches for **incentive invariants** in Solidity protocols: given
a contract plus role/utility/honest-strategy specs, it auto-discovers rational
deviations where some role profits beyond honest behavior. Distinct from
state-invariant fuzzers (Echidna, Foundry) — state stays consistent; the bug is
that the protocol's *implicit role-separation assumption* (e.g. "Borrower and
Liquidator are different parties") isn't enforced in code.

## Status

Tier 1 only. Three trivial protocols, three deviations auto-found:

| Spec                          | Honest payoff (role)            | Deviation found             | Diff      |
| ----------------------------- | ------------------------------- | --------------------------- | --------- |
| `specs/simple_lending.yaml`   | Borrower: −40 ETH               | Borrower self-liquidates    | +40 ETH   |
| `specs/simple_auction.yaml`   | Seller: +2 ETH                  | Seller shill-bids self      | +98 ETH   |
| `specs/simple_staking.yaml`   | Validator: +900 ETH (90% pool)  | Validator self-delegates    | +99 ETH   |

```
$ pytest tests/test_tier1_findings.py
====== 3 passed in 8.07s ======
```

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -e .
forge build
```

Requires Foundry (`forge`, `anvil`) on PATH and Python 3.11+.

## Run

A campaign on a single spec:

```bash
.venv/bin/python -m fuzzer.runner.campaign specs/simple_lending.yaml
```

The full validation suite:

```bash
.venv/bin/python -m pytest tests/test_tier1_findings.py -v
```

## Adding a new protocol

Three pieces, in order:

### 1. Solidity contract (`targets/.../YourContract.sol`)

Write the protocol normally. Include a header comment naming:

- the honest behavior of each role,
- the implicit role-separation assumption you suspect is unenforced,
- the deviation you expect the fuzzer to surface.

The simulator funds the contract on deploy via `deploy_value_wei`; constructor
args come from the spec's `deploy_args`.

### 2. Spec (`specs/your_spec.yaml`)

```yaml
contract: targets/.../YourContract.sol
contract_name: YourContract
deploy_value_wei: <wei sent on deploy>
deploy_args: [ ... constructor arg values; "@RoleName" resolves to that role's address ... ]

roles:
  - name: RoleA
    initial_eth_wei: <wei>
    callable_functions: [fn1, fn2]   # functions the mutator may insert/skip for this role

honest_strategies:
  RoleA:
    actions:
      - { function: fn1, args: { value_wei: ..., someArg_wei: ... } }
      - { function: simulate_price_drop, args: { factor: 0.7 } }   # pseudo-action
      - { function: wait }
      - { function: distribute_rewards, args: { amount_wei: ... } } # pseudo-action

mutator_hints:
  RoleA: { try_self_targeting: true, try_skip_actions: true, try_action_insertion: true }

expected_findings:
  - role: RoleA
    deviation_must_contain: [fn2]
    payoff_higher_than_honest: true
    min_payoff_diff_wei: <wei threshold>
```

Argument conventions:

- `value_wei` on any action → `msg.value`. Anywhere else, the simulator strips
  a trailing `_wei` if the literal key isn't an ABI parameter.
- `"@RoleName"` (with optional `_if_*` suffix the simulator strips) resolves to
  that role's address.
- Pseudo-actions: `wait`, `simulate_price_drop` (calls `setPrice` on contracts
  with that ABI from admin), `distribute_rewards` (calls `distribute()` from
  admin with msg.value=amount_wei).

Roles execute sequentially in spec order. Each role's full action list runs
before the next role starts. Reverts are caught and logged but don't fail the
scenario, which lets honest specs include speculative actions like
`liquidate(@Borrower_if_underwater)`.

### 3. Test (`tests/test_tier1_findings.py`)

Add a test that runs the campaign and asserts a matching finding exists:

```python
def test_yourcontract_finds_attack():
    report = Campaign("specs/your_spec.yaml").run()
    assert any(
        _matches_expected(f, "RoleA", ["fn2"], 1 * 10**18)
        for f in report.profitable_deviations()
    )
```

## How it works

**Mutator** (`fuzzer/mutator/strategy_mutator.py`) deterministically enumerates
candidate strategies for a role by applying four mutation kinds to the honest
strategy:

1. **Self-targeting** — rewrite each existing `address` argument to the role's
   own address.
2. **Action skipping** — drop each individual honest action.
3. **Action insertion** — for each function in `callable_functions`, insert it
   at every position with default args (address args → self; numeric args
   parameterized over a *value pool* drawn from numeric values across the
   spec).
4. **Numeric mutation** (off by default) — multiply existing numeric args by
   {0.5, 0.9, 1.1, 1.5, 2.0}.

**Simulator** (`fuzzer/core/simulator.py`) wraps an `anvil` subprocess. Per
campaign: compile once via `forge build`, deploy once, fund roles via
`anvil_setBalance`. Per scenario: `evm_snapshot` → execute roles in spec
order → measure balance deltas → `evm_revert`. Reverts are tolerated.

**Campaign** (`fuzzer/runner/campaign.py`) measures the honest baseline once,
then for each role substitutes that role's strategy with each candidate and
re-measures. A finding is recorded when `payoff(deviation) − payoff(honest) ≥
ε` (default ε = 0.01 ETH, well above tx-gas noise).

## Files

```
fuzzer/
  core/
    role.py         Role
    strategy.py     Action, Strategy
    utility.py      eth_balance_change
    spec.py         YAML spec → typed objects
    simulator.py    Anvil + web3 simulator
  mutator/
    strategy_mutator.py
  runner/
    campaign.py     Campaign.run()
  reporter/
    report.py       Finding, CampaignReport
targets/tier1_trivial/
  SimpleLending.sol     liquidate(self) bug
  SimpleAuction.sol     seller-as-bidder + double payout bug
  SimpleStaking.sol     self-delegation captures delegator pool
specs/
  simple_lending.yaml
  simple_auction.yaml
  simple_staking.yaml
tests/
  test_tier1_findings.py
```

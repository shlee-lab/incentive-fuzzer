# Baseline comparison vs Echidna

We pit our incentive fuzzer against Echidna (state-invariant fuzzing,
trail of bits) on two well-known economic-design bug classes that are
*not* state-predicate violations.

## 1. BeanstalkGov — flash-governance majority drain (April 2022, ~$182M)

The single-contract reduction of the Beanstalk Farms attack. Anyone whose
**current** stake exceeds 50% of `totalStake` at the moment of
`proposeAndExecute` can drain the treasury — even if that stake was
acquired one transaction earlier and withdrawn one transaction later.

| | Incentive fuzzer | Echidna |
|---|---|---|
| Mode | Multi-role utility delta vs honest baseline | State-predicate fuzzing |
| Budget | 650 candidates, depth ≤ 3 | 100,113 calls, seqLen 50, 4 workers |
| Wall time | ~5 s | ~75 s |
| Properties checked | utility(deviation) > utility(honest) | 4 state invariants |
| Findings | **4 TP_protocol_drain**, attacker drains the treasury | **0**, all invariants pass |

The four invariants we wrote — the strongest plausible state predicates a
real auditor would draft — all *hold at every reachable state* even while
the attack executes. After the attack `totalStake == sum(stake[*])` still
holds, `voteToken.balanceOf(gov) == totalStake` still holds, treasury
balance is ≤ initial, and per-user accounting is balanced. The bug only
shows up when you *compare* two execution paths' outcomes for the same
sender — that comparison isn't a state predicate.

## 2. OracleLending — spot-price oracle manipulation (Cream, Mango, Inverse, ...)

A lending protocol that prices its volatile collateral via the spot
reserves of its own AMM. Same shape as the Mango Markets (~$117M) and
Cream Finance (~$130M) exploits.

| | Incentive fuzzer | Echidna |
|---|---|---|
| Budget | ~1000 template candidates | not run (analogous result expected) |
| Wall time | ~10 s | — |
| Findings | **multiple TP_protocol_drain**, peak +30,000 STBL on a 100k pool | expected: 0 |
| Attack shape discovered | `deposit → swapStblForColl → borrow` | — |

The attack inflates the pool spot price between deposit and borrow,
multiplying the attacker's apparent collateral valuation. Echidna-style
state invariants over the contract — "lendingStbl ≥ debt", "reserveColl
× reserveStbl ≥ K_initial" (false in any swap), "no negative balances" —
either hold trivially or are violated by *legitimate* trades. The
bug only emerges from utility delta across the multi-step path.

## Why Echidna cannot find this bug class

State-predicate fuzzing checks `predicate(current_state) == true` after
every call. The two attacks above leave the contract in states where:

- All conservation invariants hold (`totalStake` matches stakes,
  reserves track balances).
- All per-call preconditions were satisfied (majority check passed,
  collateralization-ratio check passed).
- All non-negative-balance invariants hold (ERC20 uses uint).

The bug is a property of the **execution path's net effect on the
attacker's utility relative to honest behavior**. To express that as an
Echidna property you would need to:
1. Instrument per-sender bookkeeping of initial vs final balances.
2. Manually identify which sender is the attacker (i.e., already know
   the bug class).
3. Accept that benign profit (e.g., staking yield) also triggers the
   property.

At which point you have re-derived the incentive-fuzzer's utility-delta
semantics by hand and are no longer doing state-invariant fuzzing.

## Reproduce

```bash
# Echidna baseline on BeanstalkGov
cd comparison/echidna && bash run_echidna.sh
# Expect: all 4 echidna_* properties "passing", zero TPs.

cd ../..
source .venv/bin/activate

# Incentive fuzzer on the same contract
python -m fuzzer.runner.campaign specs/beanstalk_gov.yaml
# Expect: 4 TP_protocol_drain findings in ~5 s.

# Incentive fuzzer on the oracle manipulation scenario
python -m fuzzer.runner.campaign specs/oracle_lending.yaml
# Expect: many TP_protocol_drain findings with peak ≥ 30,000 STBL profit.
```

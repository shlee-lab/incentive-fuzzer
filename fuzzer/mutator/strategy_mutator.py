from __future__ import annotations

from typing import Any

from ..core.role import Role
from ..core.spec import MutatorHints, Spec
from ..core.strategy import Action, Strategy


# ---------------------------------------------------------------------------
# Function-flow classifier — name-based heuristic
# ---------------------------------------------------------------------------
# Classifies ABI function names by likely asset-flow direction. Used by the
# auto-compound-template generator to seed attack archetypes when the spec
# author hasn't hand-written a `compound_template`. Heuristic only — flag
# the function if any token of its name matches one of the keyword sets.

_FLOW_KEYWORDS = {
    "inflow":  ("deposit", "mint", "supply", "stake", "add", "provide", "bond",
                "buy", "lock", "seed", "fund", "join", "open"),
    "outflow": ("withdraw", "redeem", "burn", "unstake", "remove", "claim",
                "sell", "unlock", "release", "exit", "harvest",
                "borrow", "loan", "drawdown", "redeempt", "close"),
    "swap":    ("swap", "exchange", "trade", "convert"),
    "manip":   ("set", "update", "bump", "distribute", "addyield", "donate",
                "report", "poke", "rebase", "skim", "sync", "accrue",
                "transfer", "approve", "harvest", "advance"),
    "action":  ("liquidate", "slash", "execute", "propose", "vote",
                "emergencycommit", "commit"),
}


def _classify_fn(fn_name: str) -> str:
    """Return one of 'inflow', 'outflow', 'swap', 'manip', 'action', 'other'.

    Backward-compat single-category return (first match wins). Prefer
    _classify_fn_multi for archetype generation — many DeFi functions
    legitimately span multiple categories (e.g. `harvest` mutates an index
    AND distributes a reward).
    """
    base = fn_name.split(".")[-1].lower()
    for kind, keys in _FLOW_KEYWORDS.items():
        for k in keys:
            if k in base:
                return kind
    return "other"


def _classify_fn_multi(fn_name: str) -> set[str]:
    """Return the SET of categories the function name matches.

    Some functions legitimately belong to multiple roles in an attack:
      - `harvest`: index-bump (manip) AND reward-distribute (outflow)
      - `liquidate`: state action AND value-transfer (outflow when self-liq)
      - `report`: state-change (manip) AND can cascade share-price (outflow)
    Multi-category classification lets the same function fill different
    archetype slots without forcing the spec author to duplicate it.
    """
    base = fn_name.split(".")[-1].lower()
    cats: set[str] = set()
    for kind, keys in _FLOW_KEYWORDS.items():
        for k in keys:
            if k in base:
                cats.add(kind)
                break
    return cats if cats else {"other"}


def auto_compound_templates(
    callable_functions: list[str],
) -> list[list[dict]]:
    """Generate archetype-based compound templates from a function list.

    Archetypes covered:
      A. inflow -> manip -> outflow      (yield front-run, share-inflation)
      B. inflow -> swap -> outflow       (oracle spot manipulation)
      C. swap   -> swap                  (round-trip / sandwich)
      D. inflow -> action -> outflow     (governance/liquidation route)
      E. action -> action -> outflow     (multi-claim / chained claim)

    Returns a list of templates, each a list of {fn, phase} slots. Caller
    supplies values/args at the slot level or relies on the global value pool.
    """
    inflow  = [f for f in callable_functions if "inflow"  in _classify_fn_multi(f)]
    outflow = [f for f in callable_functions if "outflow" in _classify_fn_multi(f)]
    swaps   = [f for f in callable_functions if "swap"    in _classify_fn_multi(f)]
    manips  = [f for f in callable_functions if "manip"   in _classify_fn_multi(f)]
    actions = [f for f in callable_functions if "action"  in _classify_fn_multi(f)]

    # Outflow fallback: when no explicit outflow function is in the role's
    # callable set, treat swap / action functions as outflow proxies. This
    # captures cases where the only value-extraction path is via a swap
    # (bond-and-dump) or via an action like liquidate (dYdX self-liquidation
    # collects insurance-fund reward, no separate close function exposed).
    outflow_effective = outflow if outflow else (list(swaps) + list(actions))

    # The final slot of every archetype lands at PHASE_LAST so it executes
    # AFTER honest actions of other roles (which typically live at phases 0..N).
    # Setup-style slots (inflow / swap that pumps) go at the low end. Spec
    # authors with a specific phase plan can override via manual compound_template.
    PHASE_LAST = 100
    templates: list[list[dict]] = []
    # A. inflow -> manip -> outflow
    for i in inflow:
        for m in manips:
            for o in outflow_effective:
                templates.append([
                    {"fn": i, "phase": 0},
                    {"fn": m, "phase": 1},
                    {"fn": o, "phase": PHASE_LAST},
                ])
    # B. inflow -> swap -> outflow (oracle/AMM imbalance)
    for i in inflow:
        for s in swaps:
            for o in outflow_effective:
                if o == s:
                    continue
                templates.append([
                    {"fn": i, "phase": 0},
                    {"fn": s, "phase": 1},
                    {"fn": o, "phase": PHASE_LAST},
                ])
    # C. swap round-trip
    for s1 in swaps:
        for s2 in swaps:
            if s1 == s2:
                continue
            templates.append([
                {"fn": s1, "phase": 0},
                {"fn": s2, "phase": PHASE_LAST},
            ])
    # D. inflow -> action -> outflow
    for i in inflow:
        for a in actions:
            for o in outflow_effective:
                templates.append([
                    {"fn": i, "phase": 0},
                    {"fn": a, "phase": 1},
                    {"fn": o, "phase": PHASE_LAST},
                ])
    # E. multi-claim chain
    if outflow_effective:
        for o in outflow_effective:
            templates.append([
                {"fn": o, "phase": 0},
                {"fn": o, "phase": 1},
                {"fn": o, "phase": PHASE_LAST},
            ])
    # H. 2-step inflow -> outflow. Catches direct bond-and-dump,
    # buy-and-sell on a bonding curve, deposit-and-immediate-withdraw
    # patterns where no manip/swap intermediate step is needed.
    for i in inflow:
        for o in outflow_effective:
            if i == o:
                continue
            templates.append([
                {"fn": i, "phase": 0},
                {"fn": o, "phase": PHASE_LAST},
            ])
    # I. 5-step: inflow -> inflow -> manip -> outflow. Captures
    # Cream-style donation attacks (deposit, depositCollateral, donate, borrow)
    # where the attacker funnels assets in twice (asset then collateralize)
    # before triggering the inflated valuation read.
    for i1 in inflow:
        for i2 in inflow:
            if i1 == i2:
                continue
            for m in manips:
                for o in outflow_effective:
                    templates.append([
                        {"fn": i1, "phase": 0},
                        {"fn": i2, "phase": 1},
                        {"fn": m,  "phase": 2},
                        {"fn": o,  "phase": PHASE_LAST},
                    ])
    # F. 4-step: inflow -> swap (pump) -> outflow (claim) -> swap (cash out).
    for i in inflow:
        for s1 in swaps:
            for o in outflow_effective:
                for s2 in swaps:
                    if s1 == s2 or o == s2:
                        continue
                    templates.append([
                        {"fn": i,  "phase": 0},
                        {"fn": s1, "phase": 1},
                        {"fn": o,  "phase": 2},
                        {"fn": s2, "phase": PHASE_LAST},
                    ])
    # J. manip -> inflow -> outflow. Alpha-Homora-style where manip step
    # (setLpValue / setOraclePrice) must precede the inflow so the borrow
    # sees the inflated valuation.
    for m in manips:
        for i in inflow:
            for o in outflow_effective:
                templates.append([
                    {"fn": m, "phase": 0},
                    {"fn": i, "phase": 1},
                    {"fn": o, "phase": PHASE_LAST},
                ])
    # K. action -> outflow_effective. Convex-bribe / Beanstalk-vote-style
    # where attacker uses an action (vote / propose / commit) and value
    # extraction is via subsequent outflow (claim / unvote).
    for a in actions:
        for o in outflow_effective:
            templates.append([
                {"fn": a, "phase": 0},
                {"fn": o, "phase": PHASE_LAST},
            ])
    # L. action -> outflow -> outflow. Variant of K with chained outflows.
    for a in actions:
        for o1 in outflow_effective:
            for o2 in outflow_effective:
                if o1 == o2:
                    continue
                templates.append([
                    {"fn": a,  "phase": 0},
                    {"fn": o1, "phase": 1},
                    {"fn": o2, "phase": PHASE_LAST},
                ])
    # G. 4-step: inflow -> manip -> swap -> outflow.
    for i in inflow:
        for m in manips:
            for s in swaps:
                for o in outflow_effective:
                    if o == s:
                        continue
                    templates.append([
                        {"fn": i, "phase": 0},
                        {"fn": m, "phase": 1},
                        {"fn": s, "phase": 2},
                        {"fn": o, "phase": PHASE_LAST},
                    ])
    return templates


def _find_fn_abi(
    abi: list[dict],
    name: str,
    token_abis: dict[str, list[dict]] | None = None,
) -> dict | None:
    """Resolve `fn` against the main ABI, or `Token.fn` against `token_abis[Token]`."""
    if "." in name and token_abis is not None:
        tname, fn = name.split(".", 1)
        t_abi = token_abis.get(tname)
        if t_abi is not None:
            for e in t_abi:
                if e.get("type") == "function" and e["name"] == fn:
                    return e
        return None
    for e in abi:
        if e.get("type") == "function" and e["name"] == name:
            return e
    return None


def _has_address_arg(
    action: Action, abi: list[dict], token_abis: dict[str, list[dict]] | None = None
) -> bool:
    fn = _find_fn_abi(abi, action.function, token_abis)
    if fn is None:
        return False
    return any(inp["type"] == "address" for inp in fn.get("inputs", []))


def _collect_value_pool(spec: Spec, role: Role) -> list[int]:
    """Collect interesting integer values from across the spec."""
    pool: set[int] = {0, 10**18}
    for strat in spec.honest_strategies.values():
        for action in strat.actions:
            for k, v in action.args.items():
                if isinstance(v, int) and not isinstance(v, bool):
                    pool.add(v)
                elif isinstance(v, str):
                    try:
                        pool.add(int(v.replace("_", "")))
                    except ValueError:
                        pass
    for action in spec.setup_calls:
        for v in action.args.values():
            if isinstance(v, int) and not isinstance(v, bool):
                pool.add(v)
    if spec.deploy_value_wei:
        pool.add(spec.deploy_value_wei)
    for arg in spec.deploy_args:
        if isinstance(arg, int) and not isinstance(arg, bool):
            pool.add(arg)
        elif isinstance(arg, str) and not arg.startswith("@"):
            try:
                pool.add(int(arg.replace("_", "")))
            except ValueError:
                pass
    for tdef in spec.tokens:
        for v in tdef.initial_balances.values():
            if isinstance(v, int) and not isinstance(v, bool):
                pool.add(v)
    for v in spec.value_pool_extras:
        pool.add(int(v))
    pool.add(role.initial_eth)
    pool.add(1)  # always include 1 wei (donation-attack staple)
    return sorted(pool)


def _replace_address_args_with_self(
    action: Action,
    role: Role,
    abi: list[dict],
    token_abis: dict[str, list[dict]] | None = None,
) -> Action:
    fn = _find_fn_abi(abi, action.function, token_abis)
    if fn is None:
        return action
    new_args = dict(action.args)
    for inp in fn.get("inputs", []):
        if inp["type"] == "address":
            for cand in (inp["name"], f"{inp['name']}_wei"):
                if cand in new_args:
                    new_args[cand] = f"@{role.name}"
    return Action(function=action.function, args=new_args)


# Pseudo-action arg variants. These functions are dispatched by the
# simulator (not via ABI), so the auto-archetype generator has to
# synthesize their args by name. Manually-curated set covering the
# common "time advance" / "no-arg trigger" cases.
PSEUDO_ACTION_VARIANTS: dict[str, list[dict]] = {
    "wait":                [{}],
    "advance_time":        [{"seconds": 3600}, {"seconds": 86400},
                            {"seconds": 604800}, {"seconds": 2592000}],
    "simulate_price_drop": [{"factor": 0.5}, {"factor": 0.7}, {"factor": 0.9}],
    "distribute_rewards":  [{}],
}


def _build_default_args_variants(
    fn_name: str,
    role: Role,
    abi: list[dict],
    value_pool: list[int],
    all_roles: list[Role] | None = None,
    token_abis: dict[str, list[dict]] | None = None,
) -> list[dict[str, Any]]:
    # Pseudo-actions don't have ABI entries — emit hand-curated variants.
    if fn_name in PSEUDO_ACTION_VARIANTS:
        return [dict(v) for v in PSEUDO_ACTION_VARIANTS[fn_name]]
    fn = _find_fn_abi(abi, fn_name, token_abis)
    if fn is None:
        return []
    base: dict[str, Any] = {}
    numeric_keys: list[str] = []
    address_keys: list[str] = []
    bool_keys: list[str] = []
    for inp in fn.get("inputs", []):
        if inp["type"] == "address":
            base[inp["name"]] = f"@{role.name}"
            address_keys.append(inp["name"])
        elif inp["type"].startswith("uint") or inp["type"].startswith("int"):
            key = f"{inp['name']}_wei"
            base[key] = 0
            numeric_keys.append(key)
        elif inp["type"] == "bool":
            base[inp["name"]] = False
            bool_keys.append(inp["name"])
        elif inp["type"] == "bytes" or inp["type"].startswith("bytes"):
            base[inp["name"]] = ""
        else:
            base[inp["name"]] = 0
    if fn.get("stateMutability") == "payable":
        base["value_wei"] = 0
        numeric_keys.append("value_wei")

    variants = [dict(base)]
    for nk in numeric_keys:
        for val in value_pool:
            variant = dict(base)
            variant[nk] = val
            variants.append(variant)
    # Multi-numeric-arg combos: functions like mintLP(amtA, amtB), seedPool(...),
    # openMarginPosition(...) need ALL numeric args set simultaneously, not just
    # one at a time. We emit (a) "all-args-same-value" variants for each pool
    # value, and (b) up to 64 bounded cartesian-product variants so paired
    # asymmetric ratios (e.g., 1 WETH vs 1000 USDC for an LP) are also reached.
    if len(numeric_keys) > 1:
        # (a) uniform same-value across all numeric keys
        for val in value_pool:
            variant = dict(base)
            for nk in numeric_keys:
                variant[nk] = val
            variants.append(variant)
        # (b) bounded cartesian product — caps explosion on N-arg signatures.
        from itertools import product as _prod
        pool_sample = list(value_pool)
        max_combos = 64
        emitted = 0
        for combo in _prod(pool_sample, repeat=len(numeric_keys)):
            if emitted >= max_combos:
                break
            variant = dict(base)
            for nk, v in zip(numeric_keys, combo):
                variant[nk] = v
            variants.append(variant)
            emitted += 1
    # Boolean variants — try the flipped value for every bool arg.
    if bool_keys:
        for bk in bool_keys:
            variant = dict(base)
            variant[bk] = True
            variants.append(variant)
    # Address variants: try each OTHER role and "@@self" (the main contract).
    if address_keys:
        targets: list[str] = []
        if all_roles:
            targets.extend(f"@{r.name}" for r in all_roles if r.name != role.name)
        targets.append("@@self")
        if targets:
            extra = []
            for v in variants:
                for ak in address_keys:
                    for tgt in targets:
                        nv = dict(v)
                        nv[ak] = tgt
                        extra.append(nv)
            variants.extend(extra)
    seen: set[str] = set()
    deduped: list[dict[str, Any]] = []
    for v in variants:
        k = repr(sorted(v.items()))
        if k in seen:
            continue
        seen.add(k)
        deduped.append(v)
    return deduped


def generate_deviations(
    spec: Spec,
    role_name: str,
    abi: list[dict],
    token_abis: dict[str, list[dict]] | None = None,
) -> list[Strategy]:
    """Deterministically enumerate candidate deviation strategies for a role."""
    role = spec.role_by_name(role_name)
    honest = spec.honest_strategies.get(role_name)
    hints: MutatorHints = spec.mutator_hints.get(role_name, MutatorHints())
    if honest is None:
        return []

    value_pool = _collect_value_pool(spec, role)
    out: list[Strategy] = []
    seen_keys: set[str] = set()

    def _add(strat: Strategy) -> None:
        key = strat.name + "|" + ";".join(
            f"{a.function}({sorted(a.args.items())})" for a in strat.actions
        )
        if key in seen_keys:
            return
        seen_keys.add(key)
        out.append(strat)

    # 1. Self-targeting: rewrite address args of EXISTING actions to self.
    if hints.try_self_targeting:
        for i, action in enumerate(honest.actions):
            if not _has_address_arg(action, abi, token_abis):
                continue
            new_strat = honest.clone(new_name=f"self_target_{action.function}@{i}")
            new_strat.actions[i] = _replace_address_args_with_self(action, role, abi, token_abis)
            _add(new_strat)

    # 2. Action skipping.
    if hints.try_skip_actions:
        for i, action in enumerate(honest.actions):
            new_strat = honest.clone(new_name=f"skip_{action.function}@{i}")
            del new_strat.actions[i]
            _add(new_strat)

    # 3. Action insertion.
    if hints.try_action_insertion:
        for fn_name in role.callable_functions:
            variants = _build_default_args_variants(
                fn_name, role, abi, value_pool, spec.roles, token_abis
            )
            for pos in range(len(honest.actions) + 1):
                for k, args in enumerate(variants):
                    new_strat = honest.clone(new_name=f"insert_{fn_name}@{pos}#v{k}")
                    new_strat.actions.insert(pos, Action(function=fn_name, args=dict(args)))
                    _add(new_strat)

    # 5. Compound pair insertion (two actions at different phases).
    if hints.try_compound_pair_insertion:
        if hints.compound_phase_first is not None and hints.compound_phase_second is not None:
            phase_pairs = [(hints.compound_phase_first, hints.compound_phase_second)]
        else:
            role_idx = next((i for i, r in enumerate(spec.roles) if r.name == role.name), 0)
            d = role.default_phase if role.default_phase >= 0 else role_idx
            phase_pairs = [(d, d + 1)]
        for p1, p2 in phase_pairs:
            for fn1 in role.callable_functions:
                variants1 = _build_default_args_variants(
                    fn1, role, abi, value_pool, spec.roles, token_abis
                )
                for fn2 in role.callable_functions:
                    variants2 = _build_default_args_variants(
                        fn2, role, abi, value_pool, spec.roles, token_abis
                    )
                    for i, args1 in enumerate(variants1):
                        for j, args2 in enumerate(variants2):
                            new_strat = honest.clone(
                                new_name=f"compound_{fn1}@p{p1}#v{i}+{fn2}@p{p2}#v{j}"
                            )
                            new_strat.actions.append(Action(function=fn1, args=dict(args1), phase=p1))
                            new_strat.actions.append(Action(function=fn2, args=dict(args2), phase=p2))
                            _add(new_strat)

    # 6. Compound template insertion (N-action cartesian product over arg variants).
    # If auto_compound_templates is on and no manual template is provided,
    # generate archetype-based templates from role.callable_functions.
    templates_to_run: list[list[dict]] = []
    if hints.compound_template:
        templates_to_run.append(hints.compound_template)
    if hints.auto_compound_templates and not hints.compound_template:
        templates_to_run.extend(auto_compound_templates(role.callable_functions))

    for template in templates_to_run:
        from itertools import product as _product
        slots = template
        slot_meta: list[tuple[str, int, list[dict]]] = []
        for slot in slots:
            fn_name = slot["fn"]
            phase = int(slot["phase"])
            # Slot can either:
            #  - pin a literal args dict (single concrete invocation per slot),
            #    used for pseudo-actions like advance_time and for replaying
            #    well-known exploits with hand-picked params, or
            #  - override the value pool with a tight list (avoids blowup over
            #    the global pool while keeping cartesian search across slots).
            if "args" in slot:
                variants = [dict(slot["args"])]
            else:
                slot_pool = slot.get("values")
                used_pool = [int(v) for v in slot_pool] if slot_pool is not None else value_pool
                variants = _build_default_args_variants(
                    fn_name, role, abi, used_pool, spec.roles, token_abis
                )
            slot_meta.append((fn_name, phase, variants))
        var_lists = [m[2] for m in slot_meta]
        for k, combo in enumerate(_product(*var_lists)):
            new_strat = honest.clone(new_name=f"compound_template_{role.name}_#{k}")
            for (fn_name, phase, _), args in zip(slot_meta, combo):
                new_strat.actions.append(Action(function=fn_name, args=dict(args), phase=phase))
            _add(new_strat)

    # 4. Numeric mutation of existing args (multipliers).
    if hints.try_numeric_mutation:
        multipliers = (("0.5x", 0.5), ("0.9x", 0.9), ("1.1x", 1.1), ("1.5x", 1.5), ("2x", 2.0))
        for i, action in enumerate(honest.actions):
            for k, v in action.args.items():
                if not isinstance(v, int) or isinstance(v, bool):
                    continue
                for label, mult in multipliers:
                    new_strat = honest.clone(new_name=f"num_{action.function}.{k}_{label}@{i}")
                    new_strat.actions[i].args[k] = int(v * mult)
                    _add(new_strat)

    return out

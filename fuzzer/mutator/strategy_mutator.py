from __future__ import annotations

from typing import Any

from ..core.role import Role
from ..core.spec import MutatorHints, Spec
from ..core.strategy import Action, Strategy


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


def _build_default_args_variants(
    fn_name: str,
    role: Role,
    abi: list[dict],
    value_pool: list[int],
    all_roles: list[Role] | None = None,
    token_abis: dict[str, list[dict]] | None = None,
) -> list[dict[str, Any]]:
    fn = _find_fn_abi(abi, fn_name, token_abis)
    if fn is None:
        return []
    base: dict[str, Any] = {}
    numeric_keys: list[str] = []
    address_keys: list[str] = []
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
    if hints.compound_template:
        from itertools import product as _product
        slots = hints.compound_template
        slot_meta: list[tuple[str, int, list[dict]]] = []
        for slot in slots:
            fn_name = slot["fn"]
            phase = int(slot["phase"])
            variants = _build_default_args_variants(
                fn_name, role, abi, value_pool, spec.roles, token_abis
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

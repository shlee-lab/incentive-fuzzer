from __future__ import annotations

from typing import Any

from ..core.role import Role
from ..core.spec import MutatorHints, Spec
from ..core.strategy import Action, Strategy


def _find_fn_abi(abi: list[dict], name: str) -> dict | None:
    for e in abi:
        if e.get("type") == "function" and e["name"] == name:
            return e
    return None


def _is_address_value(v: Any) -> bool:
    return isinstance(v, str) and v.startswith("@")


def _has_address_arg(action: Action, abi: list[dict]) -> bool:
    fn = _find_fn_abi(abi, action.function)
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
    pool.add(role.initial_eth)
    return sorted(pool)


def _replace_address_args_with_self(action: Action, role: Role, abi: list[dict]) -> Action:
    fn = _find_fn_abi(abi, action.function)
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
    fn_name: str, role: Role, abi: list[dict], value_pool: list[int]
) -> list[dict[str, Any]]:
    fn = _find_fn_abi(abi, fn_name)
    if fn is None:
        return []
    base: dict[str, Any] = {}
    numeric_keys: list[str] = []
    for inp in fn.get("inputs", []):
        if inp["type"] == "address":
            base[inp["name"]] = f"@{role.name}"
        elif inp["type"].startswith("uint") or inp["type"].startswith("int"):
            key = f"{inp['name']}_wei"
            base[key] = 0
            numeric_keys.append(key)
        elif inp["type"] == "bool":
            base[inp["name"]] = False
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
    spec: Spec, role_name: str, abi: list[dict]
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
            if not _has_address_arg(action, abi):
                continue
            new_strat = honest.clone(new_name=f"self_target_{action.function}@{i}")
            new_strat.actions[i] = _replace_address_args_with_self(action, role, abi)
            _add(new_strat)

    # 2. Action skipping.
    if hints.try_skip_actions:
        for i, action in enumerate(honest.actions):
            new_strat = honest.clone(new_name=f"skip_{action.function}@{i}")
            del new_strat.actions[i]
            _add(new_strat)

    # 3. Action insertion (for each callable fn, each position, each default-arg variant).
    if hints.try_action_insertion:
        for fn_name in role.callable_functions:
            variants = _build_default_args_variants(fn_name, role, abi, value_pool)
            for pos in range(len(honest.actions) + 1):
                for k, args in enumerate(variants):
                    new_strat = honest.clone(new_name=f"insert_{fn_name}@{pos}#v{k}")
                    new_strat.actions.insert(pos, Action(function=fn_name, args=dict(args)))
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

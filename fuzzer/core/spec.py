from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .role import Role
from .strategy import Action, Strategy


@dataclass
class MutatorHints:
    try_self_targeting: bool = True
    try_skip_actions: bool = True
    try_action_insertion: bool = True
    try_numeric_mutation: bool = False
    try_compound_pair_insertion: bool = False
    compound_phase_first: int | None = None
    compound_phase_second: int | None = None
    # compound_template: list of {fn: str, phase: int}; mutator generates the
    # cartesian product of arg variants across these slots in order.
    compound_template: list[dict] | None = None
    # When true, the mutator auto-generates compound_templates from common
    # attack archetypes (inflow→manip→outflow, inflow→swap→outflow,
    # swap round-trip, inflow→action→outflow, multi-claim chain), classifying
    # the role's callable_functions by name heuristic. Use as a discovery
    # mode when you don't yet know the attack shape.
    auto_compound_templates: bool = False
    # Autonomous depth-N: campaign runs a beam search, extending top-K stems
    # by every single-action insertion at each depth. >=2 enables it.
    compound_beam_max_depth: int = 0
    compound_beam_width: int = 10
    # Hard cap on candidates evaluated for this role across ALL mutation modes.
    # 0 = unlimited. User-tunable knob for combinatorial control on large
    # callable_functions / cross-contract specs.
    max_candidates_per_role: int = 0


@dataclass
class ExpectedFinding:
    role: str
    deviation_must_contain: list[str]
    payoff_higher_than_honest: bool
    min_payoff_diff_wei: int


@dataclass
class TokenDef:
    name: str
    decimals: int
    initial_balances: dict[str, int]   # role-name (or "__admin__") -> raw token units
    address: str | None = None         # if set, attach to existing token at this address (fork mode)
    storage_balance_slot: int | None = None  # storage slot for balanceOf mapping (fork mode token funding)


@dataclass
class ForkConfig:
    url: str
    block: int | None = None


@dataclass
class Spec:
    contract_path: Path
    contract_name: str
    deploy_value_wei: int
    deploy_args: list[Any]
    contract_address: str | None  # if set, fork mode: attach instead of deploying
    fork: ForkConfig | None
    roles: list[Role]
    honest_strategies: dict[str, Strategy]
    mutator_hints: dict[str, MutatorHints]
    tokens: list[TokenDef] = field(default_factory=list)
    setup_calls: list["Action"] = field(default_factory=list)
    expected_findings: list[ExpectedFinding] = field(default_factory=list)
    value_pool_extras: list[int] = field(default_factory=list)

    def role_by_name(self, name: str) -> Role:
        for r in self.roles:
            if r.name == name:
                return r
        raise KeyError(name)


def _coerce_int(v: Any) -> int:
    if isinstance(v, bool):
        raise TypeError("bool is not int")
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        return int(v.replace("_", ""))
    raise TypeError(f"cannot coerce {type(v).__name__} to int: {v!r}")


def load_spec(path: str | Path, role_addresses: dict[str, str]) -> Spec:
    """Load a spec YAML. role_addresses maps role name -> EVM address (assigned by simulator)."""
    path = Path(path)
    with open(path) as f:
        raw = yaml.safe_load(f)

    contract_path = Path(raw["contract"])
    contract_name = raw["contract_name"]
    deploy_value_wei = _coerce_int(raw.get("deploy_value_wei", 0))
    deploy_args = list(raw.get("deploy_args", []) or [])
    contract_address = raw.get("contract_address")
    fork_raw = raw.get("fork")
    fork = None
    if fork_raw:
        # Expand ${ENV_VAR} in fork URL (so keys never end up in committed YAML).
        import os, re as _re
        url = fork_raw["url"]
        def _sub(m):
            v = os.environ.get(m.group(1), "")
            if not v:
                raise RuntimeError(f"env var {m.group(1)} required by spec but not set")
            return v
        url = _re.sub(r"\$\{([A-Z0-9_]+)\}", _sub, url)
        fork = ForkConfig(
            url=url,
            block=int(fork_raw["block"]) if "block" in fork_raw else None,
        )

    roles: list[Role] = []
    for r in raw["roles"]:
        name = r["name"]
        if name not in role_addresses:
            raise KeyError(f"role {name} not assigned an address")
        roles.append(
            Role.make(
                name=name,
                address=role_addresses[name],
                initial_eth=_coerce_int(r["initial_eth_wei"]),
                callable_functions=r["callable_functions"],
                primary_asset=r.get("primary_asset", "ETH"),
                default_phase=int(r.get("default_phase", -1)),
                code_path=r.get("code_path"),
                code_name=r.get("code_name"),
                code_ctor_args=tuple(r.get("code_ctor_args", []) or []),
                agent_type=r.get("agent_type", "honest"),
            )
        )
    role_lookup = {r.name: r for r in roles}

    honest: dict[str, Strategy] = {}
    for role_name, body in raw.get("honest_strategies", {}).items():
        if role_name not in role_lookup:
            raise KeyError(f"honest_strategies references unknown role {role_name}")
        actions = [
            Action(
                function=a["function"],
                args=a.get("args", {}) or {},
                phase=(int(a["phase"]) if "phase" in a else None),
            )
            for a in body["actions"]
        ]
        honest[role_name] = Strategy(role=role_lookup[role_name], name="honest", actions=actions)

    hints: dict[str, MutatorHints] = {}
    for role_name, body in (raw.get("mutator_hints") or {}).items():
        hints[role_name] = MutatorHints(
            try_self_targeting=bool(body.get("try_self_targeting", True)),
            try_skip_actions=bool(body.get("try_skip_actions", True)),
            try_action_insertion=bool(body.get("try_action_insertion", True)),
            try_numeric_mutation=bool(body.get("try_numeric_mutation", False)),
            try_compound_pair_insertion=bool(body.get("try_compound_pair_insertion", False)),
            compound_phase_first=(int(body["compound_phase_first"]) if "compound_phase_first" in body else None),
            compound_phase_second=(int(body["compound_phase_second"]) if "compound_phase_second" in body else None),
            compound_template=(list(body["compound_template"]) if "compound_template" in body else None),
            auto_compound_templates=bool(body.get("auto_compound_templates", False)),
            compound_beam_max_depth=int(body.get("compound_beam_max_depth", 0)),
            compound_beam_width=int(body.get("compound_beam_width", 10)),
            max_candidates_per_role=int(body.get("max_candidates_per_role", 0)),
        )
    for role_name in role_lookup:
        hints.setdefault(role_name, MutatorHints())

    expected: list[ExpectedFinding] = []
    for ef in raw.get("expected_findings", []) or []:
        expected.append(
            ExpectedFinding(
                role=ef["role"],
                deviation_must_contain=list(ef.get("deviation_must_contain", [])),
                payoff_higher_than_honest=bool(ef.get("payoff_higher_than_honest", True)),
                min_payoff_diff_wei=_coerce_int(ef.get("min_payoff_diff_wei", 0)),
            )
        )

    tokens: list[TokenDef] = []
    for t in raw.get("tokens", []) or []:
        balances = {k: _coerce_int(v) for k, v in (t.get("initial_balances") or {}).items()}
        tokens.append(
            TokenDef(
                name=t["name"],
                decimals=int(t.get("decimals", 18)),
                initial_balances=balances,
                address=t.get("address"),
                storage_balance_slot=int(t["storage_balance_slot"]) if "storage_balance_slot" in t else None,
            )
        )

    setup_calls: list[Action] = []
    for c in raw.get("setup_calls", []) or []:
        setup_calls.append(Action(function=c["function"], args=c.get("args", {}) or {}))

    value_pool_extras = [_coerce_int(v) for v in (raw.get("value_pool_extras") or [])]

    return Spec(
        contract_path=contract_path,
        contract_name=contract_name,
        deploy_value_wei=deploy_value_wei,
        deploy_args=deploy_args,
        contract_address=contract_address,
        fork=fork,
        roles=roles,
        honest_strategies=honest,
        mutator_hints=hints,
        tokens=tokens,
        setup_calls=setup_calls,
        expected_findings=expected,
        value_pool_extras=value_pool_extras,
    )

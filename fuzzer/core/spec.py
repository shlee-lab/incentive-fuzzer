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


@dataclass
class Spec:
    contract_path: Path
    contract_name: str
    deploy_value_wei: int
    deploy_args: list[Any]
    roles: list[Role]
    honest_strategies: dict[str, Strategy]
    mutator_hints: dict[str, MutatorHints]
    tokens: list[TokenDef] = field(default_factory=list)
    setup_calls: list["Action"] = field(default_factory=list)
    expected_findings: list[ExpectedFinding] = field(default_factory=list)

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
            )
        )

    setup_calls: list[Action] = []
    for c in raw.get("setup_calls", []) or []:
        setup_calls.append(Action(function=c["function"], args=c.get("args", {}) or {}))

    return Spec(
        contract_path=contract_path,
        contract_name=contract_name,
        deploy_value_wei=deploy_value_wei,
        deploy_args=deploy_args,
        roles=roles,
        honest_strategies=honest,
        mutator_hints=hints,
        tokens=tokens,
        setup_calls=setup_calls,
        expected_findings=expected,
    )

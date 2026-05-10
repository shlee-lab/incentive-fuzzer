from dataclasses import dataclass, field
from typing import Any

from .role import Role


@dataclass
class Action:
    function: str
    args: dict[str, Any] = field(default_factory=dict)

    def clone(self) -> "Action":
        return Action(function=self.function, args=dict(self.args))


@dataclass
class Strategy:
    role: Role
    name: str
    actions: list[Action] = field(default_factory=list)

    def clone(self, new_name: str | None = None) -> "Strategy":
        return Strategy(
            role=self.role,
            name=new_name if new_name is not None else self.name,
            actions=[a.clone() for a in self.actions],
        )

    def function_sequence(self) -> list[str]:
        return [a.function for a in self.actions]

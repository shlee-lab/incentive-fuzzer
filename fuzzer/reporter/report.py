from __future__ import annotations

from dataclasses import dataclass, field

from ..core.strategy import Strategy


@dataclass
class Finding:
    role: str
    deviation: Strategy
    honest_payoff: int
    deviation_payoff: int
    action_log: list[str] = field(default_factory=list)
    reverts: list[str] = field(default_factory=list)

    @property
    def payoff_diff_wei(self) -> int:
        return self.deviation_payoff - self.honest_payoff

    def summary(self) -> str:
        actions = " -> ".join(a.function for a in self.deviation.actions)
        return (
            f"{self.role:>12} via {self.deviation.name:<35} "
            f"honest={self.honest_payoff/1e18:+9.4f} ETH  "
            f"dev={self.deviation_payoff/1e18:+9.4f} ETH  "
            f"diff={self.payoff_diff_wei/1e18:+9.4f} ETH  "
            f"[{actions}]"
        )


@dataclass
class CampaignReport:
    spec_path: str
    honest_payoffs: dict[str, int]
    findings: list[Finding] = field(default_factory=list)
    candidates_evaluated: int = 0

    def profitable_deviations(self) -> list[Finding]:
        return [f for f in self.findings if f.payoff_diff_wei > 0]

    def best_per_role(self) -> dict[str, Finding]:
        best: dict[str, Finding] = {}
        for f in self.findings:
            cur = best.get(f.role)
            if cur is None or f.payoff_diff_wei > cur.payoff_diff_wei:
                best[f.role] = f
        return best

    def render(self) -> str:
        lines = []
        lines.append(f"Campaign: {self.spec_path}")
        lines.append(f"Candidates evaluated: {self.candidates_evaluated}")
        lines.append("Honest payoffs:")
        for role, p in self.honest_payoffs.items():
            lines.append(f"  {role}: {p/1e18:+.4f} ETH")
        lines.append(f"Profitable deviations: {len(self.profitable_deviations())}")
        for f in sorted(self.findings, key=lambda x: -x.payoff_diff_wei):
            lines.append("  " + f.summary())
        return "\n".join(lines)

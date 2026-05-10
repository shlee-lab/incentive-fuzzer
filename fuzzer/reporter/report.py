from __future__ import annotations

from dataclasses import dataclass, field

from ..core.strategy import Strategy


@dataclass
class Finding:
    role: str
    primary_asset: str
    deviation: Strategy
    honest_payoff: int          # in primary_asset's smallest unit
    deviation_payoff: int
    asset_deltas: dict[str, int] = field(default_factory=dict)  # role's all-asset deltas
    action_log: list[str] = field(default_factory=list)
    reverts: list[str] = field(default_factory=list)

    @property
    def payoff_diff_wei(self) -> int:
        # Backwards-compat name; "wei" is just the smallest unit of primary_asset.
        return self.deviation_payoff - self.honest_payoff

    def summary(self) -> str:
        actions = " -> ".join(a.function for a in self.deviation.actions)
        scale = 10**18 if self.primary_asset == "ETH" else 1
        unit = self.primary_asset
        return (
            f"{self.role:>12} via {self.deviation.name:<35} "
            f"honest={self.honest_payoff/scale:+9.4f} {unit}  "
            f"dev={self.deviation_payoff/scale:+9.4f} {unit}  "
            f"diff={self.payoff_diff_wei/scale:+9.4f} {unit}  "
            f"[{actions}]"
        )


@dataclass
class CampaignReport:
    spec_path: str
    honest_payoffs: dict[str, int]                            # role.name -> primary-asset delta
    honest_asset_deltas: dict[str, dict[str, int]] = field(default_factory=dict)
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
        lines = [f"Campaign: {self.spec_path}",
                 f"Candidates evaluated: {self.candidates_evaluated}",
                 "Honest payoffs:"]
        for role, p in self.honest_payoffs.items():
            scale = 10**18  # render ETH-equivalent for the bare honest table
            lines.append(f"  {role}: {p/scale:+.4f} (primary)")
        lines.append(f"Profitable deviations: {len(self.profitable_deviations())}")
        for f in sorted(self.findings, key=lambda x: -x.payoff_diff_wei):
            lines.append("  " + f.summary())
        return "\n".join(lines)

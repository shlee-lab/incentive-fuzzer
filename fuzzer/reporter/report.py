from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from enum import Enum

from ..core.spec import Spec
from ..core.strategy import Strategy


class FindingLabel(str, Enum):
    """Auto-assigned classification of a profitable deviation."""
    TP_VALUE_TRANSFER = "TP_value_transfer"   # extracts value from another role
    TP_PROTOCOL_DRAIN = "TP_protocol_drain"   # extracts value from the contract itself
    STRATEGIC = "strategic"                   # same action set as honest, optimized args
    OPT_OUT = "opt_out"                       # subset of honest actions, profit = avoided cost
    UNCLASSIFIED = "unclassified"


def coverage_signature(action_log: list[str]) -> frozenset[str]:
    """Set of (role.fn) pairs that executed without revert. Coarse coverage proxy."""
    out: set[str] = set()
    for line in action_log:
        if "REVERT" in line or "ERROR" in line:
            continue
        # Lines look like:
        #   "[Role] fn([args], value=N)"  for contract calls
        #   "[env] simulate_price_drop[...]"  for pseudo-actions
        if line.startswith("["):
            try:
                tag, rest = line.split("] ", 1)
                role = tag[1:]
                # Function name = first token before "(" or "["
                fn = rest.split("(", 1)[0].split("[", 1)[0].strip()
                if fn:
                    out.add(f"{role}.{fn}")
            except (ValueError, IndexError):
                continue
    return frozenset(out)


@dataclass
class Finding:
    role: str
    primary_asset: str
    deviation: Strategy
    honest_payoff: int
    deviation_payoff: int
    asset_deltas: dict[str, int] = field(default_factory=dict)
    action_log: list[str] = field(default_factory=list)
    reverts: list[str] = field(default_factory=list)
    # Set by Campaign after construction.
    label: FindingLabel = FindingLabel.UNCLASSIFIED
    label_reason: str = ""
    coverage: frozenset[str] = field(default_factory=frozenset)

    @property
    def payoff_diff_wei(self) -> int:
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
            f"[{self.label.value}]  [{actions}]"
        )


def classify_finding(
    finding: Finding,
    spec: Spec,
    honest_asset_deltas: dict[str, dict[str, int]],
    deviation_asset_deltas: dict[str, dict[str, int]],
) -> tuple[FindingLabel, str]:
    """Heuristic classifier. Decision order:

      1. OPT_OUT: deviation is a strict subset of honest actions (profit
         is from skipping costs, not from active exploit).
      2. TP_VALUE_TRANSFER (strict cashflow): another role's primary asset
         actually went BELOW its honest level AND below zero — they lost
         real funds, not just opportunity.
      3. TP_PROTOCOL_DRAIN (relaxed): main contract's primary asset
         balance lower in deviation than honest — protocol reserves
         depleted.
      4. TP_VALUE_TRANSFER (cross-role): deviation inserts a function
         that's in ANOTHER role's callable_functions — the deviating
         role is performing work the protocol intended for someone
         else, capturing their reward.
      5. STRATEGIC: all deviation actions are in this role's own
         callable_functions and no harm detected — rational arg-tweak
         within designed behavior.
      6. UNCLASSIFIED.
    """
    role = spec.role_by_name(finding.role)
    dev_fns = [a.function for a in finding.deviation.actions]
    honest = spec.honest_strategies.get(finding.role)
    honest_fns = [a.function for a in honest.actions] if honest else []

    own_callable = set(role.callable_functions)
    other_callables: set[str] = set()
    for r in spec.roles:
        if r.name != role.name:
            other_callables.update(r.callable_functions)

    dev_counter = Counter(dev_fns)
    honest_counter = Counter(honest_fns)
    is_strict_subset = (
        all(dev_counter[fn] <= honest_counter[fn] for fn in dev_counter)
        and len(dev_fns) < len(honest_fns)
    )

    # 1. OPT_OUT first: subset = passive opt-out, not exploit.
    if is_strict_subset:
        return (FindingLabel.OPT_OUT, "strict subset of honest actions")

    # 2. Other-role lost value relative to honest baseline (relaxed: doesn't
    # require dev_delta < 0; opportunity loss counts because the protocol
    # intended a payout that the deviation captured/blocked).
    for other in spec.roles:
        if other.name == role.name:
            continue
        h = honest_asset_deltas.get(other.name, {}).get(other.primary_asset, 0)
        d = deviation_asset_deltas.get(other.name, {}).get(other.primary_asset, 0)
        if d < h:
            return (
                FindingLabel.TP_VALUE_TRANSFER,
                f"{other.name}'s {other.primary_asset} fell from {h} to {d}",
            )

    # 3. Protocol drain (relaxed): contract holds less primary asset than honest.
    h_c = honest_asset_deltas.get("__contract__", {}).get(role.primary_asset, 0)
    d_c = deviation_asset_deltas.get("__contract__", {}).get(role.primary_asset, 0)
    if d_c < h_c:
        return (
            FindingLabel.TP_PROTOCOL_DRAIN,
            f"contract's {role.primary_asset} lower by {h_c - d_c} vs honest",
        )

    # 4. Cross-role: inserted function is reserved for another role.
    new_fns = set(dev_fns) - set(honest_fns)
    cross_fns = new_fns & other_callables
    if cross_fns:
        return (
            FindingLabel.TP_VALUE_TRANSFER,
            f"insertion of {sorted(cross_fns)} captures reward intended for another role",
        )

    # 5. Pure own-callable use, no real harm: rational strategy.
    # Pseudo-actions (env-driven, not user-callable) are harmless filler.
    pseudo = {"wait", "advance_time", "simulate_price_drop", "distribute_rewards"}
    if dev_counter == honest_counter or all(fn in own_callable or fn in pseudo for fn in dev_fns):
        return (FindingLabel.STRATEGIC, "uses only own callables; no other-role/contract loss")

    return (FindingLabel.UNCLASSIFIED, "")


@dataclass
class CampaignReport:
    spec_path: str
    honest_payoffs: dict[str, int]
    honest_asset_deltas: dict[str, dict[str, int]] = field(default_factory=dict)
    findings: list[Finding] = field(default_factory=list)
    candidates_evaluated: int = 0

    def profitable_deviations(self) -> list[Finding]:
        return [f for f in self.findings if f.payoff_diff_wei > 0]

    def true_positives(self) -> list[Finding]:
        return [
            f for f in self.findings
            if f.label in (FindingLabel.TP_VALUE_TRANSFER, FindingLabel.TP_PROTOCOL_DRAIN)
        ]

    def by_label(self) -> dict[FindingLabel, list[Finding]]:
        out: dict[FindingLabel, list[Finding]] = {l: [] for l in FindingLabel}
        for f in self.findings:
            out[f.label].append(f)
        return out

    def best_per_role(self) -> dict[str, Finding]:
        best: dict[str, Finding] = {}
        for f in self.findings:
            cur = best.get(f.role)
            if cur is None or f.payoff_diff_wei > cur.payoff_diff_wei:
                best[f.role] = f
        return best

    def deduplicated_by_coverage(self) -> list[Finding]:
        """Group findings by (role, coverage signature, label); keep the highest-payoff one
        per group. Collapses the long tail of redundant args-variants into a single entry."""
        best: dict[tuple, Finding] = {}
        for f in self.findings:
            key = (f.role, f.coverage, f.label)
            cur = best.get(key)
            if cur is None or f.payoff_diff_wei > cur.payoff_diff_wei:
                best[key] = f
        return list(best.values())

    def render(self) -> str:
        lines = [
            f"Campaign: {self.spec_path}",
            f"Candidates evaluated: {self.candidates_evaluated}",
            "Honest payoffs:",
        ]
        for role, p in self.honest_payoffs.items():
            scale = 10**18
            lines.append(f"  {role}: {p/scale:+.4f} (primary)")
        lines.append(f"Profitable deviations: {len(self.profitable_deviations())}")
        by_label = self.by_label()
        for lbl, fs in by_label.items():
            if fs:
                lines.append(f"  {lbl.value}: {len(fs)}")
        for f in sorted(self.findings, key=lambda x: -x.payoff_diff_wei):
            lines.append("  " + f.summary())
        return "\n".join(lines)

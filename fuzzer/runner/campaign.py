from __future__ import annotations

import sys
from pathlib import Path

from ..core.role import Role
from ..core.simulator import Simulator
from ..mutator.strategy_mutator import generate_deviations
from ..reporter.report import CampaignReport, Finding


def _default_epsilon(role: Role) -> int:
    """Filter out gas-noise findings. Only applied when primary_asset == ETH."""
    if role.primary_asset == "ETH":
        return 10**16  # 0.01 ETH
    return 0  # for tokens, accept any positive delta; tests filter by amount


class Campaign:
    def __init__(
        self,
        spec_path: str | Path,
        epsilon_wei: int | None = None,
        verbose: bool = False,
    ) -> None:
        self.spec_path = str(spec_path)
        self.epsilon_wei = epsilon_wei
        self.verbose = verbose

    def _log(self, msg: str) -> None:
        if self.verbose:
            print(msg, flush=True)

    def run(self) -> CampaignReport:
        with Simulator(self.spec_path) as sim:
            honest_result = sim.execute_scenario(sim.spec.honest_strategies)
            honest_primary = {r.name: honest_result.primary_for(r) for r in sim.spec.roles}
            honest_assets = dict(honest_result.asset_deltas)
            self._log(f"Honest payoffs (primary): {honest_primary}")

            report = CampaignReport(
                spec_path=self.spec_path,
                honest_payoffs=honest_primary,
                honest_asset_deltas=honest_assets,
            )

            for role in sim.spec.roles:
                if role.name not in sim.spec.honest_strategies:
                    continue
                eps = self.epsilon_wei if self.epsilon_wei is not None else _default_epsilon(role)
                deviations = generate_deviations(sim.spec, role.name, sim._abi)
                self._log(f"[{role.name}] {len(deviations)} deviation candidates")
                for dev in deviations:
                    scenario = dict(sim.spec.honest_strategies)
                    scenario[role.name] = dev
                    result = sim.execute_scenario(scenario)
                    report.candidates_evaluated += 1
                    payoff = result.primary_for(role)
                    diff = payoff - honest_primary.get(role.name, 0)
                    if diff >= eps and diff > 0:
                        finding = Finding(
                            role=role.name,
                            primary_asset=role.primary_asset,
                            deviation=dev,
                            honest_payoff=honest_primary.get(role.name, 0),
                            deviation_payoff=payoff,
                            asset_deltas=dict(result.asset_deltas.get(role.name, {})),
                            action_log=result.action_log,
                            reverts=result.reverts,
                        )
                        report.findings.append(finding)
                        self._log(f"  + {finding.summary()}")

            return report


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) < 1:
        print("usage: python -m fuzzer.runner.campaign <spec.yaml>", file=sys.stderr)
        return 2
    spec_path = args[0]
    report = Campaign(spec_path, verbose=True).run()
    print(report.render())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

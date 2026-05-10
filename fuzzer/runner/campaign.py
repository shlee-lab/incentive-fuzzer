from __future__ import annotations

import sys
from pathlib import Path

from ..core.simulator import Simulator
from ..mutator.strategy_mutator import generate_deviations
from ..reporter.report import CampaignReport, Finding


class Campaign:
    """Runs the honest baseline and enumerates deviation candidates per role."""

    def __init__(
        self,
        spec_path: str | Path,
        epsilon_wei: int = 10**16,  # 0.01 ETH; reverted-tx gas costs are well below this.
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
            honest_payoffs = dict(honest_result.payoffs)
            self._log(f"Honest payoffs: { {k: v/1e18 for k,v in honest_payoffs.items()} }")

            report = CampaignReport(
                spec_path=self.spec_path,
                honest_payoffs=honest_payoffs,
            )

            for role in sim.spec.roles:
                if role.name not in sim.spec.honest_strategies:
                    continue
                deviations = generate_deviations(sim.spec, role.name, sim._abi)
                self._log(f"[{role.name}] {len(deviations)} deviation candidates")
                for dev in deviations:
                    scenario = dict(sim.spec.honest_strategies)
                    scenario[role.name] = dev
                    result = sim.execute_scenario(scenario)
                    report.candidates_evaluated += 1
                    payoff = result.payoffs.get(role.name, 0)
                    diff = payoff - honest_payoffs.get(role.name, 0)
                    if diff >= self.epsilon_wei:
                        finding = Finding(
                            role=role.name,
                            deviation=dev,
                            honest_payoff=honest_payoffs.get(role.name, 0),
                            deviation_payoff=payoff,
                            action_log=result.action_log,
                            reverts=result.reverts,
                        )
                        report.findings.append(finding)
                        self._log(f"  + finding: {finding.summary()}")

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

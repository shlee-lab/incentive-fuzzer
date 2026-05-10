from __future__ import annotations

import sys
from pathlib import Path

from ..core.role import Role
from ..core.simulator import Simulator
from ..core.strategy import Action, Strategy
from ..mutator.strategy_mutator import (
    _build_default_args_variants,
    _collect_value_pool,
    generate_deviations,
)
from ..reporter.report import CampaignReport, Finding, classify_finding, coverage_signature


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

    def _token_abis(self, sim: Simulator) -> dict[str, list[dict]]:
        if not sim._token_addresses or sim._erc20_abi is None:
            return {}
        return {tname: sim._erc20_abi for tname in sim._token_addresses}

    def _budget_remaining(self, hints, used: int) -> int | None:
        cap = hints.max_candidates_per_role or 0
        if cap <= 0:
            return None
        return max(0, cap - used)

    def _role_extended_abi(self, sim: Simulator, role: Role) -> list[dict]:
        """If role has code deployed (role.code_path set), merge its ABI into
        the main contract ABI so the mutator can discover its functions."""
        if role.name in sim._role_contracts:
            return list(sim._abi) + list(sim._role_contracts[role.name].abi)
        return sim._abi

    def _run_static_mutations(
        self, sim: Simulator, role: Role, honest_primary: int, eps: int, report: CampaignReport
    ) -> int:
        hints = sim.spec.mutator_hints[role.name]
        token_abis = self._token_abis(sim)
        abi = self._role_extended_abi(sim, role)
        deviations = generate_deviations(sim.spec, role.name, abi, token_abis)
        budget = hints.max_candidates_per_role or len(deviations)
        if budget < len(deviations):
            self._log(f"[{role.name}] static budget cap: {budget}/{len(deviations)} candidates")
            deviations = deviations[:budget]
        self._log(f"[{role.name}] {len(deviations)} static deviation candidates")
        used = 0
        for dev in deviations:
            scenario = dict(sim.spec.honest_strategies)
            scenario[role.name] = dev
            result = sim.execute_scenario(scenario)
            report.candidates_evaluated += 1
            used += 1
            payoff = result.primary_for(role)
            diff = payoff - honest_primary
            if diff >= eps and diff > 0:
                finding = Finding(
                    role=role.name,
                    primary_asset=role.primary_asset,
                    deviation=dev,
                    honest_payoff=honest_primary,
                    deviation_payoff=payoff,
                    asset_deltas=dict(result.asset_deltas.get(role.name, {})),
                    action_log=result.action_log,
                    reverts=result.reverts,
                )
                finding.label, finding.label_reason = classify_finding(
                    finding, sim.spec, report.honest_asset_deltas, result.asset_deltas
                )
                finding.coverage = coverage_signature(result.action_log)
                report.findings.append(finding)
                self._log(f"  + {finding.summary()}")
        return used

    def _run_beam_search(
        self,
        sim: Simulator,
        role: Role,
        honest_primary: int,
        eps: int,
        report: CampaignReport,
        budget: int | None = None,
    ) -> None:
        """Autonomous depth-N compound discovery via beam search.

        At each depth d, extend each stem in the beam by every single-action
        insertion at phase = base_phase + (d - 1). Score stems by primary
        profit (if > 0) else by total |asset delta| (state activity); keep
        the top-K for the next depth. All profitable extensions are recorded.
        """
        hints = sim.spec.mutator_hints[role.name]
        max_depth = hints.compound_beam_max_depth
        beam_width = hints.compound_beam_width or 10
        token_abis = self._token_abis(sim)

        value_pool = _collect_value_pool(sim.spec, role)
        actions_pool: list[tuple[str, dict]] = []
        abi = self._role_extended_abi(sim, role)
        for fn in role.callable_functions:
            for args in _build_default_args_variants(
                fn, role, abi, value_pool, sim.spec.roles, token_abis
            ):
                actions_pool.append((fn, args))

        role_idx = next(i for i, r in enumerate(sim.spec.roles) if r.name == role.name)
        base_phase = role.default_phase if role.default_phase >= 0 else role_idx

        honest_strat = sim.spec.honest_strategies[role.name]
        beam: list[Strategy] = [honest_strat]
        seen_keys: set[str] = set()
        # Coverage already exercised by honest baseline — used to compute novelty.
        honest_cov = frozenset()
        try:
            honest_res = sim.execute_scenario(sim.spec.honest_strategies)
            honest_cov = coverage_signature(honest_res.action_log)
        except Exception:
            pass

        def _strat_key(s: Strategy) -> str:
            return ";".join(
                f"{a.function}@{a.phase}({sorted(a.args.items())})" for a in s.actions
            )

        used = 0
        for d in range(1, max_depth + 1):
            if budget is not None and used >= budget:
                self._log(f"[{role.name}] beam depth {d}: budget exhausted ({used}), stopping")
                return
            phase_d = base_phase + (d - 1)
            scored: list[tuple[float, Strategy]] = []
            self._log(f"[{role.name}] beam depth {d}: {len(beam)} stems x {len(actions_pool)} actions")
            for stem in beam:
                if budget is not None and used >= budget:
                    break
                for fn, args in actions_pool:
                    if budget is not None and used >= budget:
                        break
                    extended = stem.clone(new_name=f"beam_d{d}_{fn}_{role.name}")
                    extended.actions.append(Action(function=fn, args=dict(args), phase=phase_d))
                    key = _strat_key(extended)
                    if key in seen_keys:
                        continue
                    seen_keys.add(key)

                    scenario = dict(sim.spec.honest_strategies)
                    scenario[role.name] = extended
                    result = sim.execute_scenario(scenario)
                    report.candidates_evaluated += 1
                    used += 1

                    payoff = result.primary_for(role)
                    profit = payoff - honest_primary

                    cov = coverage_signature(result.action_log)
                    novelty = len(cov - honest_cov)

                    if profit >= eps and profit > 0:
                        finding = Finding(
                            role=role.name,
                            primary_asset=role.primary_asset,
                            deviation=extended,
                            honest_payoff=honest_primary,
                            deviation_payoff=payoff,
                            asset_deltas=dict(result.asset_deltas.get(role.name, {})),
                            action_log=result.action_log,
                            reverts=result.reverts,
                        )
                        finding.label, finding.label_reason = classify_finding(
                            finding, sim.spec, report.honest_asset_deltas, result.asset_deltas
                        )
                        finding.coverage = cov
                        report.findings.append(finding)
                        self._log(f"  + beam d{d} {finding.summary()}")

                    if profit > 0:
                        score = 1e30 + float(profit)  # always above any state-change score
                    else:
                        state_change = sum(
                            abs(v) for v in result.asset_deltas.get(role.name, {}).values()
                        )
                        # Coverage-guided bonus: prefer stems exercising new fns vs honest.
                        # 1e20 per novel function dwarfs any plausible state_change in raw
                        # token units but stays below the profit-found threshold.
                        score = float(state_change) + 1e20 * novelty
                    scored.append((score, extended))

            scored.sort(key=lambda x: x[0], reverse=True)
            beam = [s for _, s in scored[:beam_width]]

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
                hints = sim.spec.mutator_hints[role.name]
                used = self._run_static_mutations(
                    sim, role, honest_primary.get(role.name, 0), eps, report
                )
                if hints.compound_beam_max_depth and hints.compound_beam_max_depth > 0:
                    remaining = self._budget_remaining(hints, used)
                    self._run_beam_search(
                        sim, role, honest_primary.get(role.name, 0), eps, report, budget=remaining
                    )

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

"""Sanity check: run honest lending scenario, print payoffs and trace."""
from fuzzer.core.simulator import Simulator


def main() -> None:
    with Simulator("specs/simple_lending.yaml") as sim:
        result = sim.execute_scenario(sim.spec.honest_strategies)
        for line in result.action_log:
            print(line)
        print("---")
        for name, delta in result.payoffs.items():
            print(f"{name}: {delta} wei  ({delta / 10**18:+.4f} ETH)")
        if result.reverts:
            print("reverts:")
            for r in result.reverts:
                print("  -", r)


if __name__ == "__main__":
    main()

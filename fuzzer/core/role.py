from dataclasses import dataclass


@dataclass(frozen=True)
class Role:
    name: str
    address: str
    initial_eth: int
    callable_functions: tuple[str, ...]
    primary_asset: str = "ETH"
    default_phase: int = -1
    # Optional: deploy a Solidity contract at this role's address so the role
    # is a smart contract (can implement receive/fallback/callbacks) rather
    # than an EOA. Enables modeling reentrancy and callback-driven attacks.
    code_path: str | None = None
    code_name: str | None = None
    code_ctor_args: tuple = ()
    # For multi-agent iterated-best-response equilibrium analysis:
    #   "honest"        — sticks to spec's honest_strategies entry
    #   "best_response" — searches for best deviation against current
    #                     equilibrium strategies of other agents
    agent_type: str = "honest"

    @classmethod
    def make(
        cls,
        name: str,
        address: str,
        initial_eth: int,
        callable_functions,
        primary_asset: str = "ETH",
        default_phase: int = -1,
        code_path: str | None = None,
        code_name: str | None = None,
        code_ctor_args=(),
        agent_type: str = "honest",
    ):
        return cls(
            name=name,
            address=address,
            initial_eth=int(initial_eth),
            callable_functions=tuple(callable_functions),
            primary_asset=primary_asset,
            default_phase=int(default_phase),
            code_path=code_path,
            code_name=code_name,
            code_ctor_args=tuple(code_ctor_args),
            agent_type=agent_type,
        )

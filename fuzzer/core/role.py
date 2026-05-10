from dataclasses import dataclass


@dataclass(frozen=True)
class Role:
    name: str
    address: str
    initial_eth: int
    callable_functions: tuple[str, ...]
    primary_asset: str = "ETH"  # asset used for honest-vs-deviation comparison

    @classmethod
    def make(cls, name: str, address: str, initial_eth: int, callable_functions, primary_asset: str = "ETH"):
        return cls(
            name=name,
            address=address,
            initial_eth=int(initial_eth),
            callable_functions=tuple(callable_functions),
            primary_asset=primary_asset,
        )

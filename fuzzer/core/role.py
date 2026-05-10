from dataclasses import dataclass


@dataclass(frozen=True)
class Role:
    name: str
    address: str
    initial_eth: int
    callable_functions: tuple[str, ...]

    @classmethod
    def make(cls, name: str, address: str, initial_eth: int, callable_functions):
        return cls(
            name=name,
            address=address,
            initial_eth=int(initial_eth),
            callable_functions=tuple(callable_functions),
        )

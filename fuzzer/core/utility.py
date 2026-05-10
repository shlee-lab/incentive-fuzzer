from .role import Role


def eth_balance_change(role: Role, balance_before: int, balance_after: int) -> int:
    """Default utility: change in ETH balance for the role's address."""
    return balance_after - balance_before

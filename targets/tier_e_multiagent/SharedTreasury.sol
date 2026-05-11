// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// SharedTreasury — first-come-first-served prize pool.
///
/// Honest scenario assumed: passive holders / no one rushes to claim.
/// Multi-agent reality: each holder has incentive to claim ASAP because
/// whoever calls first gets the full pool; subsequent callers' calls
/// revert. Iterated best response converges to "first mover claims,
/// others stay honest" — a Nash equilibrium that diverges from the
/// honest-all scenario the protocol designer assumed.
///
/// Detecting this divergence is the multi-agent incentive fuzzer's
/// novel contribution: state-invariant fuzzers (Echidna) check
/// per-state assertions and cannot reason about equilibrium strategies
/// across multiple rational agents.
contract SharedTreasury {
    bool public claimed;

    constructor() payable {}

    function claim() external {
        require(!claimed, "already claimed");
        claimed = true;
        (bool ok, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(ok, "xfer");
    }
}

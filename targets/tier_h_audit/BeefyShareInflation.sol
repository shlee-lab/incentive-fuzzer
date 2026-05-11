// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// BeefyShareInflation — reduction of a Sherlock audit-class first-
/// depositor share-inflation pattern (Beefy Finance, OpenZeppelin
/// audits, plus many smaller vaults). When totalShares == 0, the first
/// depositor receives 1 share per 1 underlying — but they can then
/// inflate underlyingHeld via a donation (raw token.transfer), making
/// each share worth far more than 1. Subsequent depositors are short-
/// changed: their (newAmt * totalShares) / underlying rounds DOWN,
/// sometimes to 0, so they effectively pay underlying but receive 0
/// shares — the attacker pockets the inflated balance.
///
/// Reduction: standard vault. Attacker deposits 1 wei → donates X →
/// next honest user deposits Y < X (rounds to 0 shares) → attacker
/// withdraws and captures Y.
contract BeefyShareInflation {
    address public immutable asset;
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    constructor(address _a) { asset = _a; }

    function deposit(uint256 amt) external returns (uint256 sh) {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        uint256 held = IERC20(asset).balanceOf(address(this));
        if (totalShares == 0) {
            sh = amt;
        } else {
            // Rounds DOWN — first-depositor inflation makes this 0 for small amt.
            sh = (amt * totalShares) / (held - amt);
        }
        totalShares += sh;
        shareOf[msg.sender] += sh;
    }

    function withdraw(uint256 sh) external returns (uint256 amt) {
        uint256 held = IERC20(asset).balanceOf(address(this));
        amt = (sh * held) / totalShares;
        shareOf[msg.sender] -= sh;
        totalShares -= sh;
        require(IERC20(asset).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// RORVault — read-only reentrancy positive control with a vault and a
/// "bonus payout" function in the same contract. Real RoR involves a
/// SEPARATE consumer reading the vault's view; we collapse both into one
/// contract for the positive control to keep the spec simple. The pattern
/// is identical: the view (pricePerShare) returns stale data during a
/// withdraw's external call, and the bonus function (claimBonus) pays out
/// based on that stale view.
contract RORVault {
    uint256 public totalShares;
    uint256 public totalAssets;
    mapping(address => uint256) public shareOf;

    constructor() payable {}     // allow seeding consumer reserves at deploy

    function deposit() external payable {
        uint256 shares = msg.value;
        shareOf[msg.sender] += shares;
        totalShares += shares;
        totalAssets += msg.value;
    }

    function pricePerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalAssets * 1e18) / totalShares;
    }

    function withdraw(uint256 shares) external {
        require(shareOf[msg.sender] >= shares, "insufficient");
        uint256 amount = (shares * pricePerShare()) / 1e18;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "xfer");
        totalAssets -= amount;       // BUG: should be BEFORE the external call
    }

    function claimBonus() external {
        // Bonus scales with pricePerShare. During a withdraw callback, the
        // price is inflated, so this pays out far more than the contract
        // would expect at "rest" state.
        uint256 price = pricePerShare();
        uint256 bonus = (1 ether * price) / 1e18;
        require(address(this).balance >= bonus, "drained");
        (bool ok, ) = msg.sender.call{value: bonus}("");
        require(ok, "bonus xfer");
    }

    receive() external payable {}
}

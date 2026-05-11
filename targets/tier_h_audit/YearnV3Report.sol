// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// YearnV3Report — reduction of an audit-class finding on Yearn V3
/// strategy `report()` accounting (multiple audits flagged variations
/// of this pattern: strategy operator privilege + share-price-from-
/// report).
///
/// Pattern: the strategy operator calls `report()` to inform the vault
/// of strategy gains/losses. Share price is recomputed afterwards. A
/// strategy operator who is ALSO a depositor can call report() with
/// inflated profit numbers, then withdraw at the inflated share price.
///
/// Reduction: vault where caller-supplied `report(profit)` raises
/// share price. Attacker = strategy = depositor calls report(big) → withdraw.
contract YearnV3Report {
    address public immutable asset;
    address public strategist;

    uint256 public totalShares;
    mapping(address => uint256) public shareOf;
    uint256 public assetsHeld;

    constructor(address _a, address _s) { asset = _a; strategist = _s; }

    function deposit(uint256 amt) external returns (uint256 sh) {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        if (totalShares == 0) {
            sh = amt;
        } else {
            sh = (amt * totalShares) / assetsHeld;
        }
        totalShares += sh;
        shareOf[msg.sender] += sh;
        assetsHeld += amt;
    }

    function withdraw(uint256 sh) external returns (uint256 amt) {
        amt = (sh * assetsHeld) / totalShares;
        if (amt > IERC20(asset).balanceOf(address(this))) {
            amt = IERC20(asset).balanceOf(address(this));
        }
        shareOf[msg.sender] -= sh;
        totalShares -= sh;
        assetsHeld -= amt;
        require(IERC20(asset).transfer(msg.sender, amt));
    }

    /// BUG: caller-supplied profit number simply credits assetsHeld
    /// without any backing — share price rises immediately.
    function report(int256 profit) external {
        require(msg.sender == strategist, "not strategist");
        if (profit > 0) {
            assetsHeld += uint256(profit);
        } else if (profit < 0) {
            uint256 loss = uint256(-profit);
            if (loss > assetsHeld) loss = assetsHeld;
            assetsHeld -= loss;
        }
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

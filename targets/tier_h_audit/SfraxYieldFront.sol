// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// SfraxYieldFront — reduction of an audit-class finding on Frax
/// Finance's sFRAX (and analogous ERC4626 yield-bearing wrappers).
/// Yield is added in discrete chunks by `addYield()`. A user who
/// observes the upcoming addYield (in mempool) can deposit just before
/// and withdraw just after, capturing yield proportional to their
/// LARGE deposit that they only held for a single block.
contract SfraxYieldFront {
    address public immutable asset;
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;
    uint256 public assetsHeld;

    constructor(address _a) { asset = _a; }

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
        shareOf[msg.sender] -= sh;
        totalShares -= sh;
        assetsHeld -= amt;
        require(IERC20(asset).transfer(msg.sender, amt));
    }

    /// Anyone can trigger yield addition (in production this is
    /// keeper-routed but the audit finding is about lack of
    /// commit-time between deposit and the yield event).
    function addYield(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        assetsHeld += amt;
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

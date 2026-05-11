// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// MphFrontRun — reduction of the 88mph fixed-yield-front-run pattern (audit class).
///
/// Original pattern: a fixed-yield deposit aggregator credits MPH reward
/// tokens to depositors. The reward function reads a yield index that
/// updates each `harvest()`. New depositors who deposit *just before* a
/// harvest(), then withdraw *just after*, free-ride on yield that was
/// earned by older depositors.
///
/// Implicit assumption (NOT enforced):
/// - Yield index increase between two harvests reflects work done by
///   depositors who held through that interval.
///
/// Expected deviation:
/// - deposit(X) → harvest → withdraw(X) — collects reward proportional
///   to X * (newIndex - oldIndex), even though they were not staked
///   during the interval.
contract MphFrontRun {
    address public immutable asset;
    address public immutable reward;

    uint256 public yieldIndex = 1e18;     // ramps up on harvest()
    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public indexSnapshot;
    mapping(address => uint256) public rewardOf;

    constructor(address _asset, address _reward) {
        asset = _asset;
        reward = _reward;
    }

    function deposit(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        _accrue(msg.sender);
        stakedOf[msg.sender] += amt;
        totalStaked += amt;
    }

    function withdraw(uint256 amt) external {
        _accrue(msg.sender);
        stakedOf[msg.sender] -= amt;
        totalStaked -= amt;
        require(IERC20(asset).transfer(msg.sender, amt));
    }

    function harvest() external {
        // Yield bumps the index (real protocols compute this from Compound /
        // Aave rate accrual; we simulate +10% per harvest).
        yieldIndex = (yieldIndex * 11) / 10;
    }

    function claimReward() external {
        _accrue(msg.sender);
        uint256 r = rewardOf[msg.sender];
        rewardOf[msg.sender] = 0;
        require(IERC20(reward).transfer(msg.sender, r));
    }

    function _accrue(address u) internal {
        if (stakedOf[u] > 0) {
            uint256 delta = yieldIndex - indexSnapshot[u];
            rewardOf[u] += (stakedOf[u] * delta) / 1e18;
        }
        indexSnapshot[u] = yieldIndex;
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// CompoundV3BorrowCap — reduction of an audit-class finding on
/// Compound V3 supply-cap / borrow-cap behavior. The protocol updates
/// cap-utilization-based interest rates on each `accrue()` call. A user
/// who knows when a cap-change is going to bump interest rates can
/// stake just before the bump to capture the higher emissions.
///
/// Reduction: borrowers earn reward proportional to their share of
/// utilization. Just before the utilization-rate index update, a user
/// who deposits a large amount of collateral and immediately exits
/// captures the bumped reward.
contract CompoundV3BorrowCap {
    address public immutable asset;
    uint256 public rewardIndex = 1e18;
    uint256 public totalSupplied;
    mapping(address => uint256) public suppliedOf;
    mapping(address => uint256) public rewardSnapshot;
    mapping(address => uint256) public pendingReward;

    constructor(address _a) { asset = _a; }

    function _accrue(address u) internal {
        uint256 delta = rewardIndex - rewardSnapshot[u];
        pendingReward[u] += (suppliedOf[u] * delta) / 1e18;
        rewardSnapshot[u] = rewardIndex;
    }

    function supply(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        _accrue(msg.sender);
        suppliedOf[msg.sender] += amt;
        totalSupplied += amt;
    }

    function withdraw(uint256 amt) external {
        _accrue(msg.sender);
        suppliedOf[msg.sender] -= amt;
        totalSupplied -= amt;
        require(IERC20(asset).transfer(msg.sender, amt));
    }

    /// Anyone can poke a cap-utilization update — in real Compound V3
    /// this comes from interest accrual on every state-changing call,
    /// but the audit-class finding is about the predictability of the
    /// update. We model the "next bump is huge" case.
    function bumpRewardIndex(uint256 bump) external {
        rewardIndex += bump;
    }

    function claim() external {
        _accrue(msg.sender);
        uint256 amt = pendingReward[msg.sender];
        pendingReward[msg.sender] = 0;
        require(IERC20(asset).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

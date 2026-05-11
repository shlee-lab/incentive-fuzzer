// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// MapleDelegate — reduction of a Maple Finance pool-delegate-fee audit
/// pattern. Pool delegates earn a percentage of pool yield as performance
/// fee. The fee is computed against the current `principal` snapshot, which
/// the delegate can ALSO inflate by self-depositing right before harvest.
///
/// Pattern: delegate is a privileged role, but the FEE-calculation
/// formula depends on principal that delegate controls. The delegate
/// extracts more fees than fair by sandwiching the harvest with a
/// self-deposit / self-withdraw.
///
/// Expected deviation:
/// - depositAsDelegate(big) -> harvest() -> claimDelegateFee() -> withdrawAsDelegate
contract MapleDelegate {
    address public immutable asset;
    address public delegate;        // pool delegate

    uint256 public principal;
    uint256 public yieldIndex = 1e18;
    mapping(address => uint256) public depositOf;
    uint256 public delegateFeeAccrued;

    constructor(address _asset, address _delegate) {
        asset = _asset;
        delegate = _delegate;
    }

    function deposit(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        depositOf[msg.sender] += amt;
        principal += amt;
    }

    function withdraw(uint256 amt) external {
        depositOf[msg.sender] -= amt;
        principal -= amt;
        require(IERC20(asset).transfer(msg.sender, amt));
    }

    /// Anyone can trigger; in production this is permissioned but the
    /// FEE-extraction surface exists regardless of who calls.
    function harvest() external {
        uint256 yieldEarned = principal / 20;    // 5% per harvest (toy)
        // 10% goes to delegate as performance fee — based on CURRENT principal.
        uint256 fee = yieldEarned / 10;
        delegateFeeAccrued += fee;
        // Remaining yield raises the index (helps depositors pro-rata).
        if (principal > 0) {
            yieldIndex = yieldIndex + ((yieldEarned - fee) * 1e18) / principal;
        }
    }

    function claimDelegateFee() external {
        require(msg.sender == delegate, "not delegate");
        uint256 amt = delegateFeeAccrued;
        delegateFeeAccrued = 0;
        require(IERC20(asset).transfer(delegate, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

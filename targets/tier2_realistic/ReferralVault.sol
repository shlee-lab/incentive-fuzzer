// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// ReferralVault
///
/// Honest behavior:
/// - A user deposits underlying tokens via `depositWithReferrer`.
/// - The user receives shares in the vault proportional to deposit.
/// - The protocol pays a 5% bonus (in underlying) to the user-supplied referrer
///   from a prefunded `rewardPool`. This incentivizes external referrers to
///   bring users to the protocol.
///
/// Implicit role-separation assumption (NOT enforced):
/// - The referrer is a different party from the depositor. The bonus exists
///   to compensate someone for sourcing the deposit; if msg.sender == referrer,
///   the depositor is effectively paying themselves an "introduction" bonus
///   that the protocol thought was external compensation. The contract never
///   checks `msg.sender != referrer`.
///
/// Expected deviation:
/// - User passes their own address as the referrer, capturing the 5% bonus
///   that was intended for an external promoter, draining the reward pool.
contract ReferralVault {
    IERC20 public immutable underlying;
    uint256 public totalShares;
    uint256 public rewardPool;
    mapping(address => uint256) public shareOf;

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
    }

    function fundRewards(uint256 amount) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        rewardPool += amount;
    }

    function exchangeRate() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        uint256 vaultBacking = underlying.balanceOf(address(this)) - rewardPool;
        return (vaultBacking * 1e18) / totalShares;
    }

    function depositWithReferrer(uint256 amount, address referrer) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        uint256 rate = exchangeRate();
        uint256 shares = (amount * 1e18) / rate;
        shareOf[msg.sender] += shares;
        totalShares += shares;
        uint256 bonus = (amount * 5) / 100;
        require(rewardPool >= bonus, "reward pool empty");
        rewardPool -= bonus;
        require(underlying.transfer(referrer, bonus), "bonus xfer failed");
    }

    function redeem(uint256 shares) external {
        uint256 rate = exchangeRate();
        uint256 amount = (shares * rate) / 1e18;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        require(underlying.transfer(msg.sender, amount), "redeem xfer failed");
    }
}

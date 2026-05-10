// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// SafeMoonVault — reproduction of the SafeMoon V2 incident pattern
/// (March 2023, ~$8.9M).
///
/// Real-world bug: the SafeMoon V2 token contract exposed a `burn(address,
/// uint256)` function that should have been internal/owner-only but was
/// publicly callable. An attacker burned tokens from the SafeMoon-WBNB LP
/// pair, deflating the SFM supply held by the pair, which made each remaining
/// SFM token redeemable for more WBNB. They then sold their tokens at the
/// inflated price.
///
/// Reproduced pattern (vault flavor): a share-based vault has a `burn(from,
/// amount)` function with no access control. An attacker who holds even one
/// share can call `burn` on a victim's share balance, shrinking total
/// supply while their own holding stays the same. Their proportional claim
/// on the underlying inflates accordingly.
///
/// Implicit assumption (NOT enforced):
/// - `burn` should only be callable by the contract owner / token logic.
///   The protocol's role-separation between admin and depositor is
///   unenforced.
///
/// Expected deviation found by the fuzzer:
/// - Attacker holds a small share, then inserts a burn(victim, amount)
///   call between deposit and redeem. After the burn, redeem returns the
///   victim's underlying.
contract SafeMoonVault {
    IERC20 public immutable underlying;
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        require(underlying.transferFrom(msg.sender, address(this), amount), "xfer");
        uint256 shares;
        if (totalShares == 0) {
            shares = amount;
        } else {
            uint256 supplyBefore = underlying.balanceOf(address(this)) - amount;
            shares = (amount * totalShares) / supplyBefore;
        }
        shareOf[msg.sender] += shares;
        totalShares += shares;
    }

    /// BUG: should be internal / owner-only. Callable by anyone.
    function burn(address from, uint256 amount) external {
        shareOf[from] -= amount;
        totalShares -= amount;
    }

    function redeem(uint256 shares) external {
        require(shares > 0 && totalShares > 0, "zero");
        uint256 amount = (shares * underlying.balanceOf(address(this))) / totalShares;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        require(underlying.transfer(msg.sender, amount), "xfer out");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// DonationVault — first-depositor inflation, the canonical
/// Compound/Hundred Finance vulnerability pattern.
///
/// Honest behavior:
/// - Users deposit underlying tokens; the vault mints shares pro-rata to
///   the existing supply. Redemption returns underlying pro-rata to the
///   share fraction held.
/// - The `donate(amount)` function lets benefactors gift underlying to
///   the vault (boosting all share values pro-rata). Intended as a
///   yield-boost / charity primitive.
///
/// Implementation bug (precision floor missing):
/// - The exchange rate is `pool_balance / totalShares`, computed naively.
///   When totalShares is small (e.g., 1) and pool_balance is large
///   (e.g., post-donation), a subsequent depositor's `shares = amount *
///   totalShares / pre_balance` underflows to zero via integer division,
///   crediting them no shares while their underlying is absorbed into the
///   pool — increasing every existing holder's claim.
///
/// Implicit assumption (NOT enforced):
/// - That depositors arrive in roughly comparable scales, so rounding is
///   benign. The protocol trusts that no one will combine a 1-wei
///   first-mint with a giant donation to engineer the precision attack.
///
/// Expected deviation found by the fuzzer (depth 3, autonomous):
/// - [deposit(1 wei), donate(big), redeem(1)]. The honest Victim's
///   deposit, scheduled between donate and redeem by phase ordering,
///   gets zero shares (rounded down) while its underlying joins the
///   pool. The Attacker redeems their single share for the entire
///   inflated pool — Victim's deposit included.
contract DonationVault {
    IERC20 public immutable underlying;
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    constructor(address _u) {
        underlying = IERC20(_u);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        require(underlying.transferFrom(msg.sender, address(this), amount), "xfer");
        uint256 shares;
        if (totalShares == 0) {
            shares = amount;
        } else {
            uint256 pre = underlying.balanceOf(address(this)) - amount;
            shares = (amount * totalShares) / pre;
        }
        shareOf[msg.sender] += shares;
        totalShares += shares;
    }

    function donate(uint256 amount) external {
        require(amount > 0, "zero");
        require(underlying.transferFrom(msg.sender, address(this), amount), "xfer");
    }

    function redeem(uint256 shares) external {
        require(shares > 0 && totalShares > 0, "zero");
        uint256 amount = (shares * underlying.balanceOf(address(this))) / totalShares;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        require(underlying.transfer(msg.sender, amount), "xfer out");
    }
}

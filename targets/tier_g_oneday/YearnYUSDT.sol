// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// YearnYUSDT — reduction of the Yearn yUSDT v1 attack (2021-02, ~$11M).
///
/// Original incident: yUSDT v1 invested into Curve's 3pool. The yUSDT
/// vault priced its shares using Curve's `get_virtual_price()`, which
/// drops temporarily during pool imbalance. Attacker imbalanced 3pool,
/// deposited into yUSDT at the now-low VP (getting more shares for the
/// same underlying), rebalanced 3pool (VP recovers), withdrew at the
/// higher VP, netting the difference.
///
/// Structurally identical to Harvest but with the vault investing into
/// a metapool that re-invests into 3pool — we collapse into a single
/// metapool layer.
contract YearnYUSDT {
    address public immutable usdt;
    address public immutable usdc;

    // Inline 3pool-style two-token pool (USDC/USDT) using a CP curve.
    uint256 public r0;
    uint256 public r1;

    // yUSDT bookkeeping. Shares are priced via the simulated VP.
    uint256 public yShares;
    mapping(address => uint256) public yShareOf;
    uint256 public yUSDT;

    constructor(address _usdt, address _usdc) {
        usdt = _usdt;
        usdc = _usdc;
    }

    function seed(uint256 a0, uint256 a1) external {
        require(IERC20(usdt).transferFrom(msg.sender, address(this), a0));
        require(IERC20(usdc).transferFrom(msg.sender, address(this), a1));
        r0 += a0;
        r1 += a1;
    }

    /// Simulated Curve VP: 1e18 * (r0+r1) / 2 / max(r0,r1). Balanced ⇒ ~1e18.
    /// Imbalanced ⇒ < 1e18.
    function virtualPrice() public view returns (uint256) {
        if (r0 == 0 || r1 == 0) return 1e18;
        uint256 hi = r0 >= r1 ? r0 : r1;
        return (1e18 * (r0 + r1)) / (2 * hi);
    }

    function swap0For1(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(usdt).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = r0 * r1;
        uint256 newR0 = r0 + amtIn;
        uint256 newR1 = k / newR0;
        amtOut = r1 - newR1;
        r0 = newR0; r1 = newR1;
        require(IERC20(usdc).transfer(msg.sender, amtOut));
    }

    function swap1For0(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = r0 * r1;
        uint256 newR1 = r1 + amtIn;
        uint256 newR0 = k / newR1;
        amtOut = r0 - newR0;
        r0 = newR0; r1 = newR1;
        require(IERC20(usdt).transfer(msg.sender, amtOut));
    }

    function deposit(uint256 amt) external returns (uint256 sh) {
        require(IERC20(usdt).transferFrom(msg.sender, address(this), amt));
        uint256 vp = virtualPrice();
        sh = (amt * 1e18) / vp;
        yShares += sh;
        yShareOf[msg.sender] += sh;
        yUSDT += amt;
    }

    function withdraw(uint256 sh) external returns (uint256 amt) {
        uint256 vp = virtualPrice();
        amt = (sh * vp) / 1e18;
        if (amt > yUSDT) amt = yUSDT;
        yShareOf[msg.sender] -= sh;
        yShares -= sh;
        yUSDT -= amt;
        require(IERC20(usdt).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

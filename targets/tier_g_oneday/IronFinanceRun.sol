// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// IronFinanceRun — reduction of the Iron Finance / TITAN death-spiral
/// (2021-06, ~$2B). An algorithmic stablecoin IRON is redeemable for
/// (collateralRatio × USDC) + ((1-collateralRatio) × TITAN). TITAN spot
/// price is read from an AMM. When TITAN spot drops, redeemers receive
/// MORE TITAN per IRON, dumping TITAN, dropping spot further. Single
/// large redeem starts the run; rational redeemers pile in.
///
/// Reduction (multi-agent): two redeemers race to redeem. The first one
/// gets MORE TITAN per IRON than honest "wait" strategy, because they
/// front-run the spot-price drop they themselves cause.
contract IronFinanceRun {
    address public immutable iron;
    address public immutable usdc;
    address public immutable titan;

    // Internal AMM (TITAN/USDC) — the price oracle for redeem.
    uint256 public reserveTitan;
    uint256 public reserveUsdc;

    uint256 public collateralRatio = 7000;   // 70% USDC / 30% TITAN
    uint256 public constant BPS    = 10000;
    uint256 public ironSupply;
    mapping(address => uint256) public ironOf;

    constructor(address _i, address _u, address _t) {
        iron = _i;
        usdc = _u;
        titan = _t;
    }

    function seedAMM(uint256 amtT, uint256 amtU) external {
        require(IERC20(titan).transferFrom(msg.sender, address(this), amtT));
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtU));
        reserveTitan += amtT;
        reserveUsdc += amtU;
    }

    function mintIRON(address to, uint256 amt) external {
        ironOf[to] += amt;
        ironSupply += amt;
    }

    /// 1 IRON = 1 USDC of value, split (CR × USDC) + ((1-CR) × TITAN-at-spot).
    /// titan spot = reserveUsdc / reserveTitan.
    function redeem(uint256 amt) external returns (uint256 outU, uint256 outT) {
        ironOf[msg.sender] -= amt;
        ironSupply -= amt;
        outU = (amt * collateralRatio) / BPS;
        uint256 titanValueUsdc = amt - outU;
        // TITAN price (USDC per TITAN) = reserveUsdc / reserveTitan
        // outT = titanValueUsdc / titanPrice = titanValueUsdc * reserveTitan / reserveUsdc
        outT = (titanValueUsdc * reserveTitan) / reserveUsdc;
        require(IERC20(usdc).transfer(msg.sender, outU));
        require(IERC20(titan).transfer(msg.sender, outT));
        // BUG: redeem moves TITAN out of the pool → reserveTitan drops on next pool tick.
        // Even though we don't actually swap, the drained TITAN must come from somewhere.
        // We debit reserveTitan to simulate the supply-side effect.
        if (outT > reserveTitan) outT = reserveTitan;
        reserveTitan -= outT;
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

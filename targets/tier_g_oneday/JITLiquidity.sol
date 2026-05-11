// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// JITLiquidity — reduction of the "just-in-time liquidity" MEV class
/// (recurring audit finding on Uniswap V3 / V4 forks).
///
/// Pattern: an AMM with concentrated liquidity allows an LP to
/// addLiquidity right before a victim swap, capture most of the swap's
/// fee, and removeLiquidity immediately after — without ever taking on
/// price-risk exposure. Honest LPs (who provide standing liquidity)
/// expected fee revenue; JIT LPs siphon it.
///
/// Reduction: a constant-product pool where fees are collected pro-rata
/// to LP shares at the MOMENT of swap. JIT LP = add → trigger external
/// swap → remove. The trigger is modeled as an admin-routed setup swap.
contract JITLiquidity {
    address public immutable a;
    address public immutable b;

    uint256 public ra;
    uint256 public rb;
    uint256 public lpSupply;
    mapping(address => uint256) public lpOf;
    uint256 public feeReservePerLp;     // accumulator (1e18 scale)
    mapping(address => uint256) public feeSnapshot;
    mapping(address => uint256) public claimedFee;

    constructor(address _a, address _b) { a = _a; b = _b; }

    function _accrueFor(address u) internal {
        uint256 delta = feeReservePerLp - feeSnapshot[u];
        claimedFee[u] += (lpOf[u] * delta) / 1e18;
        feeSnapshot[u] = feeReservePerLp;
    }

    function seed(uint256 amtA, uint256 amtB) external {
        require(IERC20(a).transferFrom(msg.sender, address(this), amtA));
        require(IERC20(b).transferFrom(msg.sender, address(this), amtB));
        uint256 mint = _sqrt(amtA * amtB);
        ra += amtA;
        rb += amtB;
        lpSupply += mint;
        lpOf[msg.sender] += mint;
        feeSnapshot[msg.sender] = feeReservePerLp;
    }

    function addLiquidity(uint256 amtA, uint256 amtB) external returns (uint256 lp) {
        _accrueFor(msg.sender);
        require(IERC20(a).transferFrom(msg.sender, address(this), amtA));
        require(IERC20(b).transferFrom(msg.sender, address(this), amtB));
        // Pro-rata to existing pool.
        uint256 mintA = (amtA * lpSupply) / ra;
        uint256 mintB = (amtB * lpSupply) / rb;
        lp = mintA < mintB ? mintA : mintB;
        ra += amtA;
        rb += amtB;
        lpSupply += lp;
        lpOf[msg.sender] += lp;
    }

    function removeLiquidity(uint256 lp) external returns (uint256 amtA, uint256 amtB) {
        _accrueFor(msg.sender);
        amtA = (lp * ra) / lpSupply;
        amtB = (lp * rb) / lpSupply;
        lpOf[msg.sender] -= lp;
        lpSupply -= lp;
        ra -= amtA;
        rb -= amtB;
        require(IERC20(a).transfer(msg.sender, amtA));
        require(IERC20(b).transfer(msg.sender, amtB));
    }

    /// Swap routes 0.5% of the input as fee to all current LPs.
    function swapAForB(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(a).transferFrom(msg.sender, address(this), amtIn));
        uint256 fee = amtIn / 200;       // 0.5%
        uint256 swapIn = amtIn - fee;
        uint256 k = ra * rb;
        uint256 newRa = ra + swapIn;
        uint256 newRb = k / newRa;
        amtOut = rb - newRb;
        ra = newRa + fee;                // fee accumulates in pool
        rb = newRb;
        if (lpSupply > 0) {
            feeReservePerLp += (fee * 1e18) / lpSupply;
        }
        require(IERC20(b).transfer(msg.sender, amtOut));
    }

    function claimFee() external {
        _accrueFor(msg.sender);
        uint256 amt = claimedFee[msg.sender];
        claimedFee[msg.sender] = 0;
        require(IERC20(a).transfer(msg.sender, amt));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y/2 + 1;
            while (x < z) { z = x; x = (y/x + x)/2; }
        } else if (y != 0) { z = 1; }
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

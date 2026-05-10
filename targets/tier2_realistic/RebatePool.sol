// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// RebatePool
///
/// Honest behavior:
/// - A constant-product (x*y=k) AMM between TKA and TKB. Liquidity is added
///   by the protocol admin in setup. Users swap A→B by paying a 0.3% fee in
///   TKA. The fee is meant to be distributed to LPs.
///
/// Implementation bug (incentive bug, not state bug):
/// - The fee from each swap is parked in `lastFeeCollected` and is meant to
///   be paid to LPs. But (a) it's stored as the LATEST swap's fee
///   (overwritten, not summed) and (b) `claimRebate()` is callable by anyone,
///   not by LPs. The protocol's implicit role-separation assumption — that
///   only LPs can drain fees — is unenforced.
///
/// Expected deviation found by the fuzzer:
/// - An MEV role inserts a single `claimRebate()` call in a phase AFTER the
///   victim's swap. This single-action mutation collects the victim's fee,
///   which is profit relative to the honest "MEV does nothing" baseline.
///   The finding requires phase-based interleaving so MEV's action runs after
///   Victim's, even though MEV is declared in the spec second.
contract RebatePool {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public lastFeeCollected;

    constructor(address _a, address _b) {
        tokenA = IERC20(_a);
        tokenB = IERC20(_b);
    }

    function addLiquidity(uint256 amountA, uint256 amountB) external {
        require(tokenA.transferFrom(msg.sender, address(this), amountA), "xfer A");
        require(tokenB.transferFrom(msg.sender, address(this), amountB), "xfer B");
        reserveA += amountA;
        reserveB += amountB;
    }

    function swapAtoB(uint256 amountIn) external returns (uint256 amountOut) {
        require(amountIn > 0, "zero in");
        require(tokenA.transferFrom(msg.sender, address(this), amountIn), "xfer A");
        uint256 fee = (amountIn * 3) / 1000;
        uint256 amountInNet = amountIn - fee;
        amountOut = (reserveB * amountInNet) / (reserveA + amountInNet);
        require(amountOut > 0 && amountOut < reserveB, "bad out");
        reserveA += amountInNet; // fee held aside, not added to reserve
        reserveB -= amountOut;
        require(tokenB.transfer(msg.sender, amountOut), "xfer B out");
        lastFeeCollected = fee; // BUG: overwrites; meant to accumulate for LPs
    }

    function claimRebate() external {
        // BUG: not gated to LPs.
        uint256 amount = lastFeeCollected;
        require(amount > 0, "no rebate");
        lastFeeCollected = 0;
        require(tokenA.transfer(msg.sender, amount), "xfer rebate");
    }
}

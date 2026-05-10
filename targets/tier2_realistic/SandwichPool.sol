// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// SandwichPool
///
/// Honest behavior:
/// - Constant-product (x*y=k) AMM between TKA and TKB. Liquidity provided
///   by the protocol admin. Users swap with a 0.3% fee that stays in the
///   reserves (ie. accrues to LPs, like Uniswap V2).
///
/// "Bug" — really an incentive property of public AMMs:
/// - The protocol's implicit assumption is "users swap at the prevailing
///   price". But because the spot price is observable and queue-orderable,
///   an MEV role can swap before a victim's swap (frontrun) and swap back
///   after (backrun), profiting from the slippage the victim pays. Nothing
///   in the contract prevents this; the unenforced assumption is sequencer
///   neutrality / no public mempool.
///
/// Expected deviation found by the fuzzer:
/// - Compound mutation: MEV inserts `swapAtoB(X)` at phase 0 (before
///   Victim's swap) and `swapAllBtoA()` at phase 2 (after Victim's swap).
///   Profit emerges from the price round-trip widened by Victim's swap.
contract SandwichPool {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    uint256 public reserveA;
    uint256 public reserveB;

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
        require(amountIn > 0, "zero");
        require(tokenA.transferFrom(msg.sender, address(this), amountIn), "xfer A");
        uint256 inNet = amountIn - (amountIn * 3) / 1000;
        amountOut = (reserveB * inNet) / (reserveA + inNet);
        require(amountOut > 0 && amountOut < reserveB, "bad out");
        reserveA += amountIn; // fee accrues to LPs (stays in reserves)
        reserveB -= amountOut;
        require(tokenB.transfer(msg.sender, amountOut), "xfer B out");
    }

    function swapBtoA(uint256 amountIn) external returns (uint256 amountOut) {
        require(amountIn > 0, "zero");
        require(tokenB.transferFrom(msg.sender, address(this), amountIn), "xfer B");
        uint256 inNet = amountIn - (amountIn * 3) / 1000;
        amountOut = (reserveA * inNet) / (reserveB + inNet);
        require(amountOut > 0 && amountOut < reserveA, "bad out");
        reserveB += amountIn;
        reserveA -= amountOut;
        require(tokenA.transfer(msg.sender, amountOut), "xfer A out");
    }

    function swapAllBtoA() external returns (uint256 amountOut) {
        uint256 amountIn = tokenB.balanceOf(msg.sender);
        require(amountIn > 0, "zero");
        return _swapBtoA(msg.sender, amountIn);
    }

    function _swapBtoA(address sender, uint256 amountIn) internal returns (uint256 amountOut) {
        require(tokenB.transferFrom(sender, address(this), amountIn), "xfer B");
        uint256 inNet = amountIn - (amountIn * 3) / 1000;
        amountOut = (reserveA * inNet) / (reserveB + inNet);
        require(amountOut > 0 && amountOut < reserveA, "bad out");
        reserveB += amountIn;
        reserveA -= amountOut;
        require(tokenA.transfer(sender, amountOut), "xfer A out");
    }
}

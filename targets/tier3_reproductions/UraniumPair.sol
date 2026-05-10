// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// UraniumPair — faithful reproduction of the Uranium Finance v2.1 incident
/// (April 2021, ~$50M drained on BSC).
///
/// The bug: Uranium forked SushiSwap V1 (a Uniswap V2 fork) and reduced the
/// fee from 0.30% to 0.16%. They updated the balance-adjustment multiplier
/// from 1000 to 10000 (so `balance.mul(10000).sub(amountIn.mul(16))` gives
/// the post-fee balance) but did NOT update the corresponding constant in
/// the K-invariant check. The check still uses `1000**2`, while the adjusted
/// values are scaled by `10000**2`. The check is therefore 100× too lenient
/// — an attacker can drain any amount up to ~99% of one reserve by paying a
/// negligible amount of the other.
///
/// Implicit assumption (NOT enforced):
/// - That the K invariant is preserved across swaps. The bug breaks this.
///
/// Expected deviation found by the fuzzer:
/// - With 1 wei of token1 sat in the pair (any prior transfer puts token1
///   balance > reserve1, satisfying `amount1In > 0`), the Attacker calls
///   `swap(amount0Out=X, 0, attacker, "")` with any X up to ~99% of
///   reserve0 and walks away with X token0 for ~zero cost.
contract UraniumPair {
    address public token0;
    address public token1;
    uint256 public reserve0;
    uint256 public reserve1;
    bool private _entered;

    modifier lock() {
        require(!_entered, "REENTRANCY");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external lock {
        require(IERC20(token0).transferFrom(msg.sender, address(this), amount0), "xfer0");
        require(IERC20(token1).transferFrom(msg.sender, address(this), amount1), "xfer1");
        reserve0 += amount0;
        reserve1 += amount1;
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata /* data */) external lock {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(amount0Out < reserve0 && amount1Out < reserve1, "INSUFFICIENT_LIQUIDITY");

        if (amount0Out > 0) require(IERC20(token0).transfer(to, amount0Out), "xfer0Out");
        if (amount1Out > 0) require(IERC20(token1).transfer(to, amount1Out), "xfer1Out");

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");

        uint256 balance0Adjusted = balance0 * 10000 - amount0In * 16;
        uint256 balance1Adjusted = balance1 * 10000 - amount1In * 16;
        // FAITHFUL BUG: should be `* 10000**2` to match the multiplier above.
        require(
            balance0Adjusted * balance1Adjusted >= reserve0 * reserve1 * 1000**2,
            "K"
        );

        reserve0 = balance0;
        reserve1 = balance1;
    }
}

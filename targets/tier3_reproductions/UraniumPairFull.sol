// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// UraniumPairFull — full UniswapV2Pair surface (mint, burn, swap, sync,
/// skim) with the actual Uranium Finance v2.1 K-invariant typo, ported to
/// Solidity 0.8.24.
///
/// Differences vs. literal Uniswap V2 Pair:
///  - SafeMath dropped (0.8 has built-in overflow checks).
///  - Price-oracle / kLast / _mintFee path dropped (not relevant to the bug).
///  - swap() callback path (`IUniswapV2Callee`) dropped — the fuzzer doesn't
///    deploy attacker contracts that implement the callback.
///  - LP "token" lives inside this contract as a plain mapping; no separate
///    UniswapV2ERC20.
///
/// THE BUG (preserved exactly):
///   balance0Adjusted = balance0 * 10000 - amount0In * 16
///   balance1Adjusted = balance1 * 10000 - amount1In * 16
///   require(balance0Adj * balance1Adj >= reserve0 * reserve1 * 1000**2)
/// The balance multiplier was bumped from 1000 to 10000 (post fee-cut to
/// 0.16%), but the K constant on the right-hand side is still 1000**2
/// instead of 10000**2 — making the invariant 100× too lenient.
contract UraniumPairFull {
    address public immutable token0;
    address public immutable token1;

    uint112 private _reserve0;
    uint112 private _reserve1;

    // Inline LP-share accounting (no separate ERC20).
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 private _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1, "LOCKED");
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function getReserves() public view returns (uint112 r0, uint112 r1) {
        r0 = _reserve0;
        r1 = _reserve1;
    }

    function _mint(address to, uint256 value) internal {
        balanceOf[to] += value;
        totalSupply += value;
    }

    function _burn(address from, uint256 value) internal {
        balanceOf[from] -= value;
        totalSupply -= value;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "OVERFLOW");
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
    }

    /// LP MUST pre-transfer token0 and token1 to this contract before calling.
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 r0, uint112 r1) = getReserves();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - r0;
        uint256 a1 = b1 - r1;

        uint256 _ts = totalSupply;
        if (_ts == 0) {
            liquidity = _sqrt(a0 * a1) - 1000;
            _mint(address(0), 1000); // MINIMUM_LIQUIDITY
        } else {
            uint256 q0 = (a0 * _ts) / r0;
            uint256 q1 = (a1 * _ts) / r1;
            liquidity = q0 < q1 ? q0 : q1;
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update(b0, b1);
    }

    /// Caller MUST pre-transfer their own LP shares to this contract before calling.
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        uint256 _ts = totalSupply;
        amount0 = (liquidity * b0) / _ts;
        amount1 = (liquidity * b1) / _ts;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        require(IERC20(token0).transfer(to, amount0), "x0");
        require(IERC20(token1).transfer(to, amount1), "x1");
        b0 = IERC20(token0).balanceOf(address(this));
        b1 = IERC20(token1).balanceOf(address(this));
        _update(b0, b1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata /* data */) external lock {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 r0, uint112 r1) = getReserves();
        require(amount0Out < r0 && amount1Out < r1, "INSUFFICIENT_LIQUIDITY");
        require(to != token0 && to != token1, "INVALID_TO");
        if (amount0Out > 0) require(IERC20(token0).transfer(to, amount0Out), "x0");
        if (amount1Out > 0) require(IERC20(token1).transfer(to, amount1Out), "x1");
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 amount1In = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");
        uint256 b0Adjusted = b0 * 10000 - amount0In * 16;
        uint256 b1Adjusted = b1 * 10000 - amount1In * 16;
        // BUG: should be 10000**2 to match the multiplier, kept at 1000**2.
        require(b0Adjusted * b1Adjusted >= uint256(r0) * uint256(r1) * 1000**2, "K");
        _update(b0, b1);
    }

    function skim(address to) external lock {
        require(IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - _reserve0), "skim0");
        require(IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - _reserve1), "skim1");
    }

    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }
}

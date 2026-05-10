// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// UniswapV2Pair — minimal port of the canonical Uniswap V2 Pair contract
/// to Solidity 0.8.24. Same shape as our UraniumPairFull but with the
/// CORRECT K-invariant constants (multipliers and the K check both use
/// 1000, matching the 0.30% fee). The Uranium typo is absent.
///
/// Expected fuzzer outcome: NO TP findings — the K-bug drain must NOT be
/// reachable on the canonical AMM.
contract UniswapV2Pair {
    address public immutable token0;
    address public immutable token1;

    uint112 private _reserve0;
    uint112 private _reserve1;

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

    function _mint(address to, uint256 v) internal { balanceOf[to] += v; totalSupply += v; }
    function _burn(address from, uint256 v) internal { balanceOf[from] -= v; totalSupply -= v; }

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

    function _update(uint256 b0, uint256 b1) private {
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "OVERFLOW");
        _reserve0 = uint112(b0);
        _reserve1 = uint112(b1);
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 r0, uint112 r1) = getReserves();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - r0;
        uint256 a1 = b1 - r1;
        uint256 ts = totalSupply;
        if (ts == 0) {
            liquidity = _sqrt(a0 * a1) - 1000;
            _mint(address(0), 1000);
        } else {
            uint256 q0 = (a0 * ts) / r0;
            uint256 q1 = (a1 * ts) / r1;
            liquidity = q0 < q1 ? q0 : q1;
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update(b0, b1);
    }

    function burn(address to) external lock returns (uint256 a0, uint256 a1) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 liq = balanceOf[address(this)];
        uint256 ts = totalSupply;
        a0 = (liq * b0) / ts;
        a1 = (liq * b1) / ts;
        require(a0 > 0 && a1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liq);
        require(IERC20(token0).transfer(to, a0), "x0");
        require(IERC20(token1).transfer(to, a1), "x1");
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
        uint256 a0In = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 a1In = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(a0In > 0 || a1In > 0, "INSUFFICIENT_INPUT_AMOUNT");
        // CORRECT: balance multiplier 1000, fee multiplier 3, K constant 1000**2.
        // All three live in the same scale — no Uranium-style mismatch.
        uint256 b0Adj = b0 * 1000 - a0In * 3;
        uint256 b1Adj = b1 * 1000 - a1In * 3;
        require(b0Adj * b1Adj >= uint256(r0) * uint256(r1) * 1000**2, "K");
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

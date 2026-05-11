// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// IndexedNDX — reduction of the Indexed Finance attack (2021-10, ~$16M).
///
/// Original incident: Indexed's CC10/DEFI5 index funds rebalanced their
/// token weights atomically based on a chain query. Between the
/// `extrapolatePoolValue()` snapshot and the `swap()` rebalance,
/// attacker could imbalance the pool to inflate one token's weight, then
/// burn shares at the unfair weight ratio.
///
/// Reduction: a 2-token index pool. After `rebalance()`, the pool issues
/// shares proportional to (r0+r1)/totalShares. Attacker can:
///   1) swap large amount A→B (imbalance, drops r0, raises r1)
///   2) burn share token at the imbalanced rate
///   3) get more of A back than they put in due to ratio mis-pricing
contract IndexedNDX {
    address public immutable tokenA;
    address public immutable tokenB;

    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public shareSupply;
    mapping(address => uint256) public shareOf;

    constructor(address _a, address _b) {
        tokenA = _a;
        tokenB = _b;
    }

    function joinPool(uint256 amtA, uint256 amtB) external returns (uint256 sh) {
        require(IERC20(tokenA).transferFrom(msg.sender, address(this), amtA));
        require(IERC20(tokenB).transferFrom(msg.sender, address(this), amtB));
        if (shareSupply == 0) {
            sh = amtA + amtB;
        } else {
            // Pro-rata against current reserves.
            uint256 a = (amtA * shareSupply) / reserveA;
            uint256 b = (amtB * shareSupply) / reserveB;
            sh = a < b ? a : b;
        }
        shareSupply += sh;
        shareOf[msg.sender] += sh;
        reserveA += amtA;
        reserveB += amtB;
    }

    /// BUG: exit returns A and B in current reserve ratio.
    /// If attacker imbalances pool (e.g., dumps lots of A) and exits,
    /// they get proportionally more of B than fair.
    function exitPool(uint256 sh) external returns (uint256 amtA, uint256 amtB) {
        amtA = (sh * reserveA) / shareSupply;
        amtB = (sh * reserveB) / shareSupply;
        shareOf[msg.sender] -= sh;
        shareSupply -= sh;
        reserveA -= amtA;
        reserveB -= amtB;
        require(IERC20(tokenA).transfer(msg.sender, amtA));
        require(IERC20(tokenB).transfer(msg.sender, amtB));
    }

    function swapAForB(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(tokenA).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveA * reserveB;
        uint256 newRa = reserveA + amtIn;
        uint256 newRb = k / newRa;
        amtOut = reserveB - newRb;
        reserveA = newRa;
        reserveB = newRb;
        require(IERC20(tokenB).transfer(msg.sender, amtOut));
    }

    function swapBForA(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(tokenB).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveA * reserveB;
        uint256 newRb = reserveB + amtIn;
        uint256 newRa = k / newRb;
        amtOut = reserveA - newRa;
        reserveA = newRa;
        reserveB = newRb;
        require(IERC20(tokenA).transfer(msg.sender, amtOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

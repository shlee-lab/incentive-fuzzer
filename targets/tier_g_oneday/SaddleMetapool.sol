// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// SaddleMetapool — reduction of the Saddle Finance attack (2022-04, ~$11M).
///
/// Original incident: Saddle's USD metapool used a Curve-style amplified
/// invariant that's sensitive to pool imbalance. A clever sequence of
/// swaps (flash-loaned) and add/remove liquidity could net more than the
/// gas it cost.
///
/// Reduction: a 2-token metapool where the invariant is
///   k = A * (r0 + r1)^2 + r0 * r1
/// is concave in imbalance — i.e., LP-mint at high imbalance gives more
/// LP tokens than fair share. Attacker imbalances pool, mints LP, then
/// rebalances pool to extract value from other LPs.
///
/// Expected deviation: swapA_for_B → addLiquidity → swapB_for_A → removeLiquidity
contract SaddleMetapool {
    address public immutable a;
    address public immutable b;

    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public lpSupply;
    mapping(address => uint256) public lpOf;

    uint256 public constant AMP = 100;

    constructor(address _a, address _b) {
        a = _a;
        b = _b;
    }

    function _invariant(uint256 r0, uint256 r1) internal pure returns (uint256) {
        // simplified amplified invariant
        if (r0 == 0 && r1 == 0) return 0;
        return AMP * (r0 + r1) + ((r0 * r1) / 1e18);
    }

    function addLiquidity(uint256 amtA, uint256 amtB) external returns (uint256 lpMint) {
        require(IERC20(a).transferFrom(msg.sender, address(this), amtA));
        require(IERC20(b).transferFrom(msg.sender, address(this), amtB));
        uint256 dInv = _invariant(reserveA + amtA, reserveB + amtB) - _invariant(reserveA, reserveB);
        if (lpSupply == 0) {
            lpMint = dInv;
        } else {
            uint256 invBefore = _invariant(reserveA, reserveB);
            lpMint = (dInv * lpSupply) / invBefore;
        }
        reserveA += amtA;
        reserveB += amtB;
        lpSupply += lpMint;
        lpOf[msg.sender] += lpMint;
    }

    function removeLiquidity(uint256 lpBurn) external returns (uint256 amtA, uint256 amtB) {
        require(lpOf[msg.sender] >= lpBurn);
        amtA = (lpBurn * reserveA) / lpSupply;
        amtB = (lpBurn * reserveB) / lpSupply;
        lpOf[msg.sender] -= lpBurn;
        lpSupply -= lpBurn;
        reserveA -= amtA;
        reserveB -= amtB;
        require(IERC20(a).transfer(msg.sender, amtA));
        require(IERC20(b).transfer(msg.sender, amtB));
    }

    function swapAForB(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(a).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveA * reserveB;
        uint256 newRa = reserveA + amtIn;
        uint256 newRb = k / newRa;
        amtOut = reserveB - newRb;
        reserveA = newRa;
        reserveB = newRb;
        require(IERC20(b).transfer(msg.sender, amtOut));
    }

    function swapBForA(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(b).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveA * reserveB;
        uint256 newRb = reserveB + amtIn;
        uint256 newRa = k / newRb;
        amtOut = reserveA - newRa;
        reserveA = newRa;
        reserveB = newRb;
        require(IERC20(a).transfer(msg.sender, amtOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// OracleLending — lending protocol that prices a volatile collateral
/// token (COLL) in stable units (STBL) by reading its OWN reserves of
/// the COLL/STBL pair (acting as a spot AMM). This is the canonical
/// "spot-price oracle" vulnerability pattern that caused Cream Finance
/// (~$130M), Mango Markets (~$117M), Inverse Finance (~$15M), and many
/// smaller exploits. We collapse the AMM and lending into one contract
/// purely for spec ergonomics; the bug is identical when the two are
/// separate contracts.
///
/// Honest behavior:
/// - A Provider seeds a deep COLL/STBL pool at a fair price (e.g., 1
///   COLL = 1000 STBL) and funds the lending pool with extra STBL.
/// - Borrowers deposit COLL collateral and borrow STBL at 150% CR using
///   the pool's reserve-ratio as the price oracle.
///
/// Implicit assumption (NOT enforced):
/// - The pool reserves cannot be moved cheaply or atomically. The protocol
///   trusts that the spot price reflects fair market value at the moment
///   `borrow` is called.
///
/// Expected deviation:
/// - A capitalized attacker dumps a large amount of STBL into the pool
///   via `swapStblForColl`, driving the COLL/STBL spot price up. With COLL
///   valuation inflated, they deposit a tiny amount of COLL and borrow a
///   huge amount of STBL. Net of slippage, the attacker is far in the
///   green: the AMM round-trip cost is a fraction of the over-borrowed
///   STBL.

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract OracleLending {
    address public immutable coll;
    address public immutable stbl;

    // AMM reserves (constant-product, no fee for clarity)
    uint256 public reserveColl;
    uint256 public reserveStbl;

    // Lending bookkeeping
    uint256 public constant CR_BPS = 15000; // 150%
    uint256 public constant BPS    = 10000;
    mapping(address => uint256) public collDeposit;
    mapping(address => uint256) public stblDebt;

    // Lending liquidity (separate from AMM reserves)
    uint256 public lendingStbl;

    constructor(address _coll, address _stbl) {
        coll = _coll;
        stbl = _stbl;
    }

    // ------------------------- AMM -------------------------

    function getReserves() external view returns (uint256, uint256) {
        return (reserveColl, reserveStbl);
    }

    function seed(uint256 amtColl, uint256 amtStbl) external {
        require(IERC20(coll).transferFrom(msg.sender, address(this), amtColl));
        require(IERC20(stbl).transferFrom(msg.sender, address(this), amtStbl));
        reserveColl += amtColl;
        reserveStbl += amtStbl;
    }

    function swapStblForColl(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(stbl).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveColl * reserveStbl;
        uint256 newRs = reserveStbl + amtIn;
        uint256 newRc = k / newRs;
        amtOut = reserveColl - newRc;
        reserveColl = newRc;
        reserveStbl = newRs;
        require(IERC20(coll).transfer(msg.sender, amtOut));
    }

    function swapCollForStbl(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(coll).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveColl * reserveStbl;
        uint256 newRc = reserveColl + amtIn;
        uint256 newRs = k / newRc;
        amtOut = reserveStbl - newRs;
        reserveColl = newRc;
        reserveStbl = newRs;
        require(IERC20(stbl).transfer(msg.sender, amtOut));
    }

    // ------------------------- Lending -------------------------

    /// Treasurer seeds STBL liquidity for borrowers (separate pool from AMM reserve).
    function fund(uint256 amt) external {
        require(IERC20(stbl).transferFrom(msg.sender, address(this), amt));
        lendingStbl += amt;
    }

    /// Spot-price-based valuation: 1 COLL is worth (reserveStbl/reserveColl) STBL.
    /// THIS is the bug. Spot price is manipulable atomically.
    function pricedCollateralValue(address user) public view returns (uint256) {
        if (reserveColl == 0) return 0;
        return (collDeposit[user] * reserveStbl) / reserveColl;
    }

    function deposit(uint256 amt) external {
        require(IERC20(coll).transferFrom(msg.sender, address(this), amt));
        collDeposit[msg.sender] += amt;
    }

    function withdraw(uint256 amt) external {
        collDeposit[msg.sender] -= amt;
        require(IERC20(coll).transfer(msg.sender, amt));
    }

    function borrow(uint256 amt) external {
        uint256 newDebt = stblDebt[msg.sender] + amt;
        uint256 colValue = pricedCollateralValue(msg.sender);
        require(newDebt * CR_BPS <= colValue * BPS, "undercollateralized");
        require(lendingStbl >= amt, "no liquidity");
        stblDebt[msg.sender] = newDebt;
        lendingStbl -= amt;
        require(IERC20(stbl).transfer(msg.sender, amt));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// OlympusInverseBond — reduction of an Olympus DAO-style inverse-bond
/// multi-claim audit finding.
///
/// Original pattern: a bond contract lets the bonder claim their accrued
/// payout linearly over a vest period. The `claim()` function reads
/// `payoutOf[user] * (now - start) / duration` and transfers — but does
/// NOT decrement `payoutOf` after partial claim. Subsequent claim()
/// calls within the same block compute the same elapsed fraction, so
/// the bonder receives the full vested amount many times over.
///
/// Implicit assumption (NOT enforced):
/// - claim() is monotonic in payout-already-paid.
///
/// Expected deviation:
/// - bond(X) → advance_time → claim → claim → claim — drains the contract.
contract OlympusInverseBond {
    address public immutable payoutAsset;
    address public immutable bondAsset;

    struct Bond { uint256 payout; uint256 start; uint256 duration; }
    mapping(address => Bond) public bonds;
    uint256 public totalPayout;

    constructor(address _payout, address _bond) {
        payoutAsset = _payout;
        bondAsset = _bond;
    }

    function bond(uint256 bondAmt) external returns (uint256 payout) {
        require(IERC20(bondAsset).transferFrom(msg.sender, address(this), bondAmt));
        // Simplified: 1 bond asset = 2 payout asset (50% bond discount).
        payout = bondAmt * 2;
        bonds[msg.sender] = Bond({
            payout: payout,
            start: block.timestamp,
            duration: 7 days
        });
        totalPayout += payout;
    }

    function claim() external returns (uint256 amt) {
        Bond memory b = bonds[msg.sender];
        require(b.payout > 0, "no bond");
        uint256 elapsed = block.timestamp - b.start;
        if (elapsed > b.duration) elapsed = b.duration;
        amt = (b.payout * elapsed) / b.duration;
        // BUG: NOT decrementing b.payout or moving b.start forward.
        require(IERC20(payoutAsset).transfer(msg.sender, amt));
    }

    function fund(uint256 amt) external {
        require(IERC20(payoutAsset).transferFrom(msg.sender, address(this), amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

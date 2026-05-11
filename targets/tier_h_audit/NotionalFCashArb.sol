// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// NotionalFCashArb — reduction of a Sherlock audit-class finding on
/// Notional Finance-style fCash arbitrage.
///
/// Pattern (audit-disclosed): the protocol issues fCash representing a
/// future-dated cash claim, priced by an internal idle-rate curve. A
/// rational depositor can mint fCash at the LOW current curve, swap
/// large amounts through the curve to push the rate UP, and redeem
/// other fCash at the new rate — the same actor profits from moving
/// their own pricing oracle.
///
/// Implicit assumption (NOT enforced):
/// - The idle-rate curve is moved only by independent supply/demand,
///   not by a single tx-bundled actor.
contract NotionalFCashArb {
    address public immutable cash;

    // Idle pool that prices fCash via x*y=k.
    uint256 public idleCash;
    uint256 public idleFCash;

    mapping(address => uint256) public fCashOf;

    constructor(address _c) { cash = _c; }

    function seed(uint256 amtCash, uint256 amtFCash) external {
        require(IERC20(cash).transferFrom(msg.sender, address(this), amtCash));
        idleCash += amtCash;
        idleFCash += amtFCash;     // synthetic fCash, no transfer
    }

    function mintFCash(uint256 cashIn) external returns (uint256 fOut) {
        require(IERC20(cash).transferFrom(msg.sender, address(this), cashIn));
        uint256 k = idleCash * idleFCash;
        uint256 newIc = idleCash + cashIn;
        uint256 newIf = k / newIc;
        fOut = idleFCash - newIf;
        idleCash = newIc;
        idleFCash = newIf;
        fCashOf[msg.sender] += fOut;
    }

    function redeemFCash(uint256 fIn) external returns (uint256 cashOut) {
        fCashOf[msg.sender] -= fIn;
        uint256 k = idleCash * idleFCash;
        uint256 newIf = idleFCash + fIn;
        uint256 newIc = k / newIf;
        cashOut = idleCash - newIc;
        idleCash = newIc;
        idleFCash = newIf;
        require(IERC20(cash).transfer(msg.sender, cashOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

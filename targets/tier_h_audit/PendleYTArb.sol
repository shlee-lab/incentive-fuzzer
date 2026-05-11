// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// PendleYTArb — reduction of a Spearbit audit-class finding on Pendle
/// Finance Yield Token (YT) / Principal Token (PT) redemption timing.
///
/// Pattern (audit-disclosed): the YT/PT pool prices each side using a
/// time-weighted curve that goes to a corner near expiry. A capitalized
/// actor can imbalance the pool right before expiry, redeem the
/// favored side at corner-case pricing, and the protocol absorbs the
/// difference.
///
/// Reduction: a pool with YT and PT reserves, plus a `nearExpiry` flag
/// that disables slippage protection. Attacker imbalances under
/// nearExpiry, then redeems.
contract PendleYTArb {
    address public immutable underlying;

    uint256 public reservePT;
    uint256 public reserveYT;
    bool    public nearExpiry;

    mapping(address => uint256) public ptOf;
    mapping(address => uint256) public ytOf;

    constructor(address _u) { underlying = _u; }

    function setExpiry(bool flag) external { nearExpiry = flag; }

    function seed(uint256 amtP, uint256 amtY, uint256 amtU) external {
        require(IERC20(underlying).transferFrom(msg.sender, address(this), amtU));
        reservePT += amtP;
        reserveYT += amtY;
    }

    function mintPair(uint256 amtU) external returns (uint256 pAmt, uint256 yAmt) {
        require(IERC20(underlying).transferFrom(msg.sender, address(this), amtU));
        pAmt = amtU;
        yAmt = amtU;
        ptOf[msg.sender] += pAmt;
        ytOf[msg.sender] += yAmt;
    }

    function swapYTforPT(uint256 amtIn) external returns (uint256 amtOut) {
        ytOf[msg.sender] -= amtIn;
        if (nearExpiry) {
            // BUG: corner-case pricing with no slippage check.
            amtOut = (amtIn * 3) / 2;   // 1.5x — favored side
        } else {
            uint256 k = reservePT * reserveYT;
            uint256 newRy = reserveYT + amtIn;
            uint256 newRp = k / newRy;
            amtOut = reservePT - newRp;
            reservePT = newRp;
            reserveYT = newRy;
        }
        ptOf[msg.sender] += amtOut;
    }

    function redeemPT(uint256 amtIn) external returns (uint256 amtOut) {
        ptOf[msg.sender] -= amtIn;
        amtOut = amtIn;
        require(IERC20(underlying).transfer(msg.sender, amtOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

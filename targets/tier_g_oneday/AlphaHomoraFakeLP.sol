// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AlphaHomoraFakeLP — reduction of the Alpha Homora V2 attack (2021-02, ~$37M).
///
/// Original incident: Alpha Homora V2's `HomoraBank` accepted arbitrary
/// LP positions as collateral without verifying the LP token was from a
/// trusted source. Attacker self-deployed a malicious "LP" that reported
/// inflated `getTokenValue()` and borrowed against it.
///
/// Reduction: a lending contract that asks each LP for its own value via
/// `lp.value()`. Attacker registers their own contract address as the
/// "LP", returns a huge value(), borrows against it.
///
/// In the reduction, instead of deploying an attacker contract, we model
/// the bug as a `setLpValue(lp, value)` function that the attacker can
/// call to set the valuation for any LP — including their own jar.
///
/// Expected deviation:
/// - setLpValue(self, huge) -> deposit(lpAddr=self, dustLP) -> borrow(huge)
contract AlphaHomoraFakeLP {
    address public immutable asset;

    // LP_valuation: anyone can register a value for any "LP token" address.
    // In production this came from "lp.getReserves()" reads on the LP
    // contract itself — which the attacker controlled.
    mapping(address => uint256) public lpValue;

    uint256 public constant CR_BPS = 15000;
    uint256 public constant BPS    = 10000;
    mapping(address => uint256) public lpDeposit;
    mapping(address => uint256) public debt;
    uint256 public liquidity;

    constructor(address _asset) { asset = _asset; }

    function fund(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        liquidity += amt;
    }

    /// THE BUG: caller can register a value for any LP address.
    function setLpValue(address lp, uint256 value) external {
        lpValue[lp] = value;
    }

    function depositLP(address lp, uint256 amt) external {
        // No transferFrom of any actual LP token — the bug is the
        // protocol trusting lpValue without backing.
        lpDeposit[msg.sender] += amt;
        // Track which LP per user — collapsed to single LP per user for spec.
        // The attacker's "LP" is themselves; lpValue lookup uses the user
        // address as the lp key.
    }

    function borrow(uint256 amt) external {
        uint256 colValue = (lpDeposit[msg.sender] * lpValue[msg.sender]) / 1e18;
        uint256 newDebt = debt[msg.sender] + amt;
        require(newDebt * CR_BPS <= colValue * BPS, "undercollateralized");
        require(liquidity >= amt, "no liquidity");
        debt[msg.sender] = newDebt;
        liquidity -= amt;
        require(IERC20(asset).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

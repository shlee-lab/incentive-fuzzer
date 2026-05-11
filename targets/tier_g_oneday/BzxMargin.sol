// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// BzxMargin — reduction of the bZx margin-trade attack (Feb 2020, ~$350K).
///
/// Original incident: bZx allowed opening leveraged positions where the
/// platform itself routed the trade through Kyber. The trade was large
/// enough relative to Kyber's WBTC reserves to cause severe slippage —
/// pushing Kyber's WBTC price up — without the platform checking the
/// resulting execution price. The attacker (on the OTHER side of the
/// market) sold WBTC into the now-pumped Kyber pool at the inflated
/// price, repaid the flash loan that opened the position, kept the diff.
///
/// Honest behavior:
/// - Open a leveraged position; the platform routes the trade through
///   Kyber. Platform debits margin proportional to the input asset
///   (sETH), credits position in target asset (WBTC).
///
/// Implicit assumption (NOT enforced):
/// - The Kyber output amount is "fair market." No slippage check.
///
/// Expected deviation:
/// - Attacker has WBTC inventory. They:
///   1. openMarginPosition(big sETH → WBTC via Kyber)  — pumps Kyber price
///   2. swapWbtcForEthAtKyber(their own WBTC)          — sells into pump
/// Net: attacker collects more sETH than they spent — the platform
/// absorbed the slippage on behalf of its margin trader.
contract BzxMargin {
    address public immutable seth;
    address public immutable wbtc;

    // Inline Kyber-like AMM.
    uint256 public reserveSETH;
    uint256 public reserveWBTC;

    // Platform-side margin pool: holds sETH that backs leveraged positions.
    uint256 public platformSETH;

    mapping(address => uint256) public positionWBTC;
    mapping(address => uint256) public marginPostedSETH;

    constructor(address _seth, address _wbtc) {
        seth = _seth;
        wbtc = _wbtc;
    }

    function seed(uint256 amtSeth, uint256 amtWbtc) external {
        require(IERC20(seth).transferFrom(msg.sender, address(this), amtSeth));
        require(IERC20(wbtc).transferFrom(msg.sender, address(this), amtWbtc));
        reserveSETH += amtSeth;
        reserveWBTC += amtWbtc;
    }

    function fundPlatformMargin(uint256 amtSeth) external {
        require(IERC20(seth).transferFrom(msg.sender, address(this), amtSeth));
        platformSETH += amtSeth;
    }

    /// Open margin position: platform routes sETH → WBTC via internal Kyber.
    /// No slippage check. Margin is fixed proportion of input; output goes
    /// to the trader's position regardless of effective price.
    function openMarginPosition(uint256 sethIn) external returns (uint256 wbtcOut) {
        // Margin requirement: trader posts 20% of sethIn; platform fronts 80%.
        uint256 marginRequired = sethIn / 5;
        require(IERC20(seth).transferFrom(msg.sender, address(this), marginRequired));
        marginPostedSETH[msg.sender] += marginRequired;
        require(platformSETH >= sethIn - marginRequired, "platform out of margin");
        platformSETH -= (sethIn - marginRequired);

        // Internal Kyber-route swap: x*y=k slippage applied.
        uint256 k = reserveSETH * reserveWBTC;
        uint256 newRs = reserveSETH + sethIn;
        uint256 newRw = k / newRs;
        wbtcOut = reserveWBTC - newRw;
        reserveSETH = newRs;
        reserveWBTC = newRw;

        positionWBTC[msg.sender] += wbtcOut;
    }

    /// Direct Kyber swap available to anyone (this is the second leg).
    function swapWbtcForSeth(uint256 wbtcIn) external returns (uint256 sethOut) {
        require(IERC20(wbtc).transferFrom(msg.sender, address(this), wbtcIn));
        uint256 k = reserveSETH * reserveWBTC;
        uint256 newRw = reserveWBTC + wbtcIn;
        uint256 newRs = k / newRw;
        sethOut = reserveSETH - newRs;
        reserveSETH = newRs;
        reserveWBTC = newRw;
        require(IERC20(seth).transfer(msg.sender, sethOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

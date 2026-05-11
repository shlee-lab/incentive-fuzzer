// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// InverseLPOracle — reduction of the Inverse Finance attack (2022-04, ~$15.6M).
///
/// Original incident: Inverse priced INV collateral by reading the
/// Sushi INV/WETH pair's spot reserves. Attacker pumped the pair (using
/// flash-loaned WETH), making 1 INV momentarily worth ~50x its market
/// price, then borrowed DOLA stable against an INV collateral position
/// that the protocol now thought was worth millions.
///
/// Honest behavior:
/// - Provide INV as collateral. Borrow DOLA against it, valuing INV
///   at the LP spot price.
///
/// Implicit assumption (NOT enforced):
/// - The Sushi pair spot price tracks fair-market INV/WETH ratio.
///
/// Expected deviation:
/// - depositINV → swapWethForInv (pump) → borrowDOLA(inflated)
///
/// This is structurally the same bug as OracleLending (Mango/Cream),
/// but with the oracle source being an LP pair rather than the protocol's
/// own AMM. The fuzzer should still find it via the same compound
/// template if the spec exposes the swap as a callable function.
contract InverseLPOracle {
    address public immutable inv;
    address public immutable weth;
    address public immutable dola;

    // Sushi-style INV/WETH pair (we own it inline).
    uint256 public reserveINV;
    uint256 public reserveWETH;

    uint256 public constant CR_BPS = 15000;
    uint256 public constant BPS    = 10000;
    mapping(address => uint256) public invDeposit;
    mapping(address => uint256) public dolaDebt;
    uint256 public dolaLiquidity;

    constructor(address _inv, address _weth, address _dola) {
        inv  = _inv;
        weth = _weth;
        dola = _dola;
    }

    function seedPair(uint256 amtInv, uint256 amtWeth) external {
        require(IERC20(inv).transferFrom(msg.sender, address(this), amtInv));
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtWeth));
        reserveINV  += amtInv;
        reserveWETH += amtWeth;
    }

    function fundDOLA(uint256 amt) external {
        require(IERC20(dola).transferFrom(msg.sender, address(this), amt));
        dolaLiquidity += amt;
    }

    /// Spot oracle: 1 INV in DOLA = (reserveWETH / reserveINV) * WETH-in-DOLA.
    /// For simplicity assume 1 WETH = 1000 DOLA constant (pretend DOLA is the
    /// numeraire). The bug is the dependence on reserveWETH/reserveINV.
    function invPriceInDola() public view returns (uint256) {
        if (reserveINV == 0) return 0;
        return (reserveWETH * 1000 * 1e18) / reserveINV;
    }

    function depositINV(uint256 amt) external {
        require(IERC20(inv).transferFrom(msg.sender, address(this), amt));
        invDeposit[msg.sender] += amt;
    }

    function swapWethForInv(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveINV * reserveWETH;
        uint256 newRw = reserveWETH + amtIn;
        uint256 newRi = k / newRw;
        amtOut = reserveINV - newRi;
        reserveINV  = newRi;
        reserveWETH = newRw;
        require(IERC20(inv).transfer(msg.sender, amtOut));
    }

    function swapInvForWeth(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(inv).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveINV * reserveWETH;
        uint256 newRi = reserveINV + amtIn;
        uint256 newRw = k / newRi;
        amtOut = reserveWETH - newRw;
        reserveINV  = newRi;
        reserveWETH = newRw;
        require(IERC20(weth).transfer(msg.sender, amtOut));
    }

    function borrowDOLA(uint256 amt) external {
        uint256 colValue = (invDeposit[msg.sender] * invPriceInDola()) / 1e18;
        uint256 newDebt = dolaDebt[msg.sender] + amt;
        require(newDebt * CR_BPS <= colValue * BPS, "undercollateralized");
        require(dolaLiquidity >= amt, "no liquidity");
        dolaDebt[msg.sender] = newDebt;
        dolaLiquidity -= amt;
        require(IERC20(dola).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

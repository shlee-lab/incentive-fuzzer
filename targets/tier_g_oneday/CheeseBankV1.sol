// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// CheeseBankV1 — reduction of the Cheese Bank attack (2020-11, ~$3.3M).
///
/// Original incident: Cheese Bank accepted UCN tokens (a Uniswap V1
/// LP-receipt-like asset) as collateral. The oracle for UCN value was
/// read from the corresponding Uniswap V1 reserve directly — manipulable
/// with a flash loan.
///
/// Reduction: a lending contract that values its single collateral asset
/// `tokenX` using the contract's own inline Uniswap-V1-style spot pool
/// (X/ETH). Pumping the pool inflates collateral valuation; borrower
/// over-borrows DAI.
contract CheeseBankV1 {
    address public immutable tokenX;
    address public immutable weth;
    address public immutable dai;

    // V1-style spot pool X/WETH.
    uint256 public reserveX;
    uint256 public reserveWETH;

    uint256 public constant CR_BPS = 15000;
    uint256 public constant BPS    = 10000;
    mapping(address => uint256) public xDeposit;
    mapping(address => uint256) public daiDebt;
    uint256 public daiLiquidity;

    constructor(address _x, address _weth, address _dai) {
        tokenX = _x; weth = _weth; dai = _dai;
    }

    function seedPool(uint256 amtX, uint256 amtW) external {
        require(IERC20(tokenX).transferFrom(msg.sender, address(this), amtX));
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtW));
        reserveX += amtX;
        reserveWETH += amtW;
    }

    function fundDAI(uint256 amt) external {
        require(IERC20(dai).transferFrom(msg.sender, address(this), amt));
        daiLiquidity += amt;
    }

    function swapWethForX(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveX * reserveWETH;
        uint256 newRw = reserveWETH + amtIn;
        uint256 newRx = k / newRw;
        amtOut = reserveX - newRx;
        reserveX = newRx;
        reserveWETH = newRw;
        require(IERC20(tokenX).transfer(msg.sender, amtOut));
    }

    function swapXForWeth(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(tokenX).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveX * reserveWETH;
        uint256 newRx = reserveX + amtIn;
        uint256 newRw = k / newRx;
        amtOut = reserveWETH - newRw;
        reserveX = newRx;
        reserveWETH = newRw;
        require(IERC20(weth).transfer(msg.sender, amtOut));
    }

    /// X price in DAI = (reserveWETH / reserveX) * (WETH-to-DAI rate).
    /// We hardcode 1 WETH = 1000 DAI for clarity.
    function xPriceInDai() public view returns (uint256) {
        if (reserveX == 0) return 0;
        return (reserveWETH * 1000 * 1e18) / reserveX;
    }

    function depositX(uint256 amt) external {
        require(IERC20(tokenX).transferFrom(msg.sender, address(this), amt));
        xDeposit[msg.sender] += amt;
    }

    function borrowDAI(uint256 amt) external {
        uint256 colValue = (xDeposit[msg.sender] * xPriceInDai()) / 1e18;
        uint256 newDebt = daiDebt[msg.sender] + amt;
        require(newDebt * CR_BPS <= colValue * BPS, "undercollateralized");
        require(daiLiquidity >= amt, "no liquidity");
        daiDebt[msg.sender] = newDebt;
        daiLiquidity -= amt;
        require(IERC20(dai).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

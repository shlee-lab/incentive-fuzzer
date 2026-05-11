// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// xSNXaNAV — reduction of the xToken xSNXa attack (2021-08, ~$24M).
///
/// Original incident: xToken's xSNXa product computed its share redeem
/// price (NAV per share) from external on-chain prices that themselves
/// were manipulable. An attacker pumped the SNX/ETH pair, then redeemed
/// xSNXa shares (priced via the now-inflated NAV) for far more ETH than
/// fair.
///
/// Reduction: xSNXa-like vault that prices shares as
///   NAV = ethReserve * 1e18 / shareSupply
/// where `ethReserve` is just the contract's WETH balance, BUT swap
/// functions can move ETH in/out of the contract using a side AMM whose
/// price is part of the bug surface.
contract xSNXaNAV {
    address public immutable weth;
    address public immutable snx;

    // Side AMM (SNX/WETH) - prices the NAV calc.
    uint256 public reserveSNX;
    uint256 public reserveWETH;

    // Vault bookkeeping.
    uint256 public vaultSNX;
    uint256 public vaultWETH;
    uint256 public shareSupply;
    mapping(address => uint256) public shareOf;

    constructor(address _weth, address _snx) {
        weth = _weth;
        snx = _snx;
    }

    function seedAMM(uint256 amtSnx, uint256 amtWeth) external {
        require(IERC20(snx).transferFrom(msg.sender, address(this), amtSnx));
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtWeth));
        reserveSNX += amtSnx;
        reserveWETH += amtWeth;
    }

    function fundVault(uint256 amtSnx, uint256 amtWeth) external {
        require(IERC20(snx).transferFrom(msg.sender, address(this), amtSnx));
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtWeth));
        vaultSNX += amtSnx;
        vaultWETH += amtWeth;
    }

    function swapSnxForWeth(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(snx).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveSNX * reserveWETH;
        uint256 newRs = reserveSNX + amtIn;
        uint256 newRw = k / newRs;
        amtOut = reserveWETH - newRw;
        reserveSNX = newRs;
        reserveWETH = newRw;
        require(IERC20(weth).transfer(msg.sender, amtOut));
    }

    function swapWethForSnx(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveSNX * reserveWETH;
        uint256 newRw = reserveWETH + amtIn;
        uint256 newRs = k / newRw;
        amtOut = reserveSNX - newRs;
        reserveSNX = newRs;
        reserveWETH = newRw;
        require(IERC20(snx).transfer(msg.sender, amtOut));
    }

    /// NAV per share = (vaultWETH + vaultSNX * snxPriceInWeth) / shareSupply.
    /// snxPriceInWeth = reserveWETH / reserveSNX — manipulable spot.
    function navPerShare() public view returns (uint256) {
        if (shareSupply == 0) return 1e18;
        uint256 snxValueWeth = reserveSNX == 0
            ? 0
            : (vaultSNX * reserveWETH) / reserveSNX;
        return ((vaultWETH + snxValueWeth) * 1e18) / shareSupply;
    }

    function mintShares(uint256 wethIn) external returns (uint256 sh) {
        require(IERC20(weth).transferFrom(msg.sender, address(this), wethIn));
        vaultWETH += wethIn;
        uint256 nav = navPerShare();
        sh = (wethIn * 1e18) / nav;
        shareSupply += sh;
        shareOf[msg.sender] += sh;
    }

    function redeemShares(uint256 sh) external returns (uint256 wethOut) {
        uint256 nav = navPerShare();
        wethOut = (sh * nav) / 1e18;
        if (wethOut > vaultWETH) wethOut = vaultWETH;
        shareOf[msg.sender] -= sh;
        shareSupply -= sh;
        vaultWETH -= wethOut;
        require(IERC20(weth).transfer(msg.sender, wethOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

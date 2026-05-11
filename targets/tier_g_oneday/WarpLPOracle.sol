// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// WarpLPOracle — reduction of the Warp Finance attack (2020-12, ~$7.7M).
///
/// Original incident: Warp accepted Uniswap V2 LP tokens (USDC/WETH) as
/// collateral. It valued the LP at  2 * sqrt(reserveA * reserveB) / lpSupply,
/// reading reserves from the live pair. Attacker flash-borrowed USDC,
/// imbalanced the pool, deposited LP, borrowed against the inflated
/// valuation, then rebalanced and walked.
///
/// Implicit assumption (NOT enforced):
/// - Pair reserves track fair-market value within a block.
contract WarpLPOracle {
    address public immutable usdc;
    address public immutable weth;
    address public immutable dai;       // borrowable stable

    // Inline UniV2-style pair (USDC/WETH).
    uint256 public reserveUSDC;
    uint256 public reserveWETH;
    uint256 public lpSupply;
    mapping(address => uint256) public lpOf;

    // Warp lending bookkeeping.
    uint256 public constant CR_BPS = 15000;
    uint256 public constant BPS    = 10000;
    mapping(address => uint256) public lpCollateral;
    mapping(address => uint256) public daiDebt;
    uint256 public daiLiquidity;

    constructor(address _usdc, address _weth, address _dai) {
        usdc = _usdc; weth = _weth; dai = _dai;
    }

    function seed(uint256 amtU, uint256 amtW) external {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtU));
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtW));
        reserveUSDC += amtU;
        reserveWETH += amtW;
        uint256 mint = _sqrt(amtU * amtW);
        lpSupply += mint;
        lpOf[msg.sender] += mint;
    }

    function fundDAI(uint256 amt) external {
        require(IERC20(dai).transferFrom(msg.sender, address(this), amt));
        daiLiquidity += amt;
    }

    function swapUsdcForWeth(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveUSDC * reserveWETH;
        uint256 newRu = reserveUSDC + amtIn;
        uint256 newRw = k / newRu;
        amtOut = reserveWETH - newRw;
        reserveUSDC = newRu;
        reserveWETH = newRw;
        require(IERC20(weth).transfer(msg.sender, amtOut));
    }

    function swapWethForUsdc(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveUSDC * reserveWETH;
        uint256 newRw = reserveWETH + amtIn;
        uint256 newRu = k / newRw;
        amtOut = reserveUSDC - newRu;
        reserveUSDC = newRu;
        reserveWETH = newRw;
        require(IERC20(usdc).transfer(msg.sender, amtOut));
    }

    /// Mint LP: deposit balanced amounts.
    function mintLP(uint256 amtU, uint256 amtW) external returns (uint256 lpAmt) {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtU));
        require(IERC20(weth).transferFrom(msg.sender, address(this), amtW));
        if (lpSupply == 0) {
            lpAmt = _sqrt(amtU * amtW);
        } else {
            uint256 a = (amtU * lpSupply) / reserveUSDC;
            uint256 b = (amtW * lpSupply) / reserveWETH;
            lpAmt = a < b ? a : b;
        }
        lpSupply += lpAmt;
        reserveUSDC += amtU;
        reserveWETH += amtW;
        lpOf[msg.sender] += lpAmt;
    }

    /// THE BUG: LP price uses balanceOf(this) directly, not the cached
    /// reserveUSDC/reserveWETH. So a permissionless `IERC20.transfer(this, X)`
    /// from anyone inflates LP valuation without minting any LP — that
    /// donated balance "lifts" all LP shares' apparent value.
    /// Assume 1 USDC = 1 DAI, 1 WETH = 1000 DAI for clarity.
    function lpPriceInDAI() public view returns (uint256) {
        if (lpSupply == 0) return 0;
        uint256 balU = IERC20(usdc).balanceOf(address(this));
        uint256 balW = IERC20(weth).balanceOf(address(this));
        return ((balU + balW * 1000) * 1e18) / lpSupply;
    }

    function depositLP(uint256 lpAmt) external {
        lpOf[msg.sender] -= lpAmt;
        lpCollateral[msg.sender] += lpAmt;
    }

    function borrowDAI(uint256 amt) external {
        uint256 colValue = (lpCollateral[msg.sender] * lpPriceInDAI()) / 1e18;
        uint256 newDebt = daiDebt[msg.sender] + amt;
        require(newDebt * CR_BPS <= colValue * BPS, "undercollateralized");
        require(daiLiquidity >= amt, "no liquidity");
        daiDebt[msg.sender] = newDebt;
        daiLiquidity -= amt;
        require(IERC20(dai).transfer(msg.sender, amt));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y/2 + 1;
            while (x < z) { z = x; x = (y/x + x)/2; }
        } else if (y != 0) { z = 1; }
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

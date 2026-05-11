// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// CreamYVaultOracle — reduction of the Cream Finance attack (2021-10, ~$130M).
///
/// Original incident: Cream allowed a Yearn yUSDVault token as collateral
/// for borrowing other assets, valuing it via the vault's
/// `pricePerShare()` getter. That getter computes
///   pricePerShare = underlyingHeld / shareSupply
/// Attacker donated a huge amount of underlying directly to the vault
/// (no share mint), inflating pricePerShare. Cream then valued the
/// attacker's small share holding at the inflated price and let them
/// over-borrow USDC against it.
///
/// Honest behavior:
/// - Users deposit underlying (DAI) into yVault, getting shares
///   1:1 modulo accumulated yield.
/// - Cream lending uses pricePerShare() as the collateral oracle.
///
/// Implicit assumption (NOT enforced):
/// - underlyingHeld can only change via deposit/withdraw and accrued
///   yield. Direct donations (force-balance increases) are assumed
///   impossible — but `IERC20.transfer(vault, X)` is permissionless.
///
/// Expected deviation:
/// - deposit(small) -> donate(huge) -> borrow(against inflated share)
contract CreamYVaultOracle {
    address public immutable underlying;       // DAI-like
    address public immutable stableToBorrow;   // USDC-like

    // yVault bookkeeping
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    // Lending bookkeeping (uses pricePerShare for collateral valuation)
    uint256 public constant CR_BPS = 15000;    // 150% over-collateralization
    uint256 public constant BPS    = 10000;
    mapping(address => uint256) public sharesAsCollateral;
    mapping(address => uint256) public usdcDebt;
    uint256 public lendingUsdc;

    constructor(address _underlying, address _stable) {
        underlying = _underlying;
        stableToBorrow = _stable;
    }

    function fund(uint256 amt) external {
        require(IERC20(stableToBorrow).transferFrom(msg.sender, address(this), amt));
        lendingUsdc += amt;
    }

    // ------- yVault interface ----------------------------------------

    function pricePerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (IERC20(underlying).balanceOf(address(this)) * 1e18) / totalShares;
    }

    function deposit(uint256 amt) external returns (uint256 shares) {
        require(IERC20(underlying).transferFrom(msg.sender, address(this), amt));
        if (totalShares == 0) {
            shares = amt;
        } else {
            // pre-deposit underlying balance excludes the amount being added.
            uint256 underBefore = IERC20(underlying).balanceOf(address(this)) - amt;
            shares = (amt * totalShares) / underBefore;
        }
        totalShares += shares;
        shareOf[msg.sender] += shares;
    }

    function withdraw(uint256 shares) external returns (uint256 underAmt) {
        underAmt = (shares * IERC20(underlying).balanceOf(address(this))) / totalShares;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        require(IERC20(underlying).transfer(msg.sender, underAmt));
    }

    // ------- Lending uses yVault pricePerShare as oracle --------------

    function depositCollateral(uint256 shares) external {
        shareOf[msg.sender] -= shares;
        sharesAsCollateral[msg.sender] += shares;
    }

    function withdrawCollateral(uint256 shares) external {
        sharesAsCollateral[msg.sender] -= shares;
        shareOf[msg.sender] += shares;
    }

    function borrow(uint256 amt) external {
        uint256 colShares = sharesAsCollateral[msg.sender];
        uint256 colValue = (colShares * pricePerShare()) / 1e18;
        uint256 newDebt = usdcDebt[msg.sender] + amt;
        require(newDebt * CR_BPS <= colValue * BPS, "undercollateralized");
        require(lendingUsdc >= amt, "no liquidity");
        usdcDebt[msg.sender] = newDebt;
        lendingUsdc -= amt;
        require(IERC20(stableToBorrow).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

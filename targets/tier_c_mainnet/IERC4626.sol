// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Standard ERC4626 ABI for fork-mode attach. Used for any production
/// ERC4626 vault (sDAI, sfrxETH, MetaMorpho, etc.). Implementations are
/// stubbed out because we only need the function signatures here.
contract IERC4626 {
    function asset() external view returns (address) { return address(0); }
    function totalAssets() external view returns (uint256) { return 0; }
    function convertToShares(uint256 assets) external view returns (uint256) { return 0; }
    function convertToAssets(uint256 shares) external view returns (uint256) { return 0; }
    function maxDeposit(address) external view returns (uint256) { return 0; }
    function previewDeposit(uint256 assets) external view returns (uint256) { return 0; }
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) { return 0; }
    function maxMint(address) external view returns (uint256) { return 0; }
    function previewMint(uint256 shares) external view returns (uint256) { return 0; }
    function mint(uint256 shares, address receiver) external returns (uint256 assets) { return 0; }
    function maxWithdraw(address owner) external view returns (uint256) { return 0; }
    function previewWithdraw(uint256 assets) external view returns (uint256) { return 0; }
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) { return 0; }
    function maxRedeem(address owner) external view returns (uint256) { return 0; }
    function previewRedeem(uint256 shares) external view returns (uint256) { return 0; }
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) { return 0; }
    // ERC20 functions (every ERC4626 vault is also an ERC20):
    function balanceOf(address account) external view returns (uint256) { return 0; }
    function totalSupply() external view returns (uint256) { return 0; }
    function transfer(address to, uint256 amount) external returns (bool) { return true; }
    function approve(address spender, uint256 amount) external returns (bool) { return true; }
}

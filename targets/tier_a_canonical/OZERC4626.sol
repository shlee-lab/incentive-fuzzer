// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// OZERC4626 — minimal port of OpenZeppelin's ERC4626 (v4.9+) with the
/// recommended decimals-offset mitigation enabled (`_decimalsOffset = 6`).
///
/// The "virtual shares + virtual assets" pattern (Mudit Gupta / Trail of Bits
/// recommendation) makes the inflation attack unprofitable: even if an
/// attacker mints 1 wei worth of shares and donates a large amount, a
/// subsequent depositor's shares = assets * (totalSupply + 10^offset) /
/// (totalAssets + 1) still rounds to a non-trivial value, and the
/// attacker's redemption claim is diluted by the offset's virtual supply.
///
/// Expected fuzzer outcome: NO TP findings. Donation attack via raw
/// USDC.transfer to the vault followed by Attacker.redeem should net
/// out to a LOSS for the attacker (offset's virtual supply absorbs the
/// donation), so the fuzzer's beam search will find no profitable
/// path.
contract OZERC4626 {
    IERC20 public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 internal constant _DECIMALS_OFFSET_POW = 1_000_000; // 10^6

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        return (assets * (totalSupply + _DECIMALS_OFFSET_POW)) / (totalAssets() + 1);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return (shares * (totalAssets() + 1)) / (totalSupply + _DECIMALS_OFFSET_POW);
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        // OZ does NOT require shares > 0 here, but the math above with the
        // offset always yields shares > 0 in practice for non-zero assets.
        shares = _convertToShares(assets);
        require(asset.transferFrom(msg.sender, address(this), assets), "xfer");
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        require(shares > 0 && totalSupply > 0, "zero");
        assets = _convertToAssets(shares);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        require(asset.transfer(msg.sender, assets), "xfer out");
    }
}

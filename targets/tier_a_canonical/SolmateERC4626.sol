// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// SolmateERC4626 — minimal port of Solmate's ERC4626 mixin
/// (transmissions11/solmate). Different from OZ, Solmate does NOT use a
/// virtual-shares offset; instead it relies on an explicit
/// `require(shares != 0)` check in `deposit()` to block the inflation
/// attack's terminal step (where the victim's deposit would round to
/// zero shares).
///
/// Expected fuzzer outcome: NO TP findings. If attacker donates to
/// inflate the share price, victim's deposit reverts (ZERO_SHARES), so
/// no value can be drained.
contract SolmateERC4626 {
    IERC20 public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        shares = totalSupply == 0 ? assets : (assets * totalSupply) / totalAssets();
        require(shares != 0, "ZERO_SHARES");
        require(asset.transferFrom(msg.sender, address(this), assets), "xfer");
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        require(shares > 0 && totalSupply > 0, "zero");
        assets = (shares * totalAssets()) / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        require(asset.transfer(msg.sender, assets), "xfer out");
    }
}

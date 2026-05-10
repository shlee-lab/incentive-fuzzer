// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Lido stETH ABI port for mainnet attach (0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84).
/// Real Lido is huge; only the user-facing functions we want to fuzz are
/// declared here. submit() takes ETH, mints rebasing stETH proportional to
/// the buffered ether + total pooled ether. Withdrawals live in the separate
/// WithdrawalQueueERC721 contract — out of scope for this single-contract
/// fork test.
contract Lido {
    function submit(address _referral) external payable returns (uint256) { return 0; }
    function transfer(address _recipient, uint256 _amount) external returns (bool) { return true; }
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool) { return true; }
    function approve(address _spender, uint256 _amount) external returns (bool) { return true; }
    function transferShares(address _recipient, uint256 _sharesAmount) external returns (uint256) { return 0; }
    function balanceOf(address _account) external view returns (uint256) { return 0; }
    function sharesOf(address _account) external view returns (uint256) { return 0; }
    function totalSupply() external view returns (uint256) { return 0; }
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256) { return 0; }
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256) { return 0; }
    function getTotalPooledEther() external view returns (uint256) { return 0; }
    function getTotalShares() external view returns (uint256) { return 0; }
}

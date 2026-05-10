// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// WETH9 ABI port for mainnet attach. Function signatures match the live
/// 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 deployment. Bytecode is
/// irrelevant — fuzzer only uses this artifact's ABI to talk to the
/// existing contract via fork mode.
contract WETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function totalSupply() external view returns (uint256) { return 0; }

    function deposit() external payable {}

    function withdraw(uint256 wad) external {}

    function transfer(address dst, uint256 wad) external returns (bool) { return true; }

    function transferFrom(address src, address dst, uint256 wad) external returns (bool) { return true; }

    function approve(address guy, uint256 wad) external returns (bool) { return true; }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Curve 3pool ABI port (DAI/USDC/USDT stable pool at
/// 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7). Vyper source on mainnet —
/// we only need function signatures here for the fuzzer to talk to it via
/// fork mode.
contract Curve3Pool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256) { return 0; }

    function add_liquidity(uint256[3] memory amounts, uint256 min_mint_amount) external returns (uint256) { return 0; }

    function remove_liquidity(uint256 _amount, uint256[3] memory min_amounts) external {}

    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount) external {}

    function get_virtual_price() external view returns (uint256) { return 0; }

    function balances(uint256 i) external view returns (uint256) { return 0; }

    function coins(uint256 i) external view returns (address) { return address(0); }
}

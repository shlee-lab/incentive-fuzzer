// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// EminenceBond — reduction of the Eminence Finance attack (Sept 2020, $15M).
///
/// Original incident: Eminence used a Bancor-style bonding curve where
/// buy and sell share the same DAI reserve atomically. Attacker bought
/// EMN cheap, then bought huge amount (pumping price), then sold the
/// initial position at the now-inflated price, netting more DAI than
/// they put in.
///
/// Reduction (single contract): EMN is bookkept internally (not a
/// separate ERC20). Buy/sell hit the same daiReserve, with price()
/// monotonic in daiReserve.
///
/// Implicit assumption (NOT enforced):
/// - No single actor can both raise AND consume price in one tx.
///
/// Expected deviation:
/// - buyEMN(small) -> buyEMN(huge) -> sellEMN(small)
contract EminenceBond {
    address public immutable dai;

    uint256 public daiReserve;
    mapping(address => uint256) public emnHeld;
    uint256 public emnSupply;

    constructor(address _dai) {
        dai = _dai;
    }

    /// Continuous bonding-curve price: 1 EMN = sqrt(daiReserve)/1e3 DAI
    /// (real Eminence used Bancor formula; what matters is buy and sell
    /// share the same daiReserve atomically).
    function price() public view returns (uint256) {
        if (daiReserve == 0) return 1e15;
        return _sqrt(daiReserve) * 1e3;
    }

    function buyEMN(uint256 daiIn) external returns (uint256 emnOut) {
        require(IERC20(dai).transferFrom(msg.sender, address(this), daiIn));
        daiReserve += daiIn;
        uint256 p = price();
        emnOut = (daiIn * 1e18) / p;
        emnHeld[msg.sender] += emnOut;
        emnSupply += emnOut;
    }

    function sellEMN(uint256 emnIn) external returns (uint256 daiOut) {
        emnHeld[msg.sender] -= emnIn;
        uint256 p = price();
        daiOut = (emnIn * p) / 1e18;
        if (daiOut > daiReserve) daiOut = daiReserve;
        daiReserve -= daiOut;
        emnSupply -= emnIn;
        require(IERC20(dai).transfer(msg.sender, daiOut));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

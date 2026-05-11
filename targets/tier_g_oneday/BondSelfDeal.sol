// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// BondSelfDeal — reduction of a "protocol-owned-liquidity bond" audit
/// pattern. The protocol issues discounted bonds (paying out X+α native
/// tokens for X stablecoins) to acquire its own liquidity. The intent is
/// for the discount to attract external capital. But a privileged actor
/// (or anyone with significant capital) can buy the bond themselves and
/// pocket α — the discount that an external bonder would have earned.
///
/// Pattern: bondTreasury issues bonds for X PROTOCOL_TOKEN at discount
/// α. Anyone can deposit X STABLE, receive (1 + α) * X PROTOCOL_TOKEN.
/// Then sell PROTOCOL_TOKEN on the inline AMM (paid in STABLE), netting
/// α STABLE per cycle.
contract BondSelfDeal {
    address public immutable protocolToken;
    address public immutable stable;

    uint256 public reserveP;
    uint256 public reserveS;

    constructor(address _p, address _s) { protocolToken = _p; stable = _s; }

    function seedAMM(uint256 amtP, uint256 amtS) external {
        require(IERC20(protocolToken).transferFrom(msg.sender, address(this), amtP));
        require(IERC20(stable).transferFrom(msg.sender, address(this), amtS));
        reserveP += amtP;
        reserveS += amtS;
    }

    /// Discounted bond: deposit X stable → receive (1+α) X protocol token.
    /// We use α = 10% = 1100 BPS / 10000 BPS, but the size of α is
    /// the bug surface — whatever non-trivial α makes this profitable.
    function bond(uint256 stableIn) external returns (uint256 protocolOut) {
        require(IERC20(stable).transferFrom(msg.sender, address(this), stableIn));
        protocolOut = (stableIn * 11000) / 10000;  // 10% bonus
        // Mint the bonus from the pool's reserveP (so the pool is the
        // counterparty to the bonder, like a protocol-owned reserve).
        require(reserveP >= protocolOut, "no P reserve");
        reserveP -= protocolOut;
        require(IERC20(protocolToken).transfer(msg.sender, protocolOut));
    }

    function swapPForS(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(protocolToken).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveP * reserveS;
        uint256 newRp = reserveP + amtIn;
        uint256 newRs = k / newRp;
        amtOut = reserveS - newRs;
        reserveP = newRp;
        reserveS = newRs;
        require(IERC20(stable).transfer(msg.sender, amtOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

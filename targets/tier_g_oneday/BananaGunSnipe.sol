// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// BananaGunSnipe — reduction of single-block mint-and-flip MEV (Banana
/// Gun and similar Telegram-bot MEV genre). A new token launches its
/// liquidity in one block. Bots compete to be FIRST to mint into the
/// fresh pool at the seed price. The first buyer in the block gets a
/// hugely advantaged price relative to subsequent buyers (1000x slippage
/// is normal for $1M+ launches).
///
/// Reduction (multi-agent): a freshly-seeded AMM. Two agents both want
/// to buy. The honest baseline is "either of them in second position".
/// The deviation: be in FIRST position.
contract BananaGunSnipe {
    address public immutable t;
    address public immutable q;
    uint256 public reserveT;
    uint256 public reserveQ;

    constructor(address _t, address _q) { t = _t; q = _q; }

    function seed(uint256 amtT, uint256 amtQ) external {
        require(IERC20(t).transferFrom(msg.sender, address(this), amtT));
        require(IERC20(q).transferFrom(msg.sender, address(this), amtQ));
        reserveT += amtT;
        reserveQ += amtQ;
    }

    function swapQforT(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(q).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveT * reserveQ;
        uint256 newRq = reserveQ + amtIn;
        uint256 newRt = k / newRq;
        amtOut = reserveT - newRt;
        reserveT = newRt;
        reserveQ = newRq;
        require(IERC20(t).transfer(msg.sender, amtOut));
    }

    function swapTforQ(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(t).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveT * reserveQ;
        uint256 newRt = reserveT + amtIn;
        uint256 newRq = k / newRt;
        amtOut = reserveQ - newRq;
        reserveT = newRt;
        reserveQ = newRq;
        require(IERC20(q).transfer(msg.sender, amtOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

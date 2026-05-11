// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// DydxCrossMargin — reduction of a perp/leveraged-margin protocol's
/// cross-margin liquidation incentive (audit class, applies to dYdX,
/// GMX, Perpetual Protocol).
///
/// Pattern: positions are cross-margined — losses on one position can
/// be offset by margin posted on another. Liquidation triggers when
/// total margin < required maintenance margin. Attacker opens TWO
/// opposite-direction positions to fully hedge, posts minimum margin,
/// then triggers a liquidation event on one side via a tiny price poke,
/// pockets the liquidation insurance-fund top-up.
contract DydxCrossMargin {
    address public immutable asset;
    uint256 public price = 1000 * 1e18;

    mapping(address => int256) public longSize;
    mapping(address => int256) public shortSize;
    mapping(address => uint256) public margin;
    uint256 public insuranceFund;

    constructor(address _asset) { asset = _asset; }

    function fundInsurance(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        insuranceFund += amt;
    }

    function postMargin(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        margin[msg.sender] += amt;
    }

    function openLong(uint256 size) external {
        longSize[msg.sender] += int256(size);
    }

    function openShort(uint256 size) external {
        shortSize[msg.sender] += int256(size);
    }

    function setPrice(uint256 newPrice) external { price = newPrice; }

    /// Anyone can poke a liquidation if a sender's net position requires
    /// more margin than they hold. Liquidator gets paid from insurance
    /// fund as a "keeper reward" — flat 10% of position notional.
    function liquidate(address user) external {
        int256 net = longSize[user] - shortSize[user];
        uint256 abs = net >= 0 ? uint256(net) : uint256(-net);
        // Required margin: 10% of |net| * price (10x leverage limit).
        uint256 req = (abs * price) / 1e18 / 10;
        require(margin[user] < req, "not liquidatable");
        // Reward to liquidator from insurance fund: 10% of |net| (the
        // intended incentive for independent keepers). USER's positions
        // are also wiped — but their MARGIN balance is untouched (audit
        // bug: insurance pays keeper without debiting user).
        uint256 reward = (abs * price) / 1e18 / 10;
        if (reward > insuranceFund) reward = insuranceFund;
        insuranceFund -= reward;
        longSize[user] = 0;
        shortSize[user] = 0;
        require(IERC20(asset).transfer(msg.sender, reward));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// GmxOpenPrice — reduction of the GMX open-price MEV (audit class).
///
/// Original pattern: GMX-style perpetual exchanges use a "median of last
/// few minutes" reference price for opening/closing positions. A trader
/// who can choose precisely WHEN to open (via mempool MEV) can lock in
/// a position at a price favorable to themselves vs the index price at
/// settle time.
///
/// Reduction: a perp contract where `openLong(size)` uses
/// `refPrice` (settable by anyone via `pokePrice`). Closing reads the
/// current (slightly drifted) refPrice. Attacker pokes to a favorable
/// price, opens, then pokes back and immediately closes — netting risk-
/// free profit.
contract GmxOpenPrice {
    address public immutable collateral;

    uint256 public refPrice = 1000 * 1e18;   // 1000 collateral-units per BTC, say
    mapping(address => uint256) public sizeOf;
    mapping(address => uint256) public entryOf;
    mapping(address => uint256) public marginOf;

    constructor(address _col) { collateral = _col; }

    /// Anyone can update the reference price by submitting an observation.
    /// In production this is rate-limited by oracle keepers but the
    /// reduction shows the worst case: trustless poke.
    function pokePrice(uint256 newPrice) external {
        require(newPrice > 0, "zero");
        refPrice = newPrice;
    }

    function openLong(uint256 size, uint256 margin) external {
        require(IERC20(collateral).transferFrom(msg.sender, address(this), margin));
        marginOf[msg.sender] += margin;
        sizeOf[msg.sender] += size;
        // Lock entry at CURRENT refPrice — manipulable.
        entryOf[msg.sender] = refPrice;
    }

    function closeLong(uint256 size) external returns (uint256 payout) {
        // PnL = size * (refPrice - entry) / entry. With manipulable entry
        // we can lock entry low and close at a higher price.
        uint256 s = sizeOf[msg.sender];
        if (size > s) size = s;
        uint256 e = entryOf[msg.sender];
        uint256 p = refPrice;
        int256 pnl = int256((size * p) / e) - int256(size);
        sizeOf[msg.sender] -= size;
        if (pnl > 0) {
            payout = marginOf[msg.sender] + uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            payout = marginOf[msg.sender] > loss ? (marginOf[msg.sender] - loss) : 0;
        }
        marginOf[msg.sender] = 0;
        sizeOf[msg.sender] = 0;
        require(IERC20(collateral).transfer(msg.sender, payout));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

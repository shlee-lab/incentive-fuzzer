// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// PancakeBunnyMint — reduction of the PancakeBunny attack (2021-05, ~$45M).
///
/// Original incident: PancakeBunny's BUNNY token reward = (LP value in
/// quote) / (BUNNY price in quote). Both quantities are spot-priced
/// against AMM reserves and thus manipulable atomically with a flash
/// loan.
///
/// Reduction (single contract): an internal BUNNY/QUOTE AMM lets the
/// attacker dump quote → push BUNNY price up → claim a vast reward.
/// Inverse direction works too: attacker buys BUNNY first cheap, pumps
/// the LP-side numerator, claims.
///
/// Implicit assumption (NOT enforced):
/// - Pool spot cannot be moved cheaply within one transaction.
///
/// Expected deviation:
/// - stake(LP) → swapQuoteForBunny (pump) → claim → unstake
contract PancakeBunnyMint {
    address public immutable lp;     // staked
    address public immutable quote;  // quote asset

    // Internal BUNNY/quote spot — used to PRICE the reward.
    uint256 public reserveBunny;
    uint256 public reserveQuote;
    mapping(address => uint256) public bunnyHeld;
    uint256 public bunnySupply;

    // Staking
    uint256 public totalStaked;
    mapping(address => uint256) public staked;

    constructor(address _lp, address _quote) {
        lp = _lp;
        quote = _quote;
    }

    function seed(uint256 amtBunny, uint256 amtQuote) external {
        require(IERC20(quote).transferFrom(msg.sender, address(this), amtQuote));
        reserveBunny += amtBunny;   // BUNNY is internal; we just credit the pool's bookkeeping
        reserveQuote += amtQuote;
    }

    function stake(uint256 amt) external {
        require(IERC20(lp).transferFrom(msg.sender, address(this), amt));
        staked[msg.sender] += amt;
        totalStaked += amt;
    }

    function unstake(uint256 amt) external {
        staked[msg.sender] -= amt;
        totalStaked -= amt;
        require(IERC20(lp).transfer(msg.sender, amt));
    }

    /// Reward = stakedLp * (quoteReserve / bunnyReserve). Pumping
    /// quoteReserve relative to bunnyReserve inflates this without bound.
    function pendingReward(address user) public view returns (uint256) {
        if (reserveBunny == 0 || staked[user] == 0) return 0;
        return (staked[user] * reserveQuote) / reserveBunny;
    }

    function claim() external {
        uint256 r = pendingReward(msg.sender);
        require(r > 0, "no reward");
        bunnyHeld[msg.sender] += r;
        bunnySupply += r;
    }

    // ----- Internal AMM (BUNNY priced in quote) ------------------------

    function swapQuoteForBunny(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(quote).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveBunny * reserveQuote;
        uint256 newRq = reserveQuote + amtIn;
        uint256 newRb = k / newRq;
        amtOut = reserveBunny - newRb;
        reserveBunny = newRb;
        reserveQuote = newRq;
        bunnyHeld[msg.sender] += amtOut;
    }

    function swapBunnyForQuote(uint256 amtIn) external returns (uint256 amtOut) {
        bunnyHeld[msg.sender] -= amtIn;
        uint256 k = reserveBunny * reserveQuote;
        uint256 newRb = reserveBunny + amtIn;
        uint256 newRq = k / newRb;
        amtOut = reserveQuote - newRq;
        reserveBunny = newRb;
        reserveQuote = newRq;
        require(IERC20(quote).transfer(msg.sender, amtOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

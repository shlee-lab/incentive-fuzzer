// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// YieldFarm
///
/// Honest behavior:
/// - Users deposit STAKE tokens, accruing REWARD tokens at a constant rate
///   (`RATE` per stake-token-second). Rewards are claimed via `claim()`.
///
/// Implementation bug:
/// - `deposit` does not snapshot the user's previously-accrued rewards before
///   increasing their balance. Instead it leaves `lastUpdated` untouched on
///   subsequent deposits. The next `claim()` therefore computes
///   `(new_deposit_total) * (block.timestamp - lastUpdated)`, applying the
///   most-recent balance retroactively to time during which the user was
///   barely staked.
///
/// Expected deviation found by the fuzzer:
/// - User deposits a tiny amount, lets time accrue, deposits a much larger
///   amount, and immediately claims — collecting rewards as if the large
///   amount had been staked the whole time. Mutator finds this by inserting
///   a second `deposit` action between `advance_time` and `claim`.
contract YieldFarm {
    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    uint256 public constant RATE = 1e12; // reward smallest-units per stake-smallest-unit per second

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public lastUpdated;

    constructor(address _stake, address _reward) {
        stakeToken = IERC20(_stake);
        rewardToken = IERC20(_reward);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "xfer fail");
        // BUG: should snapshot pending rewards for old balance before increasing it.
        // (Correct logic would call an _update(msg.sender) here that converts
        // pending time*deposits[msg.sender] into a credited rewards balance.)
        deposits[msg.sender] += amount;
        if (lastUpdated[msg.sender] == 0) {
            lastUpdated[msg.sender] = block.timestamp;
        }
    }

    function claim() external {
        uint256 last = lastUpdated[msg.sender];
        if (last == 0) {
            lastUpdated[msg.sender] = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - last;
        uint256 reward = (deposits[msg.sender] * dt * RATE) / 1e18;
        lastUpdated[msg.sender] = block.timestamp;
        if (reward > 0) {
            require(rewardToken.transfer(msg.sender, reward), "reward xfer fail");
        }
    }

    function withdraw() external {
        uint256 amount = deposits[msg.sender];
        deposits[msg.sender] = 0;
        if (amount > 0) {
            require(stakeToken.transfer(msg.sender, amount), "xfer fail");
        }
    }
}

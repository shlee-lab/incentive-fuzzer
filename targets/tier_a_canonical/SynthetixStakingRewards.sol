// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// SynthetixStakingRewards — minimal port of the canonical Synthetix
/// StakingRewards.sol. Uses the rewardPerToken accumulator pattern with
/// per-user `userRewardPerTokenPaid` and an `updateReward` modifier that
/// snapshots accrued rewards BEFORE balance changes. This is the textbook
/// fix for the deposit-flash-claim bug we modeled in `YieldFarm.sol`.
///
/// Expected fuzzer outcome: NO TP findings. Inserting an extra deposit
/// before claim should NOT inflate rewards because updateReward is
/// called first, snapshotting the pre-deposit rewards.
contract SynthetixStakingRewards {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;
    uint256 public rewardRate; // tokens per second
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _staking, address _rewards, uint256 _rate) {
        stakingToken = IERC20(_staking);
        rewardsToken = IERC20(_rewards);
        rewardRate = _rate;
        lastUpdateTime = block.timestamp;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((block.timestamp - lastUpdateTime) * rewardRate * 1e18) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18
            + rewards[account];
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "zero");
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "xfer");
    }

    function withdraw(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "zero");
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        require(stakingToken.transfer(msg.sender, amount), "xfer");
    }

    function getReward() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            require(rewardsToken.transfer(msg.sender, reward), "rxfer");
        }
    }
}

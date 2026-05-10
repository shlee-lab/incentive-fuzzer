// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// SushiMasterChef — minimal port of SushiSwap's original MasterChef.sol
/// (single-pool variant — drops the `poolInfo[]` array since we only test
/// one pool).
///
/// Uses the canonical "rewardDebt" pattern: deposit() pays out the user's
/// pending rewards on their OLD balance BEFORE increasing it, then
/// resets rewardDebt to (newBalance * accSushiPerShare). This correctly
/// prevents the deposit-flash-claim bug.
///
/// Expected fuzzer outcome: NO TP findings. Inserting an extra deposit
/// before withdraw/claim should pay out only the rewards earned on the
/// pre-existing balance for the elapsed time.
contract SushiMasterChef {
    IERC20 public immutable lpToken;
    IERC20 public immutable sushi;
    uint256 public sushiPerSecond;     // analogue of sushiPerBlock
    uint256 public lastRewardTime;
    uint256 public accSushiPerShare;   // scaled by 1e12
    uint256 public totalStaked;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }
    mapping(address => UserInfo) public userInfo;

    constructor(address _lp, address _sushi, uint256 _rate) {
        lpToken = IERC20(_lp);
        sushi = IERC20(_sushi);
        sushiPerSecond = _rate;
        lastRewardTime = block.timestamp;
    }

    function pendingSushi(address user) public view returns (uint256) {
        UserInfo memory u = userInfo[user];
        uint256 acc = accSushiPerShare;
        if (block.timestamp > lastRewardTime && totalStaked != 0) {
            uint256 elapsed = block.timestamp - lastRewardTime;
            acc += (elapsed * sushiPerSecond * 1e12) / totalStaked;
        }
        return (u.amount * acc) / 1e12 - u.rewardDebt;
    }

    function updatePool() public {
        if (block.timestamp <= lastRewardTime) return;
        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - lastRewardTime;
        uint256 reward = elapsed * sushiPerSecond;
        accSushiPerShare += (reward * 1e12) / totalStaked;
        lastRewardTime = block.timestamp;
    }

    function deposit(uint256 amount) external {
        UserInfo storage u = userInfo[msg.sender];
        updatePool();
        if (u.amount > 0) {
            uint256 pending = (u.amount * accSushiPerShare) / 1e12 - u.rewardDebt;
            if (pending > 0) require(sushi.transfer(msg.sender, pending), "sxfer");
        }
        if (amount > 0) {
            require(lpToken.transferFrom(msg.sender, address(this), amount), "lpxfer");
            u.amount += amount;
            totalStaked += amount;
        }
        u.rewardDebt = (u.amount * accSushiPerShare) / 1e12;
    }

    function withdraw(uint256 amount) external {
        UserInfo storage u = userInfo[msg.sender];
        require(u.amount >= amount, "exceeds");
        updatePool();
        uint256 pending = (u.amount * accSushiPerShare) / 1e12 - u.rewardDebt;
        if (pending > 0) require(sushi.transfer(msg.sender, pending), "sxfer");
        if (amount > 0) {
            u.amount -= amount;
            totalStaked -= amount;
            require(lpToken.transfer(msg.sender, amount), "lpxfer");
        }
        u.rewardDebt = (u.amount * accSushiPerShare) / 1e12;
    }
}

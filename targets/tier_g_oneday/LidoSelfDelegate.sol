// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// LidoSelfDelegate — reduction of the validator-self-stake / slashing
/// MEV audit class (variant of the Lido NodeOperatorRegistry slashing
/// reward-routing assumption).
///
/// Pattern: a staking pool has node operators (validators) who earn a
/// share of stake reward, plus a slashing fund that penalizes them on
/// fault. The slashing fund pays into the staker reward pool. Implicit
/// assumption: "validator and staker are different people" — but a
/// validator can also be a staker (delegate to themselves). When the
/// validator slashes themselves, the slashing fund flows back to them
/// as a staker, so the punishment is partially refunded.
///
/// Reduction: stakers deposit, validators claim reward share. A
/// validator who ALSO stakes recovers (their_stake / total_stake) of
/// any slashing penalty they incur.
contract LidoSelfDelegate {
    address public immutable stEth;
    address public validator;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    uint256 public validatorReward;
    uint256 public slashingFund;

    constructor(address _stEth, address _validator) {
        stEth = _stEth;
        validator = _validator;
    }

    function stake(uint256 amt) external {
        require(IERC20(stEth).transferFrom(msg.sender, address(this), amt));
        stakedOf[msg.sender] += amt;
        totalStaked += amt;
    }

    function unstake(uint256 amt) external {
        stakedOf[msg.sender] -= amt;
        totalStaked -= amt;
        require(IERC20(stEth).transfer(msg.sender, amt));
    }

    /// Validator does work; reward is split 90% to stakers (pro-rata),
    /// 10% to validator.
    function distributeReward(uint256 amt) external {
        require(IERC20(stEth).transferFrom(msg.sender, address(this), amt));
        uint256 vShare = amt / 10;
        validatorReward += vShare;
        // remaining stays in contract, raising pro-rata stake value (implicit).
    }

    function claimValidatorReward() external {
        require(msg.sender == validator, "not validator");
        uint256 r = validatorReward;
        validatorReward = 0;
        require(IERC20(stEth).transfer(validator, r));
    }

    /// Validator gets slashed. The slashing penalty `amt` is debited from
    /// validatorReward, deposited into slashingFund, which then re-credits
    /// PRO-RATA to ALL stakers — INCLUDING the validator if they have a
    /// self-stake position.
    function slash(uint256 amt) external {
        if (amt > validatorReward) amt = validatorReward;
        validatorReward -= amt;
        slashingFund += amt;
        // Distribute slashingFund pro-rata via raising index — we just
        // record it; users claim via their stake.
    }

    /// Anyone can pull their share of slashingFund proportional to stake.
    function claimSlashingShare() external returns (uint256 share) {
        if (totalStaked == 0) return 0;
        share = (slashingFund * stakedOf[msg.sender]) / totalStaked;
        // Buggy: also lets validator (if a staker) claim. Doesn't subtract
        // from slashingFund per-user, so first claimers drain.
        if (share > slashingFund) share = slashingFund;
        slashingFund -= share;
        require(IERC20(stEth).transfer(msg.sender, share));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

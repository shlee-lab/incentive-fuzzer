// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// BeanstalkGov — reduction of the Beanstalk Farms governance attack
/// (April 2022, ~$182M).
///
/// Real-world bug: Beanstalk's governance contract checked the proposer's
/// stake at execute time (no snapshot, no time-lock). The attacker took a
/// flash loan of governance tokens, used the borrowed weight to pass and
/// immediately execute a malicious BIP that drained the protocol's
/// treasury, and repaid the flash in the same transaction.
///
/// Reduction (single-contract version, no separate flash lender):
/// - The bug is the same: anyone whose CURRENT stake is >50% of total
///   stake can call `proposeAndExecute(recipient, amount)` and instantly
///   drain `amount` of treasury asset to `recipient`. There is no
///   pre-execution snapshot, no quorum delay, no proposer freeze.
/// - The attacker doesn't need a flash loan in this reduction; they can
///   simply (a) deposit enough vote tokens to clear the 50% line,
///   (b) call proposeAndExecute, (c) withdraw their stake. Their vote
///   tokens are returned intact and the treasury is empty.
///
/// Implicit assumption (NOT enforced):
/// - Stake majority is durable / not transient. The contract trusts that
///   anyone with majority stake at the moment of execution had it
///   honestly accumulated.
///
/// Expected deviation found by the fuzzer:
/// - Three-action compound (deposit -> proposeAndExecute -> withdraw),
///   discovered via a `compound_template` mutator hint that lists the
///   slots; the mutator searches over arg variants in each slot. The
///   correct combination has the attacker depositing enough to flip the
///   majority and routing the treasury to themselves.
contract BeanstalkGov {
    IERC20 public immutable voteToken;
    IERC20 public immutable treasuryAsset;

    mapping(address => uint256) public stake;
    uint256 public totalStake;

    constructor(address _vote, address _treasury) {
        voteToken = IERC20(_vote);
        treasuryAsset = IERC20(_treasury);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        require(voteToken.transferFrom(msg.sender, address(this), amount), "xfer");
        stake[msg.sender] += amount;
        totalStake += amount;
    }

    function withdraw(uint256 amount) external {
        stake[msg.sender] -= amount;
        totalStake -= amount;
        require(voteToken.transfer(msg.sender, amount), "xfer");
    }

    function proposeAndExecute(address recipient, uint256 amount) external {
        // BUG: no snapshot, no time-lock — current-stake majority can drain.
        require(stake[msg.sender] * 2 > totalStake, "no majority");
        require(treasuryAsset.transfer(recipient, amount), "xfer");
    }
}

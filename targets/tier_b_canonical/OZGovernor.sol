// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// OZGovernor — OZ-Governor-style governance with the canonical defense
/// that distinguishes it from BeanstalkGov: quorum is computed against
/// `voteToken.totalSupply()`, NOT `totalStake`. An attacker who deposits
/// only their own (limited) voteToken holdings cannot manufacture a
/// majority by being the sole staker; they must hold majority of the
/// fixed total supply.
///
/// In real OZ Governor this combines with ERC20Votes' historical
/// snapshots and a Timelock; we keep the snapshot-vs-totalSupply core
/// (which is what defeats Beanstalk-style attacks even without flash
/// loan atomicity in our framework) and drop the per-block voting
/// machinery for clarity.
///
/// Expected fuzzer outcome: NO TP findings — attacker's stake (limited
/// by their own voteToken balance) is below totalSupply/2 quorum, so
/// proposeAndExecute reverts.
contract OZGovernor {
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
        // CANONICAL DEFENSE: quorum against TOTAL SUPPLY of voteToken,
        // not against totalStake. An attacker who only stakes their own
        // tokens can't manufacture majority — they need the majority of
        // the fixed total supply, which they don't possess.
        require(stake[msg.sender] * 2 > voteToken.totalSupply(), "insufficient quorum");
        require(treasuryAsset.transfer(recipient, amount), "xfer");
    }
}

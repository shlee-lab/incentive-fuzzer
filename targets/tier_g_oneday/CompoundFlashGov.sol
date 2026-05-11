// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// CompoundFlashGov — reduction of the Cover Protocol / Compound-style
/// governance flash-mint class (2020-12 Cover, ~$4M; analogous audit
/// findings on countless smaller protocols).
///
/// Original pattern: a governance token's voting weight is read at
/// proposal-execution time (not snapshot at proposal time). Attacker
/// flash-borrows huge amount of governance token → creates and immediately
/// executes a malicious proposal that mints reward tokens to self → repays
/// flash.
///
/// Reduction: governance contract that accepts proposal+execute in one
/// call, checks `gov.balanceOf(msg.sender)` against quorum at that
/// instant. Attacker deposits temp votes (a la flash) by holding tokens
/// for one block.
///
/// Expected deviation:
/// - deposit(gov tokens) -> proposeAndExecute(self, mintAmount) -> withdraw
contract CompoundFlashGov {
    address public immutable govToken;
    address public immutable rewardToken;

    mapping(address => uint256) public voteOf;
    uint256 public totalVotes;

    constructor(address _gov, address _reward) {
        govToken = _gov;
        rewardToken = _reward;
    }

    function deposit(uint256 amt) external {
        require(IERC20(govToken).transferFrom(msg.sender, address(this), amt));
        voteOf[msg.sender] += amt;
        totalVotes += amt;
    }

    function withdraw(uint256 amt) external {
        voteOf[msg.sender] -= amt;
        totalVotes -= amt;
        require(IERC20(govToken).transfer(msg.sender, amt));
    }

    /// BUG: vote check is taken right NOW, no snapshot or delay. Whoever
    /// has > 50% at this instant can mint arbitrary reward tokens to any
    /// recipient.
    function proposeAndExecute(address to, uint256 mintAmount) external {
        require(voteOf[msg.sender] * 2 > totalVotes, "no majority");
        require(IERC20(rewardToken).transfer(to, mintAmount), "xfer");
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// ConvexVoteBribe — reduction of Convex/Curve-style vote-bribery
/// emission-distribution gaming (audit class).
///
/// Original pattern: a gauge distributes emissions proportional to votes.
/// Anyone can post a "bribe" that pays out to voters for a gauge. Attacker
/// deposits votes for their OWN bribe gauge, claims the bribe, and
/// withdraws votes — collecting the bribe + standard emissions for one
/// epoch without committing capital.
///
/// Reduction: votes have no commitment period. Bribe amount goes
/// proportionally to whoever is voted for at the moment of claim().
contract ConvexVoteBribe {
    address public immutable voteToken;
    address public immutable bribeToken;

    mapping(address => uint256) public voteFor; // gauge -> total votes
    mapping(address => mapping(address => uint256)) public votedBy; // gauge -> user -> amount
    mapping(address => uint256) public bribePool; // gauge -> bribe deposited

    constructor(address _vote, address _bribe) {
        voteToken = _vote;
        bribeToken = _bribe;
    }

    function depositBribe(address gauge, uint256 amt) external {
        require(IERC20(bribeToken).transferFrom(msg.sender, address(this), amt));
        bribePool[gauge] += amt;
    }

    function voteOnGauge(address gauge, uint256 amt) external {
        require(IERC20(voteToken).transferFrom(msg.sender, address(this), amt));
        voteFor[gauge] += amt;
        votedBy[gauge][msg.sender] += amt;
    }

    /// BUG: claim()s out at CURRENT vote ratio, no snapshot. Attacker
    /// voteOnGauge → claim → unvote in one tx collects whole bribe pool
    /// minus other voters' share.
    function claimBribe(address gauge) external returns (uint256 amt) {
        uint256 mine = votedBy[gauge][msg.sender];
        uint256 tot  = voteFor[gauge];
        require(mine > 0 && tot > 0, "no votes");
        amt = (bribePool[gauge] * mine) / tot;
        // BUG: does NOT decrement bribePool — so it can be claimed AGAIN
        // by the same voter or others as long as their votes are still
        // recorded. Attacker can claim, then unvote, then re-vote, then
        // claim again. We instead model the single-claim version where
        // the bug is "no snapshot" so attacker collects the full ratio
        // even without commitment.
        bribePool[gauge] -= amt;
        require(IERC20(bribeToken).transfer(msg.sender, amt));
    }

    function unvote(address gauge, uint256 amt) external {
        votedBy[gauge][msg.sender] -= amt;
        voteFor[gauge] -= amt;
        require(IERC20(voteToken).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

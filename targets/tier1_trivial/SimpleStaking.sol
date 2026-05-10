// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// SimpleStaking
///
/// Honest behavior:
/// - A single registered Validator secures the protocol; outside parties
///   ("Delegators") can stake ETH to that Validator. When rewards are
///   distributed, the Validator receives 90% of the pool; the remaining 10%
///   is split pro-rata among delegators.
/// - After distribution, anyone may withdraw their original stake.
///
/// Implicit role-separation assumption (NOT enforced):
/// - The Validator and the Delegators are distinct parties. The 10%
///   delegator pool is meant to compensate external stakers; the contract
///   never checks that `msg.sender != validator` in `delegate`.
///
/// Expected deviation found by the fuzzer:
/// - The Validator delegates a large sum to themselves before distribution,
///   which entitles them to most of the delegator pool in addition to the
///   90% validator share. They then withdraw the staked amount intact,
///   capturing close to 100% of the rewards instead of the intended 90%.
contract SimpleStaking {
    address public validator;
    bool public distributed;
    uint256 public totalDelegated;
    address[] public delegatorList;
    mapping(address => uint256) public delegations;
    mapping(address => bool) public seen;

    constructor(address _validator) payable {
        validator = _validator;
    }

    function delegate() external payable {
        require(!distributed, "already distributed");
        require(msg.value > 0, "zero stake");
        if (!seen[msg.sender]) {
            seen[msg.sender] = true;
            delegatorList.push(msg.sender);
        }
        delegations[msg.sender] += msg.value;
        totalDelegated += msg.value;
    }

    function distribute() external payable {
        require(!distributed, "already distributed");
        require(msg.value > 0, "no reward");
        distributed = true;
        uint256 reward = msg.value;
        uint256 validatorShare = (reward * 90) / 100;
        uint256 delegatorPool = reward - validatorShare;
        (bool vOk, ) = payable(validator).call{value: validatorShare}("");
        require(vOk, "validator pay failed");
        if (totalDelegated == 0) return;
        for (uint256 i = 0; i < delegatorList.length; i++) {
            address d = delegatorList[i];
            uint256 share = (delegatorPool * delegations[d]) / totalDelegated;
            if (share > 0) {
                (bool dOk, ) = payable(d).call{value: share}("");
                require(dOk, "delegator pay failed");
            }
        }
    }

    function withdraw() external {
        require(distributed, "not distributed");
        uint256 amt = delegations[msg.sender];
        delegations[msg.sender] = 0;
        if (amt > 0) {
            (bool ok, ) = payable(msg.sender).call{value: amt}("");
            require(ok, "withdraw failed");
        }
    }

    receive() external payable {}
}

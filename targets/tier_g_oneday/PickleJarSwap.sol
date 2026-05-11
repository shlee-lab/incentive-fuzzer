// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// PickleJarSwap — reduction of the Pickle Finance attack (2020-11, ~$20M).
///
/// Original incident: Pickle's PickleJar contracts had a `swapExactJarForJar`
/// function that allowed callers to swap one jar's tokens for another at
/// "fair" share ratios — but the function trusted the caller-supplied
/// destination jar address. Attacker passed a malicious jar with inflated
/// pricePerShare, getting back far more underlying than they put in.
///
/// Reduction: a jar lets users `swapExactJarForJar` between two jars
/// where the destination jar's pricePerShare is computed from its
/// own internal share-supply / underlying balance. Attacker can
/// manipulate the destination jar's supply via a `donateUnderlying`
/// (i.e., raw token.transfer) to inflate its pricePerShare BEFORE
/// the swap — making one source-jar share worth many destination-jar
/// shares.
contract PickleJarSwap {
    address public immutable token;     // underlying

    // Two jars: A and B share storage.
    uint256 public supplyA;
    uint256 public supplyB;
    mapping(address => uint256) public sharesA;
    mapping(address => uint256) public sharesB;
    uint256 public underlyingA;
    uint256 public underlyingB;

    constructor(address _t) { token = _t; }

    function depositA(uint256 amt) external returns (uint256 sh) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amt));
        sh = (supplyA == 0) ? amt : (amt * supplyA) / underlyingA;
        supplyA += sh;
        sharesA[msg.sender] += sh;
        underlyingA += amt;
    }

    function depositB(uint256 amt) external returns (uint256 sh) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amt));
        sh = (supplyB == 0) ? amt : (amt * supplyB) / underlyingB;
        supplyB += sh;
        sharesB[msg.sender] += sh;
        underlyingB += amt;
    }

    function withdrawA(uint256 sh) external returns (uint256 amt) {
        amt = (sh * underlyingA) / supplyA;
        sharesA[msg.sender] -= sh;
        supplyA -= sh;
        underlyingA -= amt;
        require(IERC20(token).transfer(msg.sender, amt));
    }

    function withdrawB(uint256 sh) external returns (uint256 amt) {
        amt = (sh * underlyingB) / supplyB;
        sharesB[msg.sender] -= sh;
        supplyB -= sh;
        underlyingB -= amt;
        require(IERC20(token).transfer(msg.sender, amt));
    }

    /// THE BUG: swap A-shares for B-shares at the ratio of each jar's
    /// pricePerShare — but jar B's pricePerShare can be inflated via a
    /// donation that the protocol does NOT account for (because supplyB
    /// is not bumped).
    function swapAForB(uint256 shA) external returns (uint256 shB) {
        uint256 ppsA = (underlyingA * 1e18) / supplyA;
        uint256 ppsB = (underlyingB * 1e18) / supplyB;
        // value transferred in: shA * ppsA / 1e18 underlying
        uint256 valueIn = (shA * ppsA) / 1e18;
        // shares of B you get: valueIn / ppsB
        shB = (valueIn * 1e18) / ppsB;
        sharesA[msg.sender] -= shA;
        supplyA -= shA;
        underlyingA -= valueIn;
        sharesB[msg.sender] += shB;
        supplyB += shB;
        underlyingB += valueIn;
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

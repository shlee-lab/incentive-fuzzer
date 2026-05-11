// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// CentrifugeBondClaim — reduction of an "early-redeem from yield bond"
/// audit class. A bond NFT lets the holder claim the yield distributed
/// to that bond's cohort. Yield is distributed to ALL active bonds
/// pro-rata on each `distribute()` call. Bonds purchased AFTER an
/// announced yield event but BEFORE the distribute() actually fires
/// also participate in the distribution — free-riding on yield earned
/// before they entered.
///
/// Reduction: bond contract where buyBond → distribute → claim returns
/// the full pro-rata share of the most recent distribution, even if
/// the bond was purchased between announce and distribute.
contract CentrifugeBondClaim {
    address public immutable principal;
    address public immutable yieldAsset;

    uint256 public totalBondPrincipal;
    mapping(address => uint256) public bondPrincipalOf;
    uint256 public yieldIndex = 1e18;
    mapping(address => uint256) public yieldSnapshot;
    mapping(address => uint256) public claimedYield;

    constructor(address _p, address _y) { principal = _p; yieldAsset = _y; }

    function buyBond(uint256 amt) external {
        require(IERC20(principal).transferFrom(msg.sender, address(this), amt));
        // BUG: caller snapshots the CURRENT yieldIndex on entry, but the
        // distribute() that follows raises yieldIndex for ALL holders —
        // including this brand-new entrant. Their claim from the next
        // distribute is proportional to their full principal, even
        // though they hold for zero time.
        yieldSnapshot[msg.sender] = yieldIndex;
        bondPrincipalOf[msg.sender] += amt;
        totalBondPrincipal += amt;
    }

    function distribute(uint256 amt) external {
        require(IERC20(yieldAsset).transferFrom(msg.sender, address(this), amt));
        if (totalBondPrincipal > 0) {
            yieldIndex += (amt * 1e18) / totalBondPrincipal;
        }
    }

    function claim() external returns (uint256 amt) {
        uint256 delta = yieldIndex - yieldSnapshot[msg.sender];
        amt = (bondPrincipalOf[msg.sender] * delta) / 1e18;
        yieldSnapshot[msg.sender] = yieldIndex;
        require(IERC20(yieldAsset).transfer(msg.sender, amt));
    }

    function withdrawBond(uint256 amt) external {
        bondPrincipalOf[msg.sender] -= amt;
        totalBondPrincipal -= amt;
        require(IERC20(principal).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

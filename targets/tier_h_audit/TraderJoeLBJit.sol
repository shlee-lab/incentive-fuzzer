// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// TraderJoeLBJit — reduction of a TraderJoe Liquidity Book audit-class
/// finding (JIT in a single price bin). LB pools have discrete price
/// bins; an LP who deposits into the ACTIVE bin only captures the next
/// swap's fee and can immediately remove without taking inventory risk.
///
/// Reduction: a single-bin pool with fee accumulator. JIT LP = addToBin
/// → external swap → removeFromBin + claimFee.
contract TraderJoeLBJit {
    address public immutable a;
    address public immutable b;

    uint256 public binA;
    uint256 public binB;
    uint256 public binShares;
    mapping(address => uint256) public binShareOf;
    uint256 public feeAccPerShare;
    mapping(address => uint256) public feeSnapshot;
    mapping(address => uint256) public pendingFee;

    constructor(address _a, address _b) { a = _a; b = _b; }

    function _accrue(address u) internal {
        uint256 delta = feeAccPerShare - feeSnapshot[u];
        pendingFee[u] += (binShareOf[u] * delta) / 1e18;
        feeSnapshot[u] = feeAccPerShare;
    }

    function seedBin(uint256 amtA, uint256 amtB) external {
        require(IERC20(a).transferFrom(msg.sender, address(this), amtA));
        require(IERC20(b).transferFrom(msg.sender, address(this), amtB));
        uint256 sh = amtA + amtB;
        binA += amtA;
        binB += amtB;
        binShares += sh;
        binShareOf[msg.sender] += sh;
        feeSnapshot[msg.sender] = feeAccPerShare;
    }

    function addToBin(uint256 amtA, uint256 amtB) external returns (uint256 sh) {
        _accrue(msg.sender);
        require(IERC20(a).transferFrom(msg.sender, address(this), amtA));
        require(IERC20(b).transferFrom(msg.sender, address(this), amtB));
        // Pro-rata
        sh = (amtA * binShares) / binA + (amtB * binShares) / binB;
        binA += amtA;
        binB += amtB;
        binShares += sh;
        binShareOf[msg.sender] += sh;
    }

    function removeFromBin(uint256 sh) external returns (uint256 amtA, uint256 amtB) {
        _accrue(msg.sender);
        amtA = (sh * binA) / binShares;
        amtB = (sh * binB) / binShares;
        binShareOf[msg.sender] -= sh;
        binShares -= sh;
        binA -= amtA;
        binB -= amtB;
        require(IERC20(a).transfer(msg.sender, amtA));
        require(IERC20(b).transfer(msg.sender, amtB));
    }

    function swapAforB(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(a).transferFrom(msg.sender, address(this), amtIn));
        uint256 fee = amtIn / 100;       // 1% fee
        uint256 swapIn = amtIn - fee;
        amtOut = (swapIn * binB) / (binA + swapIn);
        binA += amtIn;       // fee accumulates in binA
        binB -= amtOut;
        if (binShares > 0) {
            feeAccPerShare += (fee * 1e18) / binShares;
        }
        require(IERC20(b).transfer(msg.sender, amtOut));
    }

    function claimFee() external {
        _accrue(msg.sender);
        uint256 amt = pendingFee[msg.sender];
        pendingFee[msg.sender] = 0;
        require(IERC20(a).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

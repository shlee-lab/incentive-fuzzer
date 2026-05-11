// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// SiloIsolatedArb — reduction of an audit-class finding on Silo
/// Finance's isolated-pool design. Each silo has its own debt/collateral
/// market. A unified user can route between silos to evade per-silo
/// risk limits — borrowing from silo A against collateral that's also
/// pledged in silo B (the protocol thinks they're isolated, but a single
/// user knows both positions).
///
/// Reduction: two silos with separate ledgers. User deposits in A,
/// borrows the limit in A, then ALSO uses the same logical asset in B
/// without the deposit-being-frozen-in-A check.
contract SiloIsolatedArb {
    address public immutable c;
    address public immutable d;

    // Silo A bookkeeping.
    mapping(address => uint256) public colA;
    mapping(address => uint256) public debtA;
    // Silo B bookkeeping.
    mapping(address => uint256) public colB;
    mapping(address => uint256) public debtB;

    uint256 public constant CR_BPS = 15000;
    uint256 public constant BPS    = 10000;

    constructor(address _c, address _d) { c = _c; d = _d; }

    function depositA(uint256 amt) external {
        require(IERC20(c).transferFrom(msg.sender, address(this), amt));
        colA[msg.sender] += amt;
    }

    function withdrawA(uint256 amt) external {
        colA[msg.sender] -= amt;
        require(IERC20(c).transfer(msg.sender, amt));
    }

    function borrowA(uint256 amt) external {
        require((debtA[msg.sender] + amt) * CR_BPS <= colA[msg.sender] * BPS, "ltv A");
        debtA[msg.sender] += amt;
        require(IERC20(d).transfer(msg.sender, amt));
    }

    /// BUG: silo B uses colA + colB as collateral basis (cross-silo
    /// accounting accident). Borrower can deposit ONCE in A, borrow in
    /// A, withdraw, deposit in B as if fresh — the bug is that
    /// borrowB's LTV check uses colA + colB without subtracting any
    /// "already pledged" amount.
    function depositB(uint256 amt) external {
        require(IERC20(c).transferFrom(msg.sender, address(this), amt));
        colB[msg.sender] += amt;
    }
    function borrowB(uint256 amt) external {
        uint256 combined = colA[msg.sender] + colB[msg.sender];
        require((debtB[msg.sender] + amt) * CR_BPS <= combined * BPS, "ltv B");
        debtB[msg.sender] += amt;
        require(IERC20(d).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

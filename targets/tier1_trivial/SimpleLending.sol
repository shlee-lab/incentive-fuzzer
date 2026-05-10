// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// SimpleLending
///
/// Honest behavior:
/// - Borrowers deposit ETH as collateral and borrow ETH against it (150% CR).
/// - When a borrower's position falls below the collateralization threshold,
///   an independent Liquidator repays the debt and seizes the collateral as
///   reward — paid for taking on the recovery work.
///
/// Implicit role-separation assumption (NOT enforced):
/// - Borrower and Liquidator are different parties. The protocol's economics
///   assume a third party performs the liquidation in exchange for the
///   seizable collateral. There is no `msg.sender != user` check in
///   `liquidate`.
///
/// Expected deviation found by the fuzzer:
/// - After their own position becomes underwater, the Borrower calls
///   `liquidate(self)` and recovers the collateral that an honest borrower
///   would have forfeited to a third-party liquidator.
contract SimpleLending {
    address public admin;
    uint256 public price; // 1e18 scale; collateralValue = collateral * price / 1e18
    uint256 public constant CR_BPS = 15000; // 150%
    uint256 public constant BPS = 10000;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor() payable {
        admin = msg.sender;
        price = 1e18;
    }

    function deposit() external payable {
        collateral[msg.sender] += msg.value;
    }

    function borrow(uint256 amount) external {
        uint256 newDebt = debt[msg.sender] + amount;
        uint256 colValue = (collateral[msg.sender] * price) / 1e18;
        require(newDebt * CR_BPS <= colValue * BPS, "undercollateralized");
        require(address(this).balance >= amount, "insufficient liquidity");
        debt[msg.sender] = newDebt;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
    }

    function isUnderwater(address user) public view returns (bool) {
        if (debt[user] == 0) return false;
        uint256 colValue = (collateral[user] * price) / 1e18;
        return debt[user] * CR_BPS > colValue * BPS;
    }

    function liquidate(address user) external payable {
        require(isUnderwater(user), "not underwater");
        uint256 debtAmt = debt[user];
        require(msg.value >= debtAmt, "must repay debt");
        uint256 collateralAmt = collateral[user];
        debt[user] = 0;
        collateral[user] = 0;
        if (msg.value > debtAmt) {
            (bool refundOk, ) = payable(msg.sender).call{value: msg.value - debtAmt}("");
            require(refundOk, "refund failed");
        }
        (bool payoutOk, ) = payable(msg.sender).call{value: collateralAmt}("");
        require(payoutOk, "payout failed");
    }

    function setPrice(uint256 newPrice) external {
        require(msg.sender == admin, "not admin");
        price = newPrice;
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// CompoundCErc20 — minimal port of Compound v2's CErc20 lending pattern,
/// with the "canonical safe" interpretation that explicitly forbids
/// self-liquidation (`require(borrower != msg.sender)` in liquidateBorrow).
///
/// Real Compound v2 does NOT have this require — it leaves the protocol
/// economically open to "self-liquidation captures the incentive bonus,"
/// which is a documented quirk rather than a bug. For Tier B FP-control
/// validation we model the SAFE variant: borrower != liquidator enforced
/// at the contract level. Other Compound v2 mechanisms preserved:
/// closeFactor (50%), liquidationIncentive (8%), CR-bounded borrow.
///
/// Expected fuzzer outcome: NO TP findings above noise floor — every
/// liquidation by the borrower against themselves reverts, and standard
/// liquidation by the Liquidator role yields the honest baseline.
contract CompoundCErc20 {
    IERC20 public immutable underlying;
    uint256 public totalCash;
    uint256 public totalBorrows;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;          // cToken shares
    mapping(address => uint256) public borrowBalanceOf;    // debt in underlying

    uint256 public price = 1e18;                            // collateral price (1e18 scale)
    uint256 public constant COLLATERAL_FACTOR = 75;         // 75%
    uint256 public constant LIQUIDATION_INCENTIVE = 108;    // 1.08x
    uint256 public constant CLOSE_FACTOR = 50;              // 50%
    address public admin;

    constructor(address _u) {
        underlying = IERC20(_u);
        admin = msg.sender;
    }

    function exchangeRate() public view returns (uint256) {
        if (totalSupply == 0) return 1e18;
        return ((totalCash + totalBorrows) * 1e18) / totalSupply;
    }

    function mint(uint256 amount) external {
        require(amount > 0, "zero");
        uint256 rate = exchangeRate();
        require(underlying.transferFrom(msg.sender, address(this), amount), "xfer");
        uint256 mintTokens = (amount * 1e18) / rate;
        balanceOf[msg.sender] += mintTokens;
        totalSupply += mintTokens;
        totalCash += amount;
    }

    function redeem(uint256 cTokens) external {
        require(cTokens > 0, "zero");
        uint256 amount = (cTokens * exchangeRate()) / 1e18;
        balanceOf[msg.sender] -= cTokens;
        totalSupply -= cTokens;
        require(totalCash >= amount, "no liquidity");
        totalCash -= amount;
        // CR check after redeem
        uint256 colValue = (balanceOf[msg.sender] * exchangeRate() * price) / 1e36;
        require(borrowBalanceOf[msg.sender] * 100 <= colValue * COLLATERAL_FACTOR, "shortfall");
        require(underlying.transfer(msg.sender, amount), "xfer out");
    }

    function borrow(uint256 amount) external {
        uint256 colValue = (balanceOf[msg.sender] * exchangeRate() * price) / 1e36;
        uint256 newDebt = borrowBalanceOf[msg.sender] + amount;
        require(newDebt * 100 <= colValue * COLLATERAL_FACTOR, "shortfall");
        require(totalCash >= amount, "no liquidity");
        borrowBalanceOf[msg.sender] = newDebt;
        totalBorrows += amount;
        totalCash -= amount;
        require(underlying.transfer(msg.sender, amount), "xfer out");
    }

    function repayBorrow(uint256 amount) external {
        uint256 cur = borrowBalanceOf[msg.sender];
        uint256 actual = amount > cur ? cur : amount;
        require(underlying.transferFrom(msg.sender, address(this), actual), "xfer");
        borrowBalanceOf[msg.sender] = cur - actual;
        totalBorrows -= actual;
        totalCash += actual;
    }

    function liquidateBorrow(address borrower, uint256 repayAmount) external {
        // CANONICAL FIX (vs real Compound v2): forbid self-liquidation.
        require(borrower != msg.sender, "self-liquidation forbidden");
        require(repayAmount > 0, "zero repay");
        // Check underwater
        uint256 colValue = (balanceOf[borrower] * exchangeRate() * price) / 1e36;
        uint256 debt = borrowBalanceOf[borrower];
        require(debt * 100 > colValue * COLLATERAL_FACTOR, "not underwater");
        // closeFactor cap
        uint256 maxRepay = (debt * CLOSE_FACTOR) / 100;
        require(repayAmount <= maxRepay, "too much");
        // Liquidator pays repayAmount
        require(underlying.transferFrom(msg.sender, address(this), repayAmount), "xfer");
        borrowBalanceOf[borrower] = debt - repayAmount;
        totalBorrows -= repayAmount;
        totalCash += repayAmount;
        // Seize cTokens at incentive (in cToken units, computed via current rate).
        uint256 seizeTokens = (repayAmount * LIQUIDATION_INCENTIVE * 1e18) / (100 * exchangeRate());
        require(balanceOf[borrower] >= seizeTokens, "insufficient collateral");
        balanceOf[borrower] -= seizeTokens;
        balanceOf[msg.sender] += seizeTokens;
    }

    function setPrice(uint256 newPrice) external {
        require(msg.sender == admin, "not admin");
        price = newPrice;
    }
}

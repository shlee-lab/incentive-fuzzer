// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// LidoLite — minimal port of the Lido liquid-staking pattern (validator
/// runs nodes, depositors get rebasing shares; rewards 10% to validator,
/// 90% rebased to depositors). Single validator, no withdrawal queue, no
/// node-operator registry — just the share/exchange-rate accounting and
/// the role-separation between validator and depositors.
///
/// Defense over our SimpleStaking reproduction:
/// - `validator` is set in constructor and immutable. User can't
///   register themselves to claim the fee.
/// - `exchangeRate` reads from internal `totalUnderlying` accumulator,
///   NOT from `stakeToken.balanceOf(address(this))` — direct ERC20
///   donations to the contract DO NOT inflate share value, so the
///   first-depositor inflation pattern can't manipulate the rate.
/// - `distributeRewards` is admin-only.
///
/// Expected fuzzer outcome: NO TP findings.
contract LidoLite {
    IERC20 public immutable stakeToken;
    address public immutable validator;
    address public immutable admin;
    uint256 public totalShares;
    uint256 public totalUnderlying;
    mapping(address => uint256) public sharesOf;

    uint256 public constant VALIDATOR_FEE_BPS = 1000; // 10%

    constructor(address _stake, address _validator, address _admin) {
        stakeToken = IERC20(_stake);
        validator = _validator;
        admin = _admin;
    }

    function exchangeRate() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalUnderlying * 1e18) / totalShares;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "xfer");
        uint256 shares = (amount * 1e18) / exchangeRate();
        require(shares > 0, "ZERO_SHARES");
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        totalUnderlying += amount;
    }

    function withdraw(uint256 shares) external {
        require(shares > 0, "zero");
        uint256 amount = (shares * exchangeRate()) / 1e18;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalUnderlying -= amount;
        require(stakeToken.transfer(msg.sender, amount), "xfer");
    }

    /// Oracle/admin reports rewards. 10% minted to validator as shares;
    /// 90% accrues into totalUnderlying (depositors rebase up).
    function distributeRewards(uint256 amount) external {
        require(msg.sender == admin, "not admin");
        require(amount > 0, "zero");
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "xfer");
        if (totalShares > 0) {
            uint256 fee = (amount * VALIDATOR_FEE_BPS) / 10000;
            uint256 validatorShares = (fee * totalShares) / totalUnderlying;
            sharesOf[validator] += validatorShares;
            totalShares += validatorShares;
        }
        totalUnderlying += amount;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// EulerDonate — reduction of the Euler Finance attack (2023-03, ~$197M).
///
/// Original incident: Euler had a `donateToReserves(amount)` function
/// that decremented the caller's eToken balance but did NOT decrement
/// their dToken (debt) liability. After donate, the caller had less
/// equity but the same debt — pushing themselves underwater. A "soft"
/// liquidator (the attacker themselves) could then liquidate the
/// underwater position and capture the discount.
///
/// Implicit assumption (NOT enforced):
/// - donateToReserves preserves user solvency.
///
/// Expected deviation:
/// - deposit -> borrow -> donateToReserves -> liquidate(self)
contract EulerDonate {
    address public immutable underlying;

    mapping(address => uint256) public eToken;      // equity (positive)
    mapping(address => uint256) public dToken;      // debt (positive)
    uint256 public reserves;
    uint256 public constant LIQ_BPS  = 11000;       // 110% of debt covered by collateral seizure
    uint256 public constant LIQ_DISC = 1000;        // 10% discount for liquidator
    uint256 public constant BPS      = 10000;

    constructor(address _u) { underlying = _u; }

    function deposit(uint256 amt) external {
        require(IERC20(underlying).transferFrom(msg.sender, address(this), amt));
        eToken[msg.sender] += amt;
    }

    function withdraw(uint256 amt) external {
        eToken[msg.sender] -= amt;
        require(IERC20(underlying).transfer(msg.sender, amt));
    }

    function borrow(uint256 amt) external {
        // 80% LTV
        require(dToken[msg.sender] + amt <= (eToken[msg.sender] * 8000) / BPS, "ltv");
        dToken[msg.sender] += amt;
        require(IERC20(underlying).transfer(msg.sender, amt));
    }

    function repay(uint256 amt) external {
        require(IERC20(underlying).transferFrom(msg.sender, address(this), amt));
        dToken[msg.sender] -= amt;
    }

    /// THE BUG: decrements caller's eToken, transfers underlying to reserves,
    /// but never touches dToken. Caller can become underwater on demand.
    function donateToReserves(uint256 amt) external {
        eToken[msg.sender] -= amt;
        reserves += amt;
    }

    /// Soft-liquidation: anyone can call once a user is underwater (debt > equity).
    /// Liquidator pays debt, seizes 110% of debt as equity (discount built in).
    function liquidate(address user) external {
        require(dToken[user] > eToken[user], "not underwater");
        uint256 d = dToken[user];
        require(IERC20(underlying).transferFrom(msg.sender, address(this), d));
        dToken[user] = 0;
        uint256 seize = (d * LIQ_BPS) / BPS;
        if (seize > eToken[user] + reserves) {
            seize = eToken[user] + reserves;
        }
        // From user's residual equity first, then from reserves (the donation).
        uint256 fromUser = seize > eToken[user] ? eToken[user] : seize;
        eToken[user] -= fromUser;
        uint256 fromReserves = seize - fromUser;
        if (fromReserves > reserves) fromReserves = reserves;
        reserves -= fromReserves;
        eToken[msg.sender] += seize;
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

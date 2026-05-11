// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// CurveCrvUSDLiq — reduction of liquidator-MEV in Curve crvUSD-style
/// soft-liquidation markets (audit pattern, also relevant to Aave /
/// Compound MEV).
///
/// Pattern: when a borrower goes underwater, ANY external actor can
/// liquidate them at a discount. The intended incentive is to attract
/// independent liquidators. But the BORROWER can also liquidate
/// themselves and capture the discount that an external liquidator
/// would have earned — flipping a 5% loss into a 5% gain.
///
/// Reduction: standard lending; borrower can call liquidate(self) once
/// underwater. There is no msg.sender != user check.
contract CurveCrvUSDLiq {
    address public immutable asset;
    uint256 public price = 1e18;
    uint256 public constant CR_BPS  = 15000;
    uint256 public constant BPS     = 10000;
    uint256 public constant LIQ_BONUS_BPS = 500;  // 5% liquidator bonus

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(address _asset) { asset = _asset; }

    function deposit(uint256 amt) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amt));
        collateral[msg.sender] += amt;
    }

    function borrow(uint256 amt) external {
        uint256 colValue = (collateral[msg.sender] * price) / 1e18;
        require((debt[msg.sender] + amt) * CR_BPS <= colValue * BPS, "ltv");
        debt[msg.sender] += amt;
        require(IERC20(asset).transfer(msg.sender, amt));
    }

    function setPrice(uint256 newPrice) external { price = newPrice; }

    function isUnderwater(address user) public view returns (bool) {
        if (debt[user] == 0) return false;
        return debt[user] * CR_BPS > collateral[user] * price * BPS / 1e18;
    }

    function liquidate(address user) external {
        require(isUnderwater(user), "not underwater");
        uint256 d = debt[user];
        require(IERC20(asset).transferFrom(msg.sender, address(this), d));
        uint256 seize = collateral[user];
        debt[user] = 0;
        collateral[user] = 0;
        // 5% bonus paid out of the seized collateral (so liquidator gets MORE than just repayment).
        require(IERC20(asset).transfer(msg.sender, seize));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

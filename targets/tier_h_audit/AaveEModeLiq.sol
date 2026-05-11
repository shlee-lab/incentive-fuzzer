// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// AaveEModeLiq — reduction of an OpenZeppelin audit-class finding on
/// Aave V3 eMode liquidation. In eMode, correlated assets (e.g.,
/// USDC/USDT/DAI) have relaxed LTV requirements (e.g., 97%) AND elevated
/// liquidation bonuses. A user who is *themselves* underwater (after
/// borrowing at 97% LTV and a price wiggle) can call liquidate(self)
/// and collect the elevated bonus, ending up with MORE collateral than
/// they started with.
contract AaveEModeLiq {
    address public immutable collateral;
    address public immutable debtAsset;

    uint256 public collateralPrice = 1e18;
    uint256 public debtPrice = 1e18;
    uint256 public constant E_MODE_LTV_BPS    = 9700;     // 97%
    uint256 public constant E_MODE_BONUS_BPS  = 600;      // 6%
    uint256 public constant BPS = 10000;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    constructor(address _c, address _d) { collateral = _c; debtAsset = _d; }

    function deposit(uint256 amt) external {
        require(IERC20(collateral).transferFrom(msg.sender, address(this), amt));
        collateralOf[msg.sender] += amt;
    }

    function borrow(uint256 amt) external {
        uint256 colValue = (collateralOf[msg.sender] * collateralPrice) / 1e18;
        uint256 maxDebt = (colValue * E_MODE_LTV_BPS) / BPS;
        uint256 newDebt = debtOf[msg.sender] + amt;
        require((newDebt * debtPrice) / 1e18 <= maxDebt, "ltv");
        debtOf[msg.sender] = newDebt;
        require(IERC20(debtAsset).transfer(msg.sender, amt));
    }

    function setPrices(uint256 cP, uint256 dP) external {
        collateralPrice = cP;
        debtPrice = dP;
    }

    function isUnderwater(address u) public view returns (bool) {
        uint256 colValue = (collateralOf[u] * collateralPrice) / 1e18;
        uint256 debtValue = (debtOf[u] * debtPrice) / 1e18;
        return debtValue > (colValue * E_MODE_LTV_BPS) / BPS;
    }

    function liquidate(address user) external {
        require(isUnderwater(user), "not underwater");
        uint256 d = debtOf[user];
        require(IERC20(debtAsset).transferFrom(msg.sender, address(this), d));
        debtOf[user] = 0;
        // Seize covers (debt + 6% bonus) worth of collateral. The bonus
        // portion is sourced from pool reserves (the contract's collateral
        // balance above what user-tracked collateralOf already accounts for).
        uint256 debtValue = (d * debtPrice) / 1e18;
        uint256 seizeValue = (debtValue * (BPS + E_MODE_BONUS_BPS)) / BPS;
        uint256 seizeCollateral = (seizeValue * 1e18) / collateralPrice;
        uint256 fromUser = seizeCollateral > collateralOf[user]
            ? collateralOf[user] : seizeCollateral;
        collateralOf[user] -= fromUser;
        require(IERC20(collateral).transfer(msg.sender, seizeCollateral));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// MimMetapoolFlash — reduction of MIM/Spell Curve metapool arbitrage
/// attacks. Metapool prices depend on the relative ratio of MIM to
/// 3CRV LP; large imbalance trades through MIM/3CRV → 3CRV/USDC chain
/// can siphon value from another LP without the protocol enforcing
/// any path-cost on the imbalance.
///
/// Reduction: a metapool with MIM ↔ 3CRV. Attacker imbalances by swapping
/// large MIM in, then withdraws an LP position at the now-favorable
/// ratio.
contract MimMetapoolFlash {
    address public immutable mim;
    address public immutable threeCrv;

    uint256 public reserveMim;
    uint256 public reserve3crv;
    uint256 public lpSupply;
    mapping(address => uint256) public lpOf;

    constructor(address _m, address _t) { mim = _m; threeCrv = _t; }

    function seed(uint256 amtM, uint256 amt3) external {
        require(IERC20(mim).transferFrom(msg.sender, address(this), amtM));
        require(IERC20(threeCrv).transferFrom(msg.sender, address(this), amt3));
        uint256 mint = _sqrt(amtM * amt3);
        reserveMim += amtM;
        reserve3crv += amt3;
        lpSupply += mint;
        lpOf[msg.sender] += mint;
    }

    function swapMimFor3crv(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(mim).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveMim * reserve3crv;
        uint256 newRm = reserveMim + amtIn;
        uint256 newR3 = k / newRm;
        amtOut = reserve3crv - newR3;
        reserveMim = newRm;
        reserve3crv = newR3;
        require(IERC20(threeCrv).transfer(msg.sender, amtOut));
    }

    function swap3crvForMim(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(threeCrv).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveMim * reserve3crv;
        uint256 newR3 = reserve3crv + amtIn;
        uint256 newRm = k / newR3;
        amtOut = reserveMim - newRm;
        reserveMim = newRm;
        reserve3crv = newR3;
        require(IERC20(mim).transfer(msg.sender, amtOut));
    }

    /// BUG: imbalanced removeLiquidity gives the LP holder back the
    /// imbalanced reserve ratio, not the fair-market ratio. Combine with
    /// pre-removal imbalance trade by the SAME actor.
    function removeLiquidity(uint256 lpBurn) external returns (uint256 amtM, uint256 amt3) {
        amtM = (lpBurn * reserveMim) / lpSupply;
        amt3 = (lpBurn * reserve3crv) / lpSupply;
        lpOf[msg.sender] -= lpBurn;
        lpSupply -= lpBurn;
        reserveMim -= amtM;
        reserve3crv -= amt3;
        require(IERC20(mim).transfer(msg.sender, amtM));
        require(IERC20(threeCrv).transfer(msg.sender, amt3));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y/2 + 1;
            while (x < z) { z = x; x = (y/x + x)/2; }
        } else if (y != 0) { z = 1; }
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

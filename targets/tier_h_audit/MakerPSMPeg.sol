// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// MakerPSMPeg — reduction of a Maker DAO Peg Stability Module
/// audit-class concern (no individual incident — pattern flagged in
/// multiple audits): PSM swaps USDC ↔ DAI at 1:1 with a small fee.
/// When PSM is empty on one side, arbitrage between PSM and the
/// secondary AMM can drain the protocol's surplus buffer.
///
/// Reduction: PSM has reserveUSDC and reserveDAI. AMM has reserveUSDC
/// and reserveDAI at a depegged price (e.g., 1 USDC = 1.05 DAI). Arber
/// loops PSM (mint DAI from USDC at 1:1) → AMM (sell DAI for USDC at
/// 1.05) → PSM (mint more) until PSM USDC empty.
contract MakerPSMPeg {
    address public immutable usdc;
    address public immutable dai;

    uint256 public psmUsdc;
    uint256 public psmDai;
    uint256 public ammUsdc;
    uint256 public ammDai;

    constructor(address _u, address _d) { usdc = _u; dai = _d; }

    function seed(uint256 psmU, uint256 psmD, uint256 ammU, uint256 ammD) external {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), psmU + ammU));
        require(IERC20(dai).transferFrom(msg.sender, address(this), psmD + ammD));
        psmUsdc += psmU;
        psmDai += psmD;
        ammUsdc += ammU;
        ammDai += ammD;
    }

    /// PSM: 1 USDC → 1 DAI (1:1, no fee in this reduction).
    function psmMintDai(uint256 usdcIn) external returns (uint256 daiOut) {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), usdcIn));
        daiOut = usdcIn;
        require(psmDai >= daiOut, "psm out of DAI");
        psmUsdc += usdcIn;
        psmDai -= daiOut;
        require(IERC20(dai).transfer(msg.sender, daiOut));
    }

    /// PSM: 1 DAI → 1 USDC.
    function psmMintUsdc(uint256 daiIn) external returns (uint256 usdcOut) {
        require(IERC20(dai).transferFrom(msg.sender, address(this), daiIn));
        usdcOut = daiIn;
        require(psmUsdc >= usdcOut, "psm out of USDC");
        psmDai += daiIn;
        psmUsdc -= usdcOut;
        require(IERC20(usdc).transfer(msg.sender, usdcOut));
    }

    function swapDaiForUsdc(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(dai).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = ammUsdc * ammDai;
        uint256 newRd = ammDai + amtIn;
        uint256 newRu = k / newRd;
        amtOut = ammUsdc - newRu;
        ammUsdc = newRu;
        ammDai = newRd;
        require(IERC20(usdc).transfer(msg.sender, amtOut));
    }

    function swapUsdcForDai(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = ammUsdc * ammDai;
        uint256 newRu = ammUsdc + amtIn;
        uint256 newRd = k / newRu;
        amtOut = ammDai - newRd;
        ammUsdc = newRu;
        ammDai = newRd;
        require(IERC20(dai).transfer(msg.sender, amtOut));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

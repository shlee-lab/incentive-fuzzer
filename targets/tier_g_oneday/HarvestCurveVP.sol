// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// HarvestCurveVP — reduction of the Harvest Finance attack (2020-10, ~$34M).
///
/// Original incident: Harvest's fUSDC/fUSDT vaults priced shares using
/// the Curve pool's `get_virtual_price()` (a function of total LP supply
/// and pool token balances). Attacker flash-borrowed USDT, imbalanced
/// the Curve pool by swapping USDT→USDC, depositing into vault at the
/// LOW share price, swapping USDC→USDT (rebalancing the pool), and
/// withdrawing at the now-RESTORED higher share price. Repeated many
/// times the imbalance trick.
///
/// Honest behavior:
/// - Users deposit underlying (USDC) into vault, get shares priced via
///   Curve VP. Withdraw later at whatever VP is then.
///
/// Implicit assumption (NOT enforced):
/// - Curve get_virtual_price() is not manipulable atomically. Reality:
///   one large imbalance trade can move it 1-2% within a single block.
///
/// Expected deviation:
/// - swapImbalance → deposit → swapRebalance → withdraw
contract HarvestCurveVP {
    address public immutable usdc;
    address public immutable usdt;

    // Curve-like balanced pool. We model just two tokens for simplicity;
    // real Curve has 3-4 and uses a complex amplification curve. The bug
    // — VP is a function of pool state — is preserved.
    uint256 public reserveUSDC;
    uint256 public reserveUSDT;

    // Vault bookkeeping. Shares are priced by Curve VP at the moment of
    // deposit / withdraw.
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;
    uint256 public vaultUSDC;   // underlying held by vault

    constructor(address _usdc, address _usdt) {
        usdc = _usdc;
        usdt = _usdt;
    }

    function seed(uint256 amtUSDC, uint256 amtUSDT) external {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtUSDC));
        require(IERC20(usdt).transferFrom(msg.sender, address(this), amtUSDT));
        reserveUSDC += amtUSDC;
        reserveUSDT += amtUSDT;
    }

    /// "Virtual price" — sum of reserves / something. Curve uses a more
    /// complex formula; what matters for the bug is that VP RISES when
    /// the pool is balanced and FALLS while imbalanced.
    /// We model: VP = 1e18 * (reserveUSDC + reserveUSDT) / max(reserveUSDC, reserveUSDT) / 2.
    /// Balanced pool → VP ≈ 1e18. Imbalanced → VP < 1e18.
    function virtualPrice() public view returns (uint256) {
        uint256 a = reserveUSDC; uint256 b = reserveUSDT;
        if (a == 0 || b == 0) return 1e18;
        uint256 hi = a >= b ? a : b;
        return (1e18 * (a + b)) / (hi * 2);
    }

    // Swap with light fee — purely to allow imbalance trades.
    function swapUsdtForUsdc(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(usdt).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveUSDC * reserveUSDT;
        uint256 newRt = reserveUSDT + amtIn;
        uint256 newRc = k / newRt;
        amtOut = reserveUSDC - newRc;
        reserveUSDC = newRc;
        reserveUSDT = newRt;
        require(IERC20(usdc).transfer(msg.sender, amtOut));
    }
    function swapUsdcForUsdt(uint256 amtIn) external returns (uint256 amtOut) {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amtIn));
        uint256 k = reserveUSDC * reserveUSDT;
        uint256 newRc = reserveUSDC + amtIn;
        uint256 newRt = k / newRc;
        amtOut = reserveUSDT - newRt;
        reserveUSDC = newRc;
        reserveUSDT = newRt;
        require(IERC20(usdt).transfer(msg.sender, amtOut));
    }

    // Vault — deposit USDC and receive shares priced at current VP.
    function deposit(uint256 amt) external returns (uint256 shares) {
        require(IERC20(usdc).transferFrom(msg.sender, address(this), amt));
        uint256 vp = virtualPrice();
        shares = (amt * 1e18) / vp;
        totalShares += shares;
        shareOf[msg.sender] += shares;
        vaultUSDC += amt;
    }

    function withdraw(uint256 shares) external returns (uint256 amt) {
        uint256 vp = virtualPrice();
        amt = (shares * vp) / 1e18;
        if (amt > vaultUSDC) amt = vaultUSDC;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        vaultUSDC -= amt;
        require(IERC20(usdc).transfer(msg.sender, amt));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

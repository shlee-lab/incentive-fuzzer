// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// MonetrixSUSDM — single-file standalone of the Monetrix sUSDM yield
/// vault currently undergoing audit on Code4rena (2026-04-monetrix).
///
/// Original source: https://github.com/code-423n4/2026-04-monetrix
/// /src/tokens/sUSDM.sol — ERC-4626-style staked stablecoin vault with
/// unstake cooldown, escrow isolation, and admin-only yield injection.
///
/// We strip OpenZeppelin Upgradeable + governance modifiers and inline
/// only the incentive-relevant surface so our single-contract spec can
/// attach to it. The audit-grade defenses we want to test against:
///
///   - _decimalsOffset() == 6 (OZ ERC4626 virtual shares — blocks
///     first-depositor share inflation)
///   - injectYield gated to onlyVault (no permissionless yield trigger,
///     so JIT yield front-run blocked)
///   - withdraw / redeem revert (must go through cooldown queue)
///   - cooldownShares burns shares + isolates assets at burn-time
///     exchange rate (so post-burn yield can't accrue to the request)
///   - empty-vault yield rejected (require totalSupply() > 0)
///
/// Question for the fuzzer: with these guards in place, is there ANY
/// rational deviation profitable?

contract MonetrixSUSDM {
    // ----- ERC20 (sUSDM share token) -----
    string public constant name   = "Staked USDM";
    string public constant symbol = "sUSDM";
    uint8  public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ----- ERC4626 underlying (USDM) — we treat it as a passive ERC20 owned by us -----
    address public immutable asset;       // USDM address

    // ----- Yield bookkeeping -----
    uint256 public totalYieldInjected;

    // ----- Cooldown queue -----
    struct UnstakeRequest {
        address owner;
        uint256 sharesAmount;
        uint256 usdmAmount;
        uint256 cooldownEnd;
    }
    uint256 public nextRequestId;
    uint256 public totalPendingClaims;
    mapping(uint256 => UnstakeRequest) public unstakeRequests;

    // ----- Admin roles -----
    address public immutable vault;       // only vault can injectYield
    uint256 public constant COOLDOWN = 7 days;
    uint256 public constant DECIMALS_OFFSET = 10**6;   // OZ-style virtual share offset

    constructor(address _asset, address _vault) {
        asset = _asset;
        vault = _vault;
    }

    // ----- ERC4626 conversion (with virtual-share offset) -----
    function totalAssets() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) - totalPendingClaims;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        // shares = assets * (totalSupply + offset) / (totalAssets + 1)
        return (assets * (totalSupply + DECIMALS_OFFSET)) / (totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * (totalAssets() + 1)) / (totalSupply + DECIMALS_OFFSET);
    }

    // ----- ERC4626 mutating -----
    function deposit(uint256 assets) external returns (uint256 shares) {
        require(IERC20(asset).transferFrom(msg.sender, address(this), assets));
        shares = convertToShares(assets);
        require(shares > 0, "zero shares");
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    function mint(uint256 shares) external returns (uint256 assets) {
        // assets = shares * (totalAssets + 1) / (totalSupply + offset), rounded up
        uint256 numerator = shares * (totalAssets() + 1);
        uint256 denominator = totalSupply + DECIMALS_OFFSET;
        assets = (numerator + denominator - 1) / denominator;
        require(IERC20(asset).transferFrom(msg.sender, address(this), assets));
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    // Withdraw / redeem MUST revert — use cooldown.
    function withdraw(uint256, address, address) external pure { revert("use cooldown"); }
    function redeem(uint256, address, address)   external pure { revert("use cooldown"); }

    // ----- Cooldown unstake -----
    function cooldownShares(uint256 shares) external returns (uint256 requestId) {
        require(shares > 0, "zero");
        require(balanceOf[msg.sender] >= shares, "balance");
        uint256 assets = convertToAssets(shares);
        require(assets > 0, "zero assets");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        totalPendingClaims += assets;
        requestId = nextRequestId++;
        unstakeRequests[requestId] = UnstakeRequest({
            owner: msg.sender,
            sharesAmount: shares,
            usdmAmount: assets,
            cooldownEnd: block.timestamp + COOLDOWN
        });
    }

    function claimUnstake(uint256 requestId) external {
        UnstakeRequest memory r = unstakeRequests[requestId];
        require(r.usdmAmount > 0, "already claimed");
        require(msg.sender == r.owner, "not owner");
        require(block.timestamp >= r.cooldownEnd, "cooldown");
        delete unstakeRequests[requestId];
        totalPendingClaims -= r.usdmAmount;
        require(IERC20(asset).transfer(msg.sender, r.usdmAmount));
    }

    // ----- Yield injection — vault only -----
    function injectYield(uint256 amount) external {
        require(msg.sender == vault, "only vault");
        require(amount > 0, "zero yield");
        require(totalSupply > 0, "empty vault");   // empty-vault yield blocked
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        totalYieldInjected += amount;
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

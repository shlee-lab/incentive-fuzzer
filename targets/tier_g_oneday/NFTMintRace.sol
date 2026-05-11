// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// NFTMintRace — reduction of a generic "limited mint allowlist" pattern
/// (recurring audit class across NFT protocols, Pudgy / Bayc / Azuki).
///
/// Pattern: mintPublic() has a per-block hard cap (e.g., max 5 mints per
/// block to "fairly distribute"). Each mint costs `price`, but the
/// secondary-market resale value is FAR higher than `price`. A rational
/// attacker mints the cap themselves, denying allowlist users — net
/// profit = cap * (resale - price).
///
/// Reduction: anyone can call mint() per block, each call gives 1 NFT
/// for `price`. The contract holds a `floorPrice` representing fair
/// secondary value (higher than price). At end of mint window, holders
/// can `sellAtFloor()` to receive floorPrice.
contract NFTMintRace {
    address public immutable paymentToken;

    uint256 public constant PRICE       = 1e18;       // 1 token per mint
    uint256 public constant FLOOR_PRICE = 10e18;      // 10 tokens floor (10x markup)
    uint256 public constant MAX_PER_BLOCK = 5;

    uint256 public lastBlock;
    uint256 public mintedThisBlock;
    mapping(address => uint256) public balanceOf;
    uint256 public treasury;

    constructor(address _payment) { paymentToken = _payment; }

    function fundFloor(uint256 amt) external {
        require(IERC20(paymentToken).transferFrom(msg.sender, address(this), amt));
        treasury += amt;
    }

    function mint(uint256 count) external {
        if (block.number != lastBlock) {
            lastBlock = block.number;
            mintedThisBlock = 0;
        }
        require(mintedThisBlock + count <= MAX_PER_BLOCK, "cap");
        require(IERC20(paymentToken).transferFrom(msg.sender, address(this), PRICE * count));
        balanceOf[msg.sender] += count;
        mintedThisBlock += count;
        treasury += PRICE * count;
    }

    function sellAtFloor(uint256 count) external {
        balanceOf[msg.sender] -= count;
        uint256 payout = FLOOR_PRICE * count;
        if (payout > treasury) payout = treasury;
        treasury -= payout;
        require(IERC20(paymentToken).transfer(msg.sender, payout));
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

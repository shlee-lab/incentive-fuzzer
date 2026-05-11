// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRORVault {
    function pricePerShare() external view returns (uint256);
}

/// StalePriceConsumer — pays bonus proportional to RORVault.pricePerShare.
/// During a vault.withdraw callback the price is inflated, so a caller that
/// queries claimBonus inside the callback drains the consumer's reserve.
contract StalePriceConsumer {
    IRORVault public vault;

    constructor(address _vault) payable {
        vault = IRORVault(_vault);
    }

    function claimBonus() external {
        // Bonus is denominated in ETH and scales with the (queried) price.
        // For honest queries, price = 1e18, so bonus = a small fixed amount.
        // During RoR, price >> 1e18 and bonus is correspondingly inflated.
        uint256 price = vault.pricePerShare();
        uint256 bonus = (1 ether * price) / 1e18; // 1 ETH * price ratio
        require(address(this).balance >= bonus, "consumer drained");
        (bool ok, ) = msg.sender.call{value: bonus}("");
        require(ok, "consumer xfer failed");
    }

    receive() external payable {}
}

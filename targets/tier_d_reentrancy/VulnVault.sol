// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// VulnVault — textbook reentrancy bug. Caller can withdraw repeatedly
/// during the external call before the balance is zeroed out.
contract VulnVault {
    mapping(address => uint256) public balanceOf;

    constructor() payable {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amt = balanceOf[msg.sender];
        require(amt > 0, "no balance");
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "transfer failed");
        balanceOf[msg.sender] = 0;   // BUG: should be set BEFORE the external call
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

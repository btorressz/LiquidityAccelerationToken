// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./LiquidityAccelerationToken.sol"; // Ensure the interface ILatToken is in your main contract

contract MockLAT is ERC20, Ownable, ILatToken {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {}

    /// @notice Allows the owner (deployer) to mint tokens for testing.
    /// @param to The address that will receive the minted tokens.
    /// @param amount The amount of tokens to mint.
    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }
}

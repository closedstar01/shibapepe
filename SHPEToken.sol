// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title ShibaPepe Token ($SHPE)
 * @author ShibaPepe Team
 * @dev ERC-20 Token - Total Supply: 1 Trillion
 * @notice For Base Network
 * @custom:security-note This token is a standard ERC20 without fee-on-transfer or rebasing mechanics
 * @custom:security-note Uses Ownable2Step for safer ownership transfer
 */
contract SHPEToken is ERC20, Ownable2Step {
    /// @notice Total token supply: 1 Trillion tokens with 18 decimals
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000_000 * 10**18; // 1 Trillion

    /**
     * @notice Initializes the token contract
     * @dev Mints total supply to deployer
     */
    constructor() ERC20("Shiba Pepe", "SHPE") Ownable(msg.sender) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /**
     * @dev Burn (destroy) tokens
     * @param amount Amount to burn
     * @notice Only owner can burn tokens to prevent accidental burns by users
     * @custom:security-note Access control intentionally added - owner-only function
     */
    function burn(uint256 amount) external onlyOwner {
        _burn(msg.sender, amount);
    }
}

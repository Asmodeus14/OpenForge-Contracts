// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title TestUSDC
 * @notice A six-decimal test token for the Sepolia deployment.
 *
 * Two changes from the version this replaces, both of which blocked people
 * from actually using the product:
 *
 * - **It has a faucet.** The old token minted its entire supply to the
 *   deployer and exposed no `mint`, so the only way for a new user to obtain
 *   test tokens was to ask the deployer to send some by hand.
 * - **It supports EIP-2612 permit**, which lets an escrow be approved and
 *   funded in a single transaction instead of two.
 */
contract TestUSDC is ERC20, ERC20Permit {
    error FaucetLimit();
    error FaucetCooldown(uint256 availableAt);

    uint256 public constant FAUCET_AMOUNT = 10_000e6;
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    mapping(address => uint256) public lastFaucetClaim;

    constructor() ERC20("Test USDC", "tUSDC") ERC20Permit("Test USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints test tokens to the caller. Worthless by construction.
    function faucet() external {
        uint256 last = lastFaucetClaim[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_COOLDOWN) {
            revert FaucetCooldown(last + FAUCET_COOLDOWN);
        }
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}

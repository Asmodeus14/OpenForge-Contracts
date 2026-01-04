// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestUSDC is ERC20 {
    constructor() ERC20("Test USD Coin", "tUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    // USDC-style decimals
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

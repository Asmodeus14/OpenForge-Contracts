require('@nomicfoundation/hardhat-toolbox');
require('dotenv').config();

/**
 * Build configuration.
 *
 * The optimizer was DISABLED in every artifact this repo shipped. That is the
 * single most expensive line in the project: an escrow is deployed once per
 * project by an end user, so deployment gas is a direct, recurring,
 * user-facing charge, and unoptimised bytecode inflates both it and every
 * subsequent call.
 *
 * `runs` is low deliberately. A high value optimises for many future calls at
 * the cost of a larger deployment; an escrow is deployed constantly and called
 * a handful of times, so the deployment size is what matters.
 */
module.exports = {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: { enabled: true, runs: 200 },
      // Pinned rather than left to default: the previous build targeted
      // `prague`, which not every node and explorer handles identically.
      evmVersion: 'cancun',
    },
  },
  networks: {
    hardhat: {},
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || '',
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 11155111,
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || '',
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === 'true',
    currency: 'USD',
  },
};

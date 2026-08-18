require('@nomicfoundation/hardhat-toolbox');
require('dotenv').config();

/**
 * A deployer key, or no accounts at all.
 *
 * Hardhat validates `accounts` while *loading the config*, so a malformed key
 * makes every command fail — including `compile` and `test`, which need no key
 * — with "private key too short, expected 32 bytes" and no indication of which
 * variable is wrong or why. Returning an empty list keeps the rest of the
 * toolchain usable and lets `scripts/deploy.js` explain the problem properly.
 *
 * The value is never logged. It is a key.
 */
function deployerAccounts() {
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  if (!key) return [];

  const normalised = key.startsWith('0x') ? key : `0x${key}`;
  const wellFormed = /^0x[0-9a-fA-F]{64}$/.test(normalised);

  if (!wellFormed) {
    // Warn rather than throw: `npm test` must still work without a key.
    console.warn(
      '\n  DEPLOYER_PRIVATE_KEY is set but is not a 32-byte hex key' +
        (key.includes('your_deployer_key') ? ' — it is still the .env.example placeholder.' : '.') +
        '\n  Deployment will refuse to run until it is fixed; other commands are unaffected.\n',
    );
    return [];
  }

  return [normalised];
}

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
      accounts: deployerAccounts(),
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

const { ethers, network, run } = require('hardhat');

/**
 * Deploys the factory and the test token, then prints exactly what the other
 * two repositories need.
 *
 * There was no deployment script of any kind before this — every address in
 * the product came from clicking through the Remix IDE, which is why two
 * different TestUSDC contracts ended up pinned and why nothing was
 * reproducible or verifiable.
 *
 * Usage:
 *   SEPOLIA_RPC_URL=...  DEPLOYER_PRIVATE_KEY=...  npm run deploy:sepolia
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  if (!deployer) {
    throw new Error('No signer. Set DEPLOYER_PRIVATE_KEY in .env');
  }

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Network   ${network.name} (chainId ${network.config.chainId})`);
  console.log(`Deployer  ${deployer.address}`);
  console.log(`Balance   ${ethers.formatEther(balance)} ETH\n`);

  if (balance === 0n) {
    throw new Error('Deployer has no ETH. Fund it from a Sepolia faucet first.');
  }

  // The fee recipient is a constructor argument rather than a constant baked
  // into every escrow's bytecode. Defaults to the deployer so a deployment
  // never silently sends fees to an address nobody controls.
  const feeRecipient = process.env.FEE_RECIPIENT || deployer.address;
  const feeBps = Number(process.env.FEE_BPS || 150);

  console.log('Deploying TestUSDC…');
  const Token = await ethers.getContractFactory('TestUSDC');
  const token = await Token.deploy();
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();

  console.log('Deploying EscrowFactory…');
  const Factory = await ethers.getContractFactory('EscrowFactory');
  const factory = await Factory.deploy(feeRecipient, feeBps);
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();

  console.log('\n─────────────────────────────────────────────');
  console.log(`  TestUSDC       ${tokenAddress}`);
  console.log(`  EscrowFactory  ${factoryAddress}`);
  console.log(`  fee recipient  ${feeRecipient}`);
  console.log(`  fee            ${feeBps} bps (${feeBps / 100}%)`);
  console.log('─────────────────────────────────────────────\n');

  console.log('Paste into OpenForge-Frontend/chain/config.ts:\n');
  console.log(`    escrowFactory: '${factoryAddress}',`);
  console.log(`    tokens: [{ address: '${tokenAddress}', symbol: 'tUSDC', decimals: 6 }]\n`);

  if (network.name !== 'hardhat' && process.env.ETHERSCAN_API_KEY) {
    console.log('Waiting for confirmations before verifying…');
    await token.deploymentTransaction().wait(5);
    await factory.deploymentTransaction().wait(5);

    for (const [address, args] of [
      [tokenAddress, []],
      [factoryAddress, [feeRecipient, feeBps]],
    ]) {
      try {
        await run('verify:verify', { address, constructorArguments: args });
      } catch (error) {
        console.warn(`Verification failed for ${address}: ${error.message}`);
      }
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

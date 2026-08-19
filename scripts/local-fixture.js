/**
 * Stands up a funded escrow on the local node so the frontend's decoding path
 * can be exercised against a real contract without spending anything.
 *
 * Run against `npx hardhat node`:
 *   npx hardhat run scripts/local-fixture.js --network localhost
 */
const { ethers } = require('hardhat');

async function main() {
  const [funder, developer] = await ethers.getSigners();

  const Token = await ethers.getContractFactory('TestUSDC');
  const token = await Token.deploy();
  await token.waitForDeployment();

  const Factory = await ethers.getContractFactory('EscrowFactory');
  const factory = await Factory.deploy(funder.address, 150);
  await factory.waitForDeployment();

  const now = (await ethers.provider.getBlock('latest')).timestamp;
  const amounts = [1_200_000_000n, 800_000_000n, 500_000_000n];
  const deadlines = [now + 30 * 86400, now + 60 * 86400, now + 90 * 86400];

  const [escrowAddress] = await factory.createEscrow.staticCall(
    developer.address,
    await token.getAddress(),
    amounts,
    deadlines,
    'bafkreiexamplecidforlocalfixtureonly000000000000000000000000',
  );
  await (
    await factory.createEscrow(
      developer.address,
      await token.getAddress(),
      amounts,
      deadlines,
      'bafkreiexamplecidforlocalfixtureonly000000000000000000000000',
    )
  ).wait();

  // Fund it, so `summary()` reports a live balance rather than zeroes.
  const total = amounts.reduce((a, b) => a + b, 0n);
  await (await token.faucet()).wait();
  await (await token.approve(escrowAddress, total)).wait();
  const escrow = await ethers.getContractAt('MilestoneEscrow', escrowAddress);
  await (await escrow.fund()).wait();

  // Release one and raise a dispute, so every field under test is non-default.
  await (await escrow.release([0])).wait();
  await (await escrow.connect(developer).raiseDispute('Local fixture dispute')).wait();

  console.log(
    JSON.stringify(
      {
        token: await token.getAddress(),
        factory: await factory.getAddress(),
        escrow: escrowAddress,
        funder: funder.address,
        developer: developer.address,
      },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

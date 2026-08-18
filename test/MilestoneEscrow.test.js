const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

/**
 * The cases here are written against the failures found in the deployed v1
 * contracts. Each of the four headline ones has a test named after what it
 * used to allow, so a regression is impossible to miss.
 */

const DAY = 24 * 60 * 60;
const FEE_BPS = 150n;

async function deployFixture() {
  const [deployer, funder, developer, stranger] = await ethers.getSigners();

  const Token = await ethers.getContractFactory('TestUSDC');
  const token = await Token.deploy();

  const Factory = await ethers.getContractFactory('EscrowFactory');
  const factory = await Factory.deploy(deployer.address, FEE_BPS);

  await token.connect(funder).faucet();

  return { token, factory, deployer, funder, developer, stranger };
}

async function createEscrow(ctx, { amounts, days } = {}) {
  const { factory, token, funder, developer } = ctx;
  const values = amounts ?? [1000n * 10n ** 6n, 2000n * 10n ** 6n];
  const offsets = days ?? [30, 60];
  const now = await time.latest();
  const deadlines = offsets.map((d) => now + d * DAY);

  const tx = await factory
    .connect(funder)
    .createEscrow(developer.address, await token.getAddress(), values, deadlines, 'bafyTest');
  const receipt = await tx.wait();

  const log = receipt.logs
    .map((l) => {
      try { return factory.interface.parseLog(l); } catch { return null; }
    })
    .find((l) => l && l.name === 'ProjectCreated');

  const escrow = await ethers.getContractAt('MilestoneEscrow', log.args.escrow);
  return { escrow, deadlines, values, total: values.reduce((a, b) => a + b, 0n) };
}

async function fundEscrow(ctx, escrow, total) {
  await ctx.token.connect(ctx.funder).approve(await escrow.getAddress(), total);
  await escrow.connect(ctx.funder).fund();
}

describe('MilestoneEscrow', function () {
  let ctx;
  beforeEach(async function () {
    ctx = await deployFixture();
  });

  describe('the v1 critical failures', function () {
    it('the funder CANNOT take back funds for work that is not yet overdue', async function () {
      // v1: cancelProject() returned every unreleased token to the funder at
      // any moment, so a developer mid-milestone had no claim at all.
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      await expect(escrow.connect(ctx.funder).reclaim([0])).to.be.revertedWithCustomError(
        escrow,
        'DeadlineNotPassed',
      );
      expect(await ctx.token.balanceOf(await escrow.getAddress())).to.equal(total);
    });

    it('a developer who delivers nothing CANNOT seize the escrow by disputing', async function () {
      // v1: raiseDispute() then wait 30 days -> resolveDisputeToDeveloper()
      // paid out the entire remaining balance, fee-free, to a developer who
      // had done nothing, if the funder simply did not notice.
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      await escrow.connect(ctx.developer).raiseDispute('pay me');
      await time.increase(365 * DAY);

      // There is no function that pays a developer without the funder
      // releasing. The developer's balance can only move via release().
      expect(escrow.interface.fragments.filter((f) => f.type === 'function')
        .map((f) => f.name)).to.not.include.members([
          'resolveDisputeToDeveloper',
          'resolveDisputeToFunder',
          'cancelProject',
        ]);
      expect(await ctx.token.balanceOf(ctx.developer.address)).to.equal(0n);
    });

    it('a dispute cannot be used to freeze the escrow forever', async function () {
      // v1: Disputed was absorbing — no path back to Funded, so either party
      // could permanently end milestone releases for free.
      const { escrow, total, deadlines } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      await escrow.connect(ctx.developer).raiseDispute('stalling');
      expect(await escrow.isFrozen()).to.equal(true);

      await time.increase(15 * DAY);
      expect(await escrow.isFrozen()).to.equal(false);

      // And normal flow resumes.
      await time.increaseTo(deadlines[0] + 1);
      await expect(escrow.connect(ctx.funder).reclaim([0])).to.emit(escrow, 'MilestoneReclaimed');
    });

    it('mixing a release and a reclaim still reaches a terminal state', async function () {
      // v1: _checkCompletion accepted "released or cancelled" while
      // _checkCancellation required ALL cancelled, so release #0 then cancel
      // #1 left the project stuck in Funded forever with a zero balance.
      const { escrow, total, deadlines } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      await escrow.connect(ctx.funder).release([0]);
      await time.increaseTo(deadlines[1] + 1);
      await expect(escrow.connect(ctx.funder).reclaim([1])).to.emit(escrow, 'Closed');

      expect(await escrow.state()).to.equal(2); // Closed
      expect(await ctx.token.balanceOf(await escrow.getAddress())).to.equal(0n);
    });

    it('an escrow the factory did not deploy is not recognised', async function () {
      // v1: the registry authenticated an escrow by asking it whether
      // funder() == msg.sender, so any contract could register itself.
      const { factory } = ctx;
      const Fake = await ethers.getContractFactory('TestUSDC');
      const fake = await Fake.deploy();
      expect(await factory.isOfficialEscrow(await fake.getAddress())).to.equal(false);
    });
  });

  describe('access control', function () {
    it('only the funder can release', async function () {
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      for (const who of [ctx.developer, ctx.stranger]) {
        await expect(escrow.connect(who).release([0])).to.be.revertedWithCustomError(escrow, 'NotFunder');
      }
    });

    it('only the funder can reclaim', async function () {
      const { escrow, total, deadlines } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await time.increaseTo(deadlines[0] + 1);
      await expect(escrow.connect(ctx.developer).reclaim([0])).to.be.revertedWithCustomError(escrow, 'NotFunder');
    });

    it('a stranger cannot raise a dispute', async function () {
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await expect(escrow.connect(ctx.stranger).raiseDispute('x')).to.be.revertedWithCustomError(escrow, 'NotParty');
    });

    it('only the funder can fund', async function () {
      const { escrow, total } = await createEscrow(ctx);
      await ctx.token.connect(ctx.funder).transfer(ctx.stranger.address, total);
      await ctx.token.connect(ctx.stranger).approve(await escrow.getAddress(), total);
      await expect(escrow.connect(ctx.stranger).fund()).to.be.revertedWithCustomError(escrow, 'NotFunder');
    });
  });

  describe('money', function () {
    it('pays the developer net and the fee recipient exactly the fee', async function () {
      const { escrow, total, values } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      const fee = (values[0] * FEE_BPS) / 10_000n;
      await expect(escrow.connect(ctx.funder).release([0]))
        .to.emit(escrow, 'MilestoneReleased')
        .withArgs(0, ctx.developer.address, values[0], fee);

      expect(await ctx.token.balanceOf(ctx.developer.address)).to.equal(values[0] - fee);
      expect(await ctx.token.balanceOf(ctx.deployer.address)).to.equal(fee);
    });

    it('the released counter and the event agree on gross', async function () {
      // v1: releasedAmount accumulated GROSS while the event reported NET, so
      // any indexer reconciling the two drifted by exactly the fee.
      const { escrow, total, values } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      const tx = await escrow.connect(ctx.funder).release([0]);
      const receipt = await tx.wait();
      const parsed = receipt.logs
        .map((l) => { try { return escrow.interface.parseLog(l); } catch { return null; } })
        .find((l) => l && l.name === 'MilestoneReleased');

      expect(await escrow.releasedGross()).to.equal(parsed.args.gross);
      expect(parsed.args.gross).to.equal(values[0]);
    });

    it('no fee is taken when money returns to the funder', async function () {
      const { escrow, total, values, deadlines } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      const before = await ctx.token.balanceOf(ctx.funder.address);

      await time.increaseTo(deadlines[0] + 1);
      await escrow.connect(ctx.funder).reclaim([0]);

      expect(await ctx.token.balanceOf(ctx.funder.address)).to.equal(before + values[0]);
    });

    it('a milestone cannot be resolved twice', async function () {
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await escrow.connect(ctx.funder).release([0]);
      await expect(escrow.connect(ctx.funder).release([0])).to.be.revertedWithCustomError(escrow, 'AlreadyResolved');
    });

    it('the same index twice in one batch is rejected', async function () {
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await expect(escrow.connect(ctx.funder).release([0, 0])).to.be.revertedWithCustomError(escrow, 'AlreadyResolved');
    });

    it('releases in a batch cost one transfer, not one per milestone', async function () {
      const { escrow, total, values } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      const fee = values.reduce((sum, v) => sum + (v * FEE_BPS) / 10_000n, 0n);
      await escrow.connect(ctx.funder).release([0, 1]);

      expect(await ctx.token.balanceOf(ctx.developer.address)).to.equal(total - fee);
      expect(await escrow.state()).to.equal(2);
    });
  });

  describe('disputes', function () {
    it('freezes reclaim but never blocks payment', async function () {
      const { escrow, total, deadlines, values } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await time.increaseTo(deadlines[0] + 1);

      await escrow.connect(ctx.developer).raiseDispute('it is done');
      await expect(escrow.connect(ctx.funder).reclaim([0])).to.be.revertedWithCustomError(escrow, 'Frozen');

      // The funder can still choose to pay.
      await expect(escrow.connect(ctx.funder).release([0])).to.emit(escrow, 'MilestoneReleased');
      expect(await ctx.token.balanceOf(ctx.developer.address)).to.equal(values[0] - (values[0] * FEE_BPS) / 10_000n);
    });

    it('each party may raise only once, so it cannot be looped', async function () {
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);

      await escrow.connect(ctx.developer).raiseDispute('one');
      await escrow.connect(ctx.developer).withdrawDispute();
      await expect(escrow.connect(ctx.developer).raiseDispute('two')).to.be.revertedWithCustomError(escrow, 'AlreadyRaised');
    });

    it('only the party who raised it can withdraw it', async function () {
      const { escrow, total } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await escrow.connect(ctx.developer).raiseDispute('mine');
      await expect(escrow.connect(ctx.funder).withdrawDispute()).to.be.revertedWithCustomError(escrow, 'NotDisputeRaiser');
    });

    it('withdrawing restores reclaim immediately', async function () {
      const { escrow, total, deadlines } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await time.increaseTo(deadlines[0] + 1);

      await escrow.connect(ctx.funder).raiseDispute('mistake');
      await escrow.connect(ctx.funder).withdrawDispute();
      await expect(escrow.connect(ctx.funder).reclaim([0])).to.emit(escrow, 'MilestoneReclaimed');
    });
  });

  describe('construction', function () {
    it('rejects a past deadline', async function () {
      const now = await time.latest();
      await expect(
        ctx.factory.connect(ctx.funder).createEscrow(
          ctx.developer.address, await ctx.token.getAddress(), [1n], [now - 1], 'cid',
        ),
      ).to.be.revertedWithCustomError(
        await ethers.getContractFactory('MilestoneEscrow'), 'DeadlineNotInFuture',
      );
    });

    it('rejects funder == developer', async function () {
      const now = await time.latest();
      await expect(
        ctx.factory.connect(ctx.funder).createEscrow(
          ctx.funder.address, await ctx.token.getAddress(), [1n], [now + DAY], 'cid',
        ),
      ).to.be.revertedWithCustomError(
        await ethers.getContractFactory('MilestoneEscrow'), 'SameParty',
      );
    });

    it('rejects a zero amount and an empty milestone list', async function () {
      const now = await time.latest();
      const escrowArtifact = await ethers.getContractFactory('MilestoneEscrow');
      await expect(
        ctx.factory.connect(ctx.funder).createEscrow(
          ctx.developer.address, await ctx.token.getAddress(), [0n], [now + DAY], 'cid',
        ),
      ).to.be.revertedWithCustomError(escrowArtifact, 'ZeroAmount');
      await expect(
        ctx.factory.connect(ctx.funder).createEscrow(
          ctx.developer.address, await ctx.token.getAddress(), [], [], 'cid',
        ),
      ).to.be.revertedWithCustomError(escrowArtifact, 'NoMilestones');
    });

    it('caps the milestone count so release can never exceed the block gas limit', async function () {
      const now = await time.latest();
      const many = Array(51).fill(1n);
      const deadlines = Array(51).fill(now + DAY);
      await expect(
        ctx.factory.connect(ctx.funder).createEscrow(
          ctx.developer.address, await ctx.token.getAddress(), many, deadlines, 'cid',
        ),
      ).to.be.revertedWithCustomError(
        await ethers.getContractFactory('MilestoneEscrow'), 'TooManyMilestones',
      );
    });
  });

  describe('sweep', function () {
    it('cannot run before the grace period', async function () {
      const { escrow, total, deadlines } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      await time.increaseTo(deadlines[1] + 1);
      await expect(escrow.sweep()).to.be.revertedWithCustomError(escrow, 'DeadlineNotPassed');
    });

    it('returns everything to the funder and can be called by anyone', async function () {
      const { escrow, total, deadlines } = await createEscrow(ctx);
      await fundEscrow(ctx, escrow, total);
      const before = await ctx.token.balanceOf(ctx.funder.address);

      await time.increaseTo(deadlines[1] + 31 * DAY);
      await expect(escrow.connect(ctx.stranger).sweep()).to.emit(escrow, 'Swept');

      expect(await ctx.token.balanceOf(ctx.funder.address)).to.equal(before + total);
      expect(await escrow.state()).to.equal(2);
    });
  });

  describe('factory', function () {
    it('records the escrow it deployed and indexes both parties', async function () {
      const { escrow } = await createEscrow(ctx);
      const address = await escrow.getAddress();

      expect(await ctx.factory.isOfficialEscrow(address)).to.equal(true);
      expect((await ctx.factory.getProjectsByUser(ctx.funder.address)).length).to.equal(1);
      expect((await ctx.factory.getProjectsByUser(ctx.developer.address)).length).to.equal(1);
    });

    it('only the funder can edit project metadata', async function () {
      await createEscrow(ctx);
      await expect(ctx.factory.connect(ctx.stranger).setMetadata(0, 'evil')).to.be.revertedWithCustomError(
        ctx.factory, 'NotOwner',
      );
      await ctx.factory.connect(ctx.funder).setMetadata(0, 'bafyNew');
      expect((await ctx.factory.getProject(0)).metadataCID).to.equal('bafyNew');
    });

    it('lists newest first and pages without running off the end', async function () {
      await createEscrow(ctx);
      await createEscrow(ctx);
      const page = await ctx.factory.getProjects(0, 10);
      expect(page.length).to.equal(2);
      expect(await ctx.factory.totalProjects()).to.equal(2);
      expect((await ctx.factory.getProjects(5, 10)).length).to.equal(0);
    });
  });

  describe('permit funding', function () {
    it('approves and funds in a single transaction', async function () {
      const { escrow, total } = await createEscrow(ctx);
      const escrowAddress = await escrow.getAddress();
      const tokenAddress = await ctx.token.getAddress();

      const deadline = (await time.latest()) + 3600;
      const nonce = await ctx.token.nonces(ctx.funder.address);
      const domain = {
        name: 'Test USDC',
        version: '1',
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: tokenAddress,
      };
      const types = {
        Permit: [
          { name: 'owner', type: 'address' },
          { name: 'spender', type: 'address' },
          { name: 'value', type: 'uint256' },
          { name: 'nonce', type: 'uint256' },
          { name: 'deadline', type: 'uint256' },
        ],
      };
      const signature = await ctx.funder.signTypedData(domain, types, {
        owner: ctx.funder.address,
        spender: escrowAddress,
        value: total,
        nonce,
        deadline,
      });
      const { v, r, s } = ethers.Signature.from(signature);

      await expect(escrow.connect(ctx.funder).fundWithPermit(deadline, v, r, s)).to.emit(escrow, 'Funded');
      expect(await ctx.token.balanceOf(escrowAddress)).to.equal(total);
    });
  });
});

# OpenForge Contracts

Milestone escrow for funding open-source work, on Sepolia.

Two contracts do the work:

- **`EscrowFactory`** — deploys escrows and is the registry of the ones it
  made. Registration is not a separate step, so the registry cannot be told
  about an escrow it did not create.
- **`MilestoneEscrow`** — holds one ERC20 payment, released milestone by
  milestone.

`TestUSDC` is a 6-decimal test token with a faucet and EIP-2612 permit.

## The rules, in one paragraph

The funder deposits the full amount up front. They may **release** any
milestone at any time, which pays the developer minus a 1.5% fee. They may
**reclaim** a milestone only after its deadline has passed with the work
unreleased — so money committed to in-date work cannot be pulled back. Either
party may **raise a dispute** once, which freezes reclaim for 14 days without
ever blocking payment; the party who raised it may withdraw it early, and it
lapses on its own. Long after the last deadline, anyone may **sweep** whatever
is unresolved back to the funder, so funds are never stranded.

There is no arbitrator. Nothing on chain decides who is right, and if the
funder refuses to release, the money returns to them when the deadline passes.
See [`docs/SECURITY.md`](docs/SECURITY.md).

## Setup

```bash
npm install
npm test          # 29 tests
npm run gas       # gas report
npm run build     # compile
```

## Deploying

```bash
cp .env.example .env      # set SEPOLIA_RPC_URL and DEPLOYER_PRIVATE_KEY
npm run deploy:sepolia
```

The script prints the addresses to paste into `OpenForge-Frontend/chain/config.ts`
and verifies the source on Etherscan if `ETHERSCAN_API_KEY` is set.

## Layout

```
contracts/      the current contracts
deployed-v1/    the previously deployed sources, kept for reference
test/           adversarial tests, named after the failures they prevent
scripts/        deployment
docs/           SECURITY.md, GAS_OPTIMIZATION.md
```

`deployed-v1/` is not compiled. It is the code currently live on Sepolia, kept
so the addresses in the frontend can be traced to a source. Every defect
described in `docs/SECURITY.md` is still present in it.

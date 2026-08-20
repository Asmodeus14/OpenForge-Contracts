# Contributing

These contracts hold money. The bar is higher here than in the other two
repositories, and the review will be slower.

## Setting up

```bash
npm install
npm test          # 29 tests
npm run gas       # gas report
npm run build     # compile
npm run size      # contract sizes
```

## Before you change anything

Read [`docs/SECURITY.md`](docs/SECURITY.md) first. It records what the
previously deployed contracts got wrong and what the current ones do instead.
Several rules that look arbitrary — mandatory deadlines, the milestone count
cap, the absence of `cancelProject` — are each preventing a specific,
documented failure. Removing one reintroduces the failure it was written for.

`deployed-v1/` is not compiled. It is the source of the contracts currently
live on Sepolia, kept so that deployed addresses can be traced back to code.
Every defect in `docs/SECURITY.md` is still present in it. Do not fix anything
there; it is a record, not a codebase.

## Tests

Every test is named after the failure it prevents:

```
✔ the funder CANNOT take back funds for work that is not yet overdue
✔ caps the milestone count so release can never exceed the block gas limit
✔ cannot run before the grace period
```

Write them the same way. A test called `should work` tells a future reader
nothing about which property must not regress.

**A change to any money path needs an adversarial test, not just a happy one.**
Show that the wrong party *cannot* do the thing, not merely that the right one
can. New tests must fail against the old code — a test that passes before your
change is not testing your change.

The full suite must pass before a pull request. It runs in about seven seconds;
there is no excuse for skipping it.

## House style

**No admin keys, no upgradeability, no pause switch.** Their absence is a
guarantee the contracts make to their users. Anything that reintroduces a
privileged address changes what the product *is*, and needs discussing before
it is written.

**Deployment gas is a user-facing cost.** An escrow is deployed per project by
an end user, so bytecode size is charged directly to them. The optimiser is
enabled with `runs: 200` deliberately — tuned for deployment cost rather than
for many future calls. See [`docs/GAS_OPTIMIZATION.md`](docs/GAS_OPTIMIZATION.md).

**Comments explain why.** Especially every check: a `require` without a reason
recorded somewhere is a rule nobody will dare delete and nobody will understand.

**Never claim an audit.** There has not been one.

## Deploying

```bash
cp .env.example .env      # SEPOLIA_RPC_URL, DEPLOYER_PRIVATE_KEY
npm run deploy:sepolia
```

The script prints the addresses for `OpenForge-frontend/chain/config.ts` and
verifies the source on Etherscan when `ETHERSCAN_API_KEY` is set. Record every
deployment in `deployments/` — an address whose source cannot be traced is
worse than no deployment at all.

Never commit `.env`, and never put a private key in a script, a test or a
comment.

## Reporting bugs

For anything exploitable, do not open an issue — see
[`docs/SECURITY.md`](docs/SECURITY.md).

Participation is covered by our [Code of Conduct](CODE_OF_CONDUCT.md).

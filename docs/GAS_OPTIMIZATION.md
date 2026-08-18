# Gas

Measured, not estimated. Two different instruments, and it matters which:

- **v1 figures** come from `eth_estimateGas` against the deployed Sepolia
  contracts during this work. They are real, on the real deployment.
- **v2 figures** come from `hardhat-gas-reporter` over the test suite
  (`npm run gas`), on a 2-milestone escrow, optimizer on.

Where a v1 number was never measured, it says so rather than guessing.

---

## The single biggest change was a build setting

Every artifact this repository shipped was compiled with
`optimizer: { enabled: false }`. That is one line, and it inflates both the
deployment bytecode and every subsequent call. It matters more here than in
most projects because **an escrow is deployed once per project by an end
user** — deployment gas is a recurring, user-facing charge, not a one-off cost
the team absorbs.

`hardhat.config.js` now sets `optimizer: { enabled: true, runs: 200 }`. `runs`
is deliberately low: a high value optimises for many future calls at the cost
of a bigger deployment, and an escrow is deployed constantly and called a
handful of times.

---

## Starting a project

| | v1 | v2 | |
|---|---|---|---|
| Deploy the escrow | 2,855,175 | — | measured on Sepolia |
| Register it | not measured | — | separate transaction |
| **Deploy + register** | **2,855,175 + register** | **1,814,955** | |
| Approve the token | 47,276 | — | measured on Sepolia |
| Deposit | not measured | 84,377 | |
| **User transactions** | **4** | **2** | |

`createEscrow` does the deploy *and* the registration for 1,814,955 gas, where
v1 charged 2,855,175 for the deployment alone and then required a second
transaction to register. On the deploy leg that is **1,040,220 gas saved,
36.4%**, before counting the registration transaction that no longer exists.

The transaction count halves because two pairs collapse:

- **deploy + register → `EscrowFactory.createEscrow`.** This was not done for
  gas; it was done because a registry that accepts arbitrary addresses can be
  lied to (see `SECURITY.md`). The saved transaction is a side effect.
- **approve + fund → `MilestoneEscrow.fundWithPermit`.** EIP-2612, with
  `TestUSDC` gaining `ERC20Permit`.

## Per-call

| Method | v2 gas | Note |
|---|---|---|
| `release` (1 milestone) | 122,985 | |
| `release` (2 in one call) | 130,170 | second milestone costs ~7,185 |
| `reclaim` | 78,054 | |
| `raiseDispute` | 30,196 | reason is emitted, never stored |
| `withdrawDispute` | 28,152 | v1 had no such function at all |
| `fund` | 84,377 | |
| `fundWithPermit` | 118,084 | replaces approve (47,276) + fund (84,377) |

Batching matters most on `release`: a funder approving three finished
milestones paid for three transactions in v1, each of which also ran an O(n)
storage loop over every milestone. Now it is one transaction, one transfer to
the developer and one to the fee recipient.

---

## Where the savings come from

**Storage layout.** The `Milestone` struct went from 4 slots to 1:

```solidity
// v1 — 4 slots
struct Milestone { uint256 amount; bool released; bool cancelled; uint256 deadline; string description; }

// v2 — 1 slot: 16 + 5 + 1 = 22 of 32 bytes
struct Milestone { uint128 amount; uint40 deadline; MilestoneStatus status; }
```

`uint128` is beyond any real ERC20 supply and `uint40` covers dates past the
year 36000. The `string description` moved to the IPFS metadata the product
already pins, where fixing a typo is a pin rather than a storage write.

The escrow's own state went from 6 slots to 3: `state`, `disputedAt`,
`resolvedCount` and two dispute flags now share one slot (10 of 32 bytes),
`totalAmount` became `immutable`, and `totalFeesCollected` was deleted because
it was derivable from the events.

The factory's `Project` record went from 10 slots to 4. Dropped: a redundant
`projectId` (it is the mapping key — a pure 20,000-gas write for data the
caller already had), and `title`/`description`/`string[] tags`, all three of
which duplicated an IPFS pointer stored in the same contract.

**The O(n) loop on the hot path.** v1 ran `_checkCompletion()` on every single
release: a full storage loop over every milestone, re-reading `milestones.length`
each iteration and issuing two separate `SLOAD`s for `.released` and
`.cancelled` — which live in the same slot, but with the optimizer off the
compiler will not merge them. v2 keeps a `resolvedCount` and compares it to the
length. O(1), and it also fixes the stuck-state bug the two asymmetric loops
caused.

**Custom errors.** v1 declared ten custom errors and then used fifteen
`require`s with string literals, six of the declared errors never being used at
all. Every string costs deployment bytecode plus gas at revert. v2 uses custom
errors throughout.

**`calldata` over `memory`** on every external function taking arrays or
strings.

**Fewer external calls.** v1's `registerProject` called `escrow.funder()` three
times and `escrow.developer()` twice — five cold `STATICCALL`s at ~2,600 gas
each where the factory now simply knows both.

---

## What was not optimised, and why

- **`sweep()` loops over every milestone twice.** It is bounded by
  `MAX_MILESTONES = 50`, runs at most once per escrow, and the clarity is
  worth more than the saving.
- **Two transfers per `release` batch** (developer, then fee recipient). Merging
  them is not possible without holding fees inside the escrow and adding a
  withdrawal path, which is more state and more risk for a few thousand gas.
- **`getProjectsByUser` returns full structs.** It is a `view`, so it costs no
  ether, and the alternative — returning ids — is what forced the frontend into
  one RPC call per id in v1.

## Reproducing

```bash
npm install
npm run gas      # the table above
npm test         # 29 tests
```

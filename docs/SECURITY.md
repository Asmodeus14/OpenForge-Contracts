# Security

What was wrong with the deployed contracts, what v2 does instead, and what is
still true that a user should know. Nothing here claims an audit: there has not
been one.

---

## The defect that mattered most

**The escrow did not escrow.**

```solidity
// deployed-v1/EScrow_cont.sol:299
function cancelProject() external onlyFunder inState(ProjectState.Funded) nonReentrant {
    uint256 remaining = _getRemainingBalance();
    if (remaining > 0) { paymentToken.safeTransfer(funder, remaining); }
    state = ProjectState.Cancelled;
```

No timelock, no notice, no developer consent. A developer who had finished
three of four milestones and not yet been paid had no on-chain claim of any
kind — the funder called this and every unreleased token went home. Since
`releaseMilestone` was also `onlyFunder`, payment was entirely discretionary.
The contract gave the developer nothing that the funder simply holding the
money in their own wallet would not.

**v2:** `cancelProject` does not exist. The funder can only `reclaim` a
milestone **after its deadline has passed with the work unreleased**. Money
committed to in-date work cannot be pulled. Deadlines are mandatory for exactly
this reason — a milestone without one could never be reclaimed and would strand
the funder's money forever.

Tested: *"the funder CANNOT take back funds for work that is not yet overdue"*.

---

## The two theft vectors

**Disputes resolved in the funder's favour by construction.**
`resolveDisputeToDeveloper` required 30 days; `resolveDisputeToFunder` required
nothing. For any dispute the funder had a 30-day window in which to take 100%
of the balance, and the developer could do nothing.

**And symmetrically, a developer could rob an inattentive funder.**
`raiseDispute` was callable by either party the moment funding landed, with no
bond and no cost. A developer who had delivered nothing raised a dispute, waited
30 days, called `resolveDisputeToDeveloper()` and swept the entire balance —
fee-free. A funder on holiday lost the project.

**v2:** there is no function that moves money to either party on a timer. The
only ways funds leave are `release` (funder chooses to pay) and `reclaim`
(deadline passed, money returns to its owner). A dispute freezes *reclaim*, not
release — so it buys the developer a fixed window to settle without the funder
pulling money out from under them, and it cannot be used to seize anything.

Tested: *"a developer who delivers nothing CANNOT seize the escrow by
disputing"*.

---

## Other findings, and their status

| Finding | v1 behaviour | v2 |
|---|---|---|
| Dispute was absorbing | No path back to `Funded`. Either party could permanently end milestone releases for free, forcing an all-or-nothing outcome. | Disputes lapse after `DISPUTE_WINDOW` (14 days) and the raiser may withdraw early. Each party may raise once, so raise/withdraw cannot be looped. |
| Registry accepted any address | Authenticated an escrow only by asking it whether `funder() == msg.sender`. Ten lines of Solidity returning `msg.sender` were enough to register a fake contract that held no money, under any title. The registry was the product's source of truth for what exists. | The factory deploys what it registers. There is no `register` function to abuse. `isOfficialEscrow` is set only by `createEscrow`. |
| Stuck non-terminal state | `_checkCompletion` accepted "released **or** cancelled" while `_checkCancellation` required **all** cancelled. Release #0 then cancel #1 left the project in `Funded` forever with a zero balance. | One `resolvedCount` compared to the milestone count. Also removes the O(n) loop from the hot path. |
| Fee-on-transfer tokens | `fund()` pulled `totalAmount` and never checked receipt, so the contract held less than the milestones summed to and the **final release reverted** — after the work was done. | The received amount is measured and must equal the total, so it fails at funding time instead. |
| Unbounded milestones | No cap. A large enough array made `releaseMilestone` exceed the block gas limit, permanently DoSing payouts. | `MAX_MILESTONES = 50`, enforced at construction. |
| Checks-effects-interactions | All three exit paths transferred, *then* wrote state. Not exploitable — `nonReentrant` covered them — but the safety rested on the guard rather than on ordering. | State written before every transfer, guard retained. |
| `raiseDispute` unguarded | The one mutating function without `nonReentrant`. | Cannot be re-entered into a money path; disputes touch no balances. |
| Fee recipient immutable in bytecode | `address public constant FEE_RECIPIENT` in every escrow. A lost or compromised key meant every past and future escrow paid fees to a dead address, forever, with no setter. | Constructor argument on the factory, passed to each escrow as `immutable`. Capped at `MAX_FEE_BPS = 500`. |
| Platform owner could rewrite projects | `onlyProjectOwner` admitted `owner()`, so the admin could rewrite any project's title, description and tags, and `forceRegisterProject` let them invent entries naming arbitrary parties. | There is no platform-owner role. Only a project's funder can edit its metadata pointer. |
| Funds stuck if the funder vanishes | Nothing recovered a balance whose funder stopped responding. | `sweep()` returns everything unresolved to the funder after every deadline plus 30 days. Permissionless, because the destination is fixed. |
| Gross/net accounting | `releasedAmount` accumulated gross while `MilestoneReleased` emitted net, so any reconciliation drifted by exactly the fee. `MilestoneCancelled` used the opposite convention for the same-named field. | Both the counter and the event use gross, and the fee is emitted alongside it. Tested. |
| Events unusable for indexing | No cancel path emitted an amount, so balance history could not be reconstructed from logs. `ProjectCancelled()` fired from three code paths with no parameters to distinguish them. `ProjectRegistered` indexed the escrow address (derivable) but not the developer. | Every event carries the amount that moved. `developer` is indexed. |

---

## What is still true

- **These contracts have not been audited.** 29 tests and a careful review are
  not an audit.
- **There is no arbitrator, so delivered work cannot be forced to be paid.**
  If the funder refuses to release, the money sits until the deadline and then
  returns to them. The escrow guarantees that the money exists and is committed
  for the agreed window — not that it will be paid. Any interface built on this
  must say so plainly.
- **A dispute is a pause, not a judgment.** Nothing on chain decides who is
  right.
- **Any ERC20 is accepted.** A token that rebases will still break accounting;
  the fee-on-transfer case is now caught at funding time rather than at the
  final release, but the correct answer is still to use a plain token.
- **Deadlines are enforced with `block.timestamp`**, which a validator can nudge
  by seconds. Irrelevant at day-scale windows.
- **The old contracts remain deployed** and hold whatever they hold. Nothing
  here migrates them, and they retain every defect above.

## Dependencies

OpenZeppelin is pinned to `5.0.2` in `package.json` with a lockfile. The
previous build vendored **three different versions** into one compilation
(4.9.0 `ReentrancyGuard`, 5.0.0 `Ownable`, 5.3.0 `SafeERC20`) via Remix, with
no manifest — and imported `@openzeppelin/contracts/security/ReentrancyGuard.sol`,
a path that does not exist in v5, so any dependency refresh broke the build.
The compiler is pinned to `0.8.24` rather than a floating `^0.8.20`, so builds
are reproducible and Etherscan verification is stable.

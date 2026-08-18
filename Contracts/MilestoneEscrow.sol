// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MilestoneEscrow
 * @notice Holds an ERC20 payment for work delivered in milestones.
 *
 * ## What this guarantees, and what it does not
 *
 * It guarantees that the money exists, that it is committed for the agreed
 * window, and that neither party can take the other's share. It does **not**
 * guarantee that delivered work gets paid: there is no arbitrator, so nothing
 * on chain can judge whether a milestone was actually completed. The funder
 * decides that, and if they refuse, the money returns to them when the
 * deadline passes. Any interface built on this must say so.
 *
 * That is a smaller promise than the version this replaces appeared to make,
 * and a much larger one than it actually kept. Previously `cancelProject()`
 * let the funder withdraw every unreleased token at any moment with no notice
 * and no developer consent — so a developer who had finished three of four
 * milestones had no claim of any kind, and the escrow gave them nothing that
 * the funder simply holding the money would not.
 *
 * ## The rules
 *
 * - The funder may **release** a milestone at any time. Paying is never
 *   blocked.
 * - The funder may **reclaim** a milestone only once its deadline has passed
 *   with the work unreleased. Money for in-date work cannot be pulled. This is
 *   the developer's actual protection, and the reason deadlines are mandatory:
 *   a milestone with no deadline could never be reclaimed and would strand the
 *   funder's money forever.
 * - Either party may **raise a dispute**, once each. A dispute freezes
 *   reclaim, not release — so it buys the developer a fixed window to settle
 *   without the funder pulling the money out from under them, and cannot be
 *   used to lock the funder's funds indefinitely.
 * - The dispute expires on its own. The party who raised it may withdraw it
 *   early.
 *
 * Deliberately absent: any path by which one party takes the other's money.
 * The previous contract had two — the funder could resolve a dispute in their
 * own favour instantly while the developer waited thirty days, and a developer
 * who delivered nothing could raise a dispute and sweep the entire balance if
 * the funder failed to notice within that window.
 */
contract MilestoneEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------- errors */

    error NotFunder();
    error NotParty();
    error WrongState();
    error NoMilestones();
    error TooManyMilestones();
    error ZeroAmount();
    error DeadlineNotInFuture();
    error LengthMismatch();
    error AlreadyResolved();
    error DeadlineNotPassed();
    error Frozen();
    error AlreadyRaised();
    error NotDisputed();
    error NotDisputeRaiser();
    error AmountNotReceived(uint256 expected, uint256 received);
    error SameParty();
    error ZeroAddress();
    error FeeTooHigh();
    error NothingToSweep();

    /* -------------------------------------------------------------- types */

    enum State {
        Created,
        Funded,
        Closed
    }

    enum MilestoneStatus {
        Pending,
        Released,
        Reclaimed
    }

    /**
     * One slot. The previous layout took four: a `uint256` amount, two bools
     * in a slot of their own, a `uint256` deadline, and an inline `string`
     * description. Descriptions now live in the project metadata already
     * pinned to IPFS, where changing a typo does not cost a storage write.
     */
    struct Milestone {
        uint128 amount; // 16 bytes — far beyond any real ERC20 supply
        uint40 deadline; // 5 bytes — unix seconds, good past the year 36000
        MilestoneStatus status; // 1 byte
    }

    /* ------------------------------------------------------------ storage */

    /// @notice A dispute freezes reclaim for this long, then lapses.
    uint40 public constant DISPUTE_WINDOW = 14 days;

    /**
     * @notice After every deadline has passed by this much, anyone may return
     * what is left to the funder.
     *
     * Without it, a funder who walks away leaves the developer's counterparty
     * funds sitting in a contract nobody can touch. The money can only ever go
     * to the funder, so making the call permissionless costs nothing.
     */
    uint40 public constant SWEEP_GRACE = 30 days;

    uint256 public constant MAX_MILESTONES = 50;
    uint16 public constant MAX_FEE_BPS = 500; // 5%

    address public immutable funder;
    address public immutable developer;
    IERC20 public immutable token;
    address public immutable feeRecipient;
    uint16 public immutable feeBps;
    /// @notice Set once at construction; was a mutable storage slot before.
    uint256 public immutable totalAmount;

    // Packed into one slot: 1 + 5 + 2 + 1 + 1 = 10 of 32 bytes.
    State public state;
    uint40 public disputedAt;
    uint16 public resolvedCount;
    bool public funderRaisedDispute;
    bool public developerRaisedDispute;

    /// @notice Gross value released, before the fee. See `MilestoneReleased`.
    uint256 public releasedGross;
    /// @notice Value returned to the funder by reclaim or sweep.
    uint256 public reclaimedTotal;

    Milestone[] private _milestones;

    /* ------------------------------------------------------------- events */

    /**
     * Events carry every amount that moves, so an indexer can reconstruct the
     * full balance history from logs alone. The previous events could not: no
     * cancel path emitted an amount at all, and `ProjectCancelled()` was fired
     * from three different code paths with no parameters to tell them apart.
     *
     * `gross` and `fee` are both emitted, and `gross` is what `releasedGross`
     * accumulates. Previously the counter accumulated gross while the event
     * reported net, so any reconciliation drifted by exactly the fee.
     */
    event Funded(address indexed funder, uint256 amount);
    event MilestoneReleased(
        uint256 indexed index,
        address indexed developer,
        uint256 gross,
        uint256 fee
    );
    event MilestoneReclaimed(
        uint256 indexed index,
        address indexed funder,
        uint256 amount
    );
    event DisputeRaised(address indexed by, uint40 expiresAt, string reason);
    event DisputeWithdrawn(address indexed by);
    event Swept(address indexed caller, uint256 amount);
    event Closed(uint256 releasedGross, uint256 reclaimedTotal);

    /* -------------------------------------------------------- constructor */

    constructor(
        address _funder,
        address _developer,
        address _token,
        address _feeRecipient,
        uint16 _feeBps,
        uint128[] memory amounts,
        uint40[] memory deadlines
    ) {
        if (_funder == address(0) || _developer == address(0)) revert ZeroAddress();
        if (_token == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        if (_funder == _developer) revert SameParty();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (amounts.length == 0) revert NoMilestones();
        if (amounts.length > MAX_MILESTONES) revert TooManyMilestones();
        if (amounts.length != deadlines.length) revert LengthMismatch();

        funder = _funder;
        developer = _developer;
        token = IERC20(_token);
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;

        uint256 sum;
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
            // Mandatory and in the future. A past deadline would be reclaimable
            // the instant the escrow was funded, which is indistinguishable
            // from the funder being able to cancel at will.
            if (deadlines[i] <= block.timestamp) revert DeadlineNotInFuture();

            _milestones.push(
                Milestone({
                    amount: amounts[i],
                    deadline: deadlines[i],
                    status: MilestoneStatus.Pending
                })
            );
            sum += amounts[i];
        }

        totalAmount = sum;
        state = State.Created;
    }

    /* ---------------------------------------------------------- modifiers */

    modifier onlyFunder() {
        if (msg.sender != funder) revert NotFunder();
        _;
    }

    modifier inState(State expected) {
        if (state != expected) revert WrongState();
        _;
    }

    /* -------------------------------------------------------------- views */

    function milestones() external view returns (Milestone[] memory) {
        return _milestones;
    }

    function milestoneCount() external view returns (uint256) {
        return _milestones.length;
    }

    /// @notice True while a live dispute is blocking reclaim.
    function isFrozen() public view returns (bool) {
        return disputedAt != 0 && block.timestamp < disputedAt + DISPUTE_WINDOW;
    }

    /**
     * @notice Everything an interface needs for one escrow, in a single call.
     *
     * Rendering an escrow previously took five or more separate RPC reads.
     */
    function summary()
        external
        view
        returns (
            State currentState,
            uint256 total,
            uint256 released,
            uint256 reclaimed,
            uint256 balance,
            uint256 count,
            uint256 resolved,
            bool frozen,
            uint40 disputeExpiresAt
        )
    {
        return (
            state,
            totalAmount,
            releasedGross,
            reclaimedTotal,
            token.balanceOf(address(this)),
            _milestones.length,
            resolvedCount,
            isFrozen(),
            disputedAt == 0 ? 0 : disputedAt + DISPUTE_WINDOW
        );
    }

    /* --------------------------------------------------------------- fund */

    /**
     * @notice Deposits the full amount.
     *
     * The received amount is measured rather than assumed. A fee-on-transfer
     * token previously left the contract holding less than the milestones add
     * up to, and the shortfall surfaced as an unexplained revert on the final
     * release — after the work was done. Now it fails immediately, before
     * anyone relies on the escrow existing.
     */
    function fund() public onlyFunder inState(State.Created) nonReentrant {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), totalAmount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != totalAmount) revert AmountNotReceived(totalAmount, received);

        state = State.Funded;
        emit Funded(msg.sender, totalAmount);
    }

    /**
     * @notice Approve and deposit in one transaction, for EIP-2612 tokens.
     *
     * Removes a whole wallet confirmation from the funding flow. Falls back to
     * `fund()` for tokens without permit.
     */
    function fundWithPermit(
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyFunder inState(State.Created) {
        // A griefer can front-run a permit to make it revert; ignoring that
        // failure lets the deposit still succeed off an existing allowance.
        try
            IERC20Permit(address(token)).permit(
                msg.sender,
                address(this),
                totalAmount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}
        fund();
    }

    /* ------------------------------------------------------------ release */

    /**
     * @notice Pays milestones to the developer, minus the fee.
     *
     * Batched, because approving three finished milestones used to cost three
     * transactions. Allowed during a dispute: paying the other party is never
     * something the contract should block.
     */
    function release(uint256[] calldata indexes)
        external
        onlyFunder
        inState(State.Funded)
        nonReentrant
    {
        uint256 grossTotal;
        uint256 feeTotal;

        for (uint256 i; i < indexes.length; ++i) {
            uint256 index = indexes[i];
            Milestone storage milestone = _milestones[index];
            if (milestone.status != MilestoneStatus.Pending) revert AlreadyResolved();

            uint256 amount = milestone.amount;
            uint256 fee = (amount * feeBps) / 10_000;

            milestone.status = MilestoneStatus.Released;
            grossTotal += amount;
            feeTotal += fee;

            emit MilestoneReleased(index, developer, amount, fee);
        }

        // Effects before interactions, and one transfer per destination rather
        // than one per milestone.
        releasedGross += grossTotal;
        resolvedCount += uint16(indexes.length);

        token.safeTransfer(developer, grossTotal - feeTotal);
        if (feeTotal > 0) token.safeTransfer(feeRecipient, feeTotal);

        _closeIfResolved();
    }

    /* ------------------------------------------------------------ reclaim */

    /**
     * @notice Returns overdue, unreleased milestones to the funder.
     *
     * This is the only way money goes back, and it replaces both
     * `cancelMilestone` and the unrestricted `cancelProject`. The deadline is
     * the whole protection: until it passes, the funder cannot touch money
     * committed to work in progress.
     */
    function reclaim(uint256[] calldata indexes)
        external
        onlyFunder
        inState(State.Funded)
        nonReentrant
    {
        if (isFrozen()) revert Frozen();

        uint256 total;
        for (uint256 i; i < indexes.length; ++i) {
            uint256 index = indexes[i];
            Milestone storage milestone = _milestones[index];
            if (milestone.status != MilestoneStatus.Pending) revert AlreadyResolved();
            if (block.timestamp <= milestone.deadline) revert DeadlineNotPassed();

            milestone.status = MilestoneStatus.Reclaimed;
            total += milestone.amount;

            emit MilestoneReclaimed(index, funder, milestone.amount);
        }

        reclaimedTotal += total;
        resolvedCount += uint16(indexes.length);

        // No fee. This is the funder's own money coming back; charging to
        // return it would be charging for a service not rendered.
        token.safeTransfer(funder, total);

        _closeIfResolved();
    }

    /* ----------------------------------------------------------- disputes */

    /**
     * @notice Freezes reclaim for `DISPUTE_WINDOW`.
     *
     * Once per party. Without that cap, raising and withdrawing in a loop
     * would let one side keep the escrow frozen indefinitely.
     *
     * The reason is emitted, not stored: it is read by people, and a string in
     * storage costs a great deal to write and nothing can act on it.
     */
    function raiseDispute(string calldata reason) external inState(State.Funded) {
        if (msg.sender == funder) {
            if (funderRaisedDispute) revert AlreadyRaised();
            funderRaisedDispute = true;
        } else if (msg.sender == developer) {
            if (developerRaisedDispute) revert AlreadyRaised();
            developerRaisedDispute = true;
        } else {
            revert NotParty();
        }

        disputedAt = uint40(block.timestamp);
        emit DisputeRaised(msg.sender, uint40(block.timestamp) + DISPUTE_WINDOW, reason);
    }

    /**
     * @notice Lifts a live dispute early.
     *
     * Only the party who raised it. The previous contract had no way out of a
     * dispute at all — raising one permanently ended milestone releases and
     * forced an all-or-nothing outcome, even if both parties agreed within
     * minutes that it had been a mistake.
     */
    function withdrawDispute() external {
        if (!isFrozen()) revert NotDisputed();

        bool raisedByCaller = (msg.sender == funder && funderRaisedDispute) ||
            (msg.sender == developer && developerRaisedDispute);
        if (!raisedByCaller) revert NotDisputeRaiser();

        disputedAt = 0;
        emit DisputeWithdrawn(msg.sender);
    }

    /* -------------------------------------------------------------- sweep */

    /**
     * @notice Returns everything unresolved to the funder, long after the last
     * deadline. Callable by anyone, because the destination is fixed.
     */
    function sweep() external inState(State.Funded) nonReentrant {
        uint256 count = _milestones.length;
        uint40 latest;
        for (uint256 i; i < count; ++i) {
            uint40 deadline = _milestones[i].deadline;
            if (deadline > latest) latest = deadline;
        }
        if (block.timestamp < latest + SWEEP_GRACE) revert DeadlineNotPassed();

        uint256 total;
        for (uint256 i; i < count; ++i) {
            Milestone storage milestone = _milestones[i];
            if (milestone.status != MilestoneStatus.Pending) continue;
            milestone.status = MilestoneStatus.Reclaimed;
            total += milestone.amount;
            emit MilestoneReclaimed(i, funder, milestone.amount);
        }
        if (total == 0) revert NothingToSweep();

        reclaimedTotal += total;
        resolvedCount = uint16(count);
        state = State.Closed;

        token.safeTransfer(funder, total);
        emit Swept(msg.sender, total);
        emit Closed(releasedGross, reclaimedTotal);
    }

    /* ------------------------------------------------------------ closing */

    /**
     * Closes once every milestone is resolved, whichever way each went.
     *
     * The previous contract had two asymmetric checks — completion accepted
     * "released or cancelled" while cancellation required *all* cancelled — so
     * releasing one milestone and cancelling another left the project stuck in
     * an active state forever, with a zero balance and no way to reach a
     * terminal state. A counter replaces both, and also removes the O(n)
     * storage loop that ran on every single release.
     */
    function _closeIfResolved() private {
        if (resolvedCount == _milestones.length) {
            state = State.Closed;
            emit Closed(releasedGross, reclaimedTotal);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title SimpleMilestoneEscrow
 * @notice A simple escrow contract between a funder and developer with milestones
 * @dev No upgradeability, no factory, no arbitrator - just funder and developer
 */
contract SimpleMilestoneEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ========== ERRORS ==========
    error NotFunder();
    error NotDeveloper();
    error InvalidState();
    error InvalidMilestone();
    error AlreadyReleased();
    error ZeroAddress();
    error ZeroAmount();
    error DeadlineNotPassed();
    error NotFunded();
    error AlreadyFunded();
    
    // ========== ENUMS ==========
    enum ProjectState {
        Created,    // Contract deployed
        Funded,     // Tokens transferred in
        Completed,  // All milestones released
        Cancelled,  // Project cancelled
        Disputed    // Dispute raised
    }
    
    // ========== STRUCTS ==========
    struct Milestone {
        uint256 amount;
        bool released;
        bool cancelled;
        uint256 deadline; // 0 = no deadline
        string description;
    }
    
    // ========== STATE VARIABLES ==========
    address public immutable funder;
    address public immutable developer;
    IERC20 public immutable paymentToken;
    
    // Fee configuration - using proper checksum
    address public constant FEE_RECIPIENT = 0xC869d7a99fa831b4B3bEe7e245F0C9348C2209a3;
    uint256 public constant FEE_BASIS_POINTS = 150; // 1.5% = 150 basis points
    
    ProjectState public state;
    uint256 public totalAmount;
    uint256 public releasedAmount;
    uint256 public totalFeesCollected;
    
    Milestone[] public milestones;
    uint256 public disputeRaisedAt;
    
    // ========== EVENTS ==========
    event MilestoneReleased(uint256 indexed index, uint256 amount, uint256 feeAmount);
    event MilestoneCancelled(uint256 indexed index, uint256 amount);
    event FeePaid(uint256 amount, address indexed recipient);
    event DisputeRaised(address indexed by, string reason);
    event DisputeResolved(bool completed);
    event ProjectFunded(uint256 amount);
    event ProjectCompleted();
    event ProjectCancelled();
    
    // ========== MODIFIERS ==========
    modifier onlyFunder() {
        if (msg.sender != funder) revert NotFunder();
        _;
    }
    
    modifier onlyDeveloper() {
        if (msg.sender != developer) revert NotDeveloper();
        _;
    }
    
    modifier onlyParties() {
        require(msg.sender == funder || msg.sender == developer, "Not authorized");
        _;
    }
    
    modifier inState(ProjectState _state) {
        if (state != _state) revert InvalidState();
        _;
    }
    
    modifier milestoneExists(uint256 index) {
        if (index >= milestones.length) revert InvalidMilestone();
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    /**
     * @notice Deploy a new escrow contract
     * @param _funder The funder address
     * @param _developer The developer address
     * @param _token The ERC20 token address for payments
     * @param _milestoneAmounts Array of milestone amounts
     * @param _milestoneDeadlines Array of milestone deadlines (timestamp, 0 = no deadline)
     * @param _milestoneDescriptions Array of milestone descriptions
     */
    constructor(
        address _funder,
        address _developer,
        address _token,
        uint256[] memory _milestoneAmounts,
        uint256[] memory _milestoneDeadlines,
        string[] memory _milestoneDescriptions
    ) {
        // Validate inputs
        require(_funder != address(0), "Invalid funder");
        require(_developer != address(0), "Invalid developer");
        require(_token != address(0), "Invalid token");
        require(_funder != _developer, "Funder cannot be developer");
        require(_milestoneAmounts.length > 0, "No milestones");
        require(
            _milestoneAmounts.length == _milestoneDeadlines.length && 
            _milestoneAmounts.length == _milestoneDescriptions.length,
            "Invalid milestone arrays"
        );
        
        funder = _funder;
        developer = _developer;
        paymentToken = IERC20(_token);
        
        // Create milestones
        uint256 sum = 0;
        for (uint256 i = 0; i < _milestoneAmounts.length; i++) {
            require(_milestoneAmounts[i] > 0, "Zero milestone amount");
            
            milestones.push(Milestone({
                amount: _milestoneAmounts[i],
                released: false,
                cancelled: false,
                deadline: _milestoneDeadlines[i],
                description: _milestoneDescriptions[i]
            }));
            sum += _milestoneAmounts[i];
        }
        
        totalAmount = sum;
        state = ProjectState.Created;
    }
    
    // ========== PUBLIC FUNCTIONS ==========
    
    /**
     * @notice Fund the escrow with tokens
     * @dev Must be called by funder after approving tokens
     */
    function fund() external onlyFunder inState(ProjectState.Created) nonReentrant {
        // Transfer tokens from funder to contract
        paymentToken.safeTransferFrom(msg.sender, address(this), totalAmount);
        
        state = ProjectState.Funded;
        emit ProjectFunded(totalAmount);
    }
    
    /**
     * @notice Release a milestone payment to developer with 1.5% fee
     * @param index The milestone index to release
     * @dev Funder can release milestones at any time, even after deadline
     */
    function releaseMilestone(uint256 index) 
        external 
        onlyFunder 
        inState(ProjectState.Funded)
        milestoneExists(index)
        nonReentrant 
    {
        Milestone storage milestone = milestones[index];
        
        require(!milestone.released, "Already released");
        require(!milestone.cancelled, "Milestone cancelled");
        
        // REMOVED: Deadline check - funder can release even after deadline
        
        milestone.released = true;
        releasedAmount += milestone.amount;
        
        // Calculate 1.5% fee
        uint256 feeAmount = (milestone.amount * FEE_BASIS_POINTS) / 10000;
        uint256 developerAmount = milestone.amount - feeAmount;
        
        // Transfer fee to fee recipient
        if (feeAmount > 0) {
            paymentToken.safeTransfer(FEE_RECIPIENT, feeAmount);
            totalFeesCollected += feeAmount;
            emit FeePaid(feeAmount, FEE_RECIPIENT);
        }
        
        // Transfer remaining amount to developer
        paymentToken.safeTransfer(developer, developerAmount);
        
        emit MilestoneReleased(index, developerAmount, feeAmount);
        
        // Check if all milestones are completed
        _checkCompletion();
    }
    
    /**
     * @notice Cancel a milestone after deadline
     * @param index The milestone index to cancel
     * @dev Can only cancel if deadline has passed and milestone not released
     */
    function cancelMilestone(uint256 index) 
        external 
        onlyFunder 
        inState(ProjectState.Funded)
        milestoneExists(index)
        nonReentrant 
    {
        Milestone storage milestone = milestones[index];
        
        require(!milestone.released, "Already released");
        require(!milestone.cancelled, "Already cancelled");
        require(milestone.deadline > 0, "No deadline set");
        require(block.timestamp > milestone.deadline, "Deadline not passed");
        
        milestone.cancelled = true;
        
        // Refund to funder (no fee on cancelled milestones)
        paymentToken.safeTransfer(funder, milestone.amount);
        
        emit MilestoneCancelled(index, milestone.amount);
        
        // Check if all milestones are cancelled
        _checkCancellation();
    }
    
    /**
     * @notice Raise a dispute
     * @param reason The reason for dispute
     */
    function raiseDispute(string memory reason) 
        external 
        onlyParties 
        inState(ProjectState.Funded) 
    {
        state = ProjectState.Disputed;
        disputeRaisedAt = block.timestamp;
        emit DisputeRaised(msg.sender, reason);
    }
    
    /**
     * @notice Resolve dispute by releasing to developer (after 30 days)
     * @dev No fee taken on dispute resolution
     */
    function resolveDisputeToDeveloper() 
        external 
        onlyDeveloper 
        inState(ProjectState.Disputed)
        nonReentrant 
    {
        require(block.timestamp >= disputeRaisedAt + 30 days, "30 days not passed");
        
        uint256 remaining = _getRemainingBalance();
        if (remaining > 0) {
            paymentToken.safeTransfer(developer, remaining);
            releasedAmount += remaining;
        }
        
        state = ProjectState.Completed;
        emit DisputeResolved(true);
        emit ProjectCompleted();
    }
    
    /**
     * @notice Resolve dispute by refunding to funder
     * @dev No fee taken on dispute resolution
     */
    function resolveDisputeToFunder() 
        external 
        onlyFunder 
        inState(ProjectState.Disputed)
        nonReentrant 
    {
        uint256 remaining = _getRemainingBalance();
        if (remaining > 0) {
            paymentToken.safeTransfer(funder, remaining);
        }
        
        state = ProjectState.Cancelled;
        emit DisputeResolved(false);
        emit ProjectCancelled();
    }
    
    /**
     * @notice Cancel the project and refund all remaining funds
     * @dev No fee taken on project cancellation
     */
    function cancelProject() 
        external 
        onlyFunder 
        inState(ProjectState.Funded)
        nonReentrant 
    {
        uint256 remaining = _getRemainingBalance();
        if (remaining > 0) {
            paymentToken.safeTransfer(funder, remaining);
        }
        
        state = ProjectState.Cancelled;
        emit ProjectCancelled();
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get all milestones
     */
    function getMilestones() external view returns (Milestone[] memory) {
        return milestones;
    }
    
    /**
     * @notice Get remaining balance
     */
    function getRemainingBalance() external view returns (uint256) {
        return _getRemainingBalance();
    }
    
    /**
     * @notice Get contract balance
     */
    function getContractBalance() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }
    
    /**
     * @notice Check if dispute is expired
     */
    function isDisputeExpired() external view returns (bool) {
        if (state != ProjectState.Disputed) return false;
        return block.timestamp >= disputeRaisedAt + 30 days;
    }
    
    /**
     * @notice Get milestone count
     */
    function milestoneCount() external view returns (uint256) {
        return milestones.length;
    }
    
    /**
     * @notice Get project status as string
     */
    function getStatus() external view returns (string memory) {
        if (state == ProjectState.Created) return "Created (Waiting for funds)";
        if (state == ProjectState.Funded) return "Funded (Active)";
        if (state == ProjectState.Completed) return "Completed";
        if (state == ProjectState.Cancelled) return "Cancelled";
        if (state == ProjectState.Disputed) return "Disputed";
        return "Unknown";
    }
    
    /**
     * @notice Calculate fee for a given amount
     * @param amount The amount to calculate fee for
     * @return feeAmount The calculated fee amount
     */
    function calculateFee(uint256 amount) public pure returns (uint256) {
        return (amount * FEE_BASIS_POINTS) / 10000;
    }
    
    /**
     * @notice Get net amount after fee for a given amount
     * @param amount The original amount
     * @return netAmount The amount after deducting 1.5% fee
     */
    function getNetAmount(uint256 amount) public pure returns (uint256) {
        return amount - calculateFee(amount);
    }
    
    /**
     * @notice Get fee configuration
     */
    function getFeeInfo() external pure returns (address recipient, uint256 basisPoints) {
        return (FEE_RECIPIENT, FEE_BASIS_POINTS);
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @dev Check if project is completed
     */
    function _checkCompletion() internal {
        for (uint256 i = 0; i < milestones.length; i++) {
            if (!milestones[i].released && !milestones[i].cancelled) {
                return;
            }
        }
        state = ProjectState.Completed;
        emit ProjectCompleted();
    }
    
    /**
     * @dev Check if project is cancelled
     */
    function _checkCancellation() internal {
        for (uint256 i = 0; i < milestones.length; i++) {
            if (!milestones[i].cancelled) {
                return;
            }
        }
        state = ProjectState.Cancelled;
        emit ProjectCancelled();
    }
    
    /**
     * @dev Get remaining balance in contract
     */
    function _getRemainingBalance() internal view returns (uint256) {
        uint256 balance = paymentToken.balanceOf(address(this));
        
        // If not funded yet, return 0
        if (state == ProjectState.Created) {
            return 0;
        }
        
        return balance;
    }
}
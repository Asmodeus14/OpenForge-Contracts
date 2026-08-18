// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MilestoneEscrow} from "./MilestoneEscrow.sol";

/**
 * @title EscrowFactory
 * @notice Deploys milestone escrows and is the registry of the ones it made.
 *
 * ## Why these are one contract
 *
 * The registry it replaces accepted *any* address as an escrow, authenticated
 * only by asking that address whether `funder()` returned the caller. Ten
 * lines of Solidity returning `msg.sender` were enough to register a contract
 * that held no money, under any title, and have the product list it as a real
 * escrow. The registry was the frontend's source of truth for what exists, so
 * the whole project list was spoofable.
 *
 * A registry that deploys the thing it registers cannot be lied to. There is
 * no `register` function to abuse, because registration is not a separate
 * step — which also removes a transaction from every project's setup.
 *
 * ## What is not stored here
 *
 * Title, description and tags used to occupy three storage slots per project,
 * one of them a dynamic `string[]`, alongside a `projectCIDs` mapping holding
 * an IPFS pointer to the same information. Only the pointer survives. Editing
 * a typo is now a pin, not a storage write, and the on-chain record shrinks
 * from ten slots to four.
 */
contract EscrowFactory {
    error ZeroAddress();
    error FeeTooHigh();
    error NotOwner();
    error UnknownProject();

    struct Project {
        // slot 0
        address escrow; // 20 bytes
        bool active; // 1 byte
        // slot 1
        address funder; // 20 bytes
        uint64 createdAt; // 8 bytes
        // slot 2
        address developer; // 20 bytes
        // slot 3
        string metadataCID;
    }

    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Where release fees go. Immutable, but not a compile-time
    /// constant baked into every escrow's bytecode as it was before — a lost
    /// or compromised key previously meant every past and future escrow paid
    /// fees to a dead address with no way to change it.
    address public immutable feeRecipient;
    uint16 public immutable feeBps;

    Project[] private _projects;

    /// @notice True only for escrows this factory deployed.
    mapping(address => bool) public isOfficialEscrow;
    mapping(address => uint256) public projectIdOf;
    mapping(address => uint256[]) private _projectsByUser;

    /**
     * `developer` is indexed. The previous event indexed the escrow address
     * instead — which is derivable from the project id — leaving a developer
     * unable to filter for "projects where I am being paid" without fetching
     * and decoding every log the registry ever emitted.
     */
    event ProjectCreated(
        uint256 indexed projectId,
        address indexed funder,
        address indexed developer,
        address escrow,
        address token,
        uint256 totalAmount,
        string metadataCID
    );
    event ProjectMetadataUpdated(uint256 indexed projectId, string metadataCID);
    event ProjectDeactivated(uint256 indexed projectId);

    constructor(address _feeRecipient, uint16 _feeBps) {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
    }

    /**
     * @notice Deploys an escrow and records it, in one transaction.
     *
     * The caller is the funder. Setting up a project used to take four
     * transactions — deploy, register, approve, deposit — of which this
     * removes one, and `MilestoneEscrow.fundWithPermit` removes another.
     */
    function createEscrow(
        address developer,
        address token,
        uint128[] calldata amounts,
        uint40[] calldata deadlines,
        string calldata metadataCID
    ) external returns (address escrowAddress, uint256 projectId) {
        MilestoneEscrow escrow = new MilestoneEscrow(
            msg.sender,
            developer,
            token,
            feeRecipient,
            feeBps,
            amounts,
            deadlines
        );

        escrowAddress = address(escrow);
        projectId = _projects.length;

        _projects.push(
            Project({
                escrow: escrowAddress,
                active: true,
                funder: msg.sender,
                createdAt: uint64(block.timestamp),
                developer: developer,
                metadataCID: metadataCID
            })
        );

        isOfficialEscrow[escrowAddress] = true;
        projectIdOf[escrowAddress] = projectId;
        _projectsByUser[msg.sender].push(projectId);
        _projectsByUser[developer].push(projectId);

        emit ProjectCreated(
            projectId,
            msg.sender,
            developer,
            escrowAddress,
            token,
            escrow.totalAmount(),
            metadataCID
        );
    }

    /* -------------------------------------------------------------- owner */

    /**
     * Only the project's funder may edit it, and only the metadata pointer.
     *
     * The previous registry let the *platform owner* rewrite any project's
     * title, description and tags, and `forceRegisterProject` let them invent
     * entries naming arbitrary funders and developers. There is no
     * platform-owner role here at all.
     */
    modifier onlyProjectFunder(uint256 projectId) {
        if (projectId >= _projects.length) revert UnknownProject();
        if (_projects[projectId].funder != msg.sender) revert NotOwner();
        _;
    }

    function setMetadata(uint256 projectId, string calldata metadataCID)
        external
        onlyProjectFunder(projectId)
    {
        _projects[projectId].metadataCID = metadataCID;
        emit ProjectMetadataUpdated(projectId, metadataCID);
    }

    /// @notice Hides a project from listings. The escrow itself is untouched.
    function deactivate(uint256 projectId) external onlyProjectFunder(projectId) {
        _projects[projectId].active = false;
        emit ProjectDeactivated(projectId);
    }

    /* -------------------------------------------------------------- views */

    function totalProjects() external view returns (uint256) {
        return _projects.length;
    }

    function getProject(uint256 projectId) external view returns (Project memory) {
        if (projectId >= _projects.length) revert UnknownProject();
        return _projects[projectId];
    }

    /// @notice A page of projects, newest first.
    function getProjects(uint256 offset, uint256 limit)
        external
        view
        returns (Project[] memory page)
    {
        uint256 total = _projects.length;
        if (offset >= total) return new Project[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new Project[](end - offset);
        for (uint256 i; i < page.length; ++i) {
            // Newest first, so a listing does not have to page to the end to
            // find recent work.
            page[i] = _projects[total - 1 - (offset + i)];
        }
    }

    /**
     * @notice Every project a wallet funds or builds, resolved in one call.
     *
     * The previous registry returned ids only, so listing a user's projects
     * cost one further RPC read per id.
     */
    function getProjectsByUser(address user) external view returns (Project[] memory) {
        uint256[] storage ids = _projectsByUser[user];
        Project[] memory out = new Project[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = _projects[ids[i]];
        }
        return out;
    }
}

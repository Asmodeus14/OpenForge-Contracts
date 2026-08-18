// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./EScrow_cont.sol";

/**
 * @title OpenForgeProjectRegistry
 * @notice Registry to map project IDs to escrow contracts
 * @dev Maintains project metadata and escrow contract references
 */
contract OpenForgeProjectRegistry is Ownable {
    // ========== ERRORS ==========
    error ProjectNotFound();
    error ProjectAlreadyRegistered();
    error NotProjectOwner();
    error InvalidProjectId();
    error ZeroAddress();
    
    // ========== STRUCTS ==========
    struct Project {
        uint256 projectId;
        address escrowAddress;
        address funder;
        address developer;
        string title;
        string description;
        string[] tags;
        uint256 createdAt;
        uint256 updatedAt;
        bool active;
    }
    
    struct EscrowInfo {
        address escrowAddress;
        uint256 projectId;
        address paymentToken;
        uint256 totalAmount;
        uint256[] milestoneAmounts;
        string[] milestoneDescriptions;
    }
    
    // ========== STATE VARIABLES ==========
    uint256 private _nextProjectId;
    
    // Project ID -> Project mapping
    mapping(uint256 => Project) public projects;
    
    // Escrow address -> Project ID mapping
    mapping(address => uint256) public escrowToProjectId;
    
    // User address -> list of project IDs
    mapping(address => uint256[]) public userProjects;
    
    // Project ID -> metadata CID (for IPFS)
    mapping(uint256 => string) public projectCIDs;
    
    // ========== EVENTS ==========
    event ProjectRegistered(
        uint256 indexed projectId,
        address indexed escrowAddress,
        address indexed funder,
        address developer,
        string title
    );
    
    event ProjectUpdated(
        uint256 indexed projectId,
        string title,
        string description,
        string[] tags
    );
    
    event ProjectMetadataUpdated(
        uint256 indexed projectId,
        string cid
    );
    
    event ProjectDeactivated(uint256 indexed projectId);
    
    // ========== MODIFIERS ==========
    modifier projectExists(uint256 projectId) {
        if (projects[projectId].escrowAddress == address(0)) {
            revert ProjectNotFound();
        }
        _;
    }
    
    modifier onlyProjectOwner(uint256 projectId) {
        Project storage project = projects[projectId];
        if (msg.sender != project.funder && msg.sender != owner()) {
            revert NotProjectOwner();
        }
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    constructor() Ownable(msg.sender) {
        _nextProjectId = 1; // Start from 1
    }
    
    // ========== MAIN FUNCTIONS ==========
    
    /**
     * @notice Register a new project with escrow contract
     * @param escrowAddress The deployed escrow contract address
     * @param title Project title
     * @param description Project description
     * @param tags Array of tags
     * @return projectId The assigned project ID
     */
    function registerProject(
        address escrowAddress,
        string memory title,
        string memory description,
        string[] memory tags
    ) external returns (uint256 projectId) {
        if (escrowAddress == address(0)) revert ZeroAddress();
        if (escrowToProjectId[escrowAddress] != 0) revert ProjectAlreadyRegistered();
        
        // Get escrow contract info
        SimpleMilestoneEscrow escrow = SimpleMilestoneEscrow(escrowAddress);
        
        // Verify caller is the funder
        require(msg.sender == escrow.funder(), "Only funder can register");
        
        // Assign project ID
        projectId = _nextProjectId++;
        
        // Create project
        projects[projectId] = Project({
            projectId: projectId,
            escrowAddress: escrowAddress,
            funder: escrow.funder(),
            developer: escrow.developer(),
            title: title,
            description: description,
            tags: tags,
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            active: true
        });
        
        // Set mappings
        escrowToProjectId[escrowAddress] = projectId;
        
        // Add to user's project list
        userProjects[escrow.funder()].push(projectId);
        userProjects[escrow.developer()].push(projectId);
        
        emit ProjectRegistered(
            projectId,
            escrowAddress,
            escrow.funder(),
            escrow.developer(),
            title
        );
        
        return projectId;
    }
    
    /**
     * @notice Update project metadata
     * @param projectId The project ID
     * @param title New title
     * @param description New description
     * @param tags New tags
     */
    function updateProject(
        uint256 projectId,
        string memory title,
        string memory description,
        string[] memory tags
    ) external projectExists(projectId) onlyProjectOwner(projectId) {
        Project storage project = projects[projectId];
        
        project.title = title;
        project.description = description;
        project.tags = tags;
        project.updatedAt = block.timestamp;
        
        emit ProjectUpdated(projectId, title, description, tags);
    }
    
    /**
     * @notice Set IPFS CID for project metadata
     * @param projectId The project ID
     * @param cid The IPFS CID
     */
    function setProjectCID(
        uint256 projectId,
        string memory cid
    ) external projectExists(projectId) onlyProjectOwner(projectId) {
        projectCIDs[projectId] = cid;
        emit ProjectMetadataUpdated(projectId, cid);
    }
    
    /**
     * @notice Deactivate a project (can be reactivated by updating)
     * @param projectId The project ID
     */
    function deactivateProject(
        uint256 projectId
    ) external projectExists(projectId) onlyProjectOwner(projectId) {
        projects[projectId].active = false;
        emit ProjectDeactivated(projectId);
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get project details
     * @param projectId The project ID
     * @return Project struct with all details
     */
    function getProject(
        uint256 projectId
    ) external view projectExists(projectId) returns (Project memory) {
        return projects[projectId];
    }
    
    /**
     * @notice Get escrow info for a project
     * @param projectId The project ID
     * @return EscrowInfo struct with escrow details
     */
    function getEscrowInfo(
        uint256 projectId
    ) external view projectExists(projectId) returns (EscrowInfo memory) {
        Project storage project = projects[projectId];
        SimpleMilestoneEscrow escrow = SimpleMilestoneEscrow(project.escrowAddress);
        
        // Get milestone info
        uint256 count = escrow.milestoneCount();
        uint256[] memory amounts = new uint256[](count);
        string[] memory descriptions = new string[](count);
        
        for (uint256 i = 0; i < count; i++) {
            (uint256 amount, , , uint256 deadline, string memory description) = escrow.milestones(i);
            amounts[i] = amount;
            descriptions[i] = string(abi.encodePacked(
                description,
                " (Deadline: ",
                deadline == 0 ? "None" : _timestampToString(deadline),
                ")"
            ));
        }
        
        return EscrowInfo({
            escrowAddress: project.escrowAddress,
            projectId: projectId,
            paymentToken: address(escrow.paymentToken()),
            totalAmount: escrow.totalAmount(),
            milestoneAmounts: amounts,
            milestoneDescriptions: descriptions
        });
    }
    
    /**
     * @notice Get project ID for an escrow contract
     * @param escrowAddress The escrow contract address
     * @return projectId The project ID
     */
    function getProjectIdByEscrow(
        address escrowAddress
    ) external view returns (uint256) {
        uint256 projectId = escrowToProjectId[escrowAddress];
        if (projectId == 0) revert ProjectNotFound();
        return projectId;
    }
    
    /**
     * @notice Get all projects for a user
     * @param user The user address
     * @return Array of project IDs
     */
    function getUserProjects(
        address user
    ) external view returns (uint256[] memory) {
        return userProjects[user];
    }
    
    /**
     * @notice Get all projects with pagination
     * @param offset Starting index
     * @param limit Maximum number of projects to return
     * @return Array of Project structs
     */
    function getAllProjects(
        uint256 offset,
        uint256 limit
    ) external view returns (Project[] memory) {
        require(offset < _nextProjectId, "Offset too high");
        
        uint256 end = offset + limit;
        if (end > _nextProjectId - 1) {
            end = _nextProjectId - 1;
        }
        
        uint256 resultSize = end - offset;
        Project[] memory result = new Project[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            uint256 projectId = offset + i + 1; // +1 because project IDs start from 1
            result[i] = projects[projectId];
        }
        
        return result;
    }
    
    /**
     * @notice Get total number of projects
     * @return Total project count
     */
    function getTotalProjects() external view returns (uint256) {
        return _nextProjectId - 1; // Subtract 1 because IDs start from 1
    }
    
    /**
     * @notice Check if project is active
     * @param projectId The project ID
     * @return bool True if project is active
     */
    function isProjectActive(
        uint256 projectId
    ) external view projectExists(projectId) returns (bool) {
        return projects[projectId].active;
    }
    
    /**
     * @notice Get project status from escrow contract
     * @param projectId The project ID
     * @return string status from escrow contract
     */
    function getProjectStatus(
        uint256 projectId
    ) external view projectExists(projectId) returns (string memory) {
        Project storage project = projects[projectId];
        SimpleMilestoneEscrow escrow = SimpleMilestoneEscrow(project.escrowAddress);
        return escrow.getStatus();
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Force register a project (admin only)
     * @dev Use this if registration fails or for migration
     */
    function forceRegisterProject(
        address escrowAddress,
        address funder,
        address developer,
        string memory title,
        string memory description,
        string[] memory tags
    ) external onlyOwner returns (uint256 projectId) {
        if (escrowAddress == address(0)) revert ZeroAddress();
        if (escrowToProjectId[escrowAddress] != 0) revert ProjectAlreadyRegistered();
        
        projectId = _nextProjectId++;
        
        projects[projectId] = Project({
            projectId: projectId,
            escrowAddress: escrowAddress,
            funder: funder,
            developer: developer,
            title: title,
            description: description,
            tags: tags,
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            active: true
        });
        
        escrowToProjectId[escrowAddress] = projectId;
        userProjects[funder].push(projectId);
        userProjects[developer].push(projectId);
        
        emit ProjectRegistered(
            projectId,
            escrowAddress,
            funder,
            developer,
            title
        );
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @dev Convert timestamp to readable string
     */
    function _timestampToString(
        uint256 timestamp
    ) internal pure returns (string memory) {
        if (timestamp == 0) return "No deadline";
        
        // Simple conversion to date string
        // In production, you might want to use a library
        return string(abi.encodePacked(
            uint2str(timestamp / 86400), " days"
        ));
    }
    
    /**
     * @dev Convert uint to string
     */
    function uint2str(
        uint256 _i
    ) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k-1;
            uint8 temp = uint8(48 + _i % 10);
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
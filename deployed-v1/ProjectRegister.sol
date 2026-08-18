// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract ProjectRegistry {
    // --- Events ---
    event ProjectRegistered(uint256 indexed projectId, address indexed builder, string metadataCID);
    event ProjectStatusUpdated(uint256 indexed projectId, uint8 oldStatus, uint8 newStatus);
    event ProjectMetadataUpdated(uint256 indexed projectId, string newMetadataCID); // NEW EVENT

    // --- Types ---
    enum Status { Draft, Funding, Completed, Failed }

    struct Project {
        address builder;
        string metadataCID; // IPFS or similar content hash
        Status status;
    }

    // --- State ---
    uint256 public nextProjectId;
    mapping(uint256 => Project) private projects;

    // --- Modifiers ---
    modifier onlyBuilder(uint256 projectId) {
        require(projects[projectId].builder == msg.sender, "Not project builder");
        _;
    }

    modifier validProject(uint256 projectId) {
        require(projectId < nextProjectId, "Invalid project ID");
        _;
    }

    modifier onlyDraftStatus(uint256 projectId) {
        require(projects[projectId].status == Status.Draft, "Can only update metadata in Draft status");
        _;
    }

    // --- Functions ---

    /// Register a new project with metadata CID (IPFS hash)
    function registerProject(string calldata metadataCID) external returns (uint256) {
        uint256 projectId = nextProjectId;
        projects[projectId] = Project({
            builder: msg.sender,
            metadataCID: metadataCID,
            status: Status.Draft
        });
        nextProjectId++;
        emit ProjectRegistered(projectId, msg.sender, metadataCID);
        return projectId;
    }

    /// Update project metadata CID (only builder can update, only in Draft status)
    function updateProjectMetadata(uint256 projectId, string calldata newMetadataCID) 
        external 
        validProject(projectId) 
        onlyBuilder(projectId)
        onlyDraftStatus(projectId)
    {
        Project storage proj = projects[projectId];
        proj.metadataCID = newMetadataCID;
        emit ProjectMetadataUpdated(projectId, newMetadataCID);
    }

    /// Update project status (only builder can update)
    function updateProjectStatus(uint256 projectId, Status newStatus) 
        external 
        validProject(projectId) 
        onlyBuilder(projectId) 
    {
        Project storage proj = projects[projectId];
        Status oldStatus = proj.status;
        require(newStatus != oldStatus, "Status unchanged");

        // Allowed status transitions:
        // Draft -> Funding
        // Funding -> Completed
        // Funding -> Failed
        require(
            (oldStatus == Status.Draft && newStatus == Status.Funding) ||
            (oldStatus == Status.Funding && (newStatus == Status.Completed || newStatus == Status.Failed)),
            "Invalid status transition"
        );

        proj.status = newStatus;
        emit ProjectStatusUpdated(projectId, uint8(oldStatus), uint8(newStatus));
    }

    /// Get project details by id
    function getProject(uint256 projectId) 
        external 
        view 
        validProject(projectId) 
        returns (address builder, string memory metadataCID, Status status) 
    {
        Project storage proj = projects[projectId];
        return (proj.builder, proj.metadataCID, proj.status);
    }
}
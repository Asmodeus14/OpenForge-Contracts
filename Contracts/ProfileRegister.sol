// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ProfileRegistry
 * @author OpenForge
 * @notice Maps a wallet address to a profile metadata CID (stored on IPFS/Arweave)
 * @dev This contract is intentionally minimal and neutral
 */
contract ProfileRegistry {

    /// @notice Emitted when a profile is created
    event ProfileCreated(address indexed user, string cid);

    /// @notice Emitted when a profile is updated
    event ProfileUpdated(address indexed user, string oldCid, string newCid);

    /// @dev Wallet => profile metadata CID
    mapping(address => string) private _profileCID;

    /// @dev Wallet => last update timestamp
    mapping(address => uint256) public lastUpdated;

    /// @dev Wallet => profile existence
    mapping(address => bool) public hasProfile;

    /// @notice Cooldown period for profile updates (14 days)
    uint256 public constant UPDATE_COOLDOWN = 14 days;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyExistingProfile() {
        require(hasProfile[msg.sender], "Profile does not exist");
        _;
    }

    modifier onlyNewProfile() {
        require(!hasProfile[msg.sender], "Profile already exists");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new profile for the caller
     * @param cid IPFS/Arweave CID pointing to profile metadata JSON
     */
    function createProfile(string calldata cid) external onlyNewProfile {
        require(bytes(cid).length > 0, "Invalid CID");

        hasProfile[msg.sender] = true;
        _profileCID[msg.sender] = cid;
        lastUpdated[msg.sender] = block.timestamp;

        emit ProfileCreated(msg.sender, cid);
    }

    /**
     * @notice Update existing profile metadata
     * @param newCid New IPFS/Arweave CID
     */
    function updateProfile(string calldata newCid) external onlyExistingProfile {
        require(bytes(newCid).length > 0, "Invalid CID");
        require(
            block.timestamp >= lastUpdated[msg.sender] + UPDATE_COOLDOWN,
            "Update cooldown active"
        );

        string memory oldCid = _profileCID[msg.sender];
        _profileCID[msg.sender] = newCid;
        lastUpdated[msg.sender] = block.timestamp;

        emit ProfileUpdated(msg.sender, oldCid, newCid);
    }

    /**
     * @notice Get profile metadata CID for a user
     * @param user Wallet address
     */
    function getProfile(address user) external view returns (string memory) {
        require(hasProfile[user], "Profile not found");
        return _profileCID[user];
    }
}

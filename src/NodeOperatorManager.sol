// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../src/interfaces/INodeOperatorManager.sol";
import "../src/interfaces/IAuctionManager.sol";
import "../src/LiquidityPool.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/// Contract which helps us control our node operators and their permissions in different aspects of the protocol
contract NodeOperatorManager is INodeOperatorManager, Initializable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable {

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event OperatorRegistered(address operator, uint64 totalKeys, uint64 keysUsed, bytes ipfsHash);
    event AddedToWhitelist(address userAddress);
    event RemovedFromWhitelist(address userAddress);
    event UpdatedOperatorApprovals(address operator, LiquidityPool.SourceOfFunds source, bool approved);

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    address public auctionManagerContractAddress;

    // user address => OperaterData Struct
    mapping(address => KeyData) public addressToOperatorData;
    mapping(address => bool) private whitelistedAddresses;
    mapping(address => bool) public registered;

    mapping(address => bool) public admins;
    mapping(address => mapping(ILiquidityPool.SourceOfFunds => bool)) public operatorApprovedTags;

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initializes contract
    function initialize() external initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Registers a user as a operator to allow them to bid
    /// @param _ipfsHash location of all IPFS data stored for operator
    /// @param _totalKeys The number of keys they have available, relates to how many validators they can run
    function registerNodeOperator(
        bytes memory _ipfsHash,
        uint64 _totalKeys
    ) public whenNotPaused {
        require(!registered[msg.sender], "Already registered");
        
        KeyData memory keyData = KeyData({
            totalKeys: _totalKeys,
            keysUsed: 0,
            ipfsHash: abi.encodePacked(_ipfsHash)
        });

        addressToOperatorData[msg.sender] = keyData;
        registered[msg.sender] = true;

        emit OperatorRegistered(
            msg.sender,
            keyData.totalKeys,
            keyData.keysUsed,
            _ipfsHash
        );
    }

    /// @notice Migrates operator details from previous contract
    /// @dev Our previous node operator contract was non upgradeable. We will be moving to an upgradeable version but need this
    ///         function to migrate the data
    function batchMigrateNodeOperator(
        address[] memory _operator, 
        bytes[] memory _ipfsHash,
        uint64[] memory _totalKeys,
        uint64[] memory _keysUsed
    ) external onlyAdmin {
        require((_operator.length == _ipfsHash.length) && (_operator.length == _totalKeys.length) && (_operator.length == _keysUsed.length), "Invalid lengths");
        for(uint256 x = 0; x < _operator.length; x++) {
            require(!registered[_operator[x]], "Already registered");

            KeyData memory keyData = KeyData({
                totalKeys: _totalKeys[x],
                keysUsed: _keysUsed[x],
                ipfsHash: abi.encodePacked(_ipfsHash[x])
            });

            addressToOperatorData[_operator[x]] = keyData;
            registered[_operator[x]] = true;

            emit OperatorRegistered(
                _operator[x],
                keyData.totalKeys,
                keyData.keysUsed,
                _ipfsHash[x]
            );
        }
    }

    /// @notice Fetches the next key they have available to use
    /// @param _user the user to fetch the key for
    /// @return The ipfs index available for the validator
    function fetchNextKeyIndex(
        address _user
    ) external onlyAuctionManagerContract returns (uint64) {
        KeyData storage keyData = addressToOperatorData[_user];
        uint64 totalKeys = keyData.totalKeys;
        require(
            keyData.keysUsed < totalKeys,
            "Insufficient public keys"
        );

        uint64 ipfsIndex = keyData.keysUsed;
        keyData.keysUsed++;
        return ipfsIndex;
    }

    /// @notice Approves or un approves an operator to run validators from a specific source of funds
    /// @dev To allow a permissioned system, we will approve node operators to run validators only for a specific source of funds (EETH / ETHER_FAN)
    ///         Some operators can be approved for both sources and some for only one. Being approved means that when a BNFT player deposits,
    ///         we allocate a source of funds to be used for the deposit. And only operators approved for that source can run the validators
    ///         being created.
    /// @param _users the operator addresses to perform an approval or denial on
    /// @param _approvedTags the source of funds we will be updating operator permissions for
    /// @param _approvals whether we are approving or un approving the operator
    function batchUpdateOperatorsApprovedTags(
        address[] memory _users, 
        LiquidityPool.SourceOfFunds[] memory _approvedTags, 
        bool[] memory _approvals
    ) external onlyAdmin {
        require(_users.length == _approvedTags.length && _users.length == _approvals.length, "Invalid array lengths");

        for(uint256 x; x < _approvedTags.length; x++) {
            operatorApprovedTags[_users[x]][_approvedTags[x]] = _approvals[x];
            emit UpdatedOperatorApprovals(_users[x], _approvedTags[x], _approvals[x]);
        }
    }

    /// @notice Adds an address to the whitelist
    /// @param _address Address of the user to add
    function addToWhitelist(address _address) external onlyAdmin {
        whitelistedAddresses[_address] = true;

        emit AddedToWhitelist(_address);
    }

    /// @notice Removed an address from the whitelist
    /// @param _address Address of the user to remove
    function removeFromWhitelist(address _address) external onlyAdmin {
        whitelistedAddresses[_address] = false;

        emit RemovedFromWhitelist(_address);
    }

    //Pauses the contract
    function pauseContract() external onlyAdmin {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyAdmin {
        _unpause();
    }

    /// @notice Function to check whether an operator is approved for a specified source of funds
    /// @param _operator the operator we are checking permissions for
    /// @param _source the source of funds we are checking the operator against
    /// @return approved whether the operator is approved or not
    function isEligibleToRunValidatorsForSourceOfFund(address _operator, ILiquidityPool.SourceOfFunds _source) external view returns (bool approved) {
        approved = operatorApprovedTags[_operator][_source];
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  GETTERS   ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetches the number of keys the user has, used or un-used
    /// @param _user the user to fetch the data for
    /// @return totalKeys The number of keys the user has
    function getUserTotalKeys(
        address _user
    ) external view returns (uint64 totalKeys) {
        totalKeys = addressToOperatorData[_user].totalKeys;
    }

    /// @notice Fetches the number of keys the user has left to use
    /// @param _user the user to fetch the data for
    /// @return numKeysRemaining the number of keys the user has remaining
    function getNumKeysRemaining(
        address _user
    ) external view returns (uint64 numKeysRemaining) {
        KeyData storage keyData = addressToOperatorData[_user];

        numKeysRemaining =
            keyData.totalKeys - keyData.keysUsed;
    }

    /// @notice Fetches if the user is whitelisted
    /// @dev Used in the auction contract to verify when a user bids that they are indeed whitelisted
    /// @param _user the user to fetch the data for
    /// @return whitelisted Bool value if they are whitelisted or not
    function isWhitelisted(
        address _user
    ) public view returns (bool whitelisted) {
        whitelisted = whitelistedAddresses[_user];
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  SETTERS   ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Sets the auction contract address for verification purposes
    /// @dev Set manually due to circular dependencies
    /// @param _auctionContractAddress address of the deployed auction contract address
    function setAuctionContractAddress(
        address _auctionContractAddress
    ) public onlyOwner {
        require(auctionManagerContractAddress == address(0), "Address already set");
        require(_auctionContractAddress != address(0), "No zero addresses");
        auctionManagerContractAddress = _auctionContractAddress;
    }

    /// @notice Updates the address of the admin
    /// @param _address the new address to set as admin
    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        require(_address != address(0), "Cannot be address zero");
        admins[_address] = _isAdmin;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAuctionManagerContract() {
        require(
            msg.sender == auctionManagerContractAddress,
            "Only auction manager contract function"
        );
        _;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "Caller is not the admin");
        _;
    }
}

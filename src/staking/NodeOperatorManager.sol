// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/staking/interfaces/INodeOperatorManager.sol";
import "@etherfi/staking/interfaces/IAuctionManager.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";

/// Contract which helps us control our node operators and their permissions in different aspects of the protocol
contract NodeOperatorManager is INodeOperatorManager, Initializable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable, RolesLibrary {

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event OperatorRegistered(address operator, uint64 totalKeys, uint64 keysUsed, bytes ipfsHash);
    event AddedToWhitelist(address userAddress);
    event RemovedFromWhitelist(address userAddress);
    event UpdatedOperatorApprovals(address operator, LiquidityPool.SourceOfFunds source, bool approved);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    error IncorrectCaller();
    error InvalidLengths();
    error AlreadyRegistered();
    error InsufficientPublicKeys();
    error InvalidArrayLengths();

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    // deprecated storage slots
    uint160 private __gap_0;

    // user address => OperaterData Struct
    mapping(address => KeyData) public addressToOperatorData;
    mapping(address => bool) private whitelistedAddresses;
    mapping(address => bool) public registered;

    // deprecated storage slots
    uint256 private __gap_1;

    mapping(address => mapping(ILiquidityPool.SourceOfFunds => bool)) public operatorApprovedTags;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------

    address public immutable auctionManagerContractAddress;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _roleRegistry, address _auctionManagerContractAddress) RolesLibrary(_roleRegistry) {
        auctionManagerContractAddress = _auctionManagerContractAddress;
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

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
        if (registered[msg.sender]) revert AlreadyRegistered();

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

    /// @notice Fetches the next key they have available to use
    /// @param _user the user to fetch the key for
    /// @return The ipfs index available for the validator
    function fetchNextKeyIndex(
        address _user
    ) external onlyAuctionManagerContract returns (uint64) {
        KeyData storage keyData = addressToOperatorData[_user];
        uint64 totalKeys = keyData.totalKeys;
        if (keyData.keysUsed >= totalKeys) revert InsufficientPublicKeys();

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
    ) external onlyOperatingMultisig {
        if ((_users.length != _approvedTags.length) || (_users.length != _approvals.length)) revert InvalidArrayLengths();

        for(uint256 x; x < _approvedTags.length; x++) {
            operatorApprovedTags[_users[x]][_approvedTags[x]] = _approvals[x];
            emit UpdatedOperatorApprovals(_users[x], _approvedTags[x], _approvals[x]);
        }
    }

    /// @notice Adds an address to the whitelist
    /// @param _address Address of the user to add
    function addToWhitelist(address _address) external onlyOperatingMultisig {
        whitelistedAddresses[_address] = true;

        emit AddedToWhitelist(_address);
    }

    /// @notice Removed an address from the whitelist
    /// @param _address Address of the user to remove
    function removeFromWhitelist(address _address) external onlyOperatingMultisig {
        whitelistedAddresses[_address] = false;

        emit RemovedFromWhitelist(_address);
    }

    //Pauses the contract
    function pauseContract() external onlyOperatingMultisig {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyOperatingMultisig {
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
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAuctionManagerContract() {
        if (msg.sender != auctionManagerContractAddress) revert IncorrectCaller();
        _;
    }
}

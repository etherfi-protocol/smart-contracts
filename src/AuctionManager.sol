// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IAuctionManager.sol";
import "./interfaces/INodeOperatorManager.sol";
import "./interfaces/IProtocolRevenueManager.sol";
import "./interfaces/IPausable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./RoleRegistry.sol";

contract AuctionManager is
    Initializable,
    IAuctionManager,
    IPausable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    uint128 public DEPRECATED_whitelistBidAmount;
    uint64 public minBidAmount;
    uint64 public maxBidAmount;
    uint256 public numberOfBids;
    uint256 public numberOfActiveBids;

    INodeOperatorManager public nodeOperatorManager;
    IProtocolRevenueManager public DEPRECATED_protocolRevenueManager;

    address public stakingManagerContractAddress;
    bool public DEPRECATED_whitelistEnabled;

    mapping(uint256 => Bid) public bids;

    address public DEPRECATED_admin;

    // new state variables for phase 2
    address public membershipManagerContractAddress;
    uint128 public accumulatedRevenue;
    uint128 public accumulatedRevenueThreshold;

    mapping(address => bool) public DEPRECATED_admins;

    RoleRegistry public roleRegistry;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant AUCTION_ADMIN_ROLE = keccak256("AUCTION_ADMIN_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event BidCreated(address indexed bidder, uint256 amountPerBid, uint256[] bidIdArray, uint64[] ipfsIndexArray);
    event BidCancelled(uint256 indexed bidId);
    event BidReEnteredAuction(uint256 indexed bidId);

    error IncorrectRole();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Initialize to set variables on deployment
    function initialize(
        address _nodeOperatorManagerContract
    ) external initializer {
        require(_nodeOperatorManagerContract != address(0), "No Zero Addresses");
        
        DEPRECATED_whitelistBidAmount = 0.001 ether;
        minBidAmount = 0.01 ether;
        maxBidAmount = 5 ether;
        numberOfBids = 1;
        DEPRECATED_whitelistEnabled = true;

        nodeOperatorManager = INodeOperatorManager(_nodeOperatorManagerContract);

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    function initializeOnUpgrade(address _membershipManagerContractAddress, uint128 _accumulatedRevenueThreshold, address _etherFiAdminContractAddress, address _nodeOperatorManagerAddress) external onlyOwner { 
        require(_membershipManagerContractAddress != address(0) && _etherFiAdminContractAddress != address(0) && _nodeOperatorManagerAddress != address(0), "No Zero Addresses");
        membershipManagerContractAddress = _membershipManagerContractAddress;
        nodeOperatorManager = INodeOperatorManager(_nodeOperatorManagerAddress);
        accumulatedRevenue = 0;
        accumulatedRevenueThreshold = _accumulatedRevenueThreshold;
        DEPRECATED_admins[_etherFiAdminContractAddress] = true;
    }

    function initializeV2dot5(address _roleRegistry) external onlyOwner {
        require(address(roleRegistry) == address(0x00), "already initialized");

        // TODO: compile list of values in DEPRECATED_admins to clear out
        roleRegistry = RoleRegistry(_roleRegistry);
    }

    /// @notice Creates bid(s) for the right to run a validator node when ETH is deposited
    /// @param _bidSize the number of bids that the node operator would like to create
    /// @param _bidAmountPerBid the ether value of each bid that is created
    /// @return bidIdArray array of the bidIDs that were created
    function createBid(
        uint256 _bidSize,
        uint256 _bidAmountPerBid
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory) {
        require(_bidSize > 0, "Bid size is too small");
        require(
                    msg.value == _bidSize * _bidAmountPerBid &&
                        _bidAmountPerBid >= minBidAmount &&
                        _bidAmountPerBid <= maxBidAmount,
                    "Incorrect bid value"
                );

        uint64 keysRemaining = nodeOperatorManager.getNumKeysRemaining(msg.sender);
        require(_bidSize <= keysRemaining, "Insufficient public keys");

        uint256[] memory bidIdArray = new uint256[](_bidSize);
        uint64[] memory ipfsIndexArray = new uint64[](_bidSize);

        for (uint256 i = 0; i < _bidSize; i++) {
            uint64 ipfsIndex = nodeOperatorManager.fetchNextKeyIndex(msg.sender);
            uint256 bidId = numberOfBids + i;
            bidIdArray[i] = bidId;
            ipfsIndexArray[i] = ipfsIndex;

            //Creates a bid object for storage and lookup in future
            bids[bidId] = Bid({
                amount: _bidAmountPerBid,
                bidderPubKeyIndex: ipfsIndex,
                bidderAddress: msg.sender,
                isActive: true
            });
        }
        numberOfBids += _bidSize;
        numberOfActiveBids += _bidSize;

        emit BidCreated(msg.sender, _bidAmountPerBid, bidIdArray, ipfsIndexArray);
        return bidIdArray;
    }

    /// @notice Cancels bids in a batch by calling the 'cancelBid' function multiple times
    /// @dev Calls an internal function to perform the cancel
    /// @param _bidIds the ID's of the bids to cancel
    function cancelBidBatch(uint256[] calldata _bidIds) external whenNotPaused {
        for (uint256 i = 0; i < _bidIds.length; i++) {
            _cancelBid(_bidIds[i]);
        }
    }

    /// @notice Cancels a specified bid by de-activating it
    /// @dev Calls an internal function to perform the cancel
    /// @param _bidId the ID of the bid to cancel
    function cancelBid(uint256 _bidId) public whenNotPaused {
        _cancelBid(_bidId);
    }

    /// @notice Updates the details of the bid which has been used in a stake match
    /// @dev Called by batchDepositWithBidIds() in StakingManager.sol
    /// @param _bidId the ID of the bid being removed from the auction (since it has been selected)
    function updateSelectedBidInformation(
        uint256 _bidId
    ) external onlyStakingManagerContract {
        Bid storage bid = bids[_bidId];
        require(bid.isActive, "The bid is not active");

        bid.isActive = false;
        numberOfActiveBids--;
    }

    /// @notice Lets a bid that was matched to a cancelled stake re-enter the auction
    /// @param _bidId the ID of the bid which was matched to the cancelled stake.
    function reEnterAuction(
        uint256 _bidId
    ) external onlyStakingManagerContract {
        Bid storage bid = bids[_bidId];
        require(!bid.isActive, "Bid already active");

        bid.isActive = true;
        numberOfActiveBids++;
        emit BidReEnteredAuction(_bidId);
    }

    /// @notice Transfer the auction fee received from the node operator to the membership NFT contract when above the threshold
    /// @dev Called by registerValidator() in StakingManager.sol
    /// @param _bidId the ID of the validator
    function processAuctionFeeTransfer(
        uint256 _bidId
    ) external onlyStakingManagerContract {
        uint256 amount = bids[_bidId].amount;
        uint256 newAccumulatedRevenue = accumulatedRevenue + amount;
        if (newAccumulatedRevenue >= accumulatedRevenueThreshold) {
            accumulatedRevenue = 0;
            (bool sent, ) = membershipManagerContractAddress.call{value: newAccumulatedRevenue}("");
            require(sent, "Failed to send Ether");
        } else {
            accumulatedRevenue = uint128(newAccumulatedRevenue);
        }
    }

    function transferAccumulatedRevenue() external {
        if (!roleRegistry.hasRole(AUCTION_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        uint256 transferAmount = accumulatedRevenue;
        accumulatedRevenue = 0;
        (bool sent, ) = membershipManagerContractAddress.call{value: transferAmount}("");
        require(sent, "Failed to send Ether");
    }

    // Pauses the contract
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }

    // Unpauses the contract
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _cancelBid(uint256 _bidId) internal {
        Bid storage bid = bids[_bidId];
        require(bid.bidderAddress == msg.sender, "Invalid bid");
        require(bid.isActive, "Bid already cancelled");

        // Cancel the bid by de-activating it
        bid.isActive = false;
        numberOfActiveBids--;

        // Refund the user with their bid amount
        (bool sent, ) = msg.sender.call{value: bid.amount}("");
        require(sent, "Failed to send Ether");

        emit BidCancelled(_bidId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetches the address of the user who placed a bid for a specific bid ID
    /// @dev Needed for registerValidator() function in Staking Contract as well as function in the EtherFiNodeManager.sol
    /// @return the address of the user who placed (owns) the bid
    function getBidOwner(uint256 _bidId) external view returns (address) {
        return bids[_bidId].bidderAddress;
    }

    /// @notice Fetches if a selected bid is currently active
    /// @dev Needed for batchDepositWithBidIds() function in Staking Contract
    /// @return the boolean value of the active flag in bids
    function isBidActive(uint256 _bidId) external view returns (bool) {
        return bids[_bidId].isActive;
    }

    /// @notice Fetches the address of the implementation contract currently being used by the proxy
    /// @return the address of the currently used implementation contract
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------------  SETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Sets the staking managers contract address in the current contract
    /// @param _stakingManagerContractAddress new stakingManagerContract address
    function setStakingManagerContractAddress(
        address _stakingManagerContractAddress
    ) external onlyOwner {
        require(address(stakingManagerContractAddress) == address(0), "Address already set");
        require(_stakingManagerContractAddress != address(0), "No zero addresses");
        stakingManagerContractAddress = _stakingManagerContractAddress;
    }

    /// @notice Updates the minimum bid price for bidders
    /// @param _newMinBidAmount the new amount to set the minimum bid price as
    function setMinBidPrice(uint64 _newMinBidAmount) external {
        if (!roleRegistry.hasRole(AUCTION_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        
        require(_newMinBidAmount < maxBidAmount, "Min bid exceeds max bid");
        minBidAmount = _newMinBidAmount;
    }

    /// @notice Updates the maximum bid price for bidders
    /// @param _newMaxBidAmount the new amount to set the maximum bid price as
    function setMaxBidPrice(uint64 _newMaxBidAmount) external {
        if (!roleRegistry.hasRole(AUCTION_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        require(_newMaxBidAmount > minBidAmount, "Min bid exceeds max bid");
        maxBidAmount = _newMaxBidAmount;
    }

    /// @notice Updates the accumulated revenue threshold that will trigger a transfer to MembershipNFT contract
    /// @param _newThreshold the new threshold to set
    function setAccumulatedRevenueThreshold(uint128 _newThreshold) external {
        if (!roleRegistry.hasRole(AUCTION_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        accumulatedRevenueThreshold = _newThreshold;
    }

    function updateNodeOperatorManager(address _address) external onlyOwner {
        nodeOperatorManager = INodeOperatorManager(
            _address
        );
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyStakingManagerContract() {
        require(msg.sender == stakingManagerContractAddress, "Only staking manager contract function");
        _;
    }
}

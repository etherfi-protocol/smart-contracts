// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/staking/interfaces/IAuctionManager.sol";
import "@etherfi/staking/interfaces/INodeOperatorManager.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZOwnable.sol";
import "@etherfi/governance/utils/DeprecatedOZPausable.sol";
import "@etherfi/governance/utils/DeprecatedOZReentrancyGuard.sol";

contract AuctionManager is
    Initializable,
    IAuctionManager,
    DeprecatedOZPausable,
    DeprecatedOZOwnable,
    PausableUntil,
    DeprecatedOZReentrancyGuard,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    uint128 public whitelistBidAmount;
    uint64 public minBidAmount;
    uint64 public maxBidAmount;
    uint256 public numberOfBids;
    uint256 public numberOfActiveBids;

    // deprecated storage slots
    uint256[2] private __gap_0;
    uint160 private __gap_1;

    bool public whitelistEnabled;
    mapping(uint256 => Bid) public bids;

    // deprecated storage slots
    uint256[4] private __gap_2;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    IBlacklister public immutable blacklister;
    INodeOperatorManager public immutable nodeOperatorManager;
    address public immutable stakingManagerContractAddress;
    address public immutable treasury;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event BidCreated(address indexed bidder, uint256 amountPerBid, uint256[] bidIdArray, uint64[] ipfsIndexArray);
    event BidCancelled(uint256 indexed bidId);
    event BidReEnteredAuction(uint256 indexed bidId);
    event BidRevenueForwarded(uint256 indexed bidId, address indexed treasury, uint256 amount);
    event WhitelistDisabled(bool whitelistStatus);
    event WhitelistEnabled(bool whitelistStatus);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error AddressZero();
    error InvalidBidSize();
    error NotWhitelisted();
    error IncorrectBidValue();
    error InsufficientPublicKeys();
    error BidNotActive();
    error BidAlreadyActive();
    error EtherTransferFailed();
    error InvalidBid();
    error BidAlreadyCancelled();
    error InvalidMinBid();
    error InvalidMaxBid();
    error InvalidWhitelistAmount();
    error IncorrectCaller();

    //--------------------------------------------------------------------------------------
    //-------------------------------------  CONSTRUCTOR  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _roleRegistry The address of the role registry
     * @param _blacklister The address of the blacklister
     * @param _nodeOperatorManagerContract The address of the node operator manager contract
     * @param _stakingManagerContractAddress The address of the staking manager contract
     * @param _treasury The address of the treasury
     */
    constructor(address _roleRegistry, address _blacklister, address _nodeOperatorManagerContract, address _stakingManagerContractAddress, address _treasury) RolesLibrary(_roleRegistry) {
        blacklister = IBlacklister(_blacklister);
        nodeOperatorManager = INodeOperatorManager(_nodeOperatorManagerContract);
        stakingManagerContractAddress = _stakingManagerContractAddress;
        treasury = _treasury;
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INITIALIZERS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize to set variables on deployment
     * @param _nodeOperatorManagerContract The address of the node operator manager contract
     */
    function initialize(
        address _nodeOperatorManagerContract
    ) external initializer {
        if (_nodeOperatorManagerContract == address(0)) revert AddressZero();
        
        whitelistBidAmount = 0.001 ether;
        minBidAmount = 0.01 ether;
        maxBidAmount = 5 ether;
        numberOfBids = 1;
        whitelistEnabled = true;

        __UUPSUpgradeable_init();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- AUCTION FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Creates bid(s) for the right to run a validator node when ETH is deposited
     * @param _bidSize the number of bids that the node operator would like to create
     * @param _bidAmountPerBid the ether value of each bid that is created
     * @return bidIdArray array of the bidIDs that were created
     */
    function createBid(
        uint256 _bidSize,
        uint256 _bidAmountPerBid
    ) external payable nonReentrant whenNotPaused nonBlacklisted returns (uint256[] memory) {
        if (_bidSize == 0) revert InvalidBidSize();
        if (whitelistEnabled) {
            if (!nodeOperatorManager.isWhitelisted(msg.sender)) revert NotWhitelisted();
            if (
                msg.value != _bidSize * _bidAmountPerBid ||
                _bidAmountPerBid < whitelistBidAmount ||
                _bidAmountPerBid > maxBidAmount
            ) revert IncorrectBidValue();
        } else {
            if (
                nodeOperatorManager.isWhitelisted(msg.sender)
            ) {
                if (
                    msg.value != _bidSize * _bidAmountPerBid ||
                    _bidAmountPerBid < whitelistBidAmount ||
                    _bidAmountPerBid > maxBidAmount
                ) revert IncorrectBidValue();
            } else {
                if (
                    msg.value != _bidSize * _bidAmountPerBid ||
                    _bidAmountPerBid < minBidAmount ||
                    _bidAmountPerBid > maxBidAmount
                ) revert IncorrectBidValue();
            }
        }
        uint64 keysRemaining = nodeOperatorManager.getNumKeysRemaining(msg.sender);
        if (_bidSize > keysRemaining) revert InsufficientPublicKeys();

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

    /**
     * @notice Cancels bids in a batch by calling the 'cancelBid' function multiple times
     * @param _bidIds the ID's of the bids to cancel
     * @dev Calls an internal function to perform the cancel
     */
    function cancelBidBatch(uint256[] calldata _bidIds) external whenNotPaused nonBlacklisted {
        for (uint256 i = 0; i < _bidIds.length; i++) {
            _cancelBid(_bidIds[i]);
        }
    }

    /**
     * @notice Cancels a specified bid by de-activating it
     * @param _bidId the ID of the bid to cancel
     * @dev Calls an internal function to perform the cancel
     */
    function cancelBid(uint256 _bidId) public whenNotPaused nonBlacklisted {
        _cancelBid(_bidId);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- STAKING FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Updates the details of the bid which has been used in a stake match
     * @param _bidId the ID of the bid being removed from the auction (since it has been selected)
     * @dev Called by batchDepositWithBidIds() in StakingManager.sol. Forwards the
     *      consumed bid's ETH to `treasury` so protocol-side bid revenue is not
     *      stranded in this contract.
     */
    function updateSelectedBidInformation(
        uint256 _bidId
    ) external onlyStakingManagerContract {
        Bid storage bid = bids[_bidId];
        if (!bid.isActive) revert BidNotActive();

        bid.isActive = false;
        numberOfActiveBids--;

        uint256 amount = bid.amount;
        if (amount > 0) {
            (bool sent, ) = treasury.call{value: amount}("");
            if (!sent) revert EtherTransferFailed();
            emit BidRevenueForwarded(_bidId, treasury, amount);
        }
    }

    /**
     * @notice Lets a bid that was matched to a cancelled stake re-enter the auction
     * @param _bidId the ID of the bid which was matched to the cancelled stake.
     */
    function reEnterAuction(
        uint256 _bidId
    ) external onlyStakingManagerContract {
        Bid storage bid = bids[_bidId];
        if (bid.isActive) revert BidAlreadyActive();

        bid.isActive = true;
        numberOfActiveBids++;
        emit BidReEnteredAuction(_bidId);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- ADMIN FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------

    /**
     * @notice Updates the minimum bid price for a non-whitelisted bidder
     * @param _newMinBidAmount the new amount to set the minimum bid price as
     * @dev Only the operating multisig can update the minimum bid price
     */
    function setMinBidPrice(uint64 _newMinBidAmount) external onlyOperatingMultisig {
        if (_newMinBidAmount >= maxBidAmount) revert InvalidMinBid();
        if (_newMinBidAmount < whitelistBidAmount) revert InvalidMinBid();
        minBidAmount = _newMinBidAmount;
    }

    /**
     * @notice Updates the maximum bid price for both whitelisted and non-whitelisted bidders
     * @param _newMaxBidAmount the new amount to set the maximum bid price as
     * @dev Only the operating multisig can update the maximum bid price
     */
    function setMaxBidPrice(uint64 _newMaxBidAmount) external onlyOperatingMultisig {
        if (_newMaxBidAmount <= minBidAmount) revert InvalidMaxBid();
        maxBidAmount = _newMaxBidAmount;
    }

    /**
     * @notice Disables the whitelisting phase of the bidding
     * @dev Allows both regular users and whitelisted users to bid
     */
    function disableWhitelist() public onlyOperatingMultisig {
        whitelistEnabled = false;
        emit WhitelistDisabled(whitelistEnabled);
    }

    /**
     * @notice Enables the whitelisting phase of the bidding
     * @dev Only users who are on a whitelist can bid
     */
    function enableWhitelist() public onlyOperatingMultisig {
        whitelistEnabled = true;
        emit WhitelistEnabled(whitelistEnabled);
    }

    /**
     * @notice Updates the minimum bid price for a whitelisted address
     * @param _newAmount the new amount to set the minimum bid price as
     * @dev Only the operating multisig can update the minimum bid price for a whitelisted address
     */
    function updateWhitelistMinBidAmount(
        uint128 _newAmount
    ) external onlyOperatingMultisig {
        if (_newAmount >= minBidAmount || _newAmount == 0) revert InvalidWhitelistAmount();
        whitelistBidAmount = _newAmount;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Cancels a bid by de-activating it and refunding the user with their bid amount
     * @param _bidId the ID of the bid to cancel
     * @dev Called by cancelBid() and cancelBidBatch()
     */
    function _cancelBid(uint256 _bidId) internal {
        Bid storage bid = bids[_bidId];
        if (bid.bidderAddress != msg.sender) revert InvalidBid();
        if (!bid.isActive) revert BidAlreadyCancelled();

        // Cancel the bid by de-activating it
        bid.isActive = false;
        numberOfActiveBids--;

        // Refund the user with their bid amount
        (bool sent, ) = msg.sender.call{value: bid.amount}("");
        if (!sent) revert EtherTransferFailed();

        emit BidCancelled(_bidId);
    }

    /**
     * @notice Authorizes the upgrade of the implementation contract
     * @param newImplementation the address of the new implementation contract
     * @dev Only the upgrade timelock can authorize the upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    /**
     * @notice Fetches the address of the user who placed a bid for a specific bid ID
     * @param _bidId the ID of the bid to fetch the owner of
     * @dev Needed for registerValidator() function in Staking Contract as well as function in the EtherFiNodeManager.sol
     * @return the address of the user who placed (owns) the bid
     */
    function getBidOwner(uint256 _bidId) external view returns (address) {
        return bids[_bidId].bidderAddress;
    }

    /**
     * @notice Fetches if a selected bid is currently active
     * @param _bidId the ID of the bid to fetch the active status of
     * @dev Needed for batchDepositWithBidIds() function in Staking Contract
     * @return the boolean value of the active flag in bids
     */
    function isBidActive(uint256 _bidId) external view returns (bool) {
        return bids[_bidId].isActive;
    }

    /**
     * @notice Fetches the address of the implementation contract currently being used by the proxy
     * @dev Needed for the getImplementation() function in the UUPSUpgradeable contract
     * @return the address of the currently used implementation contract
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to only allow the staking manager contract to call a function
     * @dev Only the staking manager contract can call this function
     */
    modifier onlyStakingManagerContract() {
        if (msg.sender != stakingManagerContractAddress) revert IncorrectCaller();
        _;
    }

    /**
     * @notice Modifier to only allow non-blacklisted addresses to call a function
     * @dev Only non-blacklisted addresses can call this function
     */
    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}

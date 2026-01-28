// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IPriorityWithdrawalQueue.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IRoleRegistry.sol";

/// @title PriorityWithdrawalQueue
/// @notice Manages priority withdrawals for whitelisted VIP users using hash-based request tracking
/// @dev Implements BoringOnChainQueue patterns with WithdrawRequestNFT validation checks
contract PriorityWithdrawalQueue is 
    Initializable, 
    OwnableUpgradeable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable,
    IPriorityWithdrawalQueue 
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Math for uint256;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Maximum delay in seconds before a request can be fulfilled
    uint32 public constant MAXIMUM_MIN_DELAY = 30 days;

    /// @notice Basis point scale for fee calculations (100% = 10000)
    uint256 private constant _BASIS_POINT_SCALE = 1e4;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IRoleRegistry public immutable roleRegistry;
    
    /// @notice Treasury address for fee collection
    address public immutable treasury;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice EnumerableSet to store all active withdraw request IDs
    EnumerableSet.Bytes32Set private _withdrawRequests;

    /// @notice Set of finalized request IDs (fulfilled and ready for claim)
    EnumerableSet.Bytes32Set private _finalizedRequests;


    /// @notice Mapping of whitelisted addresses
    mapping(address => bool) public isWhitelisted;

    /// @notice Withdrawal configuration
    WithdrawConfig private _withdrawConfig;

    /// @notice Request nonce to prevent hash collisions
    uint32 public nonce;

    /// @notice Fee split to treasury in basis points (e.g., 5000 = 50%)
    uint16 public shareRemainderSplitToTreasuryInBps;

    /// @notice Contract pause state
    bool public paused;

    /// @notice Remainder shares from claimed withdrawals (difference between request shares and actual burned)
    uint96 public totalRemainderShares;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ----------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE");
    bytes32 public constant IMPLICIT_FEE_CLAIMER_ROLE = keccak256("IMPLICIT_FEE_CLAIMER_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event Paused(address account);
    event Unpaused(address account);
    event WithdrawRequestCreated(
        bytes32 indexed requestId,
        address indexed user,
        uint96 amountOfEEth,
        uint96 shareOfEEth,
        uint32 nonce,
        uint32 creationTime
    );
    event WithdrawRequestCancelled(bytes32 indexed requestId, address indexed user, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestFinalized(bytes32 indexed requestId, address indexed user, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestClaimed(bytes32 indexed requestId, address indexed user, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestInvalidated(bytes32 indexed requestId, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WhitelistUpdated(address indexed user, bool status);
    event WithdrawConfigUpdated(uint32 minDelay, uint96 minimumAmount);
    event WithdrawCapacityUpdated(uint96 withdrawCapacity);
    event RemainderHandled(uint96 amountToTreasury, uint96 sharesOfEEthToBurn);
    event ShareRemainderSplitUpdated(uint16 newSplitInBps);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    error NotWhitelisted();
    error InvalidAmount();
    error RequestNotFound();
    error RequestNotFinalized();
    error RequestAlreadyFinalized();
    error NotRequestOwner();
    error IncorrectRole();
    error ContractPaused();
    error ContractNotPaused();
    error NotEnoughWithdrawCapacity();
    error NotMatured();
    error Keccak256Collision();
    error InvalidConfig();
    error PermitFailedAndAllowanceTooLow();
    error ArrayLengthMismatch();
    error AddressZero();
    error BadInput();
    error InvalidBurnedSharesAmount();
    error InvalidEEthSharesAfterRemainderHandling();

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyWhitelisted() {
        if (!isWhitelisted[msg.sender]) revert NotWhitelisted();
        _;
    }

    modifier onlyAdmin() {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

    modifier onlyRequestManager() {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

    modifier onlyRequestUser(address requestUser) {
        if (requestUser != msg.sender) revert NotRequestOwner();
        _;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _liquidityPool, address _eETH, address _roleRegistry, address _treasury) {
        if (_liquidityPool == address(0) || _eETH == address(0) || _roleRegistry == address(0) || _treasury == address(0)) {
            revert AddressZero();
        }
        
        liquidityPool = ILiquidityPool(_liquidityPool);
        eETH = IeETH(_eETH);
        roleRegistry = IRoleRegistry(_roleRegistry);
        treasury = _treasury;

        _disableInitializers();
    }

    /// @notice Initialize the contract
    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        nonce = 1;

        _withdrawConfig = WithdrawConfig({
            minDelay: 0,
            minimumAmount: 0.01 ether,
            withdrawCapacity: 10_000_000 ether
        });
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  USER FUNCTIONS  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Request a withdrawal of eETH
    /// @param amountOfEEth Amount of eETH to withdraw
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdraw(
        uint96 amountOfEEth
    ) external whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
        _decrementWithdrawCapacity(amountOfEEth);
        if (amountOfEEth < _withdrawConfig.minimumAmount) revert InvalidAmount();

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth);
    }

    /// @notice Request a withdrawal with permit for gasless approval
    /// @param amountOfEEth Amount of eETH to withdraw
    /// @param permit Permit signature data for eETH approval
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdrawWithPermit(
        uint96 amountOfEEth,
        PermitInput calldata permit
    ) external whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
        _decrementWithdrawCapacity(amountOfEEth);
        if (amountOfEEth < _withdrawConfig.minimumAmount) revert InvalidAmount();

        try eETH.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {}

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth);
    }

    /// @notice Cancel a pending withdrawal request
    /// @param request The withdrawal request to cancel
    /// @return requestId The cancelled request ID
    function cancelWithdraw(
        WithdrawRequest calldata request
    ) external whenNotPaused onlyRequestUser(request.user) returns (bytes32 requestId) {
        requestId = _cancelWithdrawRequest(request);
    }

    /// @notice Claim ETH for a finalized withdrawal request
    /// @param request The withdrawal request to claim
    function claimWithdraw(WithdrawRequest calldata request) external whenNotPaused nonReentrant {
        _claimWithdraw(request);
    }

    /// @notice Batch claim multiple withdrawal requests
    /// @param requests Array of withdrawal requests to claim
    function batchClaimWithdraw(WithdrawRequest[] calldata requests) external whenNotPaused nonReentrant {
        for (uint256 i = 0; i < requests.length; ++i) {
            _claimWithdraw(requests[i]);
        }
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  REQUEST MANAGER FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Request manager finalizes withdrawal requests after maturity
    /// @dev Checks maturity and deadline, marks requests as finalized
    /// @param requests Array of requests to finalize
    function fulfillRequests(WithdrawRequest[] calldata requests) external onlyRequestManager whenNotPaused {
        uint256 totalSharesToFinalize = 0;

        for (uint256 i = 0; i < requests.length; ++i) {
            WithdrawRequest calldata request = requests[i];
            bytes32 requestId = keccak256(abi.encode(request));

            // Verify request exists in pending set
            if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();
            if (_finalizedRequests.contains(requestId)) revert RequestAlreadyFinalized();

            // Check minDelay has passed (request must wait at least minDelay seconds)
            uint256 earliestFulfillTime = request.creationTime + _withdrawConfig.minDelay;
            if (block.timestamp < earliestFulfillTime) revert NotMatured();

            // Add to finalized set
            _finalizedRequests.add(requestId);
            totalSharesToFinalize += request.shareOfEEth;

            emit WithdrawRequestFinalized(requestId, request.user, request.amountOfEEth, request.shareOfEEth, request.nonce, uint32(block.timestamp));
        }

        // Lock ETH in LiquidityPool for priority withdrawals
        uint256 totalAmountToLock = liquidityPool.amountForShare(totalSharesToFinalize);
        liquidityPool.addEthAmountLockedForPriorityWithdrawal(uint128(totalAmountToLock));
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ADMIN FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Add an address to the whitelist
    /// @param user Address to whitelist
    function addToWhitelist(address user) external {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, msg.sender)) revert IncorrectRole();
        if (user == address(0)) revert AddressZero();
        isWhitelisted[user] = true;
        emit WhitelistUpdated(user, true);
    }

    /// @notice Remove an address from the whitelist
    /// @param user Address to remove from whitelist
    function removeFromWhitelist(address user) external {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, msg.sender)) revert IncorrectRole();
        isWhitelisted[user] = false;
        emit WhitelistUpdated(user, false);
    }

    /// @notice Batch update whitelist status
    /// @param users Array of user addresses
    /// @param statuses Array of whitelist statuses
    function batchUpdateWhitelist(address[] calldata users, bool[] calldata statuses) external {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, msg.sender)) revert IncorrectRole();
        if (users.length != statuses.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert AddressZero();
            isWhitelisted[users[i]] = statuses[i];
            emit WhitelistUpdated(users[i], statuses[i]);
        }
    }

    /// @notice Update withdrawal configuration
    /// @param minDelay Minimum delay before requests can be fulfilled
    /// @param minimumAmount Minimum withdrawal amount
    function updateWithdrawConfig(
        uint32 minDelay,
        uint96 minimumAmount
    ) external onlyAdmin {
        if (minDelay > MAXIMUM_MIN_DELAY) revert InvalidConfig();

        _withdrawConfig.minDelay = minDelay;
        _withdrawConfig.minimumAmount = minimumAmount;

        emit WithdrawConfigUpdated(minDelay, minimumAmount);
    }

    /// @notice Set the withdrawal capacity
    /// @param capacity New withdrawal capacity
    function setWithdrawCapacity(uint96 capacity) external onlyAdmin {
        _withdrawConfig.withdrawCapacity = capacity;
        emit WithdrawCapacityUpdated(capacity);
    }

    /// @notice Invalidate a withdrawal request (prevents finalization)
    /// @param requests Array of requests to invalidate
    /// @return invalidatedRequestIds Array of request IDs that were invalidated
    function invalidateRequests(WithdrawRequest[] calldata requests) external onlyRequestManager returns (bytes32[] memory invalidatedRequestIds) {
        invalidatedRequestIds = new bytes32[](requests.length);
        for (uint256 i = 0; i < requests.length; ++i) {
            bytes32 requestId = keccak256(abi.encode(requests[i]));
            if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();

            _cancelWithdrawRequest(requests[i]);
            invalidatedRequestIds[i] = requestId;
            emit WithdrawRequestInvalidated(requestId, requests[i].amountOfEEth, requests[i].shareOfEEth, requests[i].nonce, uint32(block.timestamp));
        }
    }

    /// @notice Handle remainder shares (from rounding differences)
    /// @dev Splits the remainder into two parts:
    ///      - Treasury: gets a percentage of the remainder based on shareRemainderSplitToTreasuryInBps
    ///      - Burn: the rest of the remainder is burned
    /// @param eEthAmount Amount of eETH remainder to handle
    function handleRemainder(uint256 eEthAmount) external {
        if (!roleRegistry.hasRole(IMPLICIT_FEE_CLAIMER_ROLE, msg.sender)) revert IncorrectRole();
        if (eEthAmount == 0) revert BadInput();
        if (eEthAmount > liquidityPool.amountForShare(totalRemainderShares)) revert BadInput();

        uint256 beforeEEthShares = eETH.shares(address(this));

        uint256 eEthAmountToTreasury = eEthAmount.mulDiv(shareRemainderSplitToTreasuryInBps, _BASIS_POINT_SCALE);
        uint256 eEthAmountToBurn = eEthAmount - eEthAmountToTreasury;
        uint256 eEthSharesToBurn = liquidityPool.sharesForAmount(eEthAmountToBurn);
        uint256 eEthSharesMoved = eEthSharesToBurn + liquidityPool.sharesForAmount(eEthAmountToTreasury);

        totalRemainderShares -= uint96(eEthSharesMoved);

        if (eEthAmountToTreasury > 0) IERC20(address(eETH)).safeTransfer(treasury, eEthAmountToTreasury);
        if (eEthSharesToBurn > 0) liquidityPool.burnEEthShares(eEthSharesToBurn);

        if (beforeEEthShares - eEthSharesMoved != eETH.shares(address(this))) revert InvalidEEthSharesAfterRemainderHandling();

        emit RemainderHandled(uint96(eEthAmountToTreasury), uint96(liquidityPool.amountForShare(eEthSharesToBurn)));
    }

    /// @notice Update the share remainder split to treasury
    /// @param _shareRemainderSplitToTreasuryInBps New split percentage in basis points (max 10000)
    function updateShareRemainderSplitToTreasury(uint16 _shareRemainderSplitToTreasuryInBps) external onlyAdmin {
        if (_shareRemainderSplitToTreasuryInBps > _BASIS_POINT_SCALE) revert InvalidConfig();
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
        emit ShareRemainderSplitUpdated(_shareRemainderSplitToTreasuryInBps);
    }

    /// @notice Pause the contract
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        if (paused) revert ContractPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (!paused) revert ContractNotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Decrement withdrawal capacity
    function _decrementWithdrawCapacity(uint96 amount) internal {
        if (_withdrawConfig.withdrawCapacity < type(uint96).max) {
            if (_withdrawConfig.withdrawCapacity < amount) revert NotEnoughWithdrawCapacity();
            _withdrawConfig.withdrawCapacity -= amount;
            emit WithdrawCapacityUpdated(_withdrawConfig.withdrawCapacity);
        }
    }

    /// @dev Increment withdrawal capacity
    function _incrementWithdrawCapacity(uint96 amount) internal {
        if (_withdrawConfig.withdrawCapacity < type(uint96).max) {
            _withdrawConfig.withdrawCapacity += amount;
            emit WithdrawCapacityUpdated(_withdrawConfig.withdrawCapacity);
        }
    }

    /// @dev Queue a new withdrawal request
    function _queueWithdrawRequest(
        address user,
        uint96 amountOfEEth
    ) internal returns (bytes32 requestId, WithdrawRequest memory req) {
        uint32 requestNonce;
        unchecked {
            requestNonce = uint32(nonce++);
        }

        uint96 shareOfEEth = uint96(liquidityPool.sharesForAmount(amountOfEEth));
        if (shareOfEEth == 0) revert InvalidAmount();

        uint32 timeNow = uint32(block.timestamp);

        req = WithdrawRequest({
            user: user,
            amountOfEEth: amountOfEEth,
            shareOfEEth: shareOfEEth,
            nonce: requestNonce,
            creationTime: timeNow
        });

        requestId = keccak256(abi.encode(req));

        bool addedToSet = _withdrawRequests.add(requestId);
        if (!addedToSet) revert Keccak256Collision();

        emit WithdrawRequestCreated(
            requestId,
            user,
            amountOfEEth,
            shareOfEEth,
            requestNonce,
            timeNow
        );
    }

    /// @dev Dequeue a withdrawal request
    function _dequeueWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        bool removedFromSet = _withdrawRequests.remove(requestId);
        if (!removedFromSet) revert RequestNotFound();

        _finalizedRequests.remove(requestId);
    }

    /// @dev Cancel a withdrawal request and return eETH to user
    function _cancelWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        
        // Check if finalized BEFORE dequeue (dequeue removes from finalized set)
        bool wasFinalized = _finalizedRequests.contains(requestId);
        
        _dequeueWithdrawRequest(request);
        
        // Calculate current value of shares
        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        uint256 amountToReturn = request.amountOfEEth < amountForShares 
            ? request.amountOfEEth 
            : amountForShares;
        
        // Calculate shares being transferred back
        uint256 sharesToTransfer = liquidityPool.sharesForAmount(amountToReturn);
        
        // Track remainder (difference between original shares and transferred shares)
        // This captures value from positive rebases where user gets original amount using fewer shares
        uint256 remainder = request.shareOfEEth > sharesToTransfer 
            ? request.shareOfEEth - sharesToTransfer 
            : 0;
        totalRemainderShares += uint96(remainder);
        
        if (wasFinalized) {
            liquidityPool.reduceEthAmountLockedForPriorityWithdrawal(uint128(amountToReturn));
        }
        
        _incrementWithdrawCapacity(request.amountOfEEth);
        
        // Transfer back the lesser of original amount or current share value (handles negative rebase)
        IERC20(address(eETH)).safeTransfer(request.user, amountToReturn);
        
        emit WithdrawRequestCancelled(requestId, request.user, uint96(amountToReturn), uint96(sharesToTransfer), request.nonce, uint32(block.timestamp));
    }

    /// @dev Internal claim function
    function _claimWithdraw(WithdrawRequest calldata request) internal {
        if (request.user != msg.sender) revert NotRequestOwner();
        
        bytes32 requestId = keccak256(abi.encode(request));
        
        if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();
        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        uint256 amountToWithdraw = request.amountOfEEth < amountForShares 
            ? request.amountOfEEth 
            : amountForShares;

        uint256 sharesToBurn = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

        _withdrawRequests.remove(requestId);
        _finalizedRequests.remove(requestId);

        // Track remainder (difference between original shares and burned shares)
        uint256 remainder = request.shareOfEEth > sharesToBurn 
            ? request.shareOfEEth - sharesToBurn 
            : 0;
        totalRemainderShares += uint96(remainder);

        uint256 burnedShares = liquidityPool.withdraw(msg.sender, amountToWithdraw);
        if (burnedShares != sharesToBurn) revert InvalidBurnedSharesAmount();

        emit WithdrawRequestClaimed(requestId, msg.sender, uint96(amountToWithdraw), uint96(sharesToBurn), request.nonce, uint32(block.timestamp));
    }

    function _authorizeUpgrade(address) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Generate a request ID from individual parameters
    /// @param _user The user address
    /// @param _amountOfEEth The amount of eETH
    /// @param _shareOfEEth The share of eETH
    /// @param _nonce The request nonce
    /// @param _creationTime The creation timestamp
    /// @return requestId The keccak256 hash of the request
    function generateWithdrawRequestId(
        address _user,
        uint96 _amountOfEEth,
        uint96 _shareOfEEth,
        uint32 _nonce,
        uint32 _creationTime
    ) public pure returns (bytes32 requestId) {
        WithdrawRequest memory req = WithdrawRequest({
            user: _user,
            amountOfEEth: _amountOfEEth,
            shareOfEEth: _shareOfEEth,
            nonce: _nonce,
            creationTime: _creationTime
        });
        requestId = keccak256(abi.encode(req));
    }

    /// @notice Get the request ID from a request struct
    /// @param request The withdrawal request
    /// @return requestId The keccak256 hash of the request
    function getRequestId(WithdrawRequest calldata request) external pure returns (bytes32) {
        return generateWithdrawRequestId(
            request.user,
            request.amountOfEEth,
            request.shareOfEEth,
            request.nonce,
            request.creationTime
        );
    }

    /// @notice Get all active request IDs
    /// @return Array of request IDs
    function getRequestIds() external view returns (bytes32[] memory) {
        return _withdrawRequests.values();
    }

    /// @notice Get all finalized request IDs
    /// @return Array of finalized request IDs
    function getFinalizedRequestIds() external view returns (bytes32[] memory) {
        return _finalizedRequests.values();
    }

    /// @notice Check if a request exists
    /// @param requestId The request ID to check
    /// @return Whether the request exists
    function requestExists(bytes32 requestId) external view returns (bool) {
        return _withdrawRequests.contains(requestId);
    }

    /// @notice Check if a request is finalized
    /// @param requestId The request ID to check
    /// @return Whether the request is finalized
    function isFinalized(bytes32 requestId) external view returns (bool) {
        return _finalizedRequests.contains(requestId);
    }

    /// @notice Get the claimable amount for a request
    /// @param request The withdrawal request
    /// @return The claimable ETH amount
    function getClaimableAmount(WithdrawRequest calldata request) external view returns (uint256) {
        bytes32 requestId = keccak256(abi.encode(request));
        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        return request.amountOfEEth < amountForShares ? request.amountOfEEth : amountForShares;
    }

    /// @notice Get the withdrawal configuration
    /// @return The withdraw config struct
    function withdrawConfig() external view returns (WithdrawConfig memory) {
        return _withdrawConfig;
    }

    /// @notice Get the total number of active requests
    /// @return The number of active requests
    function totalActiveRequests() external view returns (uint256) {
        return _withdrawRequests.length();
    }

    /// @notice Get the total remainder amount available
    /// @return The total remainder eETH amount
    function getRemainderAmount() external view returns (uint256) {
        return liquidityPool.amountForShare(totalRemainderShares);
    }

    /// @notice Get the implementation address
    /// @return The implementation address
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}

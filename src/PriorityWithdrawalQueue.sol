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

    /// @notice Maximum time in seconds a withdraw request can take to mature
    uint24 public constant MAXIMUM_SECONDS_TO_MATURITY = 30 days;

    /// @notice Maximum minimum validity period after maturity
    uint24 public constant MAXIMUM_MINIMUM_SECONDS_TO_DEADLINE = 30 days;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public liquidityPool;
    IeETH public eETH;
    IRoleRegistry public roleRegistry;

    /// @notice EnumerableSet to store all active withdraw request IDs
    EnumerableSet.Bytes32Set private _withdrawRequests;

    /// @notice Set of finalized request IDs (fulfilled and ready for claim)
    EnumerableSet.Bytes32Set private _finalizedRequests;

    /// @notice Set of invalidated request IDs
    mapping(bytes32 => bool) public invalidatedRequests;

    /// @notice Mapping of whitelisted addresses
    mapping(address => bool) public isWhitelisted;

    /// @notice Withdrawal configuration
    WithdrawConfig private _withdrawConfig;

    /// @notice Request nonce to prevent hash collisions
    uint96 public nonce;

    /// @notice Total eETH shares held for pending requests
    uint256 public totalPendingShares;

    /// @notice Total eETH shares held for finalized (claimable) requests
    uint256 public totalFinalizedShares;

    /// @notice Remainder shares from claimed withdrawals (difference between request shares and actual burned)
    uint256 public totalRemainderShares;

    /// @notice Contract pause state
    bool public paused;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ----------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ORACLE_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ORACLE_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event Paused(address account);
    event Unpaused(address account);
    event WithdrawRequestCreated(
        bytes32 indexed requestId,
        address indexed user,
        uint96 nonce,
        uint128 amountOfEEth,
        uint128 shareOfEEth,
        uint40 creationTime,
        uint24 secondsToMaturity,
        uint24 secondsToDeadline
    );
    event WithdrawRequestCancelled(bytes32 indexed requestId, address indexed user, uint256 timestamp);
    event WithdrawRequestFinalized(bytes32 indexed requestId, address indexed user, uint256 timestamp);
    event WithdrawRequestClaimed(bytes32 indexed requestId, address indexed user, uint256 amountClaimed, uint256 sharesBurned);
    event WithdrawRequestInvalidated(bytes32 indexed requestId);
    event WithdrawRequestValidated(bytes32 indexed requestId);
    event WhitelistUpdated(address indexed user, bool status);
    event WithdrawConfigUpdated(uint24 secondsToMaturity, uint24 minimumSecondsToDeadline, uint96 minimumAmount);
    event WithdrawCapacityUpdated(uint256 withdrawCapacity);
    event WithdrawsStopped();
    event RemainderHandled(uint256 remainderAmount, uint256 remainderShares);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    error NotWhitelisted();
    error InvalidAmount();
    error InvalidDeadline();
    error RequestNotFound();
    error RequestNotFinalized();
    error RequestInvalidated();
    error RequestAlreadyFinalized();
    error NotRequestOwner();
    error IncorrectRole();
    error ContractPaused();
    error ContractNotPaused();
    error WithdrawsNotAllowed();
    error NotEnoughWithdrawCapacity();
    error NotMatured();
    error DeadlinePassed();
    error Keccak256Collision();
    error InvalidConfig();
    error PermitFailedAndAllowanceTooLow();
    error BadInput();

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

    modifier onlyOracle() {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_ORACLE_ROLE, msg.sender)) revert IncorrectRole();
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
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _liquidityPool Address of the LiquidityPool contract
    /// @param _eETH Address of the eETH contract
    /// @param _roleRegistry Address of the RoleRegistry contract
    function initialize(
        address _liquidityPool,
        address _eETH,
        address _roleRegistry
    ) external initializer {
        if (_liquidityPool == address(0) || _eETH == address(0) || _roleRegistry == address(0)) {
            revert BadInput();
        }

        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        liquidityPool = ILiquidityPool(_liquidityPool);
        eETH = IeETH(_eETH);
        roleRegistry = IRoleRegistry(_roleRegistry);

        nonce = 1;
        paused = false;

        // Default config - can be updated by admin
        _withdrawConfig = WithdrawConfig({
            allowWithdraws: true,
            secondsToMaturity: 0, // Instant maturity by default for priority users
            minimumSecondsToDeadline: 1 days,
            minimumAmount: 0.01 ether,
            withdrawCapacity: type(uint256).max
        });
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  USER FUNCTIONS  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Request a withdrawal of eETH
    /// @param amountOfEEth Amount of eETH to withdraw
    /// @param secondsToDeadline Time in seconds the request is valid for after maturity
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdraw(
        uint128 amountOfEEth, 
        uint24 secondsToDeadline
    ) external whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
        _decrementWithdrawCapacity(amountOfEEth);
        _validateNewRequest(amountOfEEth, secondsToDeadline);

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth, secondsToDeadline);
    }

    /// @notice Request a withdrawal with permit for gasless approval
    /// @param amountOfEEth Amount of eETH to withdraw
    /// @param secondsToDeadline Time in seconds the request is valid for after maturity
    /// @param permit Permit signature data for eETH approval
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdrawWithPermit(
        uint128 amountOfEEth,
        uint24 secondsToDeadline,
        PermitInput calldata permit
    ) external whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
        _decrementWithdrawCapacity(amountOfEEth);
        _validateNewRequest(amountOfEEth, secondsToDeadline);

        // Try permit - continue if it fails (may already be approved)
        try eETH.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
        catch {
            if (IERC20(address(eETH)).allowance(msg.sender, address(this)) < amountOfEEth) {
                revert PermitFailedAndAllowanceTooLow();
            }
        }

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth, secondsToDeadline);
    }

    /// @notice Cancel a pending withdrawal request
    /// @param request The withdrawal request to cancel
    /// @return requestId The cancelled request ID
    function cancelWithdraw(
        WithdrawRequest calldata request
    ) external whenNotPaused onlyRequestUser(request.user) returns (bytes32 requestId) {
        requestId = _cancelWithdrawRequest(request);
    }

    /// @notice Replace an existing withdrawal request with new parameters
    /// @param oldRequest The existing request to replace
    /// @param newSecondsToDeadline New validity period for the replacement request
    /// @return oldRequestId The cancelled request ID
    /// @return newRequestId The new request ID
    function replaceWithdraw(
        WithdrawRequest calldata oldRequest,
        uint24 newSecondsToDeadline
    ) external whenNotPaused onlyRequestUser(oldRequest.user) returns (bytes32 oldRequestId, bytes32 newRequestId) {
        _validateNewRequest(oldRequest.amountOfEEth, newSecondsToDeadline);

        // Dequeue old request (no capacity increment since we're replacing)
        oldRequestId = _dequeueWithdrawRequest(oldRequest);
        
        emit WithdrawRequestCancelled(oldRequestId, oldRequest.user, block.timestamp);

        // Queue new request with same amount (no capacity decrement)
        (newRequestId,) = _queueWithdrawRequest(oldRequest.user, oldRequest.amountOfEEth, newSecondsToDeadline);
    }

    /// @notice Claim ETH for a finalized withdrawal request
    /// @param request The withdrawal request to claim
    function claimWithdraw(WithdrawRequest calldata request) external whenNotPaused nonReentrant {
        _claimWithdraw(request, request.user);
    }

    /// @notice Batch claim multiple withdrawal requests
    /// @param requests Array of withdrawal requests to claim
    function batchClaimWithdraw(WithdrawRequest[] calldata requests) external whenNotPaused nonReentrant {
        for (uint256 i = 0; i < requests.length; ++i) {
            _claimWithdraw(requests[i], requests[i].user);
        }
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  ORACLE/SOLVER FUNCTIONS  -------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Oracle finalizes withdrawal requests after maturity
    /// @dev Checks maturity and deadline, marks requests as finalized
    /// @param requests Array of requests to finalize
    function fulfillRequests(WithdrawRequest[] calldata requests) external onlyOracle whenNotPaused {
        uint256 totalSharesToFinalize = 0;

        for (uint256 i = 0; i < requests.length; ++i) {
            WithdrawRequest calldata request = requests[i];
            bytes32 requestId = keccak256(abi.encode(request));

            // Verify request exists in pending set
            if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();
            
            // Check not already finalized
            if (_finalizedRequests.contains(requestId)) revert RequestAlreadyFinalized();
            
            // Check not invalidated
            if (invalidatedRequests[requestId]) revert RequestInvalidated();

            // Check maturity
            uint256 maturity = request.creationTime + request.secondsToMaturity;
            if (block.timestamp < maturity) revert NotMatured();

            // Check deadline
            uint256 deadline = maturity + request.secondsToDeadline;
            if (block.timestamp > deadline) revert DeadlinePassed();

            // Add to finalized set
            _finalizedRequests.add(requestId);
            totalSharesToFinalize += request.shareOfEEth;

            emit WithdrawRequestFinalized(requestId, request.user, block.timestamp);
        }

        // Update accounting
        totalPendingShares -= totalSharesToFinalize;
        totalFinalizedShares += totalSharesToFinalize;

        // Lock ETH in LiquidityPool for priority withdrawals
        uint256 totalAmountToLock = liquidityPool.amountForShare(totalSharesToFinalize);
        liquidityPool.addEthAmountLockedForPriorityWithdrawal(uint128(totalAmountToLock));
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ADMIN FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Add an address to the whitelist
    /// @param user Address to whitelist
    function addToWhitelist(address user) external onlyAdmin {
        if (user == address(0)) revert BadInput();
        isWhitelisted[user] = true;
        emit WhitelistUpdated(user, true);
    }

    /// @notice Remove an address from the whitelist
    /// @param user Address to remove from whitelist
    function removeFromWhitelist(address user) external onlyAdmin {
        isWhitelisted[user] = false;
        emit WhitelistUpdated(user, false);
    }

    /// @notice Batch update whitelist status
    /// @param users Array of user addresses
    /// @param statuses Array of whitelist statuses
    function batchUpdateWhitelist(address[] calldata users, bool[] calldata statuses) external onlyAdmin {
        if (users.length != statuses.length) revert BadInput();
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert BadInput();
            isWhitelisted[users[i]] = statuses[i];
            emit WhitelistUpdated(users[i], statuses[i]);
        }
    }

    /// @notice Update withdrawal configuration
    /// @param secondsToMaturity Time until requests can be fulfilled
    /// @param minimumSecondsToDeadline Minimum validity period after maturity
    /// @param minimumAmount Minimum withdrawal amount
    function updateWithdrawConfig(
        uint24 secondsToMaturity,
        uint24 minimumSecondsToDeadline,
        uint96 minimumAmount
    ) external onlyAdmin {
        if (secondsToMaturity > MAXIMUM_SECONDS_TO_MATURITY) revert InvalidConfig();
        if (minimumSecondsToDeadline > MAXIMUM_MINIMUM_SECONDS_TO_DEADLINE) revert InvalidConfig();

        _withdrawConfig.secondsToMaturity = secondsToMaturity;
        _withdrawConfig.minimumSecondsToDeadline = minimumSecondsToDeadline;
        _withdrawConfig.minimumAmount = minimumAmount;
        _withdrawConfig.allowWithdraws = true;

        emit WithdrawConfigUpdated(secondsToMaturity, minimumSecondsToDeadline, minimumAmount);
    }

    /// @notice Set the withdrawal capacity
    /// @param capacity New withdrawal capacity
    function setWithdrawCapacity(uint256 capacity) external onlyAdmin {
        _withdrawConfig.withdrawCapacity = capacity;
        emit WithdrawCapacityUpdated(capacity);
    }

    /// @notice Stop all withdrawals
    function stopWithdraws() external onlyAdmin {
        _withdrawConfig.allowWithdraws = false;
        emit WithdrawsStopped();
    }

    /// @notice Invalidate a withdrawal request (prevents finalization)
    /// @param request The request to invalidate
    function invalidateRequest(WithdrawRequest calldata request) external onlyAdmin {
        bytes32 requestId = keccak256(abi.encode(request));
        if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();
        if (invalidatedRequests[requestId]) revert RequestInvalidated();
        
        invalidatedRequests[requestId] = true;
        emit WithdrawRequestInvalidated(requestId);
    }

    /// @notice Validate a previously invalidated request
    /// @param requestId The request ID to validate
    function validateRequest(bytes32 requestId) external onlyAdmin {
        if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();
        if (!invalidatedRequests[requestId]) revert BadInput();
        
        invalidatedRequests[requestId] = false;
        emit WithdrawRequestValidated(requestId);
    }

    /// @notice Bulk finalize requests up to a certain request ID
    /// @dev Used for batch finalization by admin
    /// @param upToRequestId The request ID to finalize up to
    function finalizeRequests(bytes32 upToRequestId) external onlyAdmin {
        // This function allows admin to mark a specific request as finalized
        // Useful for edge cases where oracle flow is bypassed
        if (!_withdrawRequests.contains(upToRequestId)) revert RequestNotFound();
        if (_finalizedRequests.contains(upToRequestId)) revert RequestAlreadyFinalized();
        
        _finalizedRequests.add(upToRequestId);
    }

    /// @notice Admin cancel multiple user withdrawals
    /// @param requests Array of requests to cancel
    /// @return cancelledRequestIds Array of cancelled request IDs
    function cancelUserWithdraws(
        WithdrawRequest[] calldata requests
    ) external onlyAdmin returns (bytes32[] memory cancelledRequestIds) {
        uint256 length = requests.length;
        cancelledRequestIds = new bytes32[](length);
        
        for (uint256 i = 0; i < length; ++i) {
            cancelledRequestIds[i] = _cancelWithdrawRequest(requests[i]);
        }
    }

    /// @notice Handle remainder shares (from rounding differences)
    /// @param sharesToBurn Amount of remainder shares to burn
    function handleRemainder(uint256 sharesToBurn) external onlyAdmin {
        if (sharesToBurn > totalRemainderShares) revert BadInput();
        
        uint256 amountToBurn = liquidityPool.amountForShare(sharesToBurn);
        totalRemainderShares -= sharesToBurn;
        
        // Burn the remainder
        liquidityPool.burnEEthShares(sharesToBurn);
        
        emit RemainderHandled(amountToBurn, sharesToBurn);
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

    /// @dev Validate new request parameters
    function _validateNewRequest(uint128 amountOfEEth, uint24 secondsToDeadline) internal view {
        if (!_withdrawConfig.allowWithdraws) revert WithdrawsNotAllowed();
        if (amountOfEEth < _withdrawConfig.minimumAmount) revert InvalidAmount();
        if (secondsToDeadline < _withdrawConfig.minimumSecondsToDeadline) revert InvalidDeadline();
    }

    /// @dev Decrement withdrawal capacity
    function _decrementWithdrawCapacity(uint128 amount) internal {
        if (_withdrawConfig.withdrawCapacity < type(uint256).max) {
            if (_withdrawConfig.withdrawCapacity < amount) revert NotEnoughWithdrawCapacity();
            _withdrawConfig.withdrawCapacity -= amount;
            emit WithdrawCapacityUpdated(_withdrawConfig.withdrawCapacity);
        }
    }

    /// @dev Increment withdrawal capacity
    function _incrementWithdrawCapacity(uint128 amount) internal {
        if (_withdrawConfig.withdrawCapacity < type(uint256).max) {
            _withdrawConfig.withdrawCapacity += amount;
            emit WithdrawCapacityUpdated(_withdrawConfig.withdrawCapacity);
        }
    }

    /// @dev Queue a new withdrawal request
    function _queueWithdrawRequest(
        address user,
        uint128 amountOfEEth,
        uint24 secondsToDeadline
    ) internal returns (bytes32 requestId, WithdrawRequest memory req) {
        uint96 requestNonce;
        unchecked {
            requestNonce = nonce++;
        }

        uint128 shareOfEEth = uint128(liquidityPool.sharesForAmount(amountOfEEth));
        if (shareOfEEth == 0) revert InvalidAmount();

        uint40 timeNow = uint40(block.timestamp);

        req = WithdrawRequest({
            nonce: requestNonce,
            user: user,
            amountOfEEth: amountOfEEth,
            shareOfEEth: shareOfEEth,
            creationTime: timeNow,
            secondsToMaturity: _withdrawConfig.secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });

        requestId = keccak256(abi.encode(req));

        bool addedToSet = _withdrawRequests.add(requestId);
        if (!addedToSet) revert Keccak256Collision();

        totalPendingShares += shareOfEEth;

        emit WithdrawRequestCreated(
            requestId,
            user,
            requestNonce,
            amountOfEEth,
            shareOfEEth,
            timeNow,
            _withdrawConfig.secondsToMaturity,
            secondsToDeadline
        );
    }

    /// @dev Dequeue a withdrawal request
    function _dequeueWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        bool removedFromSet = _withdrawRequests.remove(requestId);
        if (!removedFromSet) revert RequestNotFound();
        
        // Also remove from finalized if it was there
        _finalizedRequests.remove(requestId);
    }

    /// @dev Cancel a withdrawal request and return eETH to user
    function _cancelWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = _dequeueWithdrawRequest(request);
        
        // Update accounting based on whether it was finalized
        if (_finalizedRequests.contains(requestId)) {
            totalFinalizedShares -= request.shareOfEEth;
            // Unlock ETH from LiquidityPool
            uint256 amountToUnlock = liquidityPool.amountForShare(request.shareOfEEth);
            liquidityPool.reduceEthAmountLockedForPriorityWithdrawal(uint128(amountToUnlock));
        } else {
            totalPendingShares -= request.shareOfEEth;
        }
        
        _incrementWithdrawCapacity(request.amountOfEEth);
        
        // Return eETH to user
        IERC20(address(eETH)).safeTransfer(request.user, request.amountOfEEth);
        
        emit WithdrawRequestCancelled(requestId, request.user, block.timestamp);
    }

    /// @dev Internal claim function
    function _claimWithdraw(WithdrawRequest calldata request, address recipient) internal {
        if (request.user != msg.sender) revert NotRequestOwner();
        
        bytes32 requestId = keccak256(abi.encode(request));
        
        // Verify request exists
        if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();
        
        // Verify request is finalized
        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();
        
        // Verify not invalidated
        if (invalidatedRequests[requestId]) revert RequestInvalidated();

        // Calculate claimable amount (min of requested amount or current share value)
        // This protects users if rate has changed unfavorably, and protocol if rate increased
        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        uint256 amountToWithdraw = request.amountOfEEth < amountForShares 
            ? request.amountOfEEth 
            : amountForShares;

        uint256 sharesToBurn = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

        // Remove from sets
        _withdrawRequests.remove(requestId);
        _finalizedRequests.remove(requestId);

        // Track remainder (difference between original shares and burned shares)
        uint256 remainder = request.shareOfEEth > sharesToBurn 
            ? request.shareOfEEth - sharesToBurn 
            : 0;
        totalRemainderShares += remainder;
        
        // Update accounting
        totalFinalizedShares -= request.shareOfEEth;

        // Execute withdrawal through LiquidityPool
        uint256 burnedShares = liquidityPool.withdraw(recipient, amountToWithdraw);
        assert(burnedShares == sharesToBurn);

        emit WithdrawRequestClaimed(requestId, recipient, amountToWithdraw, burnedShares);
    }

    function _authorizeUpgrade(address) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Get the request ID from a request struct
    /// @param request The withdrawal request
    /// @return requestId The keccak256 hash of the request
    function getRequestId(WithdrawRequest calldata request) external pure returns (bytes32) {
        return keccak256(abi.encode(request));
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
        if (invalidatedRequests[requestId]) revert RequestInvalidated();

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

    /// @notice Get the total eETH amount pending (not finalized)
    /// @return The total pending eETH amount
    function totalPendingAmount() external view returns (uint256) {
        return liquidityPool.amountForShare(totalPendingShares);
    }

    /// @notice Get the total eETH amount finalized (ready for claim)
    /// @return The total finalized eETH amount
    function totalFinalizedAmount() external view returns (uint256) {
        return liquidityPool.amountForShare(totalFinalizedShares);
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

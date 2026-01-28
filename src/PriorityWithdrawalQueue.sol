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
    uint24 public constant MAXIMUM_MIN_DELAY = 30 days;

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

    /// @notice Set of invalidated request IDs
    mapping(bytes32 => bool) public invalidatedRequests;

    /// @notice Mapping of whitelisted addresses
    mapping(address => bool) public isWhitelisted;

    /// @notice Withdrawal configuration
    WithdrawConfig private _withdrawConfig;

    /// @notice Request nonce to prevent hash collisions
    uint96 public nonce;

    /// @notice Remainder shares from claimed withdrawals (difference between request shares and actual burned)
    uint256 public totalRemainderShares;

    /// @notice Fee split to treasury in basis points (e.g., 5000 = 50%)
    uint16 public shareRemainderSplitToTreasuryInBps;

    /// @notice Contract pause state
    bool public paused;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ----------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE");
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
        uint96 nonce,
        uint128 amountOfEEth,
        uint128 shareOfEEth,
        uint40 creationTime
    );
    event WithdrawRequestCancelled(bytes32 indexed requestId, address indexed user, uint256 timestamp);
    event WithdrawRequestFinalized(bytes32 indexed requestId, address indexed user, uint256 timestamp);
    event WithdrawRequestClaimed(bytes32 indexed requestId, address indexed user, uint256 amountClaimed, uint256 sharesBurned);
    event WithdrawRequestInvalidated(bytes32 indexed requestId);
    event WhitelistUpdated(address indexed user, bool status);
    event WithdrawConfigUpdated(uint24 minDelay, uint96 minimumAmount);
    event WithdrawCapacityUpdated(uint256 withdrawCapacity);
    event RemainderHandled(uint256 amountToTreasury, uint256 amountBurned);
    event ShareRemainderSplitUpdated(uint16 newSplitInBps);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    error NotWhitelisted();
    error InvalidAmount();
    error RequestNotFound();
    error RequestNotFinalized();
    error RequestInvalidated();
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
            creationTime: uint40(block.timestamp),
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
        uint128 amountOfEEth
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
        uint128 amountOfEEth,
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
            if (invalidatedRequests[requestId]) revert RequestInvalidated();

            // Check minDelay has passed (request must wait at least minDelay seconds)
            uint256 earliestFulfillTime = request.creationTime + _withdrawConfig.minDelay;
            if (block.timestamp < earliestFulfillTime) revert NotMatured();

            // Add to finalized set
            _finalizedRequests.add(requestId);
            totalSharesToFinalize += request.shareOfEEth;

            emit WithdrawRequestFinalized(requestId, request.user, block.timestamp);
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
    function addToWhitelist(address user) external onlyAdmin {
        if (user == address(0)) revert AddressZero();
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
        uint24 minDelay,
        uint96 minimumAmount
    ) external onlyAdmin {
        if (minDelay > MAXIMUM_MIN_DELAY) revert InvalidConfig();

        _withdrawConfig.minDelay = minDelay;
        _withdrawConfig.creationTime = uint40(block.timestamp);
        _withdrawConfig.minimumAmount = minimumAmount;

        emit WithdrawConfigUpdated(minDelay, minimumAmount);
    }

    /// @notice Set the withdrawal capacity
    /// @param capacity New withdrawal capacity
    function setWithdrawCapacity(uint256 capacity) external onlyAdmin {
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
            if (invalidatedRequests[requestId]) revert RequestInvalidated();

            _cancelWithdrawRequest(requests[i]);
            invalidatedRequestIds[i] = requestId;
            invalidatedRequests[requestId] = true;
            emit WithdrawRequestInvalidated(requestId);
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

        totalRemainderShares -= eEthSharesMoved;

        if (eEthAmountToTreasury > 0) IERC20(address(eETH)).safeTransfer(treasury, eEthAmountToTreasury);
        if (eEthSharesToBurn > 0) liquidityPool.burnEEthShares(eEthSharesToBurn);

        require(beforeEEthShares - eEthSharesMoved == eETH.shares(address(this)), "Invalid eETH shares after remainder handling");

        emit RemainderHandled(eEthAmountToTreasury, liquidityPool.amountForShare(eEthSharesToBurn));
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
        uint128 amountOfEEth
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
            creationTime: timeNow
        });

        requestId = keccak256(abi.encode(req));

        bool addedToSet = _withdrawRequests.add(requestId);
        if (!addedToSet) revert Keccak256Collision();

        emit WithdrawRequestCreated(
            requestId,
            user,
            requestNonce,
            amountOfEEth,
            shareOfEEth,
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
        
        // Unlock ETH from LiquidityPool if it was finalized
        if (wasFinalized) {
            uint256 amountToUnlock = liquidityPool.amountForShare(request.shareOfEEth);
            liquidityPool.reduceEthAmountLockedForPriorityWithdrawal(uint128(amountToUnlock));
        }
        
        _incrementWithdrawCapacity(request.amountOfEEth);
        
        IERC20(address(eETH)).safeTransfer(request.user, request.amountOfEEth);
        
        emit WithdrawRequestCancelled(requestId, request.user, block.timestamp);
    }

    /// @dev Internal claim function
    function _claimWithdraw(WithdrawRequest calldata request) internal {
        if (request.user != msg.sender) revert NotRequestOwner();
        
        bytes32 requestId = keccak256(abi.encode(request));
        
        if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();
        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();
        if (invalidatedRequests[requestId]) revert RequestInvalidated();

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
        totalRemainderShares += remainder;

        uint256 burnedShares = liquidityPool.withdraw(msg.sender, amountToWithdraw);
        if (burnedShares != sharesToBurn) revert InvalidBurnedSharesAmount();

        emit WithdrawRequestClaimed(requestId, msg.sender, amountToWithdraw, burnedShares);
    }

    function _authorizeUpgrade(address) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Generate a request ID from individual parameters
    /// @param _nonce The request nonce
    /// @param _user The user address
    /// @param _amountOfEEth The amount of eETH
    /// @param _shareOfEEth The share of eETH
    /// @param _creationTime The creation timestamp
    /// @return requestId The keccak256 hash of the request
    function generateWithdrawRequestId(
        uint96 _nonce,
        address _user,
        uint128 _amountOfEEth,
        uint128 _shareOfEEth,
        uint40 _creationTime
    ) public pure returns (bytes32 requestId) {
        WithdrawRequest memory req = WithdrawRequest({
            nonce: _nonce,
            user: _user,
            amountOfEEth: _amountOfEEth,
            shareOfEEth: _shareOfEEth,
            creationTime: _creationTime
        });
        requestId = keccak256(abi.encode(req));
    }

    /// @notice Get the request ID from a request struct
    /// @param request The withdrawal request
    /// @return requestId The keccak256 hash of the request
    function getRequestId(WithdrawRequest calldata request) external pure returns (bytes32) {
        return generateWithdrawRequestId(
            request.nonce,
            request.user,
            request.amountOfEEth,
            request.shareOfEEth,
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

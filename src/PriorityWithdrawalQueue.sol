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
/// @notice Manages priority withdrawals for whitelisted users
/// @dev Implements priority withdrawal queue pattern
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

    uint96 public constant MIN_AMOUNT = 0.01 ether;
    uint256 private constant _BASIS_POINT_SCALE = 1e4;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IRoleRegistry public immutable roleRegistry;
    address public immutable treasury;
    uint32 public immutable MIN_DELAY;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice EnumerableSet to store all active withdraw request IDs
    EnumerableSet.Bytes32Set private _withdrawRequests;

    /// @notice Set of finalized request IDs (fulfilled and ready for claim)
    EnumerableSet.Bytes32Set private _finalizedRequests;

    mapping(address => bool) public isWhitelisted;

    uint32 public nonce;
    uint16 public shareRemainderSplitToTreasuryInBps;
    bool public paused;
    uint96 public totalRemainderShares;
    uint128 public ethAmountLockedForPriorityWithdrawal;

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
        uint96 minAmountOut,
        uint32 nonce,
        uint32 creationTime
    );
    event WithdrawRequestCancelled(bytes32 indexed requestId, address indexed user, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestFinalized(bytes32 indexed requestId, address indexed user, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestClaimed(bytes32 indexed requestId, address indexed user, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestInvalidated(bytes32 indexed requestId, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WhitelistUpdated(address indexed user, bool status);
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
    error NotMatured();
    error UnexpectedBalanceChange();
    error Keccak256Collision();
    error PermitFailedAndAllowanceTooLow();
    error ArrayLengthMismatch();
    error AddressZero();
    error BadInput();
    error InvalidBurnedSharesAmount();
    error InvalidEEthSharesAfterRemainderHandling();
    error InsufficientOutputAmount();

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
    constructor(address _liquidityPool, address _eETH, address _roleRegistry, address _treasury, uint32 _minDelay) {
        if (_liquidityPool == address(0) || _eETH == address(0) || _roleRegistry == address(0) || _treasury == address(0)) {
            revert AddressZero();
        }
        
        liquidityPool = ILiquidityPool(_liquidityPool);
        eETH = IeETH(_eETH);
        roleRegistry = IRoleRegistry(_roleRegistry);
        treasury = _treasury;
        MIN_DELAY = _minDelay;

        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        nonce = 1;
        shareRemainderSplitToTreasuryInBps = 10000; // 100%
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  USER FUNCTIONS  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Request a withdrawal of eETH
    /// @param amountOfEEth Amount of eETH to withdraw
    /// @param minAmountOut Minimum ETH output amount (slippage protection for dynamic fees)
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdraw(
        uint96 amountOfEEth,
        uint96 minAmountOut
    ) external whenNotPaused onlyWhitelisted nonReentrant returns (bytes32 requestId) {
        if (amountOfEEth < MIN_AMOUNT) revert InvalidAmount();
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore) = _snapshotBalances();

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth, minAmountOut);
        _verifyRequestPostConditions(lpEthBefore, queueEEthSharesBefore, amountOfEEth);
    }

    /// @notice Request a withdrawal with permit for gasless approval
    /// @param amountOfEEth Amount of eETH to withdraw
    /// @param minAmountOut Minimum ETH output amount (slippage protection for dynamic fees)
    /// @param permit Permit signature data for eETH approval
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdrawWithPermit(
        uint96 amountOfEEth,
        uint96 minAmountOut,
        PermitInput calldata permit
    ) external whenNotPaused onlyWhitelisted nonReentrant returns (bytes32 requestId) {
        if (amountOfEEth < MIN_AMOUNT) revert InvalidAmount();
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore) = _snapshotBalances();

        try eETH.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {}

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth, minAmountOut);

        _verifyRequestPostConditions(lpEthBefore, queueEEthSharesBefore, amountOfEEth);
    }

    /// @notice Cancel a pending withdrawal request
    /// @param request The withdrawal request to cancel
    /// @return requestId The cancelled request ID
    function cancelWithdraw(
        WithdrawRequest calldata request
    ) external whenNotPaused onlyRequestUser(request.user) nonReentrant returns (bytes32 requestId) {
        if (request.creationTime + MIN_DELAY > block.timestamp) revert NotMatured();
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore) = _snapshotBalances();
        uint256 userEEthSharesBefore = eETH.shares(request.user);

        requestId = _cancelWithdrawRequest(request);

        _verifyCancelPostConditions(lpEthBefore, queueEEthSharesBefore, userEEthSharesBefore, request.user);
    }

    /// @notice Claim ETH for a finalized withdrawal request
    /// @dev Anyone can call this to claim on behalf of the user. Funds are sent to request.user.
    /// @param request The withdrawal request to claim
    function claimWithdraw(WithdrawRequest calldata request) external whenNotPaused nonReentrant {
        if (request.creationTime + MIN_DELAY > block.timestamp) revert NotMatured();
        
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore) = _snapshotBalances();
        uint256 userEthBefore = request.user.balance;

        _claimWithdraw(request);

        _verifyClaimPostConditions(lpEthBefore, queueEEthSharesBefore, userEthBefore, request.user);
    }

    /// @notice Batch claim multiple withdrawal requests
    /// @dev Anyone can call this to claim on behalf of users. Funds are sent to each request.user.
    /// @param requests Array of withdrawal requests to claim
    function batchClaimWithdraw(WithdrawRequest[] calldata requests) external whenNotPaused nonReentrant {
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore) = _snapshotBalances();

        for (uint256 i = 0; i < requests.length; ++i) {
            if (requests[i].creationTime + MIN_DELAY > block.timestamp) revert NotMatured();
            _claimWithdraw(requests[i]);
        }

        // Post-hook balance checks (at least one claim should have changed balances)
        if (requests.length > 0) {
            _verifyBatchClaimPostConditions(lpEthBefore, queueEEthSharesBefore);
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

            if (_finalizedRequests.contains(requestId)) revert RequestAlreadyFinalized();
            if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();

            uint256 earliestFulfillTime = request.creationTime + MIN_DELAY;
            if (block.timestamp < earliestFulfillTime) revert NotMatured();

            _withdrawRequests.remove(requestId);
            _finalizedRequests.add(requestId);
            totalSharesToFinalize += request.shareOfEEth;

            emit WithdrawRequestFinalized(requestId, request.user, request.amountOfEEth, request.shareOfEEth, request.nonce, uint32(block.timestamp));
        }

        uint256 totalAmountToLock = liquidityPool.amountForShare(totalSharesToFinalize);
        ethAmountLockedForPriorityWithdrawal += uint128(totalAmountToLock);
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

    /// @notice Invalidate a withdrawal request (prevents finalization)
    /// @param requests Array of requests to invalidate
    /// @return invalidatedRequestIds Array of request IDs that were invalidated
    function invalidateRequests(WithdrawRequest[] calldata requests) external onlyRequestManager returns (bytes32[] memory invalidatedRequestIds) {
        invalidatedRequestIds = new bytes32[](requests.length);
        for (uint256 i = 0; i < requests.length; ++i) {
            bytes32 requestId = keccak256(abi.encode(requests[i]));
            // Check both sets since pending requests are in _withdrawRequests, finalized in _finalizedRequests
            if (!(_withdrawRequests.contains(requestId) || _finalizedRequests.contains(requestId))) revert RequestNotFound();

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

    function updateShareRemainderSplitToTreasury(uint16 _shareRemainderSplitToTreasuryInBps) external onlyAdmin {
        if (_shareRemainderSplitToTreasuryInBps > _BASIS_POINT_SCALE) revert BadInput();
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
        emit ShareRemainderSplitUpdated(_shareRemainderSplitToTreasuryInBps);
    }

    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        if (paused) revert ContractPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (!paused) revert ContractNotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Snapshot balances before state changes for post-hook verification
    /// @return lpEthBefore ETH balance of LiquidityPool
    /// @return queueEEthSharesBefore eETH shares held by this contract
    function _snapshotBalances() internal view returns (uint256 lpEthBefore, uint256 queueEEthSharesBefore) {
        lpEthBefore = address(liquidityPool).balance;
        queueEEthSharesBefore = eETH.shares(address(this));
    }

    /// @dev Verify post-conditions after a request is created
    /// @param lpEthBefore ETH balance of LiquidityPool before operation
    /// @param queueEEthSharesBefore eETH shares held by queue before operation
    /// @param amountOfEEth Amount of eETH that was transferred
    function _verifyRequestPostConditions(
        uint256 lpEthBefore, 
        uint256 queueEEthSharesBefore,
        uint96 amountOfEEth
    ) internal view {
        uint256 expectedSharesReceived = liquidityPool.sharesForAmount(amountOfEEth);
        if (eETH.shares(address(this)) != queueEEthSharesBefore + expectedSharesReceived) revert UnexpectedBalanceChange();
        if (address(liquidityPool).balance != lpEthBefore) revert UnexpectedBalanceChange();
    }

    /// @dev Verify post-conditions after a cancel operation
    /// @param lpEthBefore ETH balance of LiquidityPool before operation
    /// @param queueEEthSharesBefore eETH shares held by queue before operation
    /// @param userEEthSharesBefore eETH shares held by user before operation
    /// @param user The user who cancelled
    function _verifyCancelPostConditions(
        uint256 lpEthBefore,
        uint256 queueEEthSharesBefore,
        uint256 userEEthSharesBefore,
        address user
    ) internal view {
        if (address(liquidityPool).balance != lpEthBefore) revert UnexpectedBalanceChange();
        if (eETH.shares(address(this)) >= queueEEthSharesBefore) revert UnexpectedBalanceChange();
        if (eETH.shares(user) <= userEEthSharesBefore) revert UnexpectedBalanceChange();
    }

    /// @dev Verify post-conditions after a claim operation
    /// @param lpEthBefore ETH balance of LiquidityPool before operation
    /// @param queueEEthSharesBefore eETH shares held by queue before operation
    /// @param userEthBefore ETH balance of user before operation
    /// @param user The user who claimed
    function _verifyClaimPostConditions(
        uint256 lpEthBefore,
        uint256 queueEEthSharesBefore,
        uint256 userEthBefore,
        address user
    ) internal view {
        if (address(liquidityPool).balance >= lpEthBefore) revert UnexpectedBalanceChange();
        if (eETH.shares(address(this)) >= queueEEthSharesBefore) revert UnexpectedBalanceChange();
        if (user.balance <= userEthBefore) revert UnexpectedBalanceChange();
    }

    /// @dev Verify post-conditions after a batch claim operation
    /// @param lpEthBefore ETH balance of LiquidityPool before operation
    /// @param queueEEthSharesBefore eETH shares held by queue before operation
    function _verifyBatchClaimPostConditions(
        uint256 lpEthBefore,
        uint256 queueEEthSharesBefore
    ) internal view {
        if (address(liquidityPool).balance >= lpEthBefore) revert UnexpectedBalanceChange();
        if (eETH.shares(address(this)) >= queueEEthSharesBefore) revert UnexpectedBalanceChange();
    }

    function _queueWithdrawRequest(
        address user,
        uint96 amountOfEEth,
        uint96 minAmountOut
    ) internal returns (bytes32 requestId, WithdrawRequest memory req) {
        uint32 requestNonce = nonce++;

        uint96 shareOfEEth = uint96(liquidityPool.sharesForAmount(amountOfEEth));
        if (shareOfEEth == 0) revert InvalidAmount();

        uint32 timeNow = uint32(block.timestamp);

        req = WithdrawRequest({
            user: user,
            amountOfEEth: amountOfEEth,
            shareOfEEth: shareOfEEth,
            minAmountOut: minAmountOut,
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
            minAmountOut,
            requestNonce,
            timeNow
        );
    }

    function _dequeueWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        
        bool removedFromFinalized = _finalizedRequests.remove(requestId);
        if (removedFromFinalized) return requestId;
        
        bool removedFromPending = _withdrawRequests.remove(requestId);
        if (!removedFromPending) revert RequestNotFound();
    }

    function _cancelWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        
        bool wasFinalized = _finalizedRequests.contains(requestId);
        
        _dequeueWithdrawRequest(request);
        
        if (wasFinalized) {
            uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
            uint256 amountToUnlock = request.amountOfEEth < amountForShares 
                ? request.amountOfEEth 
                : amountForShares;
            ethAmountLockedForPriorityWithdrawal -= uint128(amountToUnlock);
        }
        
        IERC20(address(eETH)).safeTransfer(request.user, request.amountOfEEth);
        
        emit WithdrawRequestCancelled(requestId, request.user, request.amountOfEEth, request.shareOfEEth, request.nonce, uint32(block.timestamp));
    }

    function _claimWithdraw(WithdrawRequest calldata request) internal {
        bytes32 requestId = keccak256(abi.encode(request));
        
        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        uint256 amountToWithdraw = request.amountOfEEth < amountForShares 
            ? request.amountOfEEth 
            : amountForShares;

        if (amountToWithdraw < request.minAmountOut) revert InsufficientOutputAmount();

        uint256 sharesToBurn = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

        _finalizedRequests.remove(requestId);

        uint256 remainder = request.shareOfEEth > sharesToBurn 
            ? request.shareOfEEth - sharesToBurn 
            : 0;
        totalRemainderShares += uint96(remainder);

        ethAmountLockedForPriorityWithdrawal -= uint128(amountToWithdraw);

        uint256 burnedShares = liquidityPool.withdraw(request.user, amountToWithdraw);
        if (burnedShares != sharesToBurn) revert InvalidBurnedSharesAmount();

        emit WithdrawRequestClaimed(requestId, request.user, uint96(amountToWithdraw), uint96(sharesToBurn), request.nonce, uint32(block.timestamp));
    }

    function _authorizeUpgrade(address) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    function generateWithdrawRequestId(
        address _user,
        uint96 _amountOfEEth,
        uint96 _shareOfEEth,
        uint96 _minAmountOut,
        uint32 _nonce,
        uint32 _creationTime
    ) public pure returns (bytes32 requestId) {
        WithdrawRequest memory req = WithdrawRequest({
            user: _user,
            amountOfEEth: _amountOfEEth,
            shareOfEEth: _shareOfEEth,
            minAmountOut: _minAmountOut,
            nonce: _nonce,
            creationTime: _creationTime
        });
        requestId = keccak256(abi.encode(req));
    }

    function getRequestId(WithdrawRequest calldata request) external pure returns (bytes32) {
        return generateWithdrawRequestId(
            request.user,
            request.amountOfEEth,
            request.shareOfEEth,
            request.minAmountOut,
            request.nonce,
            request.creationTime
        );
    }

    function getRequestIds() external view returns (bytes32[] memory) {
        return _withdrawRequests.values();
    }

    function getFinalizedRequestIds() external view returns (bytes32[] memory) {
        return _finalizedRequests.values();
    }

    function requestExists(bytes32 requestId) external view returns (bool) {
        return _withdrawRequests.contains(requestId) || _finalizedRequests.contains(requestId);
    }

    function isFinalized(bytes32 requestId) external view returns (bool) {
        return _finalizedRequests.contains(requestId);
    }

    function getClaimableAmount(WithdrawRequest calldata request) external view returns (uint256) {
        bytes32 requestId = keccak256(abi.encode(request));
        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        return request.amountOfEEth < amountForShares ? request.amountOfEEth : amountForShares;
    }

    function totalActiveRequests() external view returns (uint256) {
        return _withdrawRequests.length();
    }

    function getRemainderAmount() external view returns (uint256) {
        return liquidityPool.amountForShare(totalRemainderShares);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}

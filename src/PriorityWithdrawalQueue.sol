// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IPriorityWithdrawalQueue.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IWeETH.sol";
import "./interfaces/IRoleRegistry.sol";
import "./utils/PausableUntil.sol";

/// @title PriorityWithdrawalQueue — share-rate-freeze invariants
/// @notice Manages priority withdrawals for whitelisted users.
///
/// Once `fulfillRequests` runs for a requestId, the rate used to compute its claim payout
/// is frozen at the rate snapshotted in that fulfill call. Subsequent rebases do NOT move
/// the claim payout — this is the H-02 fix on the priority path.
///
/// Invariants:
///  I1. `_fulfillmentRates[requestId]` is set on fulfill, cleared on claim/cancel/invalidate.
///      A non-zero value implies the request is in `_finalizedRequests`.
///  I2. For a finalized requestId, the resolved rate (`_fulfillmentRates[requestId]` or, for
///      pre-upgrade legacy fulfillments, `LP.amountPerShareCeil()` substituted locally) is
///      always non-zero — LP itself rejects rate=0.
///  I3. For any finalized requestId, `getClaimableAmount(request)` and the user-visible
///      `claimWithdraw` payout are invariant under `LP.rebase()` after the fulfill block.
///      Property-tested via `test_invariant_queue_claimAmountIndependentOfPostFulfillRebase`.
///  I4. The rate snapshot uses ceiling rounding (`Math.mulDiv(1e18, TPE, TS, Up)`) so the
///      per-request solvency check (`shareOfEEth * rate / 1e18 >= amountWithFee`) and the
///      round-trip burn (`ceil(amountWithFee * 1e18 / rate) <= shareOfEEth`) both hold.
contract PriorityWithdrawalQueue is
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUntil,
    IPriorityWithdrawalQueue
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Math for uint256;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    uint96 public constant MIN_AMOUNT = 0.01 ether;
    uint96 public constant MAX_AMOUNT = 1000 ether;
    uint256 private constant _BASIS_POINT_SCALE = 1e4;
    uint256 private constant _SHARE_UNIT = 1e18;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IWeETH public immutable weETH;
    IRoleRegistry public immutable roleRegistry;
    address public immutable treasury;
    uint32 public immutable MIN_DELAY;

    uint256 public immutable minAcceptableShareRate;
    uint256 public immutable maxAcceptableShareRate;

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

    /// @notice Frozen share rate (`amountPerShareCeil()`) recorded when each request was fulfilled.
    /// @dev Empty mapping value (0) means "no snapshot" — covers pre-upgrade requests fulfilled
    ///      before the share-rate-freeze upgrade. The claim/view paths locally substitute the
    ///      live `LP.amountPerShareCeil()` for those entries, preserving legacy semantics.
    ///      LP itself rejects rate=0.
    mapping(bytes32 => uint224) private _fulfillmentRates;

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
        uint96 amountWithFee,
        uint32 nonce,
        uint32 creationTime
    );
    event WithdrawRequestCancelled(bytes32 indexed requestId, address indexed user, uint96 amountOfEEthReturned, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestFinalized(bytes32 indexed requestId, address indexed user, uint96 amountOfEEth, uint96 sharesOfEEth, uint32 nonce, uint32 timestamp);
    event WithdrawRequestClaimed(bytes32 indexed requestId, address indexed user, uint96 amountOfETHtoWithdraw, uint96 sharesBurned, uint32 nonce, uint32 timestamp);
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
    error InvalidOutputAmount();
    error InsufficientLiquidity();
    error InvalidAcceptableShareRate();
    error InvalidLiveRate();

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _requireNotPausedUntil();
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
    constructor(address _liquidityPool, address _eETH, address _weETH, address _roleRegistry, address _treasury, uint32 _minDelay, uint256 _minAcceptableShareRate, uint256 _maxAcceptableShareRate) {
        if (_liquidityPool == address(0) || _eETH == address(0) || _weETH == address(0) || _roleRegistry == address(0) || _treasury == address(0)) {
            revert AddressZero();
        }
        if (_maxAcceptableShareRate <= _minAcceptableShareRate) revert InvalidAcceptableShareRate();
        
        liquidityPool = ILiquidityPool(_liquidityPool);
        eETH = IeETH(_eETH);
        weETH = IWeETH(_weETH);
        roleRegistry = IRoleRegistry(_roleRegistry);
        treasury = _treasury;
        MIN_DELAY = _minDelay;

        minAcceptableShareRate = _minAcceptableShareRate;
        maxAcceptableShareRate = _maxAcceptableShareRate;

        _disableInitializers();
    }

    receive() external payable {
        require(msg.sender == address(liquidityPool), "Only LP");
        if (liquidityPool.escrowMigrationCompleted()) {
            ethAmountLockedForPriorityWithdrawal += uint128(msg.value);
        }
        _checkEthAmountLockedForPriorityWithdrawal();
    }

    function initialize() external initializer {
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
    /// @param amountWithFee ETH amount the user receives after fee deduction (amountOfEEth - fee)
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdraw(
        uint96 amountOfEEth,
        uint96 amountWithFee
    ) external whenNotPaused onlyWhitelisted nonReentrant returns (bytes32 requestId) {
        if (amountOfEEth < MIN_AMOUNT || amountOfEEth > MAX_AMOUNT) revert InvalidAmount();
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore,) = _snapshotBalances();

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth, amountWithFee);
        _verifyRequestPostConditions(lpEthBefore, queueEEthSharesBefore, amountOfEEth);
    }

    function requestWithdrawWithPermit(
        uint96 amountOfEEth,
        uint96 amountWithFee,
        PermitInput calldata permit
    ) external whenNotPaused onlyWhitelisted nonReentrant returns (bytes32 requestId) {
        if (amountOfEEth < MIN_AMOUNT || amountOfEEth > MAX_AMOUNT) revert InvalidAmount();
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore,) = _snapshotBalances();

        try eETH.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {
            if (IERC20(address(eETH)).allowance(msg.sender, address(this)) < amountOfEEth) {
                revert PermitFailedAndAllowanceTooLow();
            }
        }

        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), amountOfEEth);

        (requestId,) = _queueWithdrawRequest(msg.sender, amountOfEEth, amountWithFee);

        _verifyRequestPostConditions(lpEthBefore, queueEEthSharesBefore, amountOfEEth);
    }

    /// @notice Request a withdrawal using weETH (unwraps to eETH internally)
    /// @param weEthAmount Amount of weETH to withdraw
    /// @param amountWithFee ETH amount the user receives after fee deduction
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdrawWithWeETH(
        uint96 weEthAmount,
        uint96 amountWithFee
    ) external whenNotPaused onlyWhitelisted nonReentrant returns (bytes32 requestId) {
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore,) = _snapshotBalances();

        IERC20(address(weETH)).safeTransferFrom(msg.sender, address(this), weEthAmount);
        uint96 eEthAmount = uint96(weETH.unwrap(weEthAmount));

        if (eEthAmount < MIN_AMOUNT || eEthAmount > MAX_AMOUNT) revert InvalidAmount();

        (requestId,) = _queueWithdrawRequest(msg.sender, eEthAmount, amountWithFee);
        _verifyRequestPostConditions(lpEthBefore, queueEEthSharesBefore, eEthAmount);
    }

    /// @notice Request a withdrawal using weETH with EIP-2612 permit
    /// @param weEthAmount Amount of weETH to withdraw
    /// @param amountWithFee ETH amount the user receives after fee deduction
    /// @param permit The permit params for weETH approval
    /// @return requestId The hash-based ID of the created withdrawal request
    function requestWithdrawWithWeETHAndPermit(
        uint96 weEthAmount,
        uint96 amountWithFee,
        PermitInput calldata permit
    ) external whenNotPaused onlyWhitelisted nonReentrant returns (bytes32 requestId) {
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore,) = _snapshotBalances();

        try weETH.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {
            if (IERC20(address(weETH)).allowance(msg.sender, address(this)) < weEthAmount) {
                revert PermitFailedAndAllowanceTooLow();
            }
        }

        IERC20(address(weETH)).safeTransferFrom(msg.sender, address(this), weEthAmount);
        uint96 eEthAmount = uint96(weETH.unwrap(weEthAmount));

        if (eEthAmount < MIN_AMOUNT || eEthAmount > MAX_AMOUNT) revert InvalidAmount();

        (requestId,) = _queueWithdrawRequest(msg.sender, eEthAmount, amountWithFee);
        _verifyRequestPostConditions(lpEthBefore, queueEEthSharesBefore, eEthAmount);
    }

    /// @notice Cancel a pending withdrawal request
    /// @param request The withdrawal request to cancel
    /// @return requestId The cancelled request ID
    function cancelWithdraw(
        WithdrawRequest calldata request
    ) external whenNotPaused onlyRequestUser(request.user) nonReentrant returns (bytes32 requestId) {
        if (request.creationTime + MIN_DELAY > block.timestamp) revert NotMatured();
        (uint256 lpEthBefore, uint256 queueEEthSharesBefore,) = _snapshotBalances();
        uint256 userEEthSharesBefore = eETH.shares(request.user);

        bytes32 reqId = keccak256(abi.encode(request));
        bool wasFinalized = _finalizedRequests.contains(reqId);
        uint256 expectedLpEthDelta = wasFinalized ? uint256(request.amountOfEEth) : 0;

        requestId = _cancelWithdrawRequest(request);

        _verifyCancelPostConditions(lpEthBefore, queueEEthSharesBefore, userEEthSharesBefore, request.user, expectedLpEthDelta);
    }

    /// @notice Claim ETH for a finalized withdrawal request
    /// @dev Anyone can call this to claim on behalf of the user. Funds are sent to request.user.
    ///      ETH delivery forwards gas to request.user, so third parties should avoid claiming for untrusted recipients.
    /// @param request The withdrawal request to claim
    function claimWithdraw(WithdrawRequest calldata request) external nonReentrant {
        if (request.creationTime + MIN_DELAY > block.timestamp) revert NotMatured();

        (uint256 lpEthBefore, uint256 queueEEthSharesBefore, uint256 queueEthBefore) = _snapshotBalances();
        uint256 userEthBefore = request.user.balance;

        _claimWithdraw(request);

        _verifyClaimPostConditions(lpEthBefore, queueEEthSharesBefore, queueEthBefore, userEthBefore, request.user);
    }

    /// @notice Batch claim multiple withdrawal requests
    /// @dev Anyone can call this to claim on behalf of users. Funds are sent to each request.user.
    ///      Each ETH delivery forwards gas to request.user, so batching untrusted recipients can be griefed.
    /// @param requests Array of withdrawal requests to claim
    function batchClaimWithdraw(WithdrawRequest[] calldata requests) external nonReentrant {
        for (uint256 i = 0; i < requests.length; ++i) {
            if (requests[i].creationTime + MIN_DELAY > block.timestamp) revert NotMatured();
            (uint256 lpEthBefore, uint256 queueEEthSharesBefore, uint256 queueEthBefore) = _snapshotBalances();
            uint256 userEthBefore = requests[i].user.balance;
            _claimWithdraw(requests[i]);
            _verifyClaimPostConditions(lpEthBefore, queueEEthSharesBefore, queueEthBefore, userEthBefore, requests[i].user);
        }
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  REQUEST MANAGER FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Request manager finalizes withdrawal requests after maturity.
    /// @dev Locks ETH per request by calling LP.transferLockedEthForPriority — escrowed in this contract until claim or cancel.
    function fulfillRequests(WithdrawRequest[] calldata requests) external onlyRequestManager whenNotPaused {
        uint256 totalAmountToLock = 0;

        // Snapshot the share rate once for the whole batch via LP's canonical ceiling formula.
        // Claim path uses `shareOfEEth * rate / _SHARE_UNIT` for both the solvency check and the
        // burn count, decoupling payout from post-fulfill rate movement.
        uint256 rate = liquidityPool.amountPerShareCeil();
        require(rate > 0 && rate <= type(uint224).max, "invalid rate");

        for (uint256 i = 0; i < requests.length; ++i) {
            WithdrawRequest calldata request = requests[i];
            bytes32 requestId = keccak256(abi.encode(request));

            if (_finalizedRequests.contains(requestId)) revert RequestAlreadyFinalized();
            if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();

            uint256 earliestFulfillTime = request.creationTime + MIN_DELAY;
            if (block.timestamp < earliestFulfillTime) revert NotMatured();

            // Per-request solvency check at fulfill time. The freeze locks this rate in, so a
            // request that fails this check would be permanently unclaimable; fail loudly here
            // and let the request manager re-attempt after rate recovery (or invalidate).
            if (Math.mulDiv(uint256(request.shareOfEEth), rate, _SHARE_UNIT) < request.amountWithFee) {
                revert InvalidOutputAmount();
            }

            _withdrawRequests.remove(requestId);
            _finalizedRequests.add(requestId);
            _fulfillmentRates[requestId] = uint224(rate);
            totalAmountToLock += request.amountOfEEth;

            emit WithdrawRequestFinalized(requestId, request.user, request.amountOfEEth, request.shareOfEEth, request.nonce, uint32(block.timestamp));
        }

        if (totalAmountToLock > 0) {
            liquidityPool.transferLockedEthForPriority(uint128(totalAmountToLock));
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ADMIN FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------

    function addToWhitelist(address user) external {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, msg.sender)) revert IncorrectRole();
        if (user == address(0)) revert AddressZero();
        isWhitelisted[user] = true;
        emit WhitelistUpdated(user, true);
    }

    function removeFromWhitelist(address user) external {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, msg.sender)) revert IncorrectRole();
        isWhitelisted[user] = false;
        emit WhitelistUpdated(user, false);
    }

    function batchUpdateWhitelist(address[] calldata users, bool[] calldata statuses) external {
        if (!roleRegistry.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, msg.sender)) revert IncorrectRole();
        if (users.length != statuses.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert AddressZero();
            isWhitelisted[users[i]] = statuses[i];
            emit WhitelistUpdated(users[i], statuses[i]);
        }
    }

    /// @notice Invalidate and cancel withdrawal requests in any state
    /// @dev Can target both pending and finalized requests.
    ///      For finalized requests, this also prevents subsequent claims.
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

        uint256 eEthAmountToTreasury = eEthAmount.mulDiv(
            shareRemainderSplitToTreasuryInBps,
            _BASIS_POINT_SCALE,
            Math.Rounding.Up
        );
        uint256 eEthAmountToBurn = eEthAmount - eEthAmountToTreasury;
        uint256 eEthSharesToBurn = liquidityPool.sharesForAmount(eEthAmountToBurn);
        uint256 eEthSharesMoved = eEthSharesToBurn + liquidityPool.sharesForAmount(eEthAmountToTreasury);

        totalRemainderShares -= uint96(eEthSharesMoved);

        if (eEthAmountToTreasury > 0) IERC20(address(eETH)).safeTransfer(treasury, eEthAmountToTreasury);
        if (eEthSharesToBurn > 0) liquidityPool.burnEEthShares(eEthSharesToBurn);

        if (beforeEEthShares - eEthSharesMoved != eETH.shares(address(this))) revert InvalidEEthSharesAfterRemainderHandling();

        emit RemainderHandled(uint96(eEthAmountToTreasury), uint96(eEthSharesToBurn));
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

    function pauseContractUntil() external {
        if (!roleRegistry.hasRole(roleRegistry.PAUSE_UNTIL_ROLE(), msg.sender)) revert IncorrectRole();
        _pauseUntil();
    }

    function unpauseContractUntil() external {
        if (!roleRegistry.hasRole(roleRegistry.UNPAUSE_UNTIL_ROLE(), msg.sender)) revert IncorrectRole();
        _unpauseUntil();
    }

    function setPauseUntilDuration(uint256 _pauseUntilDuration) external {
        if (!roleRegistry.hasRole(roleRegistry.PAUSE_DURATION_SETTER(), msg.sender)) revert IncorrectRole();
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Snapshot balances before state changes for post-hook verification
    /// @return lpEthBefore ETH balance of LiquidityPool
    /// @return queueEEthSharesBefore eETH shares held by this contract
    /// @return queueEthBefore ETH balance of this contract (used for claim verification)
    function _snapshotBalances() internal view returns (uint256 lpEthBefore, uint256 queueEEthSharesBefore, uint256 queueEthBefore) {
        lpEthBefore = address(liquidityPool).balance;
        queueEEthSharesBefore = eETH.shares(address(this));
        queueEthBefore = address(this).balance;
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
    /// @param expectedLpEthDelta 0 for pending cancel; request.amountOfEEth for finalized cancel (ETH returned to LP)
    function _verifyCancelPostConditions(
        uint256 lpEthBefore,
        uint256 queueEEthSharesBefore,
        uint256 userEEthSharesBefore,
        address user,
        uint256 expectedLpEthDelta
    ) internal view {
        if (address(liquidityPool).balance != lpEthBefore + expectedLpEthDelta) revert UnexpectedBalanceChange();
        if (eETH.shares(address(this)) >= queueEEthSharesBefore) revert UnexpectedBalanceChange();
        if (eETH.shares(user) <= userEEthSharesBefore) revert UnexpectedBalanceChange();
    }

    /// @dev Verify post-conditions after a claim operation
    /// @param lpEthBefore ETH balance of LiquidityPool before operation
    /// @param queueEEthSharesBefore eETH shares held by queue before operation
    /// @param queueEthBefore ETH balance of this contract before operation
    /// @param userEthBefore ETH balance of user before operation
    /// @param user The user who claimed
    function _verifyClaimPostConditions(
        uint256 lpEthBefore,
        uint256 queueEEthSharesBefore,
        uint256 queueEthBefore,
        uint256 userEthBefore,
        address user
    ) internal view {
        // LP ETH balance may increase by feeEth (returned from queue to LP via returnLockedEth).
        if (address(liquidityPool).balance < lpEthBefore) revert UnexpectedBalanceChange();
        if (eETH.shares(address(this)) >= queueEEthSharesBefore) revert UnexpectedBalanceChange();
        // Queue paid ETH to the user (and optionally fee back to LP) from its own escrow balance.
        if (address(this).balance >= queueEthBefore) revert UnexpectedBalanceChange();
        if (user.balance <= userEthBefore) revert UnexpectedBalanceChange();
    }

    function _queueWithdrawRequest(
        address user,
        uint96 amountOfEEth,
        uint96 amountWithFee
    ) internal returns (bytes32 requestId, WithdrawRequest memory req) {
        uint32 requestNonce = nonce++;

        if (amountWithFee == 0 || amountWithFee > amountOfEEth) revert InvalidAmount();

        uint96 shareOfEEth = uint96(liquidityPool.sharesForAmount(amountOfEEth));
        if (shareOfEEth == 0) revert InvalidAmount();

        uint32 timeNow = uint32(block.timestamp);

        req = WithdrawRequest({
            user: user,
            amountOfEEth: amountOfEEth,
            shareOfEEth: shareOfEEth,
            amountWithFee: amountWithFee,
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
            amountWithFee,
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

    /// @dev On a finalized cancel, returns the locked ETH to LP via LP.returnLockedEth. Pending cancels do not move ETH.
    function _cancelWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        
        bool wasFinalized = _finalizedRequests.contains(requestId);
        
        _dequeueWithdrawRequest(request);

        if (wasFinalized) {
            delete _fulfillmentRates[requestId];
            ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);
            liquidityPool.returnLockedEth{value: request.amountOfEEth}(request.amountOfEEth);
            _checkEthAmountLockedForPriorityWithdrawal();
        }

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        IERC20(address(eETH)).safeTransfer(request.user, amountForShares);
        
        emit WithdrawRequestCancelled(requestId, request.user, uint96(amountForShares), request.shareOfEEth, request.nonce, uint32(block.timestamp));
    }

    /// @dev Pays the user from this contract's own ETH balance (escrowed at fulfillRequests time). LP only does share burn + accounting on the segregated path.
    function _claimWithdraw(WithdrawRequest calldata request) internal {
        bytes32 requestId = keccak256(abi.encode(request));
        
        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();

        uint224 frozenRate = _getFrozenRate(requestId);
        // Solvency check against the resolved rate (frozen for new requests, live for legacy).
        uint256 amountForShares = Math.mulDiv(uint256(request.shareOfEEth), frozenRate, _SHARE_UNIT);
        if (amountForShares < request.amountWithFee) revert InvalidOutputAmount();

        uint128 amountToWithdraw = request.amountWithFee;

        _finalizedRequests.remove(requestId);
        delete _fulfillmentRates[requestId];

        ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);

        uint256 burnedShares = liquidityPool.withdraw(amountToWithdraw, uint256(frozenRate));
        // With `amountWithFee <= shareOfEEth * rate / 1e18` enforced at fulfill (frozen path)
        // or by the live solvency check above (legacy path, resolved to live rate locally),
        // the round-trip ceiling division satisfies `burnedShares <= request.shareOfEEth` by
        // construction. Pin that invariant explicitly — a violation would imply a precision
        // bug, not a routine rounding artifact.
        if (burnedShares > request.shareOfEEth) revert InvalidBurnedSharesAmount();
        totalRemainderShares += uint96(request.shareOfEEth - burnedShares);

        require(address(this).balance >= amountToWithdraw, "Insufficient escrow");
        (bool ok, ) = payable(request.user).call{value: amountToWithdraw}("");
        require(ok, "ETH transfer failed");

        // Return fee ETH (amountOfEEth - amountWithFee) to LP to keep queue balance clean
        // and unwind the over-credited totalValueOutOfLp from fulfillRequests time.
        uint128 feeEth = uint128(request.amountOfEEth) - amountToWithdraw;
        if (feeEth > 0) {
            liquidityPool.returnLockedEth{value: feeEth}(feeEth);
        }
        _checkEthAmountLockedForPriorityWithdrawal();

        emit WithdrawRequestClaimed(requestId, request.user, uint96(amountToWithdraw), uint96(burnedShares), request.nonce, uint32(block.timestamp));
    }

    function _getFrozenRate(bytes32 requestId) internal view returns (uint224 frozenRate) {
        frozenRate = _fulfillmentRates[requestId];
        if (frozenRate == 0) {
            // Pre-upgrade legacy request (fulfilled before the share-rate-freeze upgrade) —
            // resolve to the live rate locally so claim semantics match the pre-upgrade behavior.
            // LP itself rejects rate=0; the resolved rate is what we pass through.
            uint256 live = liquidityPool.amountPerShareCeil();
            if (live < minAcceptableShareRate || live > maxAcceptableShareRate) revert InvalidLiveRate();
            frozenRate = uint224(live);
        }
    }

    function _checkEthAmountLockedForPriorityWithdrawal() internal {
        if (ethAmountLockedForPriorityWithdrawal > address(this).balance) revert InsufficientLiquidity();
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
        uint96 _amountWithFee,
        uint32 _nonce,
        uint32 _creationTime
    ) public pure returns (bytes32 requestId) {
        WithdrawRequest memory req = WithdrawRequest({
            user: _user,
            amountOfEEth: _amountOfEEth,
            shareOfEEth: _shareOfEEth,
            amountWithFee: _amountWithFee,
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
            request.amountWithFee,
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
        if (!_finalizedRequests.contains(requestId)) return 0;

        uint224 frozenRate = _getFrozenRate(requestId);
        uint256 amountForShares = Math.mulDiv(uint256(request.shareOfEEth), frozenRate, _SHARE_UNIT);
        if (amountForShares < request.amountWithFee) return 0;

        return request.amountWithFee;
    }

    /// @notice Frozen `amountForShare(_SHARE_UNIT)` recorded when `requestId` was fulfilled, or 0 if the
    ///         request was fulfilled pre-upgrade (live-rate fallback) or has not been fulfilled yet.
    function fulfillmentRate(bytes32 requestId) external view returns (uint224) {
        return _fulfillmentRates[requestId];
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

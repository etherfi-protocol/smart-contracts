// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/IWeETH.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";

/// @title PriorityWithdrawalQueue
/// @notice Manages priority withdrawals for whitelisted users
/// @dev Implements priority withdrawal queue pattern
contract PriorityWithdrawalQueue is 
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUntil,
    RolesLibrary,
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
    uint256 public constant SHARE_UNIT = 1e18;
    uint256 private constant _TOLERANCE_BUFFER = 10; // in wei to account for rounding errors

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IWeETH public immutable weETH;
    address public immutable treasury;
    uint32 public immutable minDelay;

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
    error ContractPaused();
    error ContractNotPaused();
    error NotMatured();
    error UnexpectedBalanceChange();
    error Keccak256Collision();
    error PermitFailedAndAllowanceTooLow();
    error ArrayLengthMismatch();
    error AddressZero();
    error BadInput();
    error IncorrectCaller();
    error InvalidEEthSharesAfterRemainderHandling();
    error InvalidOutputAmount();
    error InsufficientLiquidity();
    error InsufficientEscrow();
    error EthTransferFailed();
    error MigrationNotComplete();

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

    modifier onlyRequestUser(address requestUser) {
        if (requestUser != msg.sender) revert NotRequestOwner();
        _;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _liquidityPool, address _eETH, address _weETH, address _roleRegistry, address _treasury, uint32 _minDelay) RolesLibrary(_roleRegistry) {
        if (_liquidityPool == address(0) || _eETH == address(0) || _weETH == address(0) || _treasury == address(0)) {
            revert AddressZero();
        }
        
        liquidityPool = ILiquidityPool(_liquidityPool);
        eETH = IeETH(_eETH);
        weETH = IWeETH(_weETH);
        treasury = _treasury;
        minDelay = _minDelay;

        _disableInitializers();
    }

    receive() external payable {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        if (liquidityPool.escrowMigrationCompleted()) {
            ethAmountLockedForPriorityWithdrawal += uint128(msg.value);
        }
        _checkEthAmountLockedForPriorityWithdrawal();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        nonce = 1;
        shareRemainderSplitToTreasuryInBps = uint16(_BASIS_POINT_SCALE); // 100%
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
    ) external nonReentrant whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
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
    ) external nonReentrant whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
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
    ) external nonReentrant whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
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
    ) external nonReentrant whenNotPaused onlyWhitelisted returns (bytes32 requestId) {
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
    ) external nonReentrant whenNotPaused onlyRequestUser(request.user) returns (bytes32 requestId) {
        if (request.creationTime + minDelay > block.timestamp) revert NotMatured();
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
        if (request.creationTime + minDelay > block.timestamp) revert NotMatured();

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
            if (requests[i].creationTime + minDelay > block.timestamp) revert NotMatured();
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
    ///      Gated on escrowMigrationCompleted: receive() only bumps ethAmountLockedForPriorityWithdrawal post-migration,
    ///      so finalizing before that would leave the lock counter at zero and brick the resulting requests.
    function fulfillRequests(WithdrawRequest[] calldata requests) external onlyOracleOperations whenNotPaused {
        if (!liquidityPool.escrowMigrationCompleted()) revert MigrationNotComplete();
        uint256 totalAmountToLock = 0;

        for (uint256 i = 0; i < requests.length; ++i) {
            WithdrawRequest calldata request = requests[i];
            bytes32 requestId = keccak256(abi.encode(request));

            if (_finalizedRequests.contains(requestId)) revert RequestAlreadyFinalized();
            if (!_withdrawRequests.contains(requestId)) revert RequestNotFound();

            uint256 earliestFulfillTime = request.creationTime + minDelay;
            if (block.timestamp < earliestFulfillTime) revert NotMatured();

            _withdrawRequests.remove(requestId);
            _finalizedRequests.add(requestId);
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

    function addToWhitelist(address user) external onlyAdmin {
        if (user == address(0)) revert AddressZero();
        isWhitelisted[user] = true;
        emit WhitelistUpdated(user, true);
    }

    function removeFromWhitelist(address user) external onlyOperatingMultisig {
        isWhitelisted[user] = false;
        emit WhitelistUpdated(user, false);
    }

    function batchUpdateWhitelist(address[] calldata users, bool[] calldata statuses) external onlyAdmin {
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
    function invalidateRequests(WithdrawRequest[] calldata requests) external onlyOracleOperations returns (bytes32[] memory invalidatedRequestIds) {
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
    function handleRemainder(uint256 eEthAmount) external onlyHousekeepingOperations {
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

    function pauseContract() external onlyOperatingMultisig {
        if (paused) revert ContractPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unPauseContract() external onlyOperatingMultisig {
        if (!paused) revert ContractNotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    function unpauseContractUntil() external onlyOperatingMultisig {
        _unpauseUntil();
    }

    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
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
        lpEthBefore = liquidityPool.totalValueInLp();
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
        if (liquidityPool.totalValueInLp() != lpEthBefore) revert UnexpectedBalanceChange();
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
        if (liquidityPool.totalValueInLp() != lpEthBefore + expectedLpEthDelta) revert UnexpectedBalanceChange();
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
        if (liquidityPool.totalValueInLp() < lpEthBefore) revert UnexpectedBalanceChange();
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

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        if (amountForShares + _TOLERANCE_BUFFER < request.amountWithFee) revert InvalidOutputAmount();

        uint128 amountToWithdraw = request.amountWithFee;

        _finalizedRequests.remove(requestId);

        ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);

        // Derive `rate` from the request's own (amountWithFee, shareOfEEth) instead of using
        // the live rate. This makes LP's Guard 1 (`_amount <= _shareOfEEth * _rate / SHARE_UNIT`)
        // admit `amountToWithdraw` by construction (ceiling rounding ensures
        // `shareOfEEth * derivedRate / SHARE_UNIT >= amountWithFee`), eliminating a sub-tolerance
        // rate-drop DoS where PWQ's 10-wei `_TOLERANCE_BUFFER` admits but Guard 1's tighter
        // ceil/floor combo reverts. Burn semantics are unchanged: Guard 2's max-clamp picks
        // `shareAtLive` if live dropped, and Guard 3 caps at `shareOfEEth` — the request's
        // own allocation, which is also the existing PWQ-side expectation.
        uint256 rate = Math.mulDiv(amountToWithdraw, SHARE_UNIT, request.shareOfEEth, Math.Rounding.Up);
        uint256 burnedShares = liquidityPool.withdraw(amountToWithdraw, rate, request.shareOfEEth);

        uint256 remainder = request.shareOfEEth > burnedShares 
            ? request.shareOfEEth - burnedShares 
            : 0;
        totalRemainderShares += uint96(remainder);

        if (address(this).balance < amountToWithdraw) revert InsufficientEscrow();
        (bool ok, ) = payable(request.user).call{value: amountToWithdraw}("");
        if (!ok) revert EthTransferFailed();

        // Return fee ETH (amountOfEEth - amountWithFee) to LP to keep queue balance clean
        // and unwind the over-credited totalValueOutOfLp from fulfillRequests time.
        uint128 feeEth = uint128(request.amountOfEEth) - amountToWithdraw;
        if (feeEth > 0) {
            liquidityPool.returnLockedEth{value: feeEth}(feeEth);
        }
        _checkEthAmountLockedForPriorityWithdrawal();

        emit WithdrawRequestClaimed(requestId, request.user, uint96(amountToWithdraw), uint96(burnedShares), request.nonce, uint32(block.timestamp));
    }

    function _checkEthAmountLockedForPriorityWithdrawal() internal {
        if (ethAmountLockedForPriorityWithdrawal > address(this).balance) revert InsufficientLiquidity();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

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
        if (liquidityPool.amountForShare(request.shareOfEEth) < request.amountWithFee) return 0;

        return request.amountWithFee;
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/IWeETH.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZReentrancyGuard.sol";

/**
 * @title PriorityWithdrawalQueue
 * @notice Manages priority withdrawals for whitelisted users
 * @dev Implements priority withdrawal queue pattern
 */
contract PriorityWithdrawalQueue is 
    Initializable,
    UUPSUpgradeable,
    DeprecatedOZReentrancyGuard,
    ReentrancyGuardTransient,
    PausableUntil,
    IPriorityWithdrawalQueue
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Math for uint256;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    /// @notice EnumerableSet to store all active withdraw request IDs
    EnumerableSet.Bytes32Set private _withdrawRequests;

    /// @notice Set of finalized request IDs (fulfilled and ready for claim)
    EnumerableSet.Bytes32Set private _finalizedRequests;

    mapping(address => bool) public isWhitelisted;

    uint32 public nonce;
    // deprecated storage slot
    uint120 private __gap_0;
    uint128 public ethAmountLockedForPriorityWithdrawal;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------
    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IWeETH public immutable weETH;
    IBlacklister public immutable blacklister;
    address public immutable treasury;
    uint32 public immutable minDelay;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ----------------------------------------
    //--------------------------------------------------------------------------------------
    uint96 public constant MIN_AMOUNT = 0.01 ether;
    uint96 public constant MAX_AMOUNT = 1000 ether;
    uint256 private constant _TOLERANCE_BUFFER = 10; // in wei to account for rounding errors

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
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

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error NotWhitelisted();
    error InvalidAmount();
    error RequestNotFound();
    error RequestNotFinalized();
    error RequestAlreadyFinalized();
    error NotRequestOwner();
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
    //---------------------------------  CONSTRUCTOR  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _liquidityPool The address of the liquidity pool.
     * @param _eETH The address of the eETH token.
     * @param _weETH The address of the weETH token.
     * @param _blacklister The address of the blacklister.
     * @param _roleRegistry The address of the role registry.
     * @param _treasury The address of the treasury.
     * @param _minDelay The minimum delay for a withdrawal request.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _liquidityPool, address _eETH, address _weETH, address _blacklister, address _roleRegistry, address _treasury, uint32 _minDelay) RolesLibrary(_roleRegistry) {
        if (_liquidityPool == address(0) || _eETH == address(0) || _weETH == address(0) || _blacklister == address(0) || _treasury == address(0)) {
            revert AddressZero();
        }

        liquidityPool = ILiquidityPool(_liquidityPool);
        eETH = IeETH(_eETH);
        weETH = IWeETH(_weETH);
        blacklister = IBlacklister(_blacklister);
        treasury = _treasury;
        minDelay = _minDelay;

        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INITIALIZERS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the contract
     */
    function initialize() external initializer {
        __UUPSUpgradeable_init();

        nonce = 1;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECEIVE FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Receive ETH
     * @dev Only callable by the liquidity pool after escrow migration is complete.
     */
    receive() external payable {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        if (liquidityPool.escrowMigrationCompleted()) {
            ethAmountLockedForPriorityWithdrawal += uint128(msg.value);
        }
        _checkEthAmountLockedForPriorityWithdrawal();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  WITHDRAW FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Request a withdrawal of eETH
     * @param amountOfEEth Amount of eETH to withdraw
     * @param amountWithFee ETH amount the user receives after fee deduction (amountOfEEth - fee)
     * @return requestId The hash-based ID of the created withdrawal request
     */
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

    /**
     * @notice Request a withdrawal of eETH with EIP-2612 permit
     * @param amountOfEEth Amount of eETH to withdraw
     * @param amountWithFee ETH amount the user receives after fee deduction (amountOfEEth - fee)
     * @param permit The permit params for eETH approval
     * @return requestId The hash-based ID of the created withdrawal request
     */
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

    /**
     * @notice Request a withdrawal using weETH (unwraps to eETH internally)
     * @param weEthAmount Amount of weETH to withdraw
     * @param amountWithFee ETH amount the user receives after fee deduction
     * @return requestId The hash-based ID of the created withdrawal request
     */
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

    /**
     * @notice Request a withdrawal using weETH with EIP-2612 permit
     * @param weEthAmount Amount of weETH to withdraw
     * @param amountWithFee ETH amount the user receives after fee deduction
     * @param permit The permit params for weETH approval
     * @return requestId The hash-based ID of the created withdrawal request
     */
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

    /**
     * @notice Cancel a pending withdrawal request
     * @param request The withdrawal request to cancel
     * @return requestId The cancelled request ID
     */
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

    /**
     * @notice Claim ETH for a finalized withdrawal request
     * @param request The withdrawal request to claim
     */
    function claimWithdraw(WithdrawRequest calldata request) external nonReentrant {
        if (request.creationTime + minDelay > block.timestamp) revert NotMatured();

        (uint256 lpEthBefore, uint256 queueEEthSharesBefore, uint256 queueEthBefore) = _snapshotBalances();
        uint256 userEthBefore = request.user.balance;

        _claimWithdraw(request);

        _verifyClaimPostConditions(lpEthBefore, queueEEthSharesBefore, queueEthBefore, userEthBefore, request.user);
    }

    /**
     * @notice Batch claim multiple withdrawal requests
     * @param requests Array of withdrawal requests to claim
     */
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
    //----------------------------  OPERATIONAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Finalizes withdrawal requests after maturity.
     * @dev Locks ETH per request by calling LP.transferLockedEthForPriority — escrowed in this contract until claim or cancel.
     *      Gated on escrowMigrationCompleted: receive() only bumps ethAmountLockedForPriorityWithdrawal post-migration,
     *      so finalizing before that would leave the lock counter at zero and brick the resulting requests.
     * @param requests Array of withdrawal requests to finalize
     */
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

    /**
     * @notice Invalidate and cancel withdrawal requests in any state
     * @param requests Array of requests to invalidate
     * @return invalidatedRequestIds Array of request IDs that were invalidated
     * @dev Can target both pending and finalized requests.
     *      For finalized requests, this also prevents subsequent claims.
     */
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

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ADMIN FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Add a user to the whitelist
     * @param user The address of the user to add to the whitelist
     */
    function addToWhitelist(address user) external onlyAdmin {
        if (user == address(0)) revert AddressZero();
        isWhitelisted[user] = true;
        emit WhitelistUpdated(user, true);
    }

    /**
     * @notice Remove a user from the whitelist
     * @param user The address of the user to remove from the whitelist
     */
    function removeFromWhitelist(address user) external onlyOperatingMultisig {
        isWhitelisted[user] = false;
        emit WhitelistUpdated(user, false);
    }

    /**
     * @notice Batch update the whitelist
     * @param users Array of addresses to update the whitelist for
     * @param statuses Array of boolean values indicating the new whitelist status
     */
    function batchUpdateWhitelist(address[] calldata users, bool[] calldata statuses) external onlyAdmin {
        if (users.length != statuses.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert AddressZero();
            isWhitelisted[users[i]] = statuses[i];
            emit WhitelistUpdated(users[i], statuses[i]);
        }
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Snapshot balances before state changes for post-hook verification
     * @return lpEthBefore ETH balance of LiquidityPool
     * @return queueEEthSharesBefore eETH shares held by this contract
     * @return queueEthBefore ETH balance of this contract (used for claim verification)
     */
    function _snapshotBalances() internal view returns (uint256 lpEthBefore, uint256 queueEEthSharesBefore, uint256 queueEthBefore) {
        lpEthBefore = liquidityPool.totalValueInLp();
        queueEEthSharesBefore = eETH.shares(address(this));
        queueEthBefore = address(this).balance;
    }

    /**
     * @notice Verify post-conditions after a request is created
     * @param lpEthBefore ETH balance of LiquidityPool before operation
     * @param queueEEthSharesBefore eETH shares held by queue before operation
     * @param amountOfEEth Amount of eETH that was transferred
     */
    function _verifyRequestPostConditions(
        uint256 lpEthBefore, 
        uint256 queueEEthSharesBefore,
        uint96 amountOfEEth
    ) internal view {
        uint256 expectedSharesReceived = liquidityPool.sharesForAmount(amountOfEEth);
        if (eETH.shares(address(this)) != queueEEthSharesBefore + expectedSharesReceived) revert UnexpectedBalanceChange();
        if (liquidityPool.totalValueInLp() != lpEthBefore) revert UnexpectedBalanceChange();
    }

    /**
     * @notice Verify post-conditions after a cancel operation
     * @param lpEthBefore ETH balance of LiquidityPool before operation
     * @param queueEEthSharesBefore eETH shares held by queue before operation
     * @param userEEthSharesBefore eETH shares held by user before operation
     * @param user The user who cancelled
     * @param expectedLpEthDelta 0 for pending cancel; request.amountOfEEth for finalized cancel (ETH returned to LP)
     */
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

    /**
     * @notice Verify post-conditions after a claim operation
     * @param lpEthBefore ETH balance of LiquidityPool before operation
     * @param queueEEthSharesBefore eETH shares held by queue before operation
     * @param queueEthBefore ETH balance of this contract before operation
     * @param userEthBefore ETH balance of user before operation
     * @param user The user who claimed
     */
    function _verifyClaimPostConditions(
        uint256 lpEthBefore,
        uint256 queueEEthSharesBefore,
        uint256 queueEthBefore,
        uint256 userEthBefore,
        address user
    ) internal view {
        // LP ETH balance may increase by the stranded ETH swept from the queue back to LP (via LP.receive()).
        if (liquidityPool.totalValueInLp() < lpEthBefore) revert UnexpectedBalanceChange();
        if (eETH.shares(address(this)) >= queueEEthSharesBefore) revert UnexpectedBalanceChange();
        // Queue paid ETH to the user (and optionally fee back to LP) from its own escrow balance.
        if (address(this).balance >= queueEthBefore) revert UnexpectedBalanceChange();
        if (user.balance <= userEthBefore) revert UnexpectedBalanceChange();
    }

    /**
     * @notice Queue a withdrawal request
     * @param user The user who is requesting the withdrawal
     * @param amountOfEEth Amount of eETH that was requested
     * @param amountWithFee ETH amount the user receives after fee deduction (amountOfEEth - fee)
     * @return requestId The hash-based ID of the created withdrawal request
     * @return req The withdrawal request
     */
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

    /**
     * @notice Dequeue a withdrawal request
     * @param request The withdrawal request to dequeue
     * @return requestId The hash-based ID of the dequeued withdrawal request
     */
    function _dequeueWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        
        bool removedFromFinalized = _finalizedRequests.remove(requestId);
        if (removedFromFinalized) return requestId;
        
        bool removedFromPending = _withdrawRequests.remove(requestId);
        if (!removedFromPending) revert RequestNotFound();
    }

     /**
      * @notice On a finalized cancel, returns the locked ETH to LP via a plain ETH transfer (LP's receive() re-credits it). Pending cancels do not move ETH.
      * @param request The withdrawal request to cancel
      * @return requestId The hash-based ID of the cancelled withdrawal request
      */
    function _cancelWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        
        bool wasFinalized = _finalizedRequests.contains(requestId);
        
        _dequeueWithdrawRequest(request);

        if (wasFinalized) {
            ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);
            (bool ok, ) = payable(address(liquidityPool)).call{value: request.amountOfEEth}("");
            if (!ok) revert EthTransferFailed();
            _checkEthAmountLockedForPriorityWithdrawal();
        }

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        IERC20(address(eETH)).safeTransfer(request.user, amountForShares);
        
        emit WithdrawRequestCancelled(requestId, request.user, uint96(amountForShares), request.shareOfEEth, request.nonce, uint32(block.timestamp));
    }

    /**
     * @notice Pays the user from this contract's own ETH balance (escrowed at fulfillRequests time). LP only does share burn + accounting on the segregated path.
     * @param request The withdrawal request to claim
     * @dev Anyone may call claim on behalf of `request.user`, but the recipient itself must
     *      not be blacklisted at claim time — sanctioned addresses cannot receive proceeds
     *      via a non-blacklisted accomplice.
     */
    function _claimWithdraw(WithdrawRequest calldata request) internal {
        blacklister.nonBlacklisted(request.user);

        bytes32 requestId = keccak256(abi.encode(request));

        if (!_finalizedRequests.contains(requestId)) revert RequestNotFinalized();

        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        if (amountForShares + _TOLERANCE_BUFFER < request.amountWithFee) revert InvalidOutputAmount();

        uint128 amountToWithdraw = request.amountWithFee;

        _finalizedRequests.remove(requestId);

        ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);

        // `withdraw` pays out `amountToWithdraw` and unwinds the matching `totalValueOutOfLp` credit,
        // while burning the request's full `shareOfEEth`. Any escrowed ETH beyond `amountToWithdraw`
        // (e.g. the fee portion of the fulfill-time credit) is swept back to LP below as stranded ETH.
        liquidityPool.withdraw(amountToWithdraw, request.shareOfEEth);

        if (address(this).balance < amountToWithdraw) revert InsufficientEscrow();
        (bool ok, ) = payable(request.user).call{value: amountToWithdraw}("");
        if (!ok) revert EthTransferFailed();

        // Return any stranded ETH (balance above what is still locked) to LP. Guarded so an
        // under-funded queue (balance < locked) reverts cleanly via the invariant check below
        // rather than underflowing here.
        if (address(this).balance > ethAmountLockedForPriorityWithdrawal) {
            uint256 strandedEth = address(this).balance - ethAmountLockedForPriorityWithdrawal;
            (bool okStranded, ) = payable(address(liquidityPool)).call{value: strandedEth}("");
            if (!okStranded) revert EthTransferFailed();
        }
        _checkEthAmountLockedForPriorityWithdrawal();

        emit WithdrawRequestClaimed(requestId, request.user, uint96(amountToWithdraw), request.shareOfEEth, request.nonce, uint32(block.timestamp));
    }

    /**
     * @notice Checks if the ETH amount locked for priority withdrawal is sufficient
     * @dev Reverts if the ETH amount locked for priority withdrawal is greater than the ETH balance of the contract
     */
    function _checkEthAmountLockedForPriorityWithdrawal() internal view {
        if (ethAmountLockedForPriorityWithdrawal > address(this).balance) revert InsufficientLiquidity();
    }

    /**
     * @notice Authorizes the upgrade of the contract
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Generates a withdrawal request ID
     * @param _user The user who is requesting the withdrawal
     * @param _amountOfEEth Amount of eETH that was requested
     * @param _shareOfEEth eETH shares at time of request
     * @param _amountWithFee ETH amount the user receives after fee deduction (amountOfEEth - fee)
     * @param _nonce Unique nonce to prevent hash collisions
     * @param _creationTime Timestamp when request was created
     */
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

    /**
     * @notice Generates a withdrawal request ID
     * @param request The withdrawal request to generate the ID for
     * @return requestId The hash-based ID of the withdrawal request
     */
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

    /**
     * @notice Gets all withdrawal request IDs
     * @return requestIds Array of withdrawal request IDs
     */
    function getRequestIds() external view returns (bytes32[] memory) {
        return _withdrawRequests.values();
    }

    /**
     * @notice Gets all finalized withdrawal request IDs
     * @return requestIds Array of finalized withdrawal request IDs
     */
    function getFinalizedRequestIds() external view returns (bytes32[] memory) {
        return _finalizedRequests.values();
    }

    /**
     * @notice Checks if a withdrawal request exists
     * @param requestId The hash-based ID of the withdrawal request
     * @return exists True if the request exists, false otherwise
     */
    function requestExists(bytes32 requestId) external view returns (bool) {
        return _withdrawRequests.contains(requestId) || _finalizedRequests.contains(requestId);
    }

    /**
     * @notice Checks if a withdrawal request is finalized
     * @param requestId The hash-based ID of the withdrawal request
     * @return isFinalized True if the request is finalized, false otherwise
     */
    function isFinalized(bytes32 requestId) external view returns (bool) {
        return _finalizedRequests.contains(requestId);
    }

    /**
     * @notice Gets the claimable amount for a withdrawal request
     * @param request The withdrawal request to get the claimable amount for
     * @return claimableAmount The claimable amount for the withdrawal request
     */
    function getClaimableAmount(WithdrawRequest calldata request) external view returns (uint256) {
        bytes32 requestId = keccak256(abi.encode(request));
        if (!_finalizedRequests.contains(requestId)) return 0;
        if (liquidityPool.amountForShare(request.shareOfEEth) < request.amountWithFee) return 0;

        return request.amountWithFee;
    }

    /**
     * @notice Gets the total number of active withdrawal requests
     * @return totalActiveRequests The total number of active withdrawal requests
     */
    function totalActiveRequests() external view returns (uint256) {
        return _withdrawRequests.length();
    }

    /**
     * @notice Gets the implementation address
     * @return implementation The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @dev Reason why modifier has both whitelisted and blacklisted checks is becuase if whitelisted user gets compramised,
     * they can access the protocol before operating multisig can remove whitelist. so guardian can blacklist user.
     */
    modifier onlyWhitelisted() {
        if (!isWhitelisted[msg.sender]) revert NotWhitelisted();
        blacklister.nonBlacklisted(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the request user is the same as the message sender.
     * @param requestUser The address of the request user.
     */
    modifier onlyRequestUser(address requestUser) {
        if (requestUser != msg.sender) revert NotRequestOwner();
        _;
    }
}

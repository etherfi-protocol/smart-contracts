// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@etherfi/oracle/interfaces/IEtherFiAdmin.sol";
import "@etherfi/oracle/interfaces/IEtherFiOracle.sol";
import "@etherfi/staking/interfaces/IStakingManager.sol";
import "@etherfi/staking/interfaces/IAuctionManager.sol";
import "@etherfi/staking/interfaces/IEtherFiNode.sol";
import "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";

import "@etherfi/governance/utils/RolesLibrary.sol";

interface IEtherFiPausable {
    function paused() external view returns (bool);
}

contract EtherFiAdmin is Initializable, OwnableUpgradeable, UUPSUpgradeable, RolesLibrary, IEtherFiAdmin {
    using Math for uint256;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    // deprecated storage slots
    uint256[8] private __gap_0;

    uint32 public lastHandledReportRefSlot;
    uint32 public lastHandledReportRefBlock;

    // deprecated storage slots
    uint32 public __gap_1;

    int32 public acceptableRebaseAprInBps;

    uint16 public postReportWaitTimeInSlots;
    uint32 public lastAdminExecutionBlock;

    // deprecated storage slots
    uint256 private __gap_2;

    mapping(bytes32 => TaskStatus) public validatorApprovalTaskStatus;
    uint16 validatorTaskBatchSize;

    // deprecated storage slots
    uint160 private __gap_3;

    uint256 public lastStaleReportFinalizationBlock;
    uint256 public maxFinalizedWithdrawalAmountPerDay;
    uint256 public maxNumValidatorsToApprovePerDay;

    // Override for the per-report negative (slashing) rebase cap, in bps of TVL.
    // 0 = use DEFAULT_MAX_NEGATIVE_REBASE_BPS. Settable behind the operating timelock.
    uint256 public maxNegativeRebaseBps;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    IEtherFiOracle public immutable etherFiOracle;
    IStakingManager public immutable stakingManager;
    IAuctionManager public immutable auctionManager;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    ILiquidityPool public immutable liquidityPool;
    IWithdrawRequestNFT public immutable withdrawRequestNft;
    IPriorityWithdrawalQueue public immutable priorityWithdrawalQueue;

    int256 public immutable maxAcceptableRebaseAprInBps;
    uint256 public immutable maxValidatorTaskBatchSize;
    uint256 public immutable maxNumberOfRequestsToFinalizePerReport;
    uint256 public immutable maxAcceptableFinalizedWithdrawalAmountPerDay;
    uint256 public immutable maxAcceptableNumValidatorsToApprovePerDay;
    uint256 public immutable staleOracleReportBlockWindow;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    // Protocol fees must not exceed 1/MAX_PROTOCOL_FEE_INV_RATIO of total rewards (currently 20%).
    uint256 public constant MAX_PROTOCOL_FEE_INV_RATIO = 5;
    uint256 public constant STALE_REPORT_FINALIZATION_COOLDOWN = 7200; // 1 day
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10_000;

    // Default cap on how far a single report may DECREASE TVL (slashing), in bps of TVL,
    // independent of elapsedTime. `acceptableRebaseAprInBps` is annualized over elapsedTime,
    // so a long-spanning report could pass it while still dropping an outsized absolute
    // amount in one rebase. The max *initial* slashing penalty is maxEffBalance/4096 ≈
    // 2.44 bps of TVL even if every validator is slashed at once, so 3 bps is the tight
    // default. `maxNegativeRebaseBps` (settable behind the operating timelock) overrides
    // it — raised only if a correlated/mid-term slashing event is detected (visible well
    // before a 2-day timelock matters). The positive/reward upper bound lives in
    // LiquidityPool.rebase (the share-rate-increasing chokepoint).
    uint256 public constant DEFAULT_MAX_NEGATIVE_REBASE_BPS = 3;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event AdminUpdated(address _address, bool _isAdmin);
    event MaxNegativeRebaseBpsUpdated(uint256 bps);
    event AdminOperationsExecuted(address indexed _address, bytes32 indexed _reportHash);
    event ValidatorApprovalTaskCreated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);
    event ValidatorApprovalTaskCompleted(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);
    event ValidatorApprovalTaskInvalidated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error InvalidMaxAcceptableFinalizedWithdrawalAmount();
    error InvalidMaxNumberOfRequestsToFinalizePerReport();
    error InvalidMaxFinalizedWithdrawalAmountPerDay();
    error InvalidMaxNumValidatorsToApprovePerDay();
    error InvalidAcceptableRebaseApr();
    error InvalidMaxNegativeRebaseBps();
    error InvalidValidatorTaskBatchSize();
    error InvalidMaxAcceptableRebaseApr();
    error InvalidStaleOracleReportBlockWindow();
    error OracleReportNotStale();
    error StaleReportFinalizationCooldown();
    error NoWithdrawalsToFinalize();
    error ReportValidationFailed(string reason);
    error ConsensusNotReached();
    error TaskDoesNotExist();
    error TaskAlreadyCompleted();
    error TaskAlreadyExists();
    error InvalidValidatorSize();
    error InvalidArrayLengths();

    //--------------------------------------------------------------------------------------
    //-------------------------------------  CONSTRUCTOR  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _constructorAddresses The addresses of the constructor addresses
     * @param _maxAcceptableRebaseAprInBps The maximum acceptable rebase APR in basis points
     * @param _maxValidatorTaskBatchSize The maximum validator task batch size
     * @param _staleOracleReportBlockWindow The stale oracle report block window
     * @param _maxAcceptableFinalizedWithdrawalAmountPerDay The maximum acceptable finalized withdrawal amount per day
     * @param _maxAcceptableNumValidatorsToApprovePerDay The maximum acceptable number of validators to approve per day
     * @param _maxNumberOfRequestsToFinalizePerReport The maximum number of requests to finalize per report
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        ConstructorAddresses memory _constructorAddresses,
        int256 _maxAcceptableRebaseAprInBps,
        uint256 _maxValidatorTaskBatchSize,
        uint256 _staleOracleReportBlockWindow,
        uint256 _maxAcceptableFinalizedWithdrawalAmountPerDay,
        uint256 _maxAcceptableNumValidatorsToApprovePerDay,
        uint256 _maxNumberOfRequestsToFinalizePerReport
    ) RolesLibrary(_constructorAddresses.roleRegistry) {
        if (_maxAcceptableRebaseAprInBps <= 0 || _maxAcceptableRebaseAprInBps > int256(BASIS_POINTS_DENOMINATOR)) revert InvalidMaxAcceptableRebaseApr();
        if (_maxValidatorTaskBatchSize == 0) revert InvalidValidatorTaskBatchSize();
        if (_staleOracleReportBlockWindow == 0) revert InvalidStaleOracleReportBlockWindow();
        if (_maxAcceptableFinalizedWithdrawalAmountPerDay == 0) revert InvalidMaxAcceptableFinalizedWithdrawalAmount();
        if (_maxNumberOfRequestsToFinalizePerReport == 0) revert InvalidMaxNumberOfRequestsToFinalizePerReport();

        etherFiOracle = IEtherFiOracle(_constructorAddresses.etherFiOracle);
        stakingManager = IStakingManager(_constructorAddresses.stakingManager);
        auctionManager = IAuctionManager(_constructorAddresses.auctionManager);
        etherFiNodesManager = IEtherFiNodesManager(_constructorAddresses.etherFiNodesManager);
        liquidityPool = ILiquidityPool(_constructorAddresses.liquidityPool);
        withdrawRequestNft = IWithdrawRequestNFT(_constructorAddresses.withdrawRequestNft);
        priorityWithdrawalQueue = IPriorityWithdrawalQueue(_constructorAddresses.priorityWithdrawalQueue);

        maxAcceptableRebaseAprInBps = _maxAcceptableRebaseAprInBps;
        maxValidatorTaskBatchSize = _maxValidatorTaskBatchSize;
        staleOracleReportBlockWindow = _staleOracleReportBlockWindow;
        maxAcceptableFinalizedWithdrawalAmountPerDay = _maxAcceptableFinalizedWithdrawalAmountPerDay;
        maxAcceptableNumValidatorsToApprovePerDay = _maxAcceptableNumValidatorsToApprovePerDay;
        maxNumberOfRequestsToFinalizePerReport = _maxNumberOfRequestsToFinalizePerReport;

        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the EtherFiAdmin
     * @param _etherFiOracle The address of the etherFiOracle contract
     * @param _stakingManager The address of the stakingManager contract
     * @param _auctionManager The address of the auctionManager contract
     * @param _etherFiNodesManager The address of the etherFiNodesManager contract
     * @param _liquidityPool The address of the liquidityPool contract
     * @param _membershipManager The address of the membershipManager contract
     * @param _withdrawRequestNft The address of the withdrawRequestNFT contract
     * @param _acceptableRebaseAprInBps The acceptable rebase APR in basis points
     * @param _postReportWaitTimeInSlots The post report wait time in slots
     */
    function initialize(
        address _etherFiOracle,
        address _stakingManager,
        address _auctionManager,
        address _etherFiNodesManager,
        address _liquidityPool,
        address _membershipManager,
        address _withdrawRequestNft,
        int32 _acceptableRebaseAprInBps,
        uint16 _postReportWaitTimeInSlots
    ) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  ADMIN FUNCTIONS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Set the validator task batch size
     * @param _batchSize The batch size
     */
    function setValidatorTaskBatchSize(uint16 _batchSize) external onlyAdmin {
        if (_batchSize == 0 || _batchSize > maxValidatorTaskBatchSize) revert InvalidValidatorTaskBatchSize();
        validatorTaskBatchSize = _batchSize;
    }

    /**
     * @notice Update the maximum finalized withdrawal amount per day
     * @param _maxFinalizedWithdrawalAmountPerDay The maximum finalized withdrawal amount per day
     */
    function updateMaxFinalizedWithdrawalAmountPerDay(uint256 _maxFinalizedWithdrawalAmountPerDay) external onlyAdmin {
        if (_maxFinalizedWithdrawalAmountPerDay == 0 || _maxFinalizedWithdrawalAmountPerDay > maxAcceptableFinalizedWithdrawalAmountPerDay) revert InvalidMaxFinalizedWithdrawalAmountPerDay();
        maxFinalizedWithdrawalAmountPerDay = _maxFinalizedWithdrawalAmountPerDay;
    }

    /**
     * @notice Update the maximum number of validators to approve per day
     * @param _maxNumValidatorsToApprovePerDay The maximum number of validators to approve per day
     */
    function updateMaxNumValidatorsToApprovePerDay(uint256 _maxNumValidatorsToApprovePerDay) external onlyAdmin {
        if (_maxNumValidatorsToApprovePerDay > maxAcceptableNumValidatorsToApprovePerDay) revert InvalidMaxNumValidatorsToApprovePerDay();
        maxNumValidatorsToApprovePerDay = _maxNumValidatorsToApprovePerDay;
    }

    /**
     * @notice Update the acceptable rebase APR in basis points
     * @param _acceptableRebaseAprInBps The acceptable rebase APR in basis points
     */
    function updateAcceptableRebaseApr(int32 _acceptableRebaseAprInBps) external onlyAdmin {
        if (_acceptableRebaseAprInBps < 0 || _acceptableRebaseAprInBps > maxAcceptableRebaseAprInBps) revert InvalidAcceptableRebaseApr();
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
    }

    /**
     * @notice Update the post report wait time in slots
     * @param _postReportWaitTimeInSlots The post report wait time in slots
     */
    function updatePostReportWaitTimeInSlots(uint16 _postReportWaitTimeInSlots) external onlyAdmin {
        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    /** 
     * @notice Override the per-report negative (slashing) rebase cap, in bps of TVL.
     * @param _bps The maximum negative rebase bps
     * @dev Operation-Timelock-gated. 0 resets to DEFAULT_MAX_NEGATIVE_REBASE_BPS. Capped
     *      at 100% so it can be raised during a real correlated-slashing event but never
     *      set to a nonsensical value.
     */
    function setMaxNegativeRebaseBps(uint256 _bps) external onlyAdmin {
        if (_bps > BASIS_POINTS_DENOMINATOR) revert InvalidMaxNegativeRebaseBps();
        maxNegativeRebaseBps = _bps;
        emit MaxNegativeRebaseBpsUpdated(_bps);
    }

    /**
     * @notice Invalidate a validator approval task
     * @param _reportHash The hash of the report
     * @param _validators The validators to invalidate
     */
    function invalidateValidatorApprovalTask(bytes32 _reportHash, uint256[] calldata _validators) external onlyOperatingMultisig {
        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators));
        if (!validatorApprovalTaskStatus[taskHash].exists) revert TaskDoesNotExist();
        if (validatorApprovalTaskStatus[taskHash].completed) revert TaskAlreadyCompleted();
        validatorApprovalTaskStatus[taskHash].exists = false;
        emit ValidatorApprovalTaskInvalidated(taskHash, _reportHash, _validators);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  ORACLE OPERATIONS FUNCTIONS  ----------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Execute the tasks for a report
     * @param _report The report
     */
    function executeTasks(IEtherFiOracle.OracleReport calldata _report) external {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        (bool _isValid, string memory _error) = _validateReport(_report, reportHash);
        if (!_isValid) revert ReportValidationFailed(_error);

        _handleRebase(_report);
        _enqueueValidatorApprovalTask(reportHash, _report);
        _finalizeWithdrawals(_report.lastFinalizedWithdrawalRequestId, _report.finalizedWithdrawalAmount);

        lastHandledReportRefSlot = _report.refSlotTo;
        lastHandledReportRefBlock = _report.refBlockTo;
        lastAdminExecutionBlock = uint32(block.number);

        emit AdminOperationsExecuted(msg.sender, reportHash);
    }

    /**
     * @notice Execute a validator approval task
     * @param _reportHash The hash of the report
     * @param _validators The validators to approve
     * @param _pubKeys The public keys of the validators
     * @param _signatures The signatures of the validators
     */
    function executeValidatorApprovalTask(bytes32 _reportHash, uint256[] calldata _validators, bytes[] calldata _pubKeys, bytes[] calldata _signatures) external onlyOracleOperations {
        if (!etherFiOracle.isConsensusReached(_reportHash)) revert ConsensusNotReached();
        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators));
        if (!validatorApprovalTaskStatus[taskHash].exists) revert TaskDoesNotExist();
        if (validatorApprovalTaskStatus[taskHash].completed) revert TaskAlreadyCompleted();

        validatorApprovalTaskStatus[taskHash].completed = true;
        _approveValidators(_validators, _pubKeys, _signatures);
        emit ValidatorApprovalTaskCompleted(taskHash, _reportHash, _validators);
    }

    /**
     * @notice Finalizes the withdrawals when the oracle is stale
     * @dev Stale-oracle escape hatch. If oracle reports stop landing for staleOracleReportBlockWindow
     *      blocks past the last handled report, anyone can call this to finalize as many pending
     *      withdraw requests as the LP's current ETH balance can cover, in request-id order.
     *      Permissionless on purpose: a frozen oracle should not be able to freeze user redemptions.
     *      Reverts with OracleReportNotStale if the window has not elapsed, or NoWithdrawalsToFinalize
     *      if no valid pending requests can be covered.
     */
    function finalizeWithdrawalsWhenStale() external {
        if (block.number < etherFiOracle.lastPublishedReportRefBlock() + staleOracleReportBlockWindow) revert OracleReportNotStale();
        if (block.number < lastStaleReportFinalizationBlock + STALE_REPORT_FINALIZATION_COOLDOWN) revert StaleReportFinalizationCooldown();

        uint256 liquidity = liquidityPool.totalValueInLp();
        uint32 currentRequestId = withdrawRequestNft.nextRequestId() - 1;
        uint32 lastFinalizedRequestId = withdrawRequestNft.lastFinalizedRequestId();
        uint32 requestId = lastFinalizedRequestId;
        uint128 finalizedWithdrawalAmount;
        while (requestId < currentRequestId) {
            if ((requestId + 1) - lastFinalizedRequestId > maxNumberOfRequestsToFinalizePerReport) {
                break;
            }
            IWithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNft.getRequest(requestId + 1);
            if (!request.isValid) {
                requestId++;
                continue;
            }
            if (liquidity < finalizedWithdrawalAmount + request.amountOfEEth) {
                break;
            }
            finalizedWithdrawalAmount += request.amountOfEEth;
            requestId++;
        }
        if (finalizedWithdrawalAmount == 0) revert NoWithdrawalsToFinalize();
        _finalizeWithdrawals(requestId, finalizedWithdrawalAmount);
        lastStaleReportFinalizationBlock = block.number;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INTERNAL FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Approves the validators
     * @param _validatorIds The validator ids
     * @param _pubKeys The public keys of the validators
     * @param _signatures The signatures of the validators
     * @dev Builds DepositData[] from (validatorIds, pubKeys, signatures) and forwards to
     *      LiquidityPool.confirmAndFundBeaconValidators. Previously this construction lived
     *      in LiquidityPool.batchApproveRegistration; moved here so LP stays under the
     *      EIP-170 24,576-byte cap.
     */
    function _approveValidators(uint256[] calldata _validatorIds, bytes[] calldata _pubKeys, bytes[] calldata _signatures) internal {
        uint256 validatorSizeWei = liquidityPool.validatorSizeWei();
        if (validatorSizeWei < stakingManager.MIN_VALIDATOR_SIZE_WEI() || validatorSizeWei > stakingManager.MAX_VALIDATOR_SIZE_WEI()) revert InvalidValidatorSize();
        if (_validatorIds.length == 0 || _validatorIds.length != _pubKeys.length || _validatorIds.length != _signatures.length) revert InvalidArrayLengths();

        uint256 remainingEthPerValidator = validatorSizeWei - stakingManager.INITIAL_DEPOSIT_AMOUNT();
        IStakingManager.DepositData[] memory depositData = new IStakingManager.DepositData[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address eigenPod = address(IEtherFiNode(etherFiNodesManager.etherfiNodeAddress(_validatorIds[i])).getEigenPod());
            bytes memory withdrawalCredentials = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod);
            bytes32 depositDataRoot = stakingManager.generateDepositDataRoot(_pubKeys[i], _signatures[i], withdrawalCredentials, remainingEthPerValidator);

            depositData[i] = IStakingManager.DepositData({
                publicKey: _pubKeys[i],
                signature: _signatures[i],
                depositDataRoot: depositDataRoot,
                ipfsHashForEncryptedValidatorKey: ""
            });
        }

        liquidityPool.confirmAndFundBeaconValidators(depositData, validatorSizeWei);
    }

    /**
     * @notice Rebases the protocol and pays the protocol fees in a single call
     * @param _report The report
     * @dev LiquidityPool.rebase no-ops each leg when its amount is zero, so an
     *      empty report (no rewards, no fees) is a no-op.
     */
    function _handleRebase(IEtherFiOracle.OracleReport calldata _report) internal {
        if (_report.accruedRewards == 0 && _report.protocolFees == 0) {
            return;
        }

        liquidityPool.rebase(_report.accruedRewards, _report.protocolFees);
    }

    /**
     * @notice Enqueues a validator approval task
     * @param _reportHash The hash of the report
     * @param _report The report
     */
    function _enqueueValidatorApprovalTask(bytes32 _reportHash, IEtherFiOracle.OracleReport calldata _report) internal {
        if(_report.validatorsToApprove.length == 0) {
            return;
        }

        uint256 numBatches = (_report.validatorsToApprove.length).ceilDiv(validatorTaskBatchSize);

        for (uint256 i = 0; i < numBatches; i++) {
            uint256 start = i * validatorTaskBatchSize;
            uint256 end = (i + 1) * validatorTaskBatchSize > _report.validatorsToApprove.length ? _report.validatorsToApprove.length : (i + 1) * validatorTaskBatchSize;
            uint256[] memory batchValidators = new uint256[](end - start);

            for (uint256 j = start; j < end; j++) {
                batchValidators[j - start] = _report.validatorsToApprove[j];
            }
            bytes32 taskHash = keccak256(abi.encode(_reportHash, batchValidators));
            if (validatorApprovalTaskStatus[taskHash].exists) revert TaskAlreadyExists();
            validatorApprovalTaskStatus[taskHash] = TaskStatus({completed: false, exists: true});
            emit ValidatorApprovalTaskCreated(taskHash, _reportHash, batchValidators);
        }
    }
    
    /**
     * @notice Finalizes the withdraw requests
     * @param _lastFinalizedRequestId The last finalized request id
     * @param _finalizedWithdrawalAmount The finalized withdrawal amount
     */
    function _finalizeWithdrawals(uint32 _lastFinalizedRequestId, uint128 _finalizedWithdrawalAmount) internal {
        withdrawRequestNft.finalizeRequests(_lastFinalizedRequestId);
        liquidityPool.addEthAmountLockedForWithdrawal(_finalizedWithdrawalAmount);
    }

    /**
     * @notice Validates the report
     * @param _report The report
     * @param _reportHash The hash of the report
     * @return _isValid True if the report is valid, false otherwise
     * @return _error The error message
     */
    function _validateReport(IEtherFiOracle.OracleReport calldata _report, bytes32 _reportHash) internal view returns (bool, string memory) {
        bool ok;
        string memory err;

        // Stage 1: report freshness / consensus
        (ok, err) = _validateReportFreshness(_report, _reportHash);
        if (!ok) return (false, err);

        // Stage 2: derive timing
        uint256 elapsedSlots = _report.refSlotTo - lastHandledReportRefSlot;
        uint256 elapsedTime = elapsedSlots * 12 seconds;
        if (elapsedTime == 0) return (false, "EtherFiAdmin: report spans zero slots");

        // Stage 3: rebase APR cap
        (ok, err) = _validateRebaseApr(_report, elapsedTime);
        if (!ok) return (false, err);

        // Stage 4: protocol fees
        (ok, err) = _validateProtocolFees(_report);
        if (!ok) return (false, err);

        // Stage 5: validator approvals per day
        (ok, err) = _validateValidatorApprovals(_report, elapsedTime);
        if (!ok) return (false, err);

        // Stage 6: withdrawals
        (ok, err) = _validateWithdrawals(_report, elapsedTime);
        if (!ok) return (false, err);

        return (true, "");
    }

    /**
     * @notice Validates the report freshness
     * @param _report The report
     * @param _reportHash The hash of the report
     * @return _isValid True if the report freshness is valid, false otherwise
     * @return _error The error message
     */
    function _validateReportFreshness(IEtherFiOracle.OracleReport calldata _report, bytes32 _reportHash) internal view returns (bool, string memory) {
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);
        if (!etherFiOracle.isConsensusReached(_reportHash)) return (false, "EtherFiAdmin: report didn't reach consensus");
        if (slotForNextReportToProcess() != _report.refSlotFrom) return (false, "EtherFiAdmin: report has wrong `refSlotFrom`");
        if (blockForNextReportToProcess() != _report.refBlockFrom) return (false, "EtherFiAdmin: report has wrong `refBlockFrom`");
        if (current_slot < postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(_reportHash)) return (false, "EtherFiAdmin: report is too fresh");
        return (true, "");
    }

    /**
     * @notice Validates the rebase APR
     * @param _report The report
     * @param elapsedTime The elapsed time
     * @return _isValid True if the rebase APR is valid, false otherwise
     * @return _error The error message
     */
    function _validateRebaseApr(IEtherFiOracle.OracleReport calldata _report, uint256 elapsedTime) internal view returns (bool, string memory) {
        int256 currentTVL = int128(uint128(liquidityPool.getTotalPooledEther()));

        // TVL change guard: caps reported APR (absolute, positive or negative) at acceptableRebaseAprInBps.
        // Permanent invariant — protects against runaway rebase or slashing leakage in a single report.
        // - 5% APR = 0.0137% per day
        // - 10% APR = 0.0274% per day
        int256 apr;
        if (currentTVL > 0) {
            apr = int256(BASIS_POINTS_DENOMINATOR) * (_report.accruedRewards * 365 days) / (currentTVL * int256(elapsedTime));
        }
        int256 absApr = (apr > 0) ? apr : - apr;
        if (absApr > acceptableRebaseAprInBps) return (false, "EtherFiAdmin: TVL changed too much");

        // Negative (slashing) cap, independent of elapsedTime. The APR check above is
        // annualized, so a long-spanning report could pass it while still dropping an
        // outsized absolute amount in one rebase. A single report can only legitimately
        // DECREASE TVL by at most the max initial slashing penalty (~2.44 bps if every
        // validator is slashed at once), so bound the drop to effectiveMaxNegativeRebaseBps.
        // The positive/reward upper bound is enforced in LiquidityPool.rebase.
        if (_report.accruedRewards < 0 && currentTVL > 0) {
            int256 drop = -int256(_report.accruedRewards);
            if (drop * int256(BASIS_POINTS_DENOMINATOR) > currentTVL * int256(effectiveMaxNegativeRebaseBps())) {
                return (false, "EtherFiAdmin: negative rebase exceeds cap");
            }
        }
        return (true, "");
    }

    /**
     * @notice Validates the protocol fees
     * @param _report The report
     * @return _isValid True if the protocol fees are valid, false otherwise
     * @return _error The error message
     */
    function _validateProtocolFees(IEtherFiOracle.OracleReport calldata _report) internal pure returns (bool, string memory) {
        int128 totalRewards = int128(_report.protocolFees) + _report.accruedRewards;
        // protocol fees are less than 20% of total rewards
        if (_report.protocolFees > 0 && int128(_report.protocolFees) * int256(uint256(MAX_PROTOCOL_FEE_INV_RATIO)) > totalRewards) return (false, "EtherFiAdmin: protocol fees exceed 20% total rewards");
        return (true, "");
    }

    /**
     * @notice Validates the validator approvals
     * @param _report The report
     * @param elapsedTime The elapsed time
     * @return _isValid True if the validator approvals are valid, false otherwise
     * @return _error The error message
     */
    function _validateValidatorApprovals(IEtherFiOracle.OracleReport calldata _report, uint256 elapsedTime) internal view returns (bool, string memory) {
        uint256 numValidatorsToApprovePerDay = _report.validatorsToApprove.length.mulDiv(1 days, elapsedTime);
        if (numValidatorsToApprovePerDay > maxNumValidatorsToApprovePerDay) return (false, "EtherFiAdmin: number of validators to approve exceeds max");
        return (true, "");
    }

    /**
     * @notice Validates the withdrawals
     * @param _report The report
     * @param elapsedTime The elapsed time
     * @return _isValid True if the withdrawals are valid, false otherwise
     * @return _error The error message
     */
    function _validateWithdrawals(IEtherFiOracle.OracleReport calldata _report, uint256 elapsedTime) internal view returns (bool, string memory) {
        uint256 finalizedWithdrawalAmountPerDay = uint256(_report.finalizedWithdrawalAmount).mulDiv(1 days, elapsedTime);
        if (finalizedWithdrawalAmountPerDay > maxFinalizedWithdrawalAmountPerDay) return (false, "EtherFiAdmin: finalized withdrawal amount exceeds max");
        if (_report.finalizedWithdrawalAmount > liquidityPool.totalValueInLp()) return (false, "EtherFiAdmin: finalized withdrawal exceeds LP liquidity");

        // valdate finalized request id
        uint32 lastFinalizedRequestId = withdrawRequestNft.lastFinalizedRequestId();
        if (_report.lastFinalizedWithdrawalRequestId < lastFinalizedRequestId) return (false, "EtherFiAdmin: finalized withdrawal request id is less than last finalized request id");
        if (_report.lastFinalizedWithdrawalRequestId - lastFinalizedRequestId > maxNumberOfRequestsToFinalizePerReport) return (false, "EtherFiAdmin: number of requests to finalize exceeds max");
        uint256 sumOfRequests;
        for (uint256 i = lastFinalizedRequestId + 1; i <= _report.lastFinalizedWithdrawalRequestId; i++) {
            IWithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNft.getRequest(i);
            if (request.isValid) {
                sumOfRequests += request.amountOfEEth;
            }
        }
        if (sumOfRequests != _report.finalizedWithdrawalAmount) return (false, "EtherFiAdmin: sum of requests does not match finalized withdrawal amount");
        return (true, "");
    }

    /**
     * @notice Authorizes the upgrade of the contract
     * @param newImplementation The new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //----------------------------  VIEW FUNCTIONS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Checks if the report can be executed
     * @param _report The report
     * @return _isValid True if the report can be executed, false otherwise
     */
    function canExecuteTasks(IEtherFiOracle.OracleReport calldata _report) external view returns (bool _isValid) {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        (_isValid,) = _validateReport(_report, reportHash);
    }

    /**
     * @notice Gets the slot for the next report to process
     * @return The slot for the next report to process
     */
    function slotForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefSlot == 0) ? 0 : lastHandledReportRefSlot + 1;
    }

    /**
     * @notice Gets the block for the next report to process
     * @return The block for the next report to process
     */
    function blockForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefBlock == 0) ? 0 : lastHandledReportRefBlock + 1;
    }

  /**
   * @notice Gets the effective maximum negative rebase bps
   * @return The effective maximum negative rebase bps
   */
    function effectiveMaxNegativeRebaseBps() public view returns (uint256) {
        return maxNegativeRebaseBps == 0 ? DEFAULT_MAX_NEGATIVE_REBASE_BPS : maxNegativeRebaseBps;
    }

    /**
     * @notice Gets the implementation
     * @return The implementation
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}

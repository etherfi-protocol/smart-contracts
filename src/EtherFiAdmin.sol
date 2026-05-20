// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./RoleRegistry.sol";

import "./interfaces/IEtherFiOracle.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IMembershipManager.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/IPriorityWithdrawalQueue.sol";

interface IEtherFiPausable {
    function paused() external view returns (bool);
}

contract EtherFiAdmin is Initializable, OwnableUpgradeable, UUPSUpgradeable {


    struct TaskStatus {
        bool completed;
        bool exists;
    }

    IEtherFiOracle private DEPRECATED_etherFiOracle;
    IStakingManager private DEPRECATED_stakingManager;
    IAuctionManager private DEPRECATED_auctionManager;
    IEtherFiNodesManager private DEPRECATED_etherFiNodesManager;
    ILiquidityPool private DEPRECATED_liquidityPool;
    IMembershipManager private DEPRECATED_membershipManager;
    IWithdrawRequestNFT private DEPRECATED_withdrawRequestNft;

    mapping(address => bool) private DEPRECATED_admins;

    uint32 public lastHandledReportRefSlot;
    uint32 public lastHandledReportRefBlock;
    uint32 public __gap_0;

    int32 public acceptableRebaseAprInBps;

    uint16 public postReportWaitTimeInSlots;
    uint32 public lastAdminExecutionBlock;

    mapping(address => bool) private DEPRECATED_pausers;

    mapping(bytes32 => TaskStatus) public validatorApprovalTaskStatus;
    uint16 validatorTaskBatchSize;

    RoleRegistry private DEPRECATED_roleRegistry;

    uint256 public maxFinalizedWithdrawalAmountPerDay;
    uint256 public maxNumValidatorsToApprovePerDay;

    // Protocol fees must not exceed 1/MAX_PROTOCOL_FEE_INV_RATIO of total rewards (currently 20%).
    uint256 public constant MAX_PROTOCOL_FEE_INV_RATIO = 5;

    IEtherFiOracle public immutable etherFiOracle;
    IStakingManager public immutable stakingManager;
    IAuctionManager public immutable auctionManager;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    ILiquidityPool public immutable liquidityPool;
    IMembershipManager public immutable membershipManager;
    IWithdrawRequestNFT public immutable withdrawRequestNft;
    RoleRegistry public immutable roleRegistry;
    IPriorityWithdrawalQueue public immutable priorityWithdrawalQueue;

    int256 public immutable maxAcceptableRebaseAprInBps;
    uint256 public immutable maxValidatorTaskBatchSize;
    uint256 public immutable maxAcceptableFinalizedWithdrawalAmountPerDay;
    uint256 public immutable maxAcceptableNumValidatorsToApprovePerDay;
    uint256 public immutable staleOracleReportBlockWindow;

    struct ConstructorAddresses {
        address etherFiOracle;
        address stakingManager;
        address auctionManager;
        address etherFiNodesManager;
        address liquidityPool;
        address membershipManager;
        address withdrawRequestNft;
        address roleRegistry;
        address priorityWithdrawalQueue;
    }

    event AdminUpdated(address _address, bool _isAdmin);
    event AdminOperationsExecuted(address indexed _address, bytes32 indexed _reportHash);

    event ValidatorApprovalTaskCreated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);
    event ValidatorApprovalTaskCompleted(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);
    event ValidatorApprovalTaskInvalidated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);

    error IncorrectRole();
    error InvalidPriorityWithdrawalQueue();
    error InvalidMaxAcceptableFinalizedWithdrawalAmount();
    error InvalidMaxFinalizedWithdrawalAmountPerDay();
    error InvalidMaxNumValidatorsToApprovePerDay();
    error InvalidAcceptableRebaseApr();
    error InvalidValidatorTaskBatchSize();
    error InvalidMaxAcceptableRebaseApr();
    error InvalidStaleOracleReportBlockWindow();
    error OracleReportNotStale();
    error NoWithdrawalsToFinalize();
    error ReportValidationFailed(string reason);
    error ConsensusNotReached();
    error TaskDoesNotExist();
    error TaskAlreadyCompleted();
    error TaskAlreadyExists();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        ConstructorAddresses memory _constructorAddresses,
        int256 _maxAcceptableRebaseAprInBps,
        uint256 _maxValidatorTaskBatchSize,
        uint256 _staleOracleReportBlockWindow,
        uint256 _maxAcceptableFinalizedWithdrawalAmountPerDay,
        uint256 _maxAcceptableNumValidatorsToApprovePerDay
    ) {
        if (_maxAcceptableRebaseAprInBps <= 0 || _maxAcceptableRebaseAprInBps > 10_000) revert InvalidMaxAcceptableRebaseApr();
        if (_maxValidatorTaskBatchSize == 0) revert InvalidValidatorTaskBatchSize();
        if (_staleOracleReportBlockWindow == 0) revert InvalidStaleOracleReportBlockWindow();
        if (_maxAcceptableFinalizedWithdrawalAmountPerDay == 0) revert InvalidMaxAcceptableFinalizedWithdrawalAmount();

        etherFiOracle = IEtherFiOracle(_constructorAddresses.etherFiOracle);
        stakingManager = IStakingManager(_constructorAddresses.stakingManager);
        auctionManager = IAuctionManager(_constructorAddresses.auctionManager);
        etherFiNodesManager = IEtherFiNodesManager(_constructorAddresses.etherFiNodesManager);
        liquidityPool = ILiquidityPool(_constructorAddresses.liquidityPool);
        membershipManager = IMembershipManager(_constructorAddresses.membershipManager);
        withdrawRequestNft = IWithdrawRequestNFT(_constructorAddresses.withdrawRequestNft);
        roleRegistry = RoleRegistry(_constructorAddresses.roleRegistry);
        priorityWithdrawalQueue = IPriorityWithdrawalQueue(_constructorAddresses.priorityWithdrawalQueue);

        maxAcceptableRebaseAprInBps = _maxAcceptableRebaseAprInBps;
        maxValidatorTaskBatchSize = _maxValidatorTaskBatchSize;
        staleOracleReportBlockWindow = _staleOracleReportBlockWindow;
        maxAcceptableFinalizedWithdrawalAmountPerDay = _maxAcceptableFinalizedWithdrawalAmountPerDay;
        maxAcceptableNumValidatorsToApprovePerDay = _maxAcceptableNumValidatorsToApprovePerDay;

         _disableInitializers();
    }

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

    function setValidatorTaskBatchSize(uint16 _batchSize) external onlyAdmin {
        if (_batchSize == 0 || _batchSize > maxValidatorTaskBatchSize) revert InvalidValidatorTaskBatchSize();
        validatorTaskBatchSize = _batchSize;
    }

    function canExecuteTasks(IEtherFiOracle.OracleReport calldata _report) external view returns (bool _isValid) {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        (_isValid,) = _validateReport(_report, reportHash);
    }

    function executeTasks(IEtherFiOracle.OracleReport calldata _report) external {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        (bool _isValid, string memory _error) = _validateReport(_report, reportHash);
        if (!_isValid) revert ReportValidationFailed(_error);

        _handleAccruedRewards(_report);
        _handleProtocolFees(_report);
        _handleValidators(reportHash, _report);
        _handleWithdrawals(_report);

        lastHandledReportRefSlot = _report.refSlotTo;
        lastHandledReportRefBlock = _report.refBlockTo;
        lastAdminExecutionBlock = uint32(block.number);

        emit AdminOperationsExecuted(msg.sender, reportHash);
    }

    function executeValidatorApprovalTask(bytes32 _reportHash, uint256[] calldata _validators, bytes[] calldata _pubKeys, bytes[] calldata _signatures) external {
        if (!roleRegistry.hasRole(roleRegistry.ORACLE_OPERATIONS_ROLE(), msg.sender)) revert IncorrectRole();

        if (!etherFiOracle.isConsensusReached(_reportHash)) revert ConsensusNotReached();
        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators));
        if (!validatorApprovalTaskStatus[taskHash].exists) revert TaskDoesNotExist();
        if (validatorApprovalTaskStatus[taskHash].completed) revert TaskAlreadyCompleted();

        validatorApprovalTaskStatus[taskHash].completed = true;
        liquidityPool.batchApproveRegistration(_validators, _pubKeys, _signatures);
        emit ValidatorApprovalTaskCompleted(taskHash, _reportHash, _validators);
    }

    function invalidateValidatorApprovalTask(bytes32 _reportHash, uint256[] calldata _validators) external onlyOperations {
        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators));
        if (!validatorApprovalTaskStatus[taskHash].exists) revert TaskDoesNotExist();
        if (validatorApprovalTaskStatus[taskHash].completed) revert TaskAlreadyCompleted();
        validatorApprovalTaskStatus[taskHash].exists = false;
        emit ValidatorApprovalTaskInvalidated(taskHash, _reportHash, _validators);
    }

    /// @notice Stale-oracle escape hatch. If oracle reports stop landing for staleOracleReportBlockWindow
    ///         blocks past the last handled report, anyone can call this to finalize as many pending
    ///         withdraw requests as the LP's current ETH balance can cover, in request-id order.
    ///         Permissionless on purpose: a frozen oracle should not be able to freeze user redemptions.
    /// @dev    Reverts with OracleReportNotStale if the window has not elapsed, or NoWithdrawalsToFinalize
    ///         if no valid pending requests can be covered.
    function finalizeWithdrawalsWhenStale() external {
        if (block.number < lastHandledReportRefBlock + staleOracleReportBlockWindow) revert OracleReportNotStale();

        uint256 liquidity = address(liquidityPool).balance;
        uint32 currentRequestId = withdrawRequestNft.nextRequestId() - 1;
        uint32 lastFinalizedRequestId = withdrawRequestNft.lastFinalizedRequestId();
        uint32 requestId = lastFinalizedRequestId;
        uint128 finalizedWithdrawalAmount;
        while (requestId < currentRequestId) {
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
    }

    //protocol owns the eth that was distributed to NO and treasury in eigenpods and etherfinodes 
    function _handleProtocolFees(IEtherFiOracle.OracleReport calldata _report) internal { 
        if(_report.protocolFees == 0) {
            return;
        }
        liquidityPool.payProtocolFees(uint128(_report.protocolFees));
    }

    function _handleAccruedRewards(IEtherFiOracle.OracleReport calldata _report) internal {
        if (_report.accruedRewards == 0) {
            return;
        }

        membershipManager.rebase(_report.accruedRewards);
    }

    function _enqueueValidatorApprovalTask(bytes32 _reportHash, IEtherFiOracle.OracleReport calldata _report) internal {
        if(_report.validatorsToApprove.length == 0) {
            return;
        }

        uint256 numBatches = (_report.validatorsToApprove.length + validatorTaskBatchSize - 1) / validatorTaskBatchSize;

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

    function _handleValidators(bytes32 _reportHash, IEtherFiOracle.OracleReport calldata _report) internal {
        _enqueueValidatorApprovalTask(_reportHash, _report);
    }

    function _handleWithdrawals(IEtherFiOracle.OracleReport calldata _report) internal {
        _finalizeWithdrawals(_report.lastFinalizedWithdrawalRequestId, _report.finalizedWithdrawalAmount);
    }
    
    function _finalizeWithdrawals(uint32 _lastFinalizedRequestId, uint128 _finalizedWithdrawalAmount) internal {
        withdrawRequestNft.finalizeRequests(_lastFinalizedRequestId);
        liquidityPool.addEthAmountLockedForWithdrawal(_finalizedWithdrawalAmount);
    }

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

    function _validateReportFreshness(IEtherFiOracle.OracleReport calldata _report, bytes32 _reportHash) internal view returns (bool, string memory) {
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);
        if (!etherFiOracle.isConsensusReached(_reportHash)) return (false, "EtherFiAdmin: report didn't reach consensus");
        if (slotForNextReportToProcess() != _report.refSlotFrom) return (false, "EtherFiAdmin: report has wrong `refSlotFrom`");
        if (blockForNextReportToProcess() != _report.refBlockFrom) return (false, "EtherFiAdmin: report has wrong `refBlockFrom`");
        if (current_slot < postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(_reportHash)) return (false, "EtherFiAdmin: report is too fresh");
        return (true, "");
    }

    function _validateRebaseApr(IEtherFiOracle.OracleReport calldata _report, uint256 elapsedTime) internal view returns (bool, string memory) {
        int256 currentTVL = int128(uint128(liquidityPool.getTotalPooledEther()));

        // TVL change guard: caps reported APR (absolute, positive or negative) at acceptableRebaseAprInBps.
        // Permanent invariant — protects against runaway rebase or slashing leakage in a single report.
        // - 5% APR = 0.0137% per day
        // - 10% APR = 0.0274% per day
        int256 apr;
        if (currentTVL > 0) {
            apr = 10000 * (_report.accruedRewards * 365 days) / (currentTVL * int256(elapsedTime));
        }
        int256 absApr = (apr > 0) ? apr : - apr;
        if (absApr > acceptableRebaseAprInBps) return (false, "EtherFiAdmin: TVL changed too much");
        return (true, "");
    }

    function _validateProtocolFees(IEtherFiOracle.OracleReport calldata _report) internal pure returns (bool, string memory) {
        if (_report.protocolFees < 0) return (false, "EtherFiAdmin: protocol fees can't be negative");
        int128 totalRewards = _report.protocolFees + _report.accruedRewards;
        // protocol fees are less than 20% of total rewards
        if (_report.protocolFees > 0 && _report.protocolFees * int256(uint256(MAX_PROTOCOL_FEE_INV_RATIO)) > totalRewards) return (false, "EtherFiAdmin: protocol fees exceed 20% total rewards");
        return (true, "");
    }

    function _validateValidatorApprovals(IEtherFiOracle.OracleReport calldata _report, uint256 elapsedTime) internal view returns (bool, string memory) {
        uint256 numValidatorsToApprovePerDay = (_report.validatorsToApprove.length * 1 days) / elapsedTime;
        if (numValidatorsToApprovePerDay > maxNumValidatorsToApprovePerDay) return (false, "EtherFiAdmin: number of validators to approve exceeds max");
        return (true, "");
    }

    function _validateWithdrawals(IEtherFiOracle.OracleReport calldata _report, uint256 elapsedTime) internal view returns (bool, string memory) {
        uint256 finalizedWithdrawalAmountPerDay = (_report.finalizedWithdrawalAmount * 1 days) / elapsedTime;
        if (finalizedWithdrawalAmountPerDay > maxFinalizedWithdrawalAmountPerDay) return (false, "EtherFiAdmin: finalized withdrawal amount exceeds max");
        if (_report.finalizedWithdrawalAmount > address(liquidityPool).balance) return (false, "EtherFiAdmin: finalized withdrawal exceeds LP liquidity");

        // valdate finalized request id
        uint32 lastFinalizedRequestId = withdrawRequestNft.lastFinalizedRequestId();
        if (_report.lastFinalizedWithdrawalRequestId < lastFinalizedRequestId) return (false, "EtherFiAdmin: finalized withdrawal request id is less than last finalized request id");
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

    function slotForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefSlot == 0) ? 0 : lastHandledReportRefSlot + 1;
    }

    function blockForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefBlock == 0) ? 0 : lastHandledReportRefBlock + 1;
    }

    function updateMaxFinalizedWithdrawalAmountPerDay(uint256 _maxFinalizedWithdrawalAmountPerDay) external onlyAdmin {
        if (_maxFinalizedWithdrawalAmountPerDay == 0 || _maxFinalizedWithdrawalAmountPerDay > maxAcceptableFinalizedWithdrawalAmountPerDay) revert InvalidMaxFinalizedWithdrawalAmountPerDay();
        maxFinalizedWithdrawalAmountPerDay = _maxFinalizedWithdrawalAmountPerDay;
    }

    function updateMaxNumValidatorsToApprovePerDay(uint256 _maxNumValidatorsToApprovePerDay) external onlyAdmin {
        if (_maxNumValidatorsToApprovePerDay > maxAcceptableNumValidatorsToApprovePerDay) revert InvalidMaxNumValidatorsToApprovePerDay();
        maxNumValidatorsToApprovePerDay = _maxNumValidatorsToApprovePerDay;
    }

    function updateAcceptableRebaseApr(int32 _acceptableRebaseAprInBps) external onlyAdmin {
        if (_acceptableRebaseAprInBps < 0 || _acceptableRebaseAprInBps > maxAcceptableRebaseAprInBps) revert InvalidAcceptableRebaseApr();
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
    }

    function updatePostReportWaitTimeInSlots(uint16 _postReportWaitTimeInSlots) external onlyAdmin {
        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    modifier onlyAdmin() {
        roleRegistry.onlyOperatingTimelock(msg.sender);
        _;
    }

    modifier onlyOperations() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }
}

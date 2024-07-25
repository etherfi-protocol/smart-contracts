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

contract EtherFiAdmin is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    enum TaskType {
        ValidatorApproval,
        SendExitRequests,
        ProcessNodeExit,
        MarkBeingSlashed
    }

    struct TaskStatus {
        bool completed;
        bool exists;
        TaskType taskType;
    }

    IEtherFiOracle public etherFiOracle;
    IStakingManager public DEPRECATED_stakingManager;
    IAuctionManager public DEPRECATED_auctionManager;
    IEtherFiNodesManager public etherFiNodesManager;
    ILiquidityPool public liquidityPool;
    IMembershipManager public membershipManager;
    IWithdrawRequestNFT public withdrawRequestNft;

    mapping(address => bool) public DEPRECATED_admins;

    uint32 public lastHandledReportRefSlot;
    uint32 public lastHandledReportRefBlock;
    uint32 public numValidatorsToSpinUp;

    int32 public acceptableRebaseAprInBps;

    uint16 public postReportWaitTimeInSlots;
    uint32 public lastAdminExecutionBlock;

    mapping(address => bool) public DEPRECATED_pausers;

    mapping(bytes32 => TaskStatus) public validatorManagementTaskStatus;
    uint16 validatorTaskBatchSize;

    RoleRegistry public roleRegistry;

    bytes32 public constant ETHERFI_ADMIN_ADMIN_ROLE = keccak256("ETHERFI_ADMIN_ADMIN_ROLE");

    event AdminUpdated(address _address, bool _isAdmin);
    event AdminOperationsExecuted(address indexed _address, bytes32 indexed _reportHash);

    event ValidatorManagementTaskCreated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators, uint32[] _timestamps, TaskType _taskType);
    event ValidatorManagementTaskCompleted(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators, uint32[] _timestamps, TaskType _taskType);
    event ValidatorManagementTaskInvalidated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators, uint32[] _timestamps,TaskType _taskType);

    error IncorrectRole();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
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

        etherFiOracle = IEtherFiOracle(_etherFiOracle);
        DEPRECATED_stakingManager = IStakingManager(_stakingManager);
        DEPRECATED_auctionManager = IAuctionManager(_auctionManager);
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipManager = IMembershipManager(_membershipManager);
        withdrawRequestNft = IWithdrawRequestNFT(_withdrawRequestNft);
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    function initializeV2dot5(address _roleRegistry) external onlyOwner {
        require(address(roleRegistry) == address(0x00), "already initialized");

        // TODO: compile list of values in DEPRECATED_pausers to clear out
        // TODO: compile list of values in DEPRECATED_admins to clear out
        roleRegistry = RoleRegistry(_roleRegistry);
    }


    function setValidatorTaskBatchSize(uint16 _batchSize) external onlyOwner {
        validatorTaskBatchSize = _batchSize;
    }

    function canExecuteTasks(IEtherFiOracle.OracleReport calldata _report) external view returns (bool) {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);

        if (!etherFiOracle.isConsensusReached(reportHash)) return false;
        if (slotForNextReportToProcess() != _report.refSlotFrom) return false;
        if (blockForNextReportToProcess() != _report.refBlockFrom) return false;
        if (current_slot < postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(reportHash)) return false;
        return true;
    }

    function executeTasks(IEtherFiOracle.OracleReport calldata _report) external {
        if (!roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);
        require(etherFiOracle.isConsensusReached(reportHash), "EtherFiAdmin: report didn't reach consensus");
        require(slotForNextReportToProcess() == _report.refSlotFrom, "EtherFiAdmin: report has wrong `refSlotFrom`");
        require(blockForNextReportToProcess() == _report.refBlockFrom, "EtherFiAdmin: report has wrong `refBlockFrom`");
        require(current_slot >= postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(reportHash), "EtherFiAdmin: report is too fresh");

        numValidatorsToSpinUp = _report.numValidatorsToSpinUp;

        _handleAccruedRewards(_report);
        _handleProtocolFees(_report);
        _handleValidators(reportHash, _report);
        _handleWithdrawals(_report);
        _handleTargetFundsAllocations(_report);

        lastHandledReportRefSlot = _report.refSlotTo;
        lastHandledReportRefBlock = _report.refBlockTo;
        lastAdminExecutionBlock = uint32(block.number);

        emit AdminOperationsExecuted(msg.sender, reportHash);
    }

    //_timestamp will only be used for TaskType.ProcessNodeExit and pubkeys and signatures will only be used for TaskType.ValidatorApproval
    function executeValidatorManagementTask(bytes32 _reportHash, uint256[] calldata _validators, uint32[] calldata _timestamps, bytes[] calldata _pubKeys, bytes[] calldata _signatures) external {
        if (!roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        require(etherFiOracle.isConsensusReached(_reportHash), "EtherFiAdmin: report didn't reach consensus");
        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators, _timestamps));
        require(validatorManagementTaskStatus[taskHash].exists, "EtherFiAdmin: task doesn't exist");
        require(!validatorManagementTaskStatus[taskHash].completed, "EtherFiAdmin: task already completed");
        TaskType taskType = validatorManagementTaskStatus[taskHash].taskType;

        if (taskType == TaskType.ValidatorApproval) {
        liquidityPool.batchApproveRegistration(_validators, _pubKeys, _signatures);
        } else if (taskType == TaskType.SendExitRequests) {
            liquidityPool.sendExitRequests(_validators);
        } else if (taskType == TaskType.ProcessNodeExit) {
            etherFiNodesManager.processNodeExit(_validators, _timestamps);
        } else if (taskType == TaskType.MarkBeingSlashed) {
            etherFiNodesManager.markBeingSlashed(_validators);
        }
        validatorManagementTaskStatus[taskHash].completed = true;
        emit ValidatorManagementTaskCompleted(taskHash, _reportHash, _validators, _timestamps, taskType);
    }

    function invalidateValidatorManagementTask(bytes32 _reportHash, uint256[] calldata _validators, uint32[] calldata _timestamps) external {
        if (!roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators, _timestamps));
        require(validatorManagementTaskStatus[taskHash].exists, "EtherFiAdmin: task doesn't exist");
        require(!validatorManagementTaskStatus[taskHash].completed, "EtherFiAdmin: task already completed");
        validatorManagementTaskStatus[taskHash].exists = false;
        emit ValidatorManagementTaskInvalidated(taskHash, _reportHash, _validators, _timestamps, validatorManagementTaskStatus[taskHash].taskType);
    }

    //protocol owns the eth that was distributed to NO and treasury in eigenpods and etherfinodes 
    function _handleProtocolFees(IEtherFiOracle.OracleReport calldata _report) internal { 
        require(_report.protocolFees >= 0, "EtherFiAdmin: protocol fees can't be negative");
        if(_report.protocolFees == 0) {
            return;
        }
        liquidityPool.payProtocolFees(uint128(_report.protocolFees));
    }

    function _handleAccruedRewards(IEtherFiOracle.OracleReport calldata _report) internal {
        if (_report.accruedRewards == 0) {
            return;
        }

        // compute the elapsed time since the last rebase
        int256 elapsedSlots = int32(_report.refSlotTo - lastHandledReportRefSlot);
        int256 elapsedTime = 12 seconds * elapsedSlots;

        // This guard will be removed in future versions
        // Ensure that thew TVL didnt' change too much
        // Check if the absolute change (increment, decrement) in TVL is beyond the threshold variable
        // - 5% APR = 0.0137% per day
        // - 10% APR = 0.0274% per day
        int256 currentTVL = int128(uint128(liquidityPool.getTotalPooledEther()));
        int256 apr;
        if (currentTVL > 0) {
            apr = 10000 * (_report.accruedRewards * 365 days) / (currentTVL * elapsedTime);
        }
        int256 absApr = (apr > 0) ? apr : - apr;
        require(absApr <= acceptableRebaseAprInBps, "EtherFiAdmin: TVL changed too much");

        membershipManager.rebase(_report.accruedRewards);
    }

    function _enqueueValidatorManagementTask(bytes32 _reportHash, uint256[] calldata _validators, uint32[] memory _timestamps, TaskType taskType) internal {
        uint256 numBatches = (_validators.length + validatorTaskBatchSize - 1) / validatorTaskBatchSize;

        if(_validators.length == 0) {
            return;
        }
        for (uint256 i = 0; i < numBatches; i++) {
            uint256 start = i * validatorTaskBatchSize;
            uint256 end = (i + 1) * validatorTaskBatchSize > _validators.length ? _validators.length : (i + 1) * validatorTaskBatchSize;
            uint256 timestampSize = taskType == TaskType.ProcessNodeExit ? end - start : 0;
            uint256[] memory batchValidators = new uint256[](end - start);
            uint32[] memory batchTimestamps = new uint32[](timestampSize);

            for (uint256 j = start; j < end; j++) {
                batchValidators[j - start] = _validators[j];
                if(taskType == TaskType.ProcessNodeExit) {
                    batchTimestamps[j - start] = _timestamps[j];
                }
            }
            bytes32 taskHash = keccak256(abi.encode(_reportHash, batchValidators, batchTimestamps));
            validatorManagementTaskStatus[taskHash] = TaskStatus({completed: false, exists: true, taskType: taskType});
            emit ValidatorManagementTaskCreated(taskHash, _reportHash, batchValidators, batchTimestamps, taskType);
        }
    }

    function _handleValidators(bytes32 _reportHash, IEtherFiOracle.OracleReport calldata _report) internal {
            uint32[] memory emptyTimestamps = new uint32[](0);
            _enqueueValidatorManagementTask(_reportHash, _report.validatorsToApprove, emptyTimestamps,  TaskType.ValidatorApproval);
            _enqueueValidatorManagementTask(_reportHash, _report.liquidityPoolValidatorsToExit, emptyTimestamps,  TaskType.SendExitRequests);
            _enqueueValidatorManagementTask(_reportHash, _report.exitedValidators, _report.exitedValidatorsExitTimestamps, TaskType.ProcessNodeExit);
            _enqueueValidatorManagementTask(_reportHash, _report.slashedValidators, emptyTimestamps, TaskType.MarkBeingSlashed);
    }

    function _handleWithdrawals(IEtherFiOracle.OracleReport calldata _report) internal {
        for (uint256 i = 0; i < _report.withdrawalRequestsToInvalidate.length; i++) {
            withdrawRequestNft.invalidateRequest(_report.withdrawalRequestsToInvalidate[i]);
        }
        withdrawRequestNft.finalizeRequests(_report.lastFinalizedWithdrawalRequestId);

        liquidityPool.addEthAmountLockedForWithdrawal(_report.finalizedWithdrawalAmount);
    }

    function _handleTargetFundsAllocations(IEtherFiOracle.OracleReport calldata _report) internal {
        // To handle the case when we want to avoid updating the params too often (to save gas fee)
        if (_report.eEthTargetAllocationWeight == 0 && _report.etherFanTargetAllocationWeight == 0) {
            return;
        }
        liquidityPool.setStakingTargetWeights(_report.eEthTargetAllocationWeight, _report.etherFanTargetAllocationWeight);
    }

    function slotForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefSlot == 0) ? 0 : lastHandledReportRefSlot + 1;
    }

    function blockForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefBlock == 0) ? 0 : lastHandledReportRefBlock + 1;
    }

    function updateAcceptableRebaseApr(int32 _acceptableRebaseAprInBps) external onlyOwner {
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
    }

    function updatePostReportWaitTimeInSlots(uint16 _postReportWaitTimeInSlots) external {
        if (!roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
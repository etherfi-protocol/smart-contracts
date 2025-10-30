// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./RoleRegistry.sol";

import "./interfaces/IAuctionManager.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IEtherFiOracle.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IMembershipManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IWithdrawRequestNFT.sol";

interface IEtherFiPausable {
    function paused() external view returns (bool);
}

contract EtherFiAdmin is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    struct TaskStatus {
        bool completed;
        bool exists;
    }

    IEtherFiOracle public etherFiOracle;
    IStakingManager public stakingManager;
    IAuctionManager public auctionManager;
    IEtherFiNodesManager public etherFiNodesManager;
    ILiquidityPool public liquidityPool;
    IMembershipManager public membershipManager;
    IWithdrawRequestNFT public withdrawRequestNft;

    mapping(address => bool) public DEPRECATED_admins;

    uint32 public lastHandledReportRefSlot;
    uint32 public lastHandledReportRefBlock;
    uint32 public __gap_0;

    int32 public acceptableRebaseAprInBps;

    uint16 public postReportWaitTimeInSlots;
    uint32 public lastAdminExecutionBlock;

    mapping(address => bool) public DEPRECATED_pausers;

    mapping(bytes32 => TaskStatus) public validatorApprovalTaskStatus;
    uint16 validatorTaskBatchSize;

    RoleRegistry public roleRegistry;

    bytes32 public constant ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE");
    bytes32 public constant ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE");

    event AdminUpdated(address _address, bool _isAdmin);
    event AdminOperationsExecuted(address indexed _address, bytes32 indexed _reportHash);

    event ValidatorApprovalTaskCreated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);
    event ValidatorApprovalTaskCompleted(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);
    event ValidatorApprovalTaskInvalidated(bytes32 indexed _taskHash, bytes32 indexed _reportHash, uint256[] _validators);

    error IncorrectRole();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _etherFiOracle, address _stakingManager, address _auctionManager, address _etherFiNodesManager, address _liquidityPool, address _membershipManager, address _withdrawRequestNft, int32 _acceptableRebaseAprInBps, uint16 _postReportWaitTimeInSlots) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        etherFiOracle = IEtherFiOracle(_etherFiOracle);
        stakingManager = IStakingManager(_stakingManager);
        auctionManager = IAuctionManager(_auctionManager);
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipManager = IMembershipManager(_membershipManager);
        withdrawRequestNft = IWithdrawRequestNFT(_withdrawRequestNft);
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    // pause {etherfi oracle, staking manager, auction manager, etherfi nodes manager, liquidity pool, membership manager}
    // based on the boolean flags
    // if true, pause,
    // else, unpuase
    function pause(bool _etherFiOracle, bool _stakingManager, bool _auctionManager, bool _etherFiNodesManager, bool _liquidityPool, bool _membershipManager) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        if (_etherFiOracle && !IEtherFiPausable(address(etherFiOracle)).paused()) etherFiOracle.pauseContract();

        if (_stakingManager && !IEtherFiPausable(address(stakingManager)).paused()) stakingManager.pauseContract();

        if (_auctionManager && !IEtherFiPausable(address(auctionManager)).paused()) auctionManager.pauseContract();

        if (_etherFiNodesManager && !IEtherFiPausable(address(etherFiNodesManager)).paused()) etherFiNodesManager.pauseContract();

        if (_liquidityPool && !IEtherFiPausable(address(liquidityPool)).paused()) liquidityPool.pauseContract();

        if (_membershipManager && !IEtherFiPausable(address(membershipManager)).paused()) membershipManager.pauseContract();
    }

    function unPause(bool _etherFiOracle, bool _stakingManager, bool _auctionManager, bool _etherFiNodesManager, bool _liquidityPool, bool _membershipManager) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (_etherFiOracle && IEtherFiPausable(address(etherFiOracle)).paused()) etherFiOracle.unPauseContract();

        if (_stakingManager && IEtherFiPausable(address(stakingManager)).paused()) stakingManager.unPauseContract();

        if (_auctionManager && IEtherFiPausable(address(auctionManager)).paused()) auctionManager.unPauseContract();

        if (_etherFiNodesManager && IEtherFiPausable(address(etherFiNodesManager)).paused()) etherFiNodesManager.unPauseContract();

        if (_liquidityPool && IEtherFiPausable(address(liquidityPool)).paused()) liquidityPool.unPauseContract();

        if (_membershipManager && IEtherFiPausable(address(membershipManager)).paused()) membershipManager.unPauseContract();
    }

    function initializeRoleRegistry(address _roleRegistry) external onlyOwner {
        require(address(roleRegistry) == address(0x00), "already initialized");
        roleRegistry = RoleRegistry(_roleRegistry);
        validatorTaskBatchSize = 100;
    }

    function setValidatorTaskBatchSize(uint16 _batchSize) external {
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
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
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE, msg.sender)) revert IncorrectRole();

        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);
        require(etherFiOracle.isConsensusReached(reportHash), "EtherFiAdmin: report didn't reach consensus");
        require(slotForNextReportToProcess() == _report.refSlotFrom, "EtherFiAdmin: report has wrong `refSlotFrom`");
        require(blockForNextReportToProcess() == _report.refBlockFrom, "EtherFiAdmin: report has wrong `refBlockFrom`");
        require(current_slot >= postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(reportHash), "EtherFiAdmin: report is too fresh");

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
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE, msg.sender)) revert IncorrectRole();

        require(etherFiOracle.isConsensusReached(_reportHash), "EtherFiAdmin: report didn't reach consensus");
        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators));
        require(validatorApprovalTaskStatus[taskHash].exists, "EtherFiAdmin: task doesn't exist");
        require(!validatorApprovalTaskStatus[taskHash].completed, "EtherFiAdmin: task already completed");

        validatorApprovalTaskStatus[taskHash].completed = true;
        liquidityPool.batchApproveRegistration(_validators, _pubKeys, _signatures);
        emit ValidatorApprovalTaskCompleted(taskHash, _reportHash, _validators);
    }

    function invalidateValidatorApprovalTask(bytes32 _reportHash, uint256[] calldata _validators) external {
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        bytes32 taskHash = keccak256(abi.encode(_reportHash, _validators));
        require(validatorApprovalTaskStatus[taskHash].exists, "EtherFiAdmin: task doesn't exist");
        require(!validatorApprovalTaskStatus[taskHash].completed, "EtherFiAdmin: task already completed");
        validatorApprovalTaskStatus[taskHash].exists = false;
        emit ValidatorApprovalTaskInvalidated(taskHash, _reportHash, _validators);
    }

    //protocol owns the eth that was distributed to NO and treasury in eigenpods and etherfinodes
    function _handleProtocolFees(IEtherFiOracle.OracleReport calldata _report) internal {
        require(_report.protocolFees >= 0, "EtherFiAdmin: protocol fees can't be negative");
        if (_report.protocolFees == 0) return;
        int128 totalRewards = _report.protocolFees + _report.accruedRewards;
        // protocol fees are less than 20% of total rewards
        require(_report.protocolFees * 5 <= totalRewards, "EtherFiAdmin: protocol fees exceed 20% total rewards");

        liquidityPool.payProtocolFees(uint128(_report.protocolFees));
    }

    function _handleAccruedRewards(IEtherFiOracle.OracleReport calldata _report) internal {
        if (_report.accruedRewards == 0) return;

        // compute the elapsed time since the last rebase
        int256 elapsedSlots = int32(_report.refSlotTo - lastHandledReportRefSlot);
        int256 elapsedTime = 12 seconds * elapsedSlots;

        // This guard will be removed in future versions
        // Ensure that the new TVL didnt' change too much
        // Check if the absolute change (increment, decrement) in TVL is beyond the threshold variable
        // - 5% APR = 0.0137% per day
        // - 10% APR = 0.0274% per day
        int256 currentTVL = int128(uint128(liquidityPool.getTotalPooledEther()));
        int256 apr;
        if (currentTVL > 0) apr = 10_000 * (_report.accruedRewards * 365 days) / (currentTVL * elapsedTime);
        int256 absApr = (apr > 0) ? apr : -apr;
        require(absApr <= acceptableRebaseAprInBps, "EtherFiAdmin: TVL changed too much");

        membershipManager.rebase(_report.accruedRewards);
    }

    function _enqueueValidatorApprovalTask(bytes32 _reportHash, uint256[] calldata _validators) internal {
        uint256 numBatches = (_validators.length + validatorTaskBatchSize - 1) / validatorTaskBatchSize;

        if (_validators.length == 0) return;
        for (uint256 i = 0; i < numBatches; i++) {
            uint256 start = i * validatorTaskBatchSize;
            uint256 end = (i + 1) * validatorTaskBatchSize > _validators.length ? _validators.length : (i + 1) * validatorTaskBatchSize;
            uint256[] memory batchValidators = new uint256[](end - start);

            for (uint256 j = start; j < end; j++) {
                batchValidators[j - start] = _validators[j];
            }
            bytes32 taskHash = keccak256(abi.encode(_reportHash, batchValidators));
            require(!validatorApprovalTaskStatus[taskHash].exists, "Task already exists");
            validatorApprovalTaskStatus[taskHash] = TaskStatus({completed: false, exists: true});
            emit ValidatorApprovalTaskCreated(taskHash, _reportHash, batchValidators);
        }
    }

    function _handleValidators(bytes32 _reportHash, IEtherFiOracle.OracleReport calldata _report) internal {
        _enqueueValidatorApprovalTask(_reportHash, _report.validatorsToApprove);
    }

    function _handleWithdrawals(IEtherFiOracle.OracleReport calldata _report) internal {
        for (uint256 i = 0; i < _report.withdrawalRequestsToInvalidate.length; i++) {
            withdrawRequestNft.invalidateRequest(_report.withdrawalRequestsToInvalidate[i]);
        }
        withdrawRequestNft.finalizeRequests(_report.lastFinalizedWithdrawalRequestId);
        liquidityPool.addEthAmountLockedForWithdrawal(_report.finalizedWithdrawalAmount);
    }

    function slotForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefSlot == 0) ? 0 : lastHandledReportRefSlot + 1;
    }

    function blockForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefBlock == 0) ? 0 : lastHandledReportRefBlock + 1;
    }

    function updateAcceptableRebaseApr(int32 _acceptableRebaseAprInBps) external {
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
    }

    function updatePostReportWaitTimeInSlots(uint16 _postReportWaitTimeInSlots) external {
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }
}

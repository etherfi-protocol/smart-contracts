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

    IEtherFiOracle public DEPRECATED_etherFiOracle;
    IStakingManager public DEPRECATED_stakingManager;
    IAuctionManager public DEPRECATED_auctionManager;
    IEtherFiNodesManager public DEPRECATED_etherFiNodesManager;
    ILiquidityPool public DEPRECATED_liquidityPool;
    IMembershipManager public DEPRECATED_membershipManager;
    IWithdrawRequestNFT public DEPRECATED_withdrawRequestNft;

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

    RoleRegistry public DEPRECATED_roleRegistry;

    uint256 public maxFinalizedWithdrawalAmountPerDay;
    uint256 public maxNumValidatorsToApprovePerDay;

    bytes32 public constant ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE");
    bytes32 public constant ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE");

    IEtherFiOracle public immutable etherFiOracle;
    IStakingManager public immutable stakingManager;
    IAuctionManager public immutable auctionManager;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    ILiquidityPool public immutable liquidityPool;
    IMembershipManager public immutable membershipManager;
    IWithdrawRequestNFT public immutable withdrawRequestNft;
    RoleRegistry public immutable roleRegistry;
    IPriorityWithdrawalQueue public immutable priorityWithdrawalQueue;

    int256 public immutable MAX_ACCEPTABLE_REBASE_APR_IN_BPS;
    uint256 public immutable MAX_VALIDATOR_TASK_BATCH_SIZE;
    uint256 public immutable MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY;
    uint256 public immutable MAX_NUM_VALIDATORS_TO_APPROVE_PER_DAY;
    uint256 public immutable STALE_ORACLE_REPORT_BLOCK_WINDOW;

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
    error InvalidMaxFinalizedWithdrawalAmountPerDay();
    error InvalidMaxNumValidatorsToApprovePerDay();
    error InvalidAcceptableRebaseApr();
    error InvalidValidatorTaskBatchSize();
    error InvalidMaxAcceptableRebaseApr();
    error InvalidStaleOracleReportBlockWindow();
    error OracleReportNotStale();
    error NoWithdrawalsToFinalize();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        ConstructorAddresses memory _constructorAddresses,
        int256 _maxAcceptableRebaseAprInBps,
        uint256 _maxValidatorTaskBatchSize,
        uint256 _staleOracleReportBlockWindow,
        uint256 _maxFinalizedWithdrawalAmountPerDay,
        uint256 _maxNumValidatorsToApprovePerDay
    ) {
        if (_maxAcceptableRebaseAprInBps <= 0 || _maxAcceptableRebaseAprInBps > 10_000) revert InvalidMaxAcceptableRebaseApr();
        if (_maxValidatorTaskBatchSize == 0) revert InvalidValidatorTaskBatchSize();
        if (_staleOracleReportBlockWindow == 0) revert InvalidStaleOracleReportBlockWindow();
        if (_maxFinalizedWithdrawalAmountPerDay == 0) revert InvalidMaxFinalizedWithdrawalAmountPerDay();
        // _maxNumValidatorsToApprovePerDay = 0 is allowed (signals "pause new validators") per author intent

        etherFiOracle = IEtherFiOracle(_constructorAddresses.etherFiOracle);
        stakingManager = IStakingManager(_constructorAddresses.stakingManager);
        auctionManager = IAuctionManager(_constructorAddresses.auctionManager);
        etherFiNodesManager = IEtherFiNodesManager(_constructorAddresses.etherFiNodesManager);
        liquidityPool = ILiquidityPool(_constructorAddresses.liquidityPool);
        membershipManager = IMembershipManager(_constructorAddresses.membershipManager);
        withdrawRequestNft = IWithdrawRequestNFT(_constructorAddresses.withdrawRequestNft);
        roleRegistry = RoleRegistry(_constructorAddresses.roleRegistry);
        priorityWithdrawalQueue = IPriorityWithdrawalQueue(_constructorAddresses.priorityWithdrawalQueue);

        MAX_ACCEPTABLE_REBASE_APR_IN_BPS = _maxAcceptableRebaseAprInBps;
        MAX_VALIDATOR_TASK_BATCH_SIZE = _maxValidatorTaskBatchSize;
        STALE_ORACLE_REPORT_BLOCK_WINDOW = _staleOracleReportBlockWindow;
        MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY = _maxFinalizedWithdrawalAmountPerDay;
        MAX_NUM_VALIDATORS_TO_APPROVE_PER_DAY = _maxNumValidatorsToApprovePerDay;

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

        DEPRECATED_etherFiOracle = IEtherFiOracle(_etherFiOracle);
        DEPRECATED_stakingManager = IStakingManager(_stakingManager);
        DEPRECATED_auctionManager = IAuctionManager(_auctionManager);
        DEPRECATED_etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
        DEPRECATED_liquidityPool = ILiquidityPool(_liquidityPool);
        DEPRECATED_membershipManager = IMembershipManager(_membershipManager);
        DEPRECATED_withdrawRequestNft = IWithdrawRequestNFT(_withdrawRequestNft);
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    // pause {etherfi oracle, staking manager, auction manager, etherfi nodes manager, liquidity pool, membership manager}
    // based on the boolean flags
    // if true, pause,
    // else, unpuase
    function pause(bool _etherFiOracle, bool _stakingManager, bool _auctionManager, bool _etherFiNodesManager, bool _liquidityPool, bool _membershipManager) external {
        if( !roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        if (_etherFiOracle && !IEtherFiPausable(address(etherFiOracle)).paused()) {
            etherFiOracle.pauseContract();
        }

        if (_stakingManager && !IEtherFiPausable(address(stakingManager)).paused()) {
            stakingManager.pauseContract();
        }

        if (_auctionManager && !IEtherFiPausable(address(auctionManager)).paused()) {
            auctionManager.pauseContract();
        }

        if (_etherFiNodesManager && !IEtherFiPausable(address(etherFiNodesManager)).paused()) {
            etherFiNodesManager.pauseContract();
        }

        if (_liquidityPool && !IEtherFiPausable(address(liquidityPool)).paused()) {
            liquidityPool.pauseContract();
        }

        if (_membershipManager && !IEtherFiPausable(address(membershipManager)).paused()) {
            membershipManager.pauseContract();
        }
    }

    function unPause(bool _etherFiOracle, bool _stakingManager, bool _auctionManager, bool _etherFiNodesManager, bool _liquidityPool, bool _membershipManager) external {
        if( !roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (_etherFiOracle && IEtherFiPausable(address(etherFiOracle)).paused()) {
            etherFiOracle.unPauseContract();
        }

        if (_stakingManager && IEtherFiPausable(address(stakingManager)).paused()) {
            stakingManager.unPauseContract();
        }

        if (_auctionManager && IEtherFiPausable(address(auctionManager)).paused()) {
            auctionManager.unPauseContract();
        }

        if (_etherFiNodesManager && IEtherFiPausable(address(etherFiNodesManager)).paused()) {
            etherFiNodesManager.unPauseContract();
        }

        if (_liquidityPool && IEtherFiPausable(address(liquidityPool)).paused()) {
            liquidityPool.unPauseContract();
        }

        if (_membershipManager && IEtherFiPausable(address(membershipManager)).paused()) {
            membershipManager.unPauseContract();
        }
    }

    function initializeRoleRegistry(address _roleRegistry) external onlyOwner {
        require(address(roleRegistry) == address(0x00), "already initialized");
        DEPRECATED_roleRegistry = RoleRegistry(_roleRegistry);
        validatorTaskBatchSize = 100;
    }


    function setValidatorTaskBatchSize(uint16 _batchSize) external {
        if(!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (_batchSize == 0 || _batchSize > MAX_VALIDATOR_TASK_BATCH_SIZE) revert InvalidValidatorTaskBatchSize();
        validatorTaskBatchSize = _batchSize;
    }

    function canExecuteTasks(IEtherFiOracle.OracleReport calldata _report) external view returns (bool _isValid) {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        (_isValid,) = _validateReport(_report, reportHash);
    }

    function executeTasks(IEtherFiOracle.OracleReport calldata _report) external {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        (bool _isValid, string memory _error) = _validateReport(_report, reportHash);
        require(_isValid, _error);

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

    function finalizeWithdrawalsWhenStale() external {
        if (block.number < lastHandledReportRefBlock + STALE_ORACLE_REPORT_BLOCK_WINDOW) revert OracleReportNotStale();

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
            require(!validatorApprovalTaskStatus[taskHash].exists, "Task already exists");
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
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);
        if (!etherFiOracle.isConsensusReached(_reportHash)) return (false, "EtherFiAdmin: report didn't reach consensus");
        if (slotForNextReportToProcess() != _report.refSlotFrom) return (false, "EtherFiAdmin: report has wrong `refSlotFrom`");
        if (blockForNextReportToProcess() != _report.refBlockFrom) return (false, "EtherFiAdmin: report has wrong `refBlockFrom`");
        if (current_slot < postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(_reportHash)) return (false, "EtherFiAdmin: report is too fresh");

        uint256 elapsedTime = (_report.refSlotTo - lastHandledReportRefSlot) * 12 seconds;
        if (elapsedTime == 0) return (false, "EtherFiAdmin: report spans zero slots");

        // validate accrued rewards
        int256 currentTVL = int128(uint128(liquidityPool.getTotalPooledEther()));

        // This guard will be removed in future versions
        // Ensure that the new TVL didnt' change too much
        // Check if the absolute change (increment, decrement) in TVL is beyond the threshold variable
        // - 5% APR = 0.0137% per day
        // - 10% APR = 0.0274% per day
        int256 apr;
        if (currentTVL > 0) {
            apr = 10000 * (_report.accruedRewards * 365 days) / (currentTVL * int256(elapsedTime));
        }
        int256 absApr = (apr > 0) ? apr : - apr;
        if (absApr > acceptableRebaseAprInBps) return (false, "EtherFiAdmin: TVL changed too much");

        // validate protocol fees
        if (_report.protocolFees < 0) return (false, "EtherFiAdmin: protocol fees can't be negative");
        int128 totalRewards = _report.protocolFees + _report.accruedRewards;
        // protocol fees are less than 20% of total rewards
        if (_report.protocolFees > 0 && _report.protocolFees * 5 > totalRewards) return (false, "EtherFiAdmin: protocol fees exceed 20% total rewards");

        // validate approvals
        uint256 numValidatorsToApprovePerDay = (_report.validatorsToApprove.length * 1 days) / elapsedTime;
        if (numValidatorsToApprovePerDay > maxNumValidatorsToApprovePerDay) return (false, "EtherFiAdmin: number of validators to approve exceeds max");

        // validate withdrawals
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

        // report is valid
        return (true, "");
    }

    function slotForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefSlot == 0) ? 0 : lastHandledReportRefSlot + 1;
    }

    function blockForNextReportToProcess() public view returns (uint32) {
        return (lastHandledReportRefBlock == 0) ? 0 : lastHandledReportRefBlock + 1;
    }

    function updateMaxFinalizedWithdrawalAmountPerDay(uint256 _maxFinalizedWithdrawalAmountPerDay) external {
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (_maxFinalizedWithdrawalAmountPerDay == 0 || _maxFinalizedWithdrawalAmountPerDay > MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY) revert InvalidMaxFinalizedWithdrawalAmountPerDay();
        maxFinalizedWithdrawalAmountPerDay = _maxFinalizedWithdrawalAmountPerDay;
    }

    function updateMaxNumValidatorsToApprovePerDay(uint256 _maxNumValidatorsToApprovePerDay) external {
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (_maxNumValidatorsToApprovePerDay > MAX_NUM_VALIDATORS_TO_APPROVE_PER_DAY) revert InvalidMaxNumValidatorsToApprovePerDay();
        maxNumValidatorsToApprovePerDay = _maxNumValidatorsToApprovePerDay;
    }

    function updateAcceptableRebaseApr(int32 _acceptableRebaseAprInBps) external {
        if (!roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (_acceptableRebaseAprInBps < 0 || _acceptableRebaseAprInBps > MAX_ACCEPTABLE_REBASE_APR_IN_BPS) revert InvalidAcceptableRebaseApr();
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

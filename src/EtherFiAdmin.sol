// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IEtherFiOracle.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IMembershipManager.sol";
import "./interfaces/IWithdrawRequestNFT.sol";

interface IEtherFiPausable {
    function paused() external view returns (bool);
}

contract EtherFiAdmin is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    IEtherFiOracle public etherFiOracle;
    IStakingManager public stakingManager;
    IAuctionManager public auctionManager;
    IEtherFiNodesManager public etherFiNodesManager;
    ILiquidityPool public liquidityPool;
    IMembershipManager public membershipManager;
    IWithdrawRequestNFT public withdrawRequestNft;

    mapping(address => bool) public admins;

    uint32 public lastHandledReportRefSlot;
    uint32 public lastHandledReportRefBlock;
    uint32 public numValidatorsToSpinUp;

    int32 public acceptableRebaseAprInBps;

    uint16 public postReportWaitTimeInSlots;
    uint32 public lastAdminExecutionBlock;

    mapping(address => bool) public pausers;

    event AdminUpdated(address _address, bool _isAdmin);
    event AdminOperationsExecuted(address indexed _address, bytes32 indexed _reportHash);

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
    function pause(bool _etherFiOracle, bool _stakingManager, bool _auctionManager, bool _etherFiNodesManager, bool _liquidityPool, bool _membershipManager) external isPauser() {
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

    function unPause(bool _etherFiOracle, bool _stakingManager, bool _auctionManager, bool _etherFiNodesManager, bool _liquidityPool, bool _membershipManager) external onlyOwner {
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

    function canExecuteTasks(IEtherFiOracle.OracleReport calldata _report) external view returns (bool) {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);

        if (!etherFiOracle.isConsensusReached(reportHash)) return false;
        if (slotForNextReportToProcess() != _report.refSlotFrom) return false;
        if (blockForNextReportToProcess() != _report.refBlockFrom) return false;
        if (current_slot < postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(reportHash)) return false;
        return true;
    }

    function executeTasks(IEtherFiOracle.OracleReport calldata _report, bytes[] calldata _pubKey, bytes[] calldata _signature) external isAdmin() {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        uint32 current_slot = etherFiOracle.computeSlotAtTimestamp(block.timestamp);
        require(etherFiOracle.isConsensusReached(reportHash), "EtherFiAdmin: report didn't reach consensus");
        require(slotForNextReportToProcess() == _report.refSlotFrom, "EtherFiAdmin: report has wrong `refSlotFrom`");
        require(blockForNextReportToProcess() == _report.refBlockFrom, "EtherFiAdmin: report has wrong `refBlockFrom`");
        require(current_slot >= postReportWaitTimeInSlots + etherFiOracle.getConsensusSlot(reportHash), "EtherFiAdmin: report is too fresh");

        numValidatorsToSpinUp = _report.numValidatorsToSpinUp;

        _handleAccruedRewards(_report);
        _handleProtocolFees(_report);
        _handleValidators(_report, _pubKey, _signature);
        _handleWithdrawals(_report);
        _handleTargetFundsAllocations(_report);

        lastHandledReportRefSlot = _report.refSlotTo;
        lastHandledReportRefBlock = _report.refBlockTo;
        lastAdminExecutionBlock = uint32(block.number);

        emit AdminOperationsExecuted(msg.sender, reportHash);
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

    function _handleValidators(IEtherFiOracle.OracleReport calldata _report, bytes[] calldata _pubKey, bytes[] calldata _signature) internal {
        // validatorsToApprove
        if (_report.validatorsToApprove.length > 0) {
            liquidityPool.batchApproveRegistration(_report.validatorsToApprove, _pubKey, _signature);
        }

        // liquidityPoolValidatorsToExit
        if (_report.liquidityPoolValidatorsToExit.length > 0) {
            liquidityPool.sendExitRequests(_report.liquidityPoolValidatorsToExit);
        }

        // exitedValidators
        if (_report.exitedValidators.length > 0) {
            etherFiNodesManager.processNodeExit(_report.exitedValidators, _report.exitedValidatorsExitTimestamps);
        }

        // slashedValidators
        if (_report.slashedValidators.length > 0) {
            etherFiNodesManager.markBeingSlashed(_report.slashedValidators);
        }
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

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;

        emit AdminUpdated(_address, _isAdmin);
    }

    function updatePauser(address _address, bool _isPauser) external onlyOwner {
        pausers[_address] = _isPauser;
    }

    function updateAcceptableRebaseApr(int32 _acceptableRebaseAprInBps) external onlyOwner {
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
    }

    function updatePostReportWaitTimeInSlots(uint16 _postReportWaitTimeInSlots) external isAdmin {
        postReportWaitTimeInSlots = _postReportWaitTimeInSlots;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


    modifier isAdmin() {
        require(admins[msg.sender] || msg.sender == owner(), "EtherFiAdmin: not an admin");
        _;
    }

    modifier isPauser() {
        require(pausers[msg.sender] || msg.sender == owner(), "EtherFiAdmin: not a pauser");
        _;
    }
}
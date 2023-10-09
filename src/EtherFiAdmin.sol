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

import "forge-std/console.sol";

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
        int32 _acceptableRebaseAprInBps
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
    }

    function executeTasks(IEtherFiOracle.OracleReport calldata _report, bytes[] calldata _pubKey, bytes[] calldata _signature) external isAdmin() {
        bytes32 reportHash = etherFiOracle.generateReportHash(_report);
        require(etherFiOracle.isConsensusReached(reportHash), "EtherFiAdmin: report didn't reach consensus");
        require(slotForNextReportToProcess() == _report.refSlotFrom, "EtherFiAdmin: report has wrong `refSlotFrom`");
        require(blockForNextReportToProcess() == _report.refBlockFrom, "EtherFiAdmin: report has wrong `refBlockFrom`");

        //The number of validators for the current scheduling period we can spin up
        //Important variable when calculating how many BNFT players to assign for the scheduling period
        //See natspec in LP for more information
        numValidatorsToSpinUp = _report.numValidatorsToSpinUp;

        _handleAccruedRewards(_report);
        _handleValidators(_report, _pubKey, _signature);
        _handleWithdrawals(_report);
        _handleTargetFundsAllocations(_report);

        lastHandledReportRefSlot = _report.refSlotTo;
        lastHandledReportRefBlock = _report.refBlockTo;

        emit AdminOperationsExecuted(msg.sender, reportHash);
    }

    function _handleAccruedRewards(IEtherFiOracle.OracleReport calldata _report) internal {
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
        liquidityPool.batchApproveRegistration(_report.validatorsToApprove, _pubKey, _signature);

        // liquidityPoolValidatorsToExit
        liquidityPool.sendExitRequests(_report.liquidityPoolValidatorsToExit);

        // exitedValidators
        etherFiNodesManager.processNodeExit(_report.exitedValidators, _report.exitedValidatorsExitTimestamps);

        // slashedValidators
        etherFiNodesManager.markBeingSlashed(_report.slashedValidators);
    }

    function _handleWithdrawals(IEtherFiOracle.OracleReport calldata _report) internal {
        for (uint256 i = 0; i < _report.withdrawalRequestsToInvalidate.length; i++) {
            withdrawRequestNft.invalidateRequest(_report.withdrawalRequestsToInvalidate[i]);
        }
        withdrawRequestNft.finalizeRequests(_report.lastFinalizedWithdrawalRequestId);

        liquidityPool.addEthAmountLockedForWithdrawal(_report.finalizedWithdrawalAmount);
    }

    function _handleTargetFundsAllocations(IEtherFiOracle.OracleReport calldata _report) internal {
        if (_report.eEthTargetAllocationWeight == 0 || _report.etherFanTargetAllocationWeight == 0) {
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

    function updateAcceptableRebaseApr(int32 _acceptableRebaseAprInBps) external onlyOwner {
        acceptableRebaseAprInBps = _acceptableRebaseAprInBps;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


    modifier isAdmin() {
        require(admins[msg.sender], "EtherFiAdmin: not an admin");
        _;
    }
}
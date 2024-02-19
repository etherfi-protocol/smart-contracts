// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IProtocolRevenueManager.sol";
import "./interfaces/IStakingManager.sol";
import "./TNFT.sol";
import "./BNFT.sol";


contract EtherFiNodesManager is
    Initializable,
    IEtherFiNodesManager,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    uint64 public numberOfValidators;
    uint64 public nonExitPenaltyPrincipal;
    uint64 public nonExitPenaltyDailyRate; // in basis points
    uint64 public SCALE;

    address public treasuryContract;
    address public stakingManagerContract;
    address public DEPRECATED_protocolRevenueManagerContract;

    // validatorId == bidId -> withdrawalSafeAddress
    mapping(uint256 => address) public etherfiNodeAddress;

    TNFT public tnft;
    BNFT public bnft;
    IAuctionManager public auctionManager;
    IProtocolRevenueManager public DEPRECATED_protocolRevenueManager;

    //Holds the data for the revenue splits depending on where the funds are received from
    RewardsSplit public stakingRewardsSplit;
    RewardsSplit public DEPRECATED_protocolRewardsSplit;

    address public DEPRECATED_admin;
    mapping(address => bool) public admins;

    IEigenPodManager public eigenPodManager;
    IDelayedWithdrawalRouter public delayedWithdrawalRouter;
    // max number of queued eigenlayer withdrawals to attempt to claim in a single tx
    uint8 public maxEigenlayerWithdrawals;

    // stack of re-usable withdrawal safes to save gas
    address[] public unusedWithdrawalSafes;

    bool public enableNodeRecycling;

    mapping(uint256 => ValidatorInfo) private validatorInfos;

    IDelegationManager public delegationManager;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event FundsWithdrawn(uint256 indexed _validatorId, uint256 amount);
    event NodeExitRequested(uint256 _validatorId);
    event NodeExitRequestReverted(uint256 _validatorId);
    event NodeExitProcessed(uint256 _validatorId);
    event NodeEvicted(uint256 _validatorId);
    event PhaseChanged(uint256 indexed _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase);

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    error InvalidParams();
    error NonZeroAddress();

    /// @dev Sets the revenue splits on deployment
    /// @dev AuctionManager, treasury and deposit contracts must be deployed first
    /// @param _treasuryContract The address of the treasury contract for interaction
    /// @param _auctionContract The address of the auction contract for interaction
    /// @param _stakingManagerContract The address of the staking contract for interaction
    /// @param _tnftContract The address of the TNFT contract for interaction
    /// @param _bnftContract The address of the BNFT contract for interaction
    function initialize(
        address _treasuryContract,
        address _auctionContract,
        address _stakingManagerContract,
        address _tnftContract,
        address _bnftContract
    ) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        SCALE = 1_000_000;

        treasuryContract = _treasuryContract;
        stakingManagerContract = _stakingManagerContract;

        auctionManager = IAuctionManager(_auctionContract);
        tnft = TNFT(_tnftContract);
        bnft = BNFT(_bnftContract);
    }

    function initializeOnUpgrade(address _etherFiAdmin, address _eigenPodManager, address _delayedWithdrawalRouter, uint8 _maxEigenlayerWithdrawals) public onlyOwner {
        admins[_etherFiAdmin] = true;
        eigenPodManager = IEigenPodManager(_eigenPodManager);
        delayedWithdrawalRouter = IDelayedWithdrawalRouter(_delayedWithdrawalRouter);
        maxEigenlayerWithdrawals = _maxEigenlayerWithdrawals;
    }

    error NotTnftOwner();
    error ValidatorNotLive();
    error ValidatorNotExited();

    /// @notice Send the request to exit the validators as their T-NFT holder
    /// @param _validatorIds IDs of the validators
    function batchSendExitRequest(uint256[] calldata _validatorIds) external whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _sendExitRequest(_validatorIds[i]);
        }
    }

    /// @notice Revert the exit request for the validators as their T-NFT holder
    /// @param _validatorIds IDs of the validators
    function batchRevertExitRequest(uint256[] calldata _validatorIds) external whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _revertExitRequest(_validatorIds[i]);
        }
    }

    /// @notice Once the node's exit & funds withdrawal from Beacon is observed, the protocol calls this function to process their exits.
    /// @param _validatorIds The list of validators which exited
    /// @param _exitTimestamps The list of exit timestamps of the validators
    function processNodeExit(
        uint256[] calldata _validatorIds,
        uint32[] calldata _exitTimestamps
    ) external onlyAdmin nonReentrant whenNotPaused {
        if (_validatorIds.length != _exitTimestamps.length) revert InvalidParams();
        
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _processNodeExit(_validatorIds[i], _exitTimestamps[i]);
        }
    }

    /// @notice queue a withdrawal of eth from an eigenPod. You must wait for the queuing period
    ///         defined by eigenLayer before you can finish the withdrawal via etherFiNode.claimQueuedWithdrawals()
    /// @param _validatorIds The validator Ids
    function batchQueueRestakedWithdrawal(uint256[] calldata _validatorIds) public whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address etherfiNode = etherfiNodeAddress[_validatorIds[i]];
            IEtherFiNode(etherfiNode).queueRestakedWithdrawal();
        }
    }

    /// @notice Process the rewards skimming from the safe of the validator
    ///         when the safe is being shared by the multiple validatators, it batch process all of their rewards skimming in one shot
    /// @param _validatorId The validator Id
    function partialWithdraw(uint256 _validatorId) public nonReentrant whenNotPaused {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        _updateEtherFiNode(_validatorId);

        // sweep rewards from eigenPod if any queued withdrawals are ready to be claimed
        IEtherFiNode(etherfiNode).claimQueuedWithdrawals(maxEigenlayerWithdrawals, false);

        // distribute the rewards payouts. It reverts if the safe's balance >= 16 ether
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury ) = _getTotalRewardsPayoutsFromSafe(_validatorId);
        _distributePayouts(etherfiNode, _validatorId, toTreasury, toOperator, toTnft, toBnft);
    }

    function batchPartialWithdraw(uint256[] calldata _validatorIds) external whenNotPaused{
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            partialWithdraw( _validatorIds[i]);
        }
    }

    /// @notice process the full withdrawal
    /// @dev This fullWithdrawal is allowed only after it's marked as EXITED.
    /// @dev EtherFi will be monitoring the status of the validator nodes and mark them EXITED if they do;
    /// @dev It is a point of centralization in Phase 1
    /// @param _validatorId the validator Id to withdraw from
    function fullWithdraw(uint256 _validatorId) public nonReentrant whenNotPaused{
        address etherfiNode = etherfiNodeAddress[_validatorId];
        _updateEtherFiNode(_validatorId);
        require (!IEtherFiNode(etherfiNode).claimQueuedWithdrawals(maxEigenlayerWithdrawals, true), "PENDING_WITHDRAWALS");
        
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = getFullWithdrawalPayouts(_validatorId);
        _unRegisterValidator(_validatorId);
        _distributePayouts(etherfiNode, _validatorId, toTreasury, toOperator, toTnft, toBnft);

        tnft.burnFromWithdrawal(_validatorId);
        bnft.burnFromWithdrawal(_validatorId);
    }

    /// @notice Process the full withdrawal for multiple validators
    /// @param _validatorIds The validator Ids
    function batchFullWithdraw(uint256[] calldata _validatorIds) external whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            fullWithdraw(_validatorIds[i]);
        }
    }

    /// @notice Once the Oracle observes that the validator is being slashed, the protocol calls this function to mark the validator as being slashed
    ///         The validator marked as being slashed must exit in order to withdraw funds
    /// @param _validatorIds The validator Ids
    function markBeingSlashed(
        uint256[] calldata _validatorIds
    ) external whenNotPaused onlyAdmin {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _updateEtherFiNode(_validatorIds[i]);
            _setValidatorPhase(etherfiNodeAddress[_validatorIds[i]], _validatorIds[i], IEtherFiNode.VALIDATOR_PHASE.BEING_SLASHED);
        }
    }

    /// @dev create a new proxy instance of the etherFiNode withdrawal safe contract.
    /// @param _createEigenPod whether or not to create an associated eigenPod contract.
    function instantiateEtherFiNode(bool _createEigenPod) internal returns (address) {
        BeaconProxy proxy = new BeaconProxy(IStakingManager(stakingManagerContract).getEtherFiNodeBeacon(), "");
        address node = address(proxy);
        IEtherFiNode(node).initialize(address(this));
        if (_createEigenPod) {
            IEtherFiNode(node).createEigenPod();
        }
        return node;
    }

    /// @dev instantiate EtherFiNode and EigenPod proxy instances
    /// @param _count How many instances to create
    /// @param _enableRestaking Whether or not to instantiate an associated eigenPod. (This can still be done later)
    function createUnusedWithdrawalSafe(uint256 _count, bool _enableRestaking) external returns (address[] memory) {
        address[] memory createdSafes = new address[](_count);
        for (uint256 i = 0; i < _count; i++) {
            address newNode = instantiateEtherFiNode(_enableRestaking);
            unusedWithdrawalSafes.push(newNode);

            createdSafes[i] = address(newNode);
        }
        return createdSafes;
    }

    error AlreadyInstalled();
    error NotInstalled();
    error InvalidEtherFiNodeVersion();

    function allocateEtherFiNode(bool _enableRestaking) external onlyStakingManagerContract returns (address withdrawalSafeAddress) {
        // can I re-use an existing safe
        if (unusedWithdrawalSafes.length > 0 && enableNodeRecycling) {
            // pop
            withdrawalSafeAddress = unusedWithdrawalSafes[unusedWithdrawalSafes.length-1];
            unusedWithdrawalSafes.pop();
        } else {
            // make a new one
            withdrawalSafeAddress = instantiateEtherFiNode(_enableRestaking);
        }

        // make sure the safe is migrated to v1
        IEtherFiNode(withdrawalSafeAddress).migrateVersion(0);
    }

    function updateEtherFiNode(uint256 _validatorId) external onlyStakingManagerContract {
        _updateEtherFiNode(_validatorId);
    }

    function _updateEtherFiNode(uint256 _validatorId) internal {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        if (IEtherFiNode(etherfiNode).version() != 0) return;

        validatorInfos[_validatorId] = ValidatorInfo({
            validatorIndex: 0, // not initialized yet. TODO: update it by the Oracle
            exitRequestTimestamp: IEtherFiNode(etherfiNode).DEPRECATED_exitRequestTimestamp(),
            exitTimestamp: IEtherFiNode(etherfiNode).DEPRECATED_exitTimestamp(),
            phase: IEtherFiNode(etherfiNode).DEPRECATED_phase()
        });
        IEtherFiNode(etherfiNode).migrateVersion(_validatorId);
    }

    /// @notice Registers the validator with the EtherFiNode contract
    /// @param _validatorId ID of the validator associated to the node
    /// @param _enableRestaking whether or not to enable restaking
    /// @param _withdrawalSafeAddress address of the withdrawal safe
    function registerValidator(uint256 _validatorId, bool _enableRestaking, address _withdrawalSafeAddress) external onlyStakingManagerContract {
        if (etherfiNodeAddress[_validatorId] != address(0)) revert AlreadyInstalled();
        if (IEtherFiNode(_withdrawalSafeAddress).version() != 1) revert InvalidEtherFiNodeVersion();

        etherfiNodeAddress[_validatorId] = _withdrawalSafeAddress;

        IEtherFiNode(_withdrawalSafeAddress).registerValidator(_validatorId, _enableRestaking);
        _setValidatorPhase(_withdrawalSafeAddress, _validatorId, IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED);
    }

    /// @notice Unset the EtherFiNode contract for the validator ID
    /// @param _validatorId ID of the validator associated
    function unregisterValidator(uint256 _validatorId) external onlyStakingManagerContract {
        _unRegisterValidator(_validatorId);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  SETTER   --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Sets the staking rewards split
    /// @notice Splits must add up to the SCALE of 1_000_000
    /// @param _treasury the split going to the treasury
    /// @param _nodeOperator the split going to the nodeOperator
    /// @param _tnft the split going to the tnft holder
    /// @param _bnft the split going to the bnft holder
    function setStakingRewardsSplit(uint64 _treasury, uint64 _nodeOperator, uint64 _tnft, uint64 _bnft)
        public onlyAdmin
    {
        if (_treasury + _nodeOperator + _tnft + _bnft != SCALE) revert InvalidParams();
        stakingRewardsSplit.treasury = _treasury;
        stakingRewardsSplit.nodeOperator = _nodeOperator;
        stakingRewardsSplit.tnft = _tnft;
        stakingRewardsSplit.bnft = _bnft;
    }

    error InvalidPenaltyRate();
    /// @notice Sets the Non Exit Penalty 
    /// @param _nonExitPenaltyPrincipal the new principal amount
    /// @param _nonExitPenaltyDailyRate the new non exit daily rate
    function setNonExitPenalty(uint64 _nonExitPenaltyDailyRate, uint64 _nonExitPenaltyPrincipal) public onlyAdmin {
        if(_nonExitPenaltyDailyRate > 10000) revert InvalidPenaltyRate();
        nonExitPenaltyPrincipal = _nonExitPenaltyPrincipal;
        nonExitPenaltyDailyRate = _nonExitPenaltyDailyRate;
    }


    /// @notice Sets the phase of the validator
    /// @param _validatorId id of the validator associated to this etherfi node
    /// @param _phase phase of the validator
    function setValidatorPhase(uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase) public onlyStakingManagerContract {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        _setValidatorPhase(etherfiNode, _validatorId, _phase);
    }

    /// @notice set maximum number of queued eigenlayer withdrawals that can be processed in 1 tx
    /// @param _max max number of queued withdrawals
    function setMaxEigenLayerWithdrawals(uint8 _max) external onlyAdmin {
        maxEigenlayerWithdrawals = _max;
    }

    /// @notice set whether newly spun up validators should use a previously recycled node (if available) to save gas
    function setEnableNodeRecycling(bool _enabled) external onlyAdmin {
        enableNodeRecycling = _enabled;
    }

    /// @notice Increments the number of validators by a certain amount
    /// @param _count how many new validators to increment by
    function incrementNumberOfValidators(uint64 _count) external onlyStakingManagerContract {
        numberOfValidators += _count;
    }

    /// @notice Updates the address of the admin
    /// @param _address the new address to set as admin
    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    //Pauses the contract
    function pauseContract() external onlyAdmin {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyAdmin {
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Once the node's exit is observed, the protocol calls this function:
    ///         - mark it EXITED
    /// @param _validatorId the validator ID
    /// @param _exitTimestamp the exit timestamp
    function _processNodeExit(uint256 _validatorId, uint32 _exitTimestamp) internal {
        _updateEtherFiNode(_validatorId);

        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).processNodeExit();
        validatorInfos[_validatorId].exitTimestamp = _exitTimestamp;

        _setValidatorPhase(etherfiNode, _validatorId, IEtherFiNode.VALIDATOR_PHASE.EXITED);

        numberOfValidators -= 1;

        emit NodeExitProcessed(_validatorId);
    }

    function _sendExitRequest(uint256 _validatorId) internal {
        if (msg.sender != tnft.ownerOf(_validatorId)) revert NotTnftOwner();
        if (phase(_validatorId) != IEtherFiNode.VALIDATOR_PHASE.LIVE) revert ValidatorNotLive();

        _updateEtherFiNode(_validatorId);

        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).updateNumExitRequests(1, 0);
        validatorInfos[_validatorId].exitRequestTimestamp = uint32(block.timestamp);

        emit NodeExitRequested(_validatorId);
    }

    function _revertExitRequest(uint256 _validatorId) internal {
        if (msg.sender != tnft.ownerOf(_validatorId)) revert NotTnftOwner();

        _updateEtherFiNode(_validatorId);

        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).updateNumExitRequests(0, 1);
        validatorInfos[_validatorId].exitRequestTimestamp = 0;

        emit NodeExitRequestReverted(_validatorId);
    }

    function _setValidatorPhase(address _node, uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _newPhase) internal {
        IEtherFiNode(_node).validatePhaseTransition(phase(_validatorId), _newPhase);
        validatorInfos[_validatorId].phase = _newPhase;

        emit PhaseChanged(_validatorId, _newPhase);
    }

    function _unRegisterValidator(uint256 _validatorId) internal {
        address safeAddress = etherfiNodeAddress[_validatorId];
        if (safeAddress == address(0)) revert NotInstalled();

        if (phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.EXITED) {
            _setValidatorPhase(safeAddress, _validatorId, IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN);
        } else {
            _setValidatorPhase(safeAddress, _validatorId, IEtherFiNode.VALIDATOR_PHASE.NOT_INITIALIZED);
        }

        // If there was an exit request, decrement the number of exit requests
        if (validatorInfos[_validatorId].exitRequestTimestamp != 0) {
            IEtherFiNode(safeAddress).updateNumExitRequests(0, 1);
        }
        IEtherFiNode(safeAddress).unRegisterValidator(_validatorId);

        delete etherfiNodeAddress[_validatorId];
        // delete validatorInfos[_validatorId];

        if (IEtherFiNode(safeAddress).numAssociatedValidators() == 0) {
            unusedWithdrawalSafes.push(safeAddress);
        }
    }

    // it returns the "total" payout amounts from the safe that the validator is associated with
    // it performs some sanity-checks on the validator status, safe balance
    function _getTotalRewardsPayoutsFromSafe(
        uint256 _validatorId
    ) internal view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        require(phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.LIVE, "Must be LIVE");
        address etherfiNode = etherfiNodeAddress[_validatorId];
        require(address(etherfiNode).balance < 16 ether, "balance >= 16 ETH");
        require(IEtherFiNode(etherfiNode).numExitRequestsByTnft() == 0, "PENDING_EXIT_REQUEST");

        return IEtherFiNode(etherfiNode).getRewardsPayouts(
            validatorInfos[_validatorId].exitRequestTimestamp,
            stakingRewardsSplit
        );
    }

    function _distributePayouts(address _etherfiNode, uint256 _validatorId, uint256 _toTreasury, uint256 _toOperator, uint256 _toTnft, uint256 _toBnft) internal {
        IEtherFiNode(_etherfiNode).withdrawFunds(
            treasuryContract, _toTreasury,
            auctionManager.getBidOwner(_validatorId), _toOperator,
            tnft.ownerOf(_validatorId), _toTnft,
            bnft.ownerOf(_validatorId), _toBnft
        );
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


    //--------------------------------------------------------------------------------------
    //-------------------------------------  GETTER   --------------------------------------
    //--------------------------------------------------------------------------------------

    function numAssociatedValidators(uint256 _validatorId) external view returns (uint256) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        if (etherfiNode == address(0)) return 0;
        return IEtherFiNode(etherfiNode).numAssociatedValidators();
    }

    /// @notice Fetches the phase a specific node is in
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return validatorPhase the phase the node is in
    function phase(uint256 _validatorId) public view returns (IEtherFiNode.VALIDATOR_PHASE validatorPhase) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        ValidatorInfo memory info = validatorInfos[_validatorId];
        if (info.exitTimestamp == 0) {
            if (etherfiNode == address(0)) {
                validatorPhase = IEtherFiNode.VALIDATOR_PHASE.NOT_INITIALIZED;
            } else if (IEtherFiNode(etherfiNode).version() == 0) {
                validatorPhase = IEtherFiNode(etherfiNode).DEPRECATED_phase();
            } else {
                validatorPhase = info.phase;
            }
        } else {
            validatorPhase = info.phase;
        }
    }

    /// @notice Generates withdraw credentials for a validator
    /// @param _address associated with the validator for the withdraw credentials
    /// @return the generated withdraw key for the node
    function generateWithdrawalCredentials(address _address) public pure returns (bytes memory) {   
        return abi.encodePacked(bytes1(0x01), bytes11(0x0), _address);
    }

    /// @notice get the length of the unusedWithdrawalSafes array
    function getUnusedWithdrawalSafesLength() external view returns (uint256) {
        return unusedWithdrawalSafes.length;
    }

    function getWithdrawalSafeAddress(uint256 _validatorId) public view returns (address) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        return IEtherFiNode(etherfiNode).isRestakingEnabled() ? IEtherFiNode(etherfiNode).eigenPod() : etherfiNode;
    }

    /// @notice Fetches the withdraw credentials for a specific node
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return the generated withdraw key for the node
    function getWithdrawalCredentials(uint256 _validatorId) external view returns (bytes memory) {
        return generateWithdrawalCredentials(getWithdrawalSafeAddress(_validatorId));
    }

    /// @notice Fetches if the node has an exit request
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return bool value based on if an exit request has been sent
    function isExitRequested(uint256 _validatorId) external view returns (bool) {
        ValidatorInfo memory info = getValidatorInfo(_validatorId);
        return info.exitRequestTimestamp > 0;
    }

    /// @notice Fetches the nodes non exit penalty amount
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return nonExitPenalty the amount of the penalty
    function getNonExitPenalty(uint256 _validatorId) public view returns (uint256 nonExitPenalty) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        ValidatorInfo memory info = getValidatorInfo(_validatorId);
        return IEtherFiNode(etherfiNode).getNonExitPenalty(info.exitRequestTimestamp, info.exitTimestamp);
    }

    function getValidatorInfo(uint256 _validatorId) public view returns (ValidatorInfo memory) {
        ValidatorInfo memory info = validatorInfos[_validatorId];
        info.phase = phase(_validatorId);
        return info;
    }

    /// @notice Get the rewards payouts for a specific validator = (total payouts from the safe / N) where N is the number of the validators associated with the same safe
    /// @param _validatorId ID of the validator
    ///
    /// @return toNodeOperator  the TVL for the Node Operator
    /// @return toTnft          the TVL for the T-NFT holder
    /// @return toBnft          the TVL for the B-NFT holder
    /// @return toTreasury      the TVL for the Treasury
    function getRewardsPayouts(
        uint256 _validatorId
    ) public view returns (uint256, uint256, uint256, uint256) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        uint256 n = IEtherFiNode(etherfiNode).numAssociatedValidators();
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury ) = _getTotalRewardsPayoutsFromSafe(_validatorId);
        return (toOperator / n, toTnft / n, toBnft / n, toTreasury / n);
    }

    /// @notice Fetches the full withdraw payouts for a specific validator
    /// @param _validatorId id of the validator associated to etherfi node
    ///
    /// @return toNodeOperator  the TVL for the Node Operator
    /// @return toTnft          the TVL for the T-NFT holder
    /// @return toBnft          the TVL for the B-NFT holder
    /// @return toTreasury      the TVL for the Treasury
    function getFullWithdrawalPayouts(
        uint256 _validatorId
    ) public view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        require(phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.EXITED, "NOT_EXITED");

        address etherfiNode = etherfiNodeAddress[_validatorId];
        return IEtherFiNode(etherfiNode).getFullWithdrawalPayouts(getValidatorInfo(_validatorId), stakingRewardsSplit);
    }

    /// @notice Compute the TVLs for {node operator, t-nft holder, b-nft holder, treasury}
    /// @param _validatorId id of the validator associated to etherfi node
    /// @param _beaconBalance the balance of the validator in Consensus Layer
    ///
    /// @return toNodeOperator  the TVL for the Node Operator
    /// @return toTnft          the TVL for the T-NFT holder
    /// @return toBnft          the TVL for the B-NFT holder
    /// @return toTreasury      the TVL for the Treasury
    function calculateTVL(
        uint256 _validatorId,
        uint256 _beaconBalance
    ) public view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        return IEtherFiNode(etherfiNode).calculateTVL(_beaconBalance, getValidatorInfo(_validatorId), stakingRewardsSplit, false);
    }

    /// @notice return the eigenpod associated with the etherFiNode connected to the provided validator
    /// @dev The existence of a connected eigenpod does not imply the node is currently configured for restaking.
    ///      use isRestakingEnabled() instead
    function getEigenPod(uint256 _validatorId) public view returns (address) {
        IEtherFiNode etherfiNode = IEtherFiNode(etherfiNodeAddress[_validatorId]);
        return etherfiNode.eigenPod();
    }

    /// @notice return whether the provided validator is configured for restaknig via eigenLayer
    function isRestakingEnabled(uint256 _validatorId) public view returns (bool) {
        IEtherFiNode etherfiNode = IEtherFiNode(etherfiNodeAddress[_validatorId]);
        return etherfiNode.isRestakingEnabled();
    }

    /// @notice Fetches the address of the implementation contract currently being used by the proxy
    /// @return The address of the currently used implementation contract
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    error NotStakingManager();

    function _requireAdmin() internal view virtual {
        require(admins[msg.sender] || msg.sender == owner(), "Not admin");
    }

    function _onlyStakingManagerContract() internal view virtual {
        if (msg.sender != stakingManagerContract) revert NotStakingManager();
    }


    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyStakingManagerContract() {
        _onlyStakingManagerContract();
        _;
    }

    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }
}

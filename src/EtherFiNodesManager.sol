// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "./RoleRegistry.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IProtocolRevenueManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IPausable.sol";
import "./TNFT.sol";
import "./BNFT.sol";
import "forge-std/console.sol";


contract EtherFiNodesManager is
    Initializable,
    IEtherFiNodesManager,
    IPausable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    uint64 public numberOfValidators; // # of validators in LIVE or WAITING_FOR_APPROVAL phases
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
    address public DEPRECATED_protocolRevenueManager;

    RewardsSplit public stakingRewardsSplit;
    uint256 public DEPRECATED_protocolRewardsSplit;

    address public DEPRECATED_admin;
    mapping(address => bool) public DEPRECATED_admins;

    IEigenPodManager public eigenPodManager;
    IDelayedWithdrawalRouter public DEPRECATED_delayedWithdrawalRouter;
    uint8 public DEPRECATED_maxEigenlayerWithdrawals;

    // stack of re-usable withdrawal safes to save gas
    address[] public unusedWithdrawalSafes;

    bool public DEPRECATED_enableNodeRecycling;

    mapping(uint256 => ValidatorInfo) private validatorInfos;

    IDelegationManager public delegationManager;

    mapping(address => bool) public DEPRECATED_eigenLayerOperatingAdmin;

    RoleRegistry public roleRegistry;
    // function -> allowed
    mapping(bytes4 => bool) public allowedForwardedEigenpodCalls;
    // function -> target_address -> allowed
    mapping(bytes4 => mapping(address => bool)) public allowedForwardedExternalCalls;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 constant public NODE_ADMIN_ROLE = keccak256("EFNM_NODE_ADMIN_ROLE");
    bytes32 constant public WHITELIST_UPDATER = keccak256("EFNM_WHITELIST_UPDATER");
    bytes32 constant public EIGENPOD_CALLER_ROLE = keccak256("EFNM_EIGENPOD_CALLER_ROLE");
    bytes32 constant public EXTERNAL_CALLER_ROLE = keccak256("EFNM_EXTERNAL_CALLER_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event FundsWithdrawn(uint256 indexed _validatorId, uint256 amount);
    event NodeExitRequested(uint256 _validatorId);
    event NodeExitRequestReverted(uint256 _validatorId);
    event NodeExitProcessed(uint256 _validatorId);
    event NodeEvicted(uint256 _validatorId);
    event PhaseChanged(uint256 indexed _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase);

    event PartialWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
    event FullWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
    event QueuedRestakingWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, bytes32[] withdrawalRoots);

    event AllowedForwardedExternalCallsUpdated(bytes4 indexed selector, address indexed _target, bool _allowed);
    event AllowedForwardedEigenpodCallsUpdated(bytes4 indexed selector, bool _allowed);

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
    error IncorrectRole();
    error ForwardedCallNotAllowed();
    error InvalidForwardedCall();

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
        address _bnftContract,
        address _eigenPodManager, 
        address _delayedWithdrawalRouter,
        address _delegationManager
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

        eigenPodManager = IEigenPodManager(_eigenPodManager);
        DEPRECATED_delayedWithdrawalRouter = IDelayedWithdrawalRouter(_delayedWithdrawalRouter);
        delegationManager = IDelegationManager(_delegationManager);
    }

    function initializeV2dot5(address _roleRegistry) external onlyOwner {
        require(address(roleRegistry) == address(0x00), "already initialized");

        // clear out deprecated variables so its easier for us to re-initialize in future
        DEPRECATED_protocolRevenueManagerContract = address(0x0);
        DEPRECATED_protocolRevenueManager = address(0x0);
        DEPRECATED_protocolRewardsSplit = 0;
        DEPRECATED_admin = address(0x0);
        DEPRECATED_enableNodeRecycling = false;
        DEPRECATED_maxEigenlayerWithdrawals = 0;

        // TODO: compile list of values in DEPRECATED_admins to clear out
        // TODO: compile list of values in DEPRECATED_eigenLayerOperatingAdmin to clear out

        roleRegistry = RoleRegistry(_roleRegistry);
    }


    /// @notice Send the request to exit the validators as their T-NFT holder
    ///         The B-NFT holder must serve the request otherwise their bond will get penalized gradually
    /// @param _validatorIds IDs of the validators
    function batchSendExitRequest(uint256[] calldata _validatorIds) external whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            uint256 _validatorId = _validatorIds[i];
            address etherfiNode = etherfiNodeAddress[_validatorId];

            // require (msg.sender == tnft.ownerOf(_validatorId), "NOT_TNFT_OWNER");
            // require (phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.LIVE, "NOT_LIVE");
            // require (!isExitRequested(_validatorId), "ASKED");
            require (msg.sender == tnft.ownerOf(_validatorId) && phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.LIVE && !isExitRequested(_validatorId), "INVALID");

            _updateEtherFiNode(_validatorId);
            _updateExitRequestTimestamp(_validatorId, etherfiNode, uint32(block.timestamp));

            emit NodeExitRequested(_validatorId);
        }
    }


    /// @notice Once the node's exit & funds withdrawal from Beacon is observed, the protocol calls this function to process their exits.
    /// @param _validatorIds The list of validators which exited
    /// @param _exitTimestamps The list of exit timestamps of the validators
    function processNodeExit(
        uint256[] calldata _validatorIds,
        uint32[] calldata _exitTimestamps
    ) external nonReentrant whenNotPaused {
        if (!roleRegistry.hasRole(NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (_validatorIds.length != _exitTimestamps.length) revert InvalidParams();

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            uint256 _validatorId = _validatorIds[i];
            address etherfiNode = etherfiNodeAddress[_validatorId];

            _updateEtherFiNode(_validatorId);

            bytes32[] memory withdrawalRoots = IEtherFiNode(etherfiNode).processNodeExit(_validatorId);
            validatorInfos[_validatorId].exitTimestamp = _exitTimestamps[i];

            _setValidatorPhase(etherfiNode, _validatorId, IEtherFiNode.VALIDATOR_PHASE.EXITED);

            numberOfValidators -= 1;

            emit NodeExitProcessed(_validatorId);
            emit QueuedRestakingWithdrawal(_validatorId, etherfiNode, withdrawalRoots);
        }
    }

    /// @notice queue a withdrawal of eth from an eigenPod. You must wait for the queuing period
    ///         defined by eigenLayer before you can finish the withdrawal via etherFiNode.claimDelayedWithdrawalRouterWithdrawals()
    /// @param _validatorIds The validator Ids
    function batchQueueRestakedWithdrawal(uint256[] calldata _validatorIds) public whenNotPaused {
        if (!roleRegistry.hasRole(NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address etherfiNode = etherfiNodeAddress[_validatorIds[i]];
            IEtherFiNode(etherfiNode).queueEigenpodFullWithdrawal();
        }
    }

    function completeQueuedWithdrawals(uint256[] calldata _validatorIds, IDelegationManager.Withdrawal[] memory withdrawals, uint256[] calldata middlewareTimesIndexes, bool _receiveAsTokens) external {
        if (!roleRegistry.hasRole(NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address etherfiNode = etherfiNodeAddress[_validatorIds[i]];
            IEtherFiNode(etherfiNode).completeQueuedWithdrawal(withdrawals[i], middlewareTimesIndexes[i], _receiveAsTokens);
        }
    }

    /// @dev With Eigenlayer's PEPE model, shares are at the pod level, not validator level
    ///      so uncareful use of this function will result in distributing rewards from
    ///      mulitiple validators, not just the rewards of the provided ID. We fundamentally should
    ///      rework this mechanism as it no longer makes much sense as implemented.
    /// @notice Process the rewards skimming from the safe of the validator
    ///         when the safe is being shared by the multiple validatators, it batch process all of their rewards skimming in one shot
    /// @param _validatorId The validator Id
    /// Full Flow of the partial withdrawal for a validator
    //  1. validator is exited & fund is withdrawn from the beacon chain
    //  2. perform `EigenPod.startCheckpoint()`
    //  3. perform `EigenPod.verifyCheckpointProofs()`
    //  4. wait for 'withdrawalDelayBlocks' (= 7 days) delay to be passed
    //  5. Finally, perform `EtherFiNodesManager.partialWithdraw` for the validator
    function partialWithdraw(uint256 _validatorId) public nonReentrant whenNotPaused {
        // locking to admin because of above explanation
        if (!roleRegistry.hasRole(NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        address etherfiNode = etherfiNodeAddress[_validatorId];
        _updateEtherFiNode(_validatorId);

        // distribute the rewards payouts. It reverts if the safe's balance >= 16 ether
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury ) = _getTotalRewardsPayoutsFromSafe(_validatorId, true);
        _distributePayouts(etherfiNode, _validatorId, toTreasury, toOperator, toTnft, toBnft);

        emit PartialWithdrawal(_validatorId, etherfiNode, toOperator, toTnft, toBnft, toTreasury);
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
    /// Full Flow of the full withdrawal for a validator
    //  1. validator is exited & fund is withdrawn from the beacon chain
    //  2. perform `EigenPod.startCheckpoint()` this starts a checkpoint proof for all validators in the pod
    //  3. perform `EigenPod.verifyCheckpointProofs()` must submit 1 proof per validator in the pod
    //  4. perform `EtherFiNodesManager.processNodeExit` which calls `DelegationManager.queueWithdrawals`
    //  5. wait for 'minWithdrawalDelayBlocks' (= 7 days) delay to be passed
    //  6. perform `EtherFiNodesManager.completeQueuedWithdrawals` which calls `DelegationManager.completeQueuedWithdrawal`
    //  7. Finally, perform `EtherFiNodesManager.fullWithdraw`
    function fullWithdraw(uint256 _validatorId) public nonReentrant whenNotPaused {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        _updateEtherFiNode(_validatorId);
        require(phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.EXITED, "NOT_EXITED");

        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = getFullWithdrawalPayouts(_validatorId);
        _setValidatorPhase(etherfiNode, _validatorId, IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN); // EXITED -> FULLY_WITHDRAWN
        _unRegisterValidator(_validatorId);
        _distributePayouts(etherfiNode, _validatorId, toTreasury, toOperator, toTnft, toBnft);

        tnft.burnFromWithdrawal(_validatorId);
        bnft.burnFromWithdrawal(_validatorId);

        emit FullWithdrawal(_validatorId, etherfiNode, toOperator, toTnft, toBnft, toTreasury);
    }

    /// @notice Process the full withdrawal for multiple validators
    /// @param _validatorIds The validator Ids
    function batchFullWithdraw(uint256[] calldata _validatorIds) external whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            fullWithdraw(_validatorIds[i]);
        }
    }

    /// @notice Once the Oracle observes that the validator is being slashed, it marks the validator as being slashed
    ///         The validator marked as being slashed must exit in order to withdraw funds
    /// @param _validatorIds The validator Ids
    function markBeingSlashed(
        uint256[] calldata _validatorIds
    ) external whenNotPaused {
        if (!roleRegistry.hasRole(NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _updateEtherFiNode(_validatorIds[i]);
            _setValidatorPhase(etherfiNodeAddress[_validatorIds[i]], _validatorIds[i], IEtherFiNode.VALIDATOR_PHASE.BEING_SLASHED);
        }
    }

    /// @dev instantiate EtherFiNode and EigenPod proxy instances
    /// @param _count How many instances to create
    /// @param _enableRestaking Whether or not to instantiate an associated eigenPod. (This can still be done later)
    function createUnusedWithdrawalSafe(uint256 _count, bool _enableRestaking) external returns (address[] memory) {
        address[] memory createdSafes = new address[](_count);
        for (uint256 i = 0; i < _count; i++) {
            address newNode = IStakingManager(stakingManagerContract).instantiateEtherFiNode(_enableRestaking);
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
        if (unusedWithdrawalSafes.length > 0) {
            // pop
            withdrawalSafeAddress = unusedWithdrawalSafes[unusedWithdrawalSafes.length-1];
            unusedWithdrawalSafes.pop();
        } else {
            // make a new one
            withdrawalSafeAddress = IStakingManager(stakingManagerContract).instantiateEtherFiNode(_enableRestaking);
        }

        // make sure the safe is migrated to v1
        ValidatorInfo memory info = ValidatorInfo(0, 0, 0, IEtherFiNode.VALIDATOR_PHASE.NOT_INITIALIZED);
        IEtherFiNode(withdrawalSafeAddress).migrateVersion(0, info);
    }

    function updateEtherFiNode(uint256 _validatorId) external {
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

        IEtherFiNode(etherfiNode).migrateVersion(_validatorId, validatorInfos[_validatorId]);
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
        // Called by StakingManager.CancelDeposit
        // {STAKE_DEPOSITED, WAITING_FOR_APPROVAL} -> {NOT_INITIALIZED}
        _updateEtherFiNode(_validatorId);
        _setValidatorPhase(etherfiNodeAddress[_validatorId], _validatorId, IEtherFiNode.VALIDATOR_PHASE.NOT_INITIALIZED);
        _unRegisterValidator(_validatorId);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------- EIGENPOD MANAGEMENT  -----------------------------------
    //--------------------------------------------------------------------------------------

    // checkpoint proofs need to be started by the eigenpod owner or configured `proofSubmitter`
    // but once they have been started, anyone can submit proofs for individual validators directly
    // to the Eigenpod contract

    /// @notice Start a PEPE pod checkpoint balance proof. A new proof cannot be started until
    ///         the previous proof is completed
    /// @dev Eigenlayer's PEPE proof system operates on pod-level and will require checkpoint proofs for
    ///      every single validator associated with the pod. For efficiency you will want to try to only
    ///      do checkpoints whene you wish to update most of the validators in the associated pod at once
    function startCheckpoint(uint256 _validatorId, bool _revertIfNoBalance) external {
        if (!roleRegistry.hasRole(EIGENPOD_CALLER_ROLE, msg.sender)) revert IncorrectRole();

        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).startCheckpoint(_revertIfNoBalance);
    }

    // @notice you can delegate 1 additional wallet that is allowed to call startCheckpoint() and
    //         verifyWithdrawalCredentials() on behalf of this pod
    /// @dev this will affect all validators in the pod, not just the provided validator
    function setProofSubmitter(uint256 _validatorId, address _newProofSubmitter) external {
        if (!roleRegistry.hasRole(EIGENPOD_CALLER_ROLE, msg.sender)) revert IncorrectRole();

        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).setProofSubmitter(_newProofSubmitter);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Update the whitelist for external calls that can be executed by an EtherfiNode
    /// @param _selector method selector
    /// @param _target call target for forwarded call
    /// @param _allowed enable or disable the call
    function updateAllowedForwardedExternalCalls(bytes4 _selector, address _target, bool _allowed) external {
        if (!roleRegistry.hasRole(WHITELIST_UPDATER, msg.sender)) revert IncorrectRole();

        allowedForwardedExternalCalls[_selector][_target] = _allowed;
        emit AllowedForwardedExternalCallsUpdated(_selector, _target, _allowed);
    }

    /// @notice Update the whitelist for external calls that can be executed against the corresponding eigenpod
    /// @param _selector method selector
    /// @param _allowed enable or disable the call
    function updateAllowedForwardedEigenpodCalls(bytes4 _selector, bool _allowed) external {
        if (!roleRegistry.hasRole(WHITELIST_UPDATER, msg.sender)) revert IncorrectRole();

        allowedForwardedEigenpodCalls[_selector] = _allowed;
        emit AllowedForwardedEigenpodCallsUpdated(_selector, _allowed);
    }

    // https://github.com/Layr-Labs/eigenlayer-contracts/blob/dev/src/contracts/pods/EigenPod.sol
    /// @notice Call the eigenPod contract
    // - verifyWithdrawalCredentials
    // - recoverTokens
    function forwardEigenpodCall(uint256[] calldata _validatorIds, bytes[] calldata _data) external nonReentrant whenNotPaused returns (bytes[] memory returnData) {
        if (!roleRegistry.hasRole(EIGENPOD_CALLER_ROLE, msg.sender)) revert IncorrectRole();

        returnData = new bytes[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _verifyForwardedEigenpodCall(_data[i], _validatorIds[i]);
            returnData[i] = IEtherFiNode(etherfiNodeAddress[_validatorIds[i]]).callEigenPod(_data[i]);
        }
    }

    function forwardExternalCall(uint256[] calldata _validatorIds, bytes[] calldata _data, address _target) external nonReentrant whenNotPaused returns (bytes[] memory returnData) {
        if (!roleRegistry.hasRole(EXTERNAL_CALLER_ROLE, msg.sender)) revert IncorrectRole();

        returnData = new bytes[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _verifyForwardedExternalCall(_target, _data[i], _validatorIds[i]);
            returnData[i] = IEtherFiNode(etherfiNodeAddress[_validatorIds[i]]).forwardCall(_target, _data[i]);
        }
    }

    function _verifyForwardedEigenpodCall(bytes calldata _data, uint256 _validatorId) internal view {

        if (_data.length < 4) revert InvalidForwardedCall();
        bytes4 selector = bytes4(_data[:4]);

        if (!allowedForwardedEigenpodCalls[selector]) revert ForwardedCallNotAllowed();

        // can add extra restrictions to specific calls here i.e. checking specific paramaters
        // if (selector == ...) { custom logic }
    }

    function _verifyForwardedExternalCall(address _to, bytes calldata _data, uint256 _validatorId) internal view {

        if (_data.length < 4) revert InvalidForwardedCall();
        bytes4 selector = bytes4(_data[:4]);

        if (!allowedForwardedExternalCalls[selector][_to]) revert ForwardedCallNotAllowed();

        // can add extra restrictions to specific calls here i.e. checking specific paramaters
        // if (selector == ...) { custom logic }
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
    function setStakingRewardsSplit(uint64 _treasury, uint64 _nodeOperator, uint64 _tnft, uint64 _bnft) public {
        if (!roleRegistry.hasRole(NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
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
    function setNonExitPenalty(uint64 _nonExitPenaltyDailyRate, uint64 _nonExitPenaltyPrincipal) public {
        if (!roleRegistry.hasRole(NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
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

    /// @notice Increments the number of validators by a certain amount
    /// @param _count how many new validators to increment by
    function incrementNumberOfValidators(uint64 _count) external onlyStakingManagerContract {
        numberOfValidators += _count;
    }

    // Pauses the contract
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }

    // Unpauses the contract
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _updateExitRequestTimestamp(uint256 _validatorId, address _etherfiNode, uint32 _exitRequestTimestamp) internal {
        IEtherFiNode(_etherfiNode).updateNumExitRequests(_exitRequestTimestamp > 0 ? 1 : 0, _exitRequestTimestamp == 0 ? 1 : 0);
        validatorInfos[_validatorId].exitRequestTimestamp = _exitRequestTimestamp;
    }

    function _setValidatorPhase(address _node, uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _newPhase) internal {
        IEtherFiNode(_node).validatePhaseTransition(phase(_validatorId), _newPhase);
        validatorInfos[_validatorId].phase = _newPhase;

        if (_newPhase == IEtherFiNode.VALIDATOR_PHASE.LIVE) {
            IEtherFiNode(_node).updateNumberOfAssociatedValidators(1, 0);
        }
        if (_newPhase == IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN) {
            IEtherFiNode(_node).processFullWithdraw(_validatorId);
        }
        if (_newPhase == IEtherFiNode.VALIDATOR_PHASE.EXITED) {
            IEtherFiNode(_node).updateNumExitedValidators(1, 0);
        }

        emit PhaseChanged(_validatorId, _newPhase);
    }

    function _unRegisterValidator(uint256 _validatorId) internal {
        address safeAddress = etherfiNodeAddress[_validatorId];
        if (safeAddress == address(0)) revert NotInstalled();

        bool doRecycle = IEtherFiNode(safeAddress).unRegisterValidator(_validatorId, validatorInfos[_validatorId]);

        delete etherfiNodeAddress[_validatorId];
        // delete validatorInfos[_validatorId];

        if (doRecycle) {
            unusedWithdrawalSafes.push(safeAddress);
        }
    }

    // it returns the "total" payout amounts from the safe that the validator is associated with
    // it performs some sanity-checks on the validator status, safe balance
    function _getTotalRewardsPayoutsFromSafe(
        uint256 _validatorId,
        bool _checkExit
    ) internal view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        require(phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.LIVE, "NOT_LIVE");
        address etherfiNode = etherfiNodeAddress[_validatorId];

        // When there is any pending exit request from T-NFT holder,
        // the corresponding valiator must exit
        // Only the admin can bypass it to provide the liquidity to the liquidity pool
        require(!_checkExit || IEtherFiNode(etherfiNode).numExitRequestsByTnft() == 0, "PENDING_EXIT_REQUEST");
        require(IEtherFiNode(etherfiNode).numExitedValidators() == 0, "NEED_FULL_WITHDRAWAL");

        // Once the balance of the safe goes over 16 ETH, 
        // it is impossible to tell if that ETH is from staking rewards or from principal (16 ETH ~ 32 ETH)
        // In such a case, the validator must exit and perform the full withdrawal
        // This is to prevent the principal of the exited validators from being mistakenly distributed out as rewards
        // 
        // Therefore, someone should trigger 'partialWithdraw' from the safe before its accrued staking rewards goes above 16 ETH
        // The ether.fi's bot will handle this for a while, but in the long-term we will make it an incentivzed process such that the caller can get some fees
        // 
        // The boolean flag '_checkMaxBalance' is FALSE only when this is called for 'forcePartialWithdraw'
        // where the Admin handles the case when the balance goes over 16 ETH
        require(!_checkExit || address(etherfiNode).balance < 16 ether, "MUST_EXIT");

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

    error SendFail();

    function _sendFund(address _recipient, uint256 _amount) internal {
        uint256 balanace = address(this).balance;
        (bool sent, ) = _recipient.call{value: _amount}("");
        if (!sent || address(this).balance != balanace - _amount) revert SendFail();
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
    function isExitRequested(uint256 _validatorId) public view returns (bool) {
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
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury ) = _getTotalRewardsPayoutsFromSafe(_validatorId, true);
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

    /// @notice Fetches the address of the implementation contract currently being used by the proxy
    /// @return The address of the currently used implementation contract
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    error NotStakingManager();

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
}

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
import "./EtherFiNode.sol";
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
    uint64 public nonExitPenaltyDailyRate;
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
    RewardsSplit public protocolRewardsSplit;

    address public DEPRECATED_admin;
    mapping(address => bool) public admins;

    IEigenPodManager public eigenPodManager;
    IDelayedWithdrawalRouter public delayedWithdrawalRouter;
    // max number of queued eigenlayer withdrawals to attempt to claim in a single tx
    uint8 public maxEigenlayerWithrawals;

    // stack of re-usable withdrawal safes to save gas
    address[] public unusedWithdrawalSafes;


    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event FundsWithdrawn(uint256 indexed _validatorId, uint256 amount);
    event NodeExitRequested(uint256 _validatorId);
    event NodeExitProcessed(uint256 _validatorId);
    event NodeEvicted(uint256 _validatorId);
    event PhaseChanged(uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase);
    event WithdrawalSafeReset(uint256 indexed _validatorId, address indexed withdrawalSafeAddress);

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /// @dev Sets the revenue splits on deployment
    /// @dev AuctionManager, treasury and deposit contracts must be deployed first
    /// @param _treasuryContract The address of the treasury contract for interaction
    /// @param _auctionContract The address of the auction contract for interaction
    /// @param _stakingManagerContract The address of the staking contract for interaction
    /// @param _tnftContract The address of the TNFT contract for interaction
    /// @param _bnftContract The address of the BNFT contract for interaction
    /// @param _protocolRevenueManagerContract The address of the protocols revenue manager contract for interaction
    function initialize(
        address _treasuryContract,
        address _auctionContract,
        address _stakingManagerContract,
        address _tnftContract,
        address _bnftContract,
        address _protocolRevenueManagerContract
    ) external initializer {
        require(_treasuryContract != address(0), "No zero addresses");
        require(_auctionContract != address(0), "No zero addresses");
        require(_stakingManagerContract != address(0), "No zero addresses");
        require(_tnftContract != address(0), "No zero addresses");
        require(_bnftContract != address(0), "No zero addresses");
        require(_protocolRevenueManagerContract != address(0), "No zero addresses"); 

        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        nonExitPenaltyPrincipal = 1 ether;
        nonExitPenaltyDailyRate = 3; // 3% per day
        SCALE = 1_000_000;

        treasuryContract = _treasuryContract;
        stakingManagerContract = _stakingManagerContract;

        auctionManager = IAuctionManager(_auctionContract);
        tnft = TNFT(_tnftContract);
        bnft = BNFT(_bnftContract);

        // in basis points for higher resolution
        stakingRewardsSplit = RewardsSplit({
            treasury: 50_000, // 5 %
            nodeOperator: 50_000, // 5 %
            tnft: 815_625, // 90 % * 29 / 32
            bnft: 84_375 // 90 % * 3 / 32
        });
        require(
            stakingRewardsSplit.treasury + stakingRewardsSplit.nodeOperator + stakingRewardsSplit.tnft + stakingRewardsSplit.bnft == SCALE,
            "Splits not equal to scale"
        );

        protocolRewardsSplit = RewardsSplit({
            treasury: 250_000, // 25 %
            nodeOperator: 250_000, // 25 %
            tnft: 453_125, // 50 % * 29 / 32
            bnft: 46_875 // 50 % * 3 / 32
        });
        require(
            protocolRewardsSplit.treasury + protocolRewardsSplit.nodeOperator + protocolRewardsSplit.tnft + protocolRewardsSplit.bnft == SCALE,
            "Splits not equal to scale"
        );
    }


    /// @notice Send the request to exit the validator node
    /// @param _validatorId ID of the validator associated
    function sendExitRequest(uint256 _validatorId) public whenNotPaused {
        require(msg.sender == tnft.ownerOf(_validatorId), "You are not the owner of the T-NFT");
        require(phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.LIVE, "validator node is not live");
        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).setExitRequestTimestamp();

        emit NodeExitRequested(_validatorId);
    }

    /// @notice Send the request to exit multiple nodes
    /// @param _validatorIds IDs of the validators associated
    function batchSendExitRequest(uint256[] calldata _validatorIds) external whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            sendExitRequest(_validatorIds[i]);
        }
    }

    /// @notice Once the node's exit is observed, the protocol calls this function to process their exits.
    /// @param _validatorIds The list of validators which exited
    /// @param _exitTimestamps The list of exit timestamps of the validators
    function processNodeExit(
        uint256[] calldata _validatorIds,
        uint32[] calldata _exitTimestamps
    ) external onlyAdmin nonReentrant whenNotPaused {
        require(_validatorIds.length == _exitTimestamps.length, "Check params");
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _processNodeExit(_validatorIds[i], _exitTimestamps[i]);
        }
    }

    /// @notice Once the node's malicious behavior (such as front-running) is observed, the protocol calls this function to evict them.
    /// @param _validatorIds The list of validators which should be evicted
    function processNodeEvict(
        uint256[] calldata _validatorIds
    ) external onlyAdmin nonReentrant whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _processNodeEvict(_validatorIds[i]);
        }
    }

    /// @notice queue a withdrawal of eth from an eigenPod. You must wait for the queuing period
    ///         defined by eigenLayer before you can finish the withdrawal via etherFiNode.claimQueuedWithdrawals()
    /// @param _validatorId The validator Id
    function queueRestakedWithdrawal(uint256 _validatorId) external whenNotPaused {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).queueRestakedWithdrawal();
    }

    /// @notice Process the rewards skimming
    /// @param _validatorId The validator Id
    function partialWithdraw(uint256 _validatorId) public nonReentrant whenNotPaused {
        address etherfiNode = etherfiNodeAddress[_validatorId];

        // sweep rewards from eigenPod if any queued withdrawals are ready to be claimed
        if (IEtherFiNode(etherfiNode).isRestakingEnabled()) {
            // claim any queued withdrawals that are ready
            IEtherFiNode(etherfiNode).claimQueuedWithdrawals(maxEigenlayerWithrawals);
            // queue up an balance currently in the contract so they are ready to be swept in the future
            IEtherFiNode(etherfiNode).queueRestakedWithdrawal();
        }

        require(
            address(etherfiNode).balance < 8 ether,
            "etherfi node contract's balance is above 8 ETH. You should exit the node."
        );
        require(
            IEtherFiNode(etherfiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.LIVE || IEtherFiNode(etherfiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN,
            "you can skim the rewards only when the node is LIVE or FULLY_WITHDRAWN."
        );

        // Retrieve all possible rewards: {Staking, Protocol} rewards and the vested auction fee reward
        // 'beaconBalance == 32 ether' means there is no accrued staking rewards and no slashing penalties  
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury ) 
            = getRewardsPayouts(_validatorId, 32 ether);

        _distributePayouts(_validatorId, toTreasury, toOperator, toTnft, toBnft);
    }

    /// @notice Batch-process the rewards skimming
    /// @param _validatorIds A list of the validator Ids
    function partialWithdrawBatch(uint256[] calldata _validatorIds) external whenNotPaused{
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            partialWithdraw( _validatorIds[i]);
        }
    }

    /// @notice Batch-process the rewards skimming for the validator nodes belonging to the same operator
    /// @param _operator The address of the operator to withdraw from
    /// @param _validatorIds The ID's of the validators to be withdrawn from
    function partialWithdrawBatchGroupByOperator(
        address _operator,
        uint256[] memory _validatorIds
    ) external nonReentrant whenNotPaused{
        uint256 totalOperatorAmount;
        uint256 totalTreasuryAmount;
        address tnftHolder;
        address bnftHolder;

        address etherfiNode;
        uint256 _validatorId;
        uint256[] memory payouts = new uint256[](4);  // (operator, tnft, bnft, treasury)
        for (uint i = 0; i < _validatorIds.length; i++) {
            _validatorId = _validatorIds[i];
            etherfiNode = etherfiNodeAddress[_validatorId];
            require(
                _operator == auctionManager.getBidOwner(_validatorId),
                "Not bid owner"
            );
            require(
                payable(etherfiNode).balance < 8 ether,
                "etherfi node contract's balance is above 8 ETH. You should exit the node."
            );
            require(
                IEtherFiNode(etherfiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.LIVE || IEtherFiNode(etherfiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN,
                "you can skim the rewards only when the node is LIVE or FULLY_WITHDRAWN."
            );

            // 'beaconBalance == 32 ether' means there is no accrued staking rewards and no slashing penalties  
            (payouts[0], payouts[1], payouts[2], payouts[3])
                = getRewardsPayouts(_validatorId, 32 ether);

            IEtherFiNode(etherfiNode).moveRewardsToManager(payouts[0] + payouts[1] + payouts[2] + payouts[3]);

            bool sent;
            tnftHolder = tnft.ownerOf(_validatorId);
            bnftHolder = bnft.ownerOf(_validatorId);
            if (tnftHolder == bnftHolder) {
                (sent, ) = payable(tnftHolder).call{value: payouts[1] + payouts[2]}("");
                if (!sent) totalTreasuryAmount += payouts[1] + payouts[2];
            } else {
                (sent, ) = payable(tnftHolder).call{value: payouts[1]}("");
                if (!sent) totalTreasuryAmount += payouts[1];
                (sent, ) = payable(bnftHolder).call{value: payouts[2]}("");
                if (!sent) totalTreasuryAmount += payouts[2];
            }
            totalOperatorAmount += payouts[0];
            totalTreasuryAmount += payouts[3];
        }
        (bool sent, ) = payable(_operator).call{value: totalOperatorAmount}("");
        if (!sent) totalTreasuryAmount += totalOperatorAmount;
        (sent, ) = payable(treasuryContract).call{value: totalTreasuryAmount}("");
        require(sent, "Failed to send Ether");
    }

    error MustClaimRestakedWithdrawals();

    /// @notice process the full withdrawal
    /// @dev This fullWithdrawal is allowed only after it's marked as EXITED.
    /// @dev EtherFi will be monitoring the status of the validator nodes and mark them EXITED if they do;
    /// @dev It is a point of centralization in Phase 1
    /// @param _validatorId the validator Id to withdraw from
    function fullWithdraw(uint256 _validatorId) public nonReentrant whenNotPaused{
        address etherfiNode = etherfiNodeAddress[_validatorId];

        if (IEtherFiNode(etherfiNode).isRestakingEnabled()) {
            // sweep rewards from eigenPod
            IEtherFiNode(etherfiNode).claimQueuedWithdrawals(5);
            // require that all pending withdrawals have cleared
            if (IEtherFiNode(etherfiNode).hasOutstandingEigenLayerWithdrawals()) revert MustClaimRestakedWithdrawals();
        }

        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) 
            = getFullWithdrawalPayouts(_validatorId);
        _setPhase(etherfiNode, _validatorId, IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN);


        _distributePayouts(_validatorId, toTreasury, toOperator, toTnft, toBnft);

        // automatically recycle this node if entire execution layer balance is withdrawn
        if (IEtherFiNode(etherfiNode).totalBalanceInExecutionLayer() == 0) {
            unusedWithdrawalSafes.push(etherfiNodeAddress[_validatorId]);
            IEtherFiNode(etherfiNode).resetWithdrawalSafe();
        }
    }

    /// @notice Process the full withdrawal for multiple validators
    /// @param _validatorIds The validator Ids
    function fullWithdrawBatch(uint256[] calldata _validatorIds) external whenNotPaused {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            fullWithdraw(_validatorIds[i]);
        }
    }

    function markBeingSlashed(
        uint256[] calldata _validatorIds
    ) external whenNotPaused onlyAdmin {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address etherfiNode = etherfiNodeAddress[_validatorIds[i]];
            _setPhase(etherfiNode, _validatorIds[i], IEtherFiNode.VALIDATOR_PHASE.BEING_SLASHED);
        }
    }

    error CannotResetNodeWithBalance();

    /// @notice reset unused withdrawal safes so that future validators can save gas creating contracts
    /// @dev Only nodes that are CANCELLED or FULLY_WITHDRAWN can be reset for reuse
    function resetWithdrawalSafes(uint256[] calldata _validatorIds) external onlyAdmin {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            IEtherFiNode node = IEtherFiNode(etherfiNodeAddress[_validatorIds[i]]);

            // don't allow the node to be recycled if it is in the withrdawn state but still has a balance.
            if (node.phase() == IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN) {
                if (node.totalBalanceInExecutionLayer() > 0) {
                    revert CannotResetNodeWithBalance();
                }
            }

            // reset safe and add to unused stack for later re-use
            node.resetWithdrawalSafe();
            unusedWithdrawalSafes.push(address(node));
            etherfiNodeAddress[_validatorIds[i]] = address(0);
            emit WithdrawalSafeReset(_validatorIds[i], address(node));
        }
    }

    /// @dev create a new proxy instance of the etherFiNode withdrawal safe contract.
    /// @param _createEigenPod whether or not to create an associated eigenPod contract.
    function instantiateEtherFiNode(bool _createEigenPod) internal returns (address) {
            BeaconProxy proxy = new BeaconProxy(IStakingManager(stakingManagerContract).getEtherFiNodeBeacon(), "");
            EtherFiNode node = EtherFiNode(payable(proxy));
            node.initialize(address(this));
            if (_createEigenPod) {
                node.createEigenPod();
            }

            return address(node);
    }

    /// @dev pre-create withdrawal safe contracts so that future staking operations are cheaper.
    ///   This is just pre-paying the gas cost of instantiating EtherFiNode and EigenPod proxy instances
    /// @param _count How many instances to create
    /// @param _enableRestaking Whether or not to instantiate an associated eigenPod. (This can still be done later)
    function createUnusedWithdrawalSafe(uint256 _count, bool _enableRestaking) external returns (address[] memory) {
        address[] memory createdSafes = new address[](_count);
        for (uint256 i = 0; i < _count; i++) {

            // create safe and add to pool of unused safes
            address newNode = instantiateEtherFiNode(_enableRestaking);
            unusedWithdrawalSafes.push(newNode);
            createdSafes[i] = address(newNode);
        }
        return createdSafes;
    }

    /// @notice Registers the validator ID for the EtherFiNode contract
    /// @param _validatorId ID of the validator associated to the node
    function registerEtherFiNode(uint256 _validatorId, bool _enableRestaking) external onlyStakingManagerContract returns (address) {
        require(etherfiNodeAddress[_validatorId] == address(0), "already installed");

        address withdrawalSafeAddress;

        // can I re-use an existing safe
        if (unusedWithdrawalSafes.length > 0) {
            // pop
            withdrawalSafeAddress = unusedWithdrawalSafes[unusedWithdrawalSafes.length-1];
            unusedWithdrawalSafes.pop();
        } else {
            // make a new one
            withdrawalSafeAddress = instantiateEtherFiNode(_enableRestaking);
        }

        IEtherFiNode(withdrawalSafeAddress).recordStakingStart(_enableRestaking);
        etherfiNodeAddress[_validatorId] = withdrawalSafeAddress;
        return withdrawalSafeAddress;
    }

    /// @notice Unset the EtherFiNode contract for the validator ID
    /// @param _validatorId ID of the validator associated
    function unregisterEtherFiNode(uint256 _validatorId) external onlyStakingManagerContract {
        address safeAddress = etherfiNodeAddress[_validatorId];
        require(safeAddress != address(0), "not installed");

        // recycle the node
        unusedWithdrawalSafes.push(etherfiNodeAddress[_validatorId]);
        IEtherFiNode(safeAddress).resetWithdrawalSafe();

        etherfiNodeAddress[_validatorId] = address(0);
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
        public onlyAdmin amountsEqualScale(_treasury, _nodeOperator, _tnft, _bnft)
    {
        stakingRewardsSplit.treasury = _treasury;
        stakingRewardsSplit.nodeOperator = _nodeOperator;
        stakingRewardsSplit.tnft = _tnft;
        stakingRewardsSplit.bnft = _bnft;
    }

    /// @notice Sets the protocol rewards split
    /// @notice Splits must add up to the SCALE of 1_000_000
    /// @param _treasury the split going to the treasury
    /// @param _nodeOperator the split going to the nodeOperator
    /// @param _tnft the split going to the tnft holder
    /// @param _bnft the split going to the bnft holder
    function setProtocolRewardsSplit(uint64 _treasury, uint64 _nodeOperator, uint64 _tnft, uint64 _bnft)
        public onlyAdmin amountsEqualScale(_treasury, _nodeOperator, _tnft, _bnft)
    {
        protocolRewardsSplit.treasury = _treasury;
        protocolRewardsSplit.nodeOperator = _nodeOperator;
        protocolRewardsSplit.tnft = _tnft;
        protocolRewardsSplit.bnft = _bnft;
    }

    /// @notice Sets the Non Exit Penalty Principal amount
    /// @param _nonExitPenaltyPrincipal the new principal amount
    function setNonExitPenaltyPrincipal (uint64 _nonExitPenaltyPrincipal) public onlyAdmin {
        nonExitPenaltyPrincipal = _nonExitPenaltyPrincipal;
    }

    /// @notice Sets the Non Exit Penalty Daily Rate amount
    /// @param _nonExitPenaltyDailyRate the new non exit daily rate
    function setNonExitPenaltyDailyRate(uint64 _nonExitPenaltyDailyRate) public onlyAdmin {
        require(_nonExitPenaltyDailyRate <= 100, "Invalid penalty rate");
        nonExitPenaltyDailyRate = _nonExitPenaltyDailyRate;
    }

    /// @notice Sets the phase of the validator
    /// @param _validatorId id of the validator associated to this etherfi node
    /// @param _phase phase of the validator
    function setEtherFiNodePhase(uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase) public onlyStakingManagerContract {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        _setPhase(etherfiNode, _validatorId, _phase);
    }

    /// @notice Sets the ipfs hash of the validator's encrypted private key
    /// @param _validatorId id of the validator associated to this etherfi node
    /// @param _ipfs ipfs hash
    function setEtherFiNodeIpfsHashForEncryptedValidatorKey(uint256 _validatorId, string calldata _ipfs) 
        external onlyStakingManagerContract {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).setIpfsHashForEncryptedValidatorKey(_ipfs);
    }

    /// @notice set maximum number of queued eigenlayer withdrawals that can be processed in 1 tx
    /// @param _max max number of queued withdrawals
    function setMaxEigenLayerWithdrawals(uint8 _max) external onlyOwner {
        maxEigenlayerWithrawals = _max;
    }

    /// @notice Increments the number of validators by a certain amount
    /// @param _count how many new validators to increment by
    function incrementNumberOfValidators(uint64 _count) external onlyStakingManagerContract {
        numberOfValidators += _count;
    }

    /// @notice Updates the address of the admin
    /// @param _address the new address to set as admin
    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        require(_address != address(0), "Cannot be address zero");
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
        address etherfiNode = etherfiNodeAddress[_validatorId];

        // Mark EXITED
        IEtherFiNode(etherfiNode).markExited(_exitTimestamp);

        numberOfValidators -= 1;

        emit NodeExitProcessed(_validatorId);
    }

    function _setPhase(address _node, uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase) internal {
        IEtherFiNode(_node).setPhase(_phase);
        emit PhaseChanged(_validatorId, _phase);
    }

    function _processNodeEvict(uint256 _validatorId) internal {
        address etherfiNode = etherfiNodeAddress[_validatorId];

        // Mark EVICTED
        IEtherFiNode(etherfiNode).markEvicted();

        numberOfValidators -= 1;

        // Return the all amount in the contract back to the node operator
        uint256 returnAmount = address(etherfiNode).balance;
        _distributePayouts(_validatorId, 0, returnAmount, 0, 0);

        emit NodeEvicted(_validatorId);
    }

    function _distributePayouts(uint256 _validatorId, uint256 _toTreasury, uint256 _toOperator, uint256 _toTnft, uint256 _toBnft) internal {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        IEtherFiNode(etherfiNode).withdrawFunds(
            treasuryContract, _toTreasury,
            auctionManager.getBidOwner(_validatorId), _toOperator,
            tnft.ownerOf(_validatorId), _toTnft,
            bnft.ownerOf(_validatorId), _toBnft
        );
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Eigenlayer EigenPodManager
    function setEigenPodMananger(address _addr) external onlyOwner {
        eigenPodManager = IEigenPodManager(_addr);
    }

    // Eigenlayer DelayedWithdrawalRouter
    function setDelayedWithdrawalRouter(address _addr) external onlyOwner {
        delayedWithdrawalRouter = IDelayedWithdrawalRouter(_addr);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  GETTER   --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetches the phase a specific node is in
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return validatorPhase the phase the node is in
    function phase(uint256 _validatorId) public view returns (IEtherFiNode.VALIDATOR_PHASE validatorPhase) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        validatorPhase = IEtherFiNode(etherfiNode).phase();
    }

    /// @notice Fetches the ipfs hash for the encrypted key data from a specific node
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return the ifs hash associated to the node
    function ipfsHashForEncryptedValidatorKey(uint256 _validatorId) external view returns (string memory) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        return IEtherFiNode(etherfiNode).ipfsHashForEncryptedValidatorKey();
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

    /// @notice Fetches the withdraw credentials for a specific node
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return the generated withdraw key for the node
    function getWithdrawalCredentials(uint256 _validatorId) external view returns (bytes memory) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        require(etherfiNode != address(0), "The validator Id is invalid.");
        
        if (IEtherFiNode(etherfiNode).isRestakingEnabled()) {
            return generateWithdrawalCredentials(IEtherFiNode(etherfiNode).eigenPod());
        } else {
            return generateWithdrawalCredentials(etherfiNode);
        }
    }

    /// @notice Fetches if the node has an exit request
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return bool value based on if an exit request has been sent
    function isExitRequested(uint256 _validatorId) external view returns (bool) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        return IEtherFiNode(etherfiNode).exitRequestTimestamp() > 0;
    }

    /// @notice Fetches the nodes non exit penalty amount
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return nonExitPenalty the amount of the penalty
    function getNonExitPenalty(uint256 _validatorId) public view returns (uint256 nonExitPenalty) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        uint32 tNftExitRequestTimestamp = IEtherFiNode(etherfiNode).exitRequestTimestamp();
        uint32 bNftExitRequestTimestamp = IEtherFiNode(etherfiNode).exitTimestamp();
        return IEtherFiNode(etherfiNode).getNonExitPenalty(tNftExitRequestTimestamp, bNftExitRequestTimestamp);
    }

    /// @notice Fetches the claimable rewards payouts based on the accrued rewards
    // 
    /// Note that since the smart contract running in the execution layer does not know the consensus layer data
    /// such as the status and balance of the validator, 
    /// the partial withdrawal assumes that the validator is in active & not being slashed + the beacon balance is 32 ether.
    /// Therefore, you need to set _beaconBalance = 32 ether to see the same payouts for the partial withdrawal
    ///
    /// @param _validatorId ID of the validator associated to etherfi node
    /// @param _beaconBalance the balance of the validator in Consensus Layer
    /// @return toNodeOperator  the TVL for the Node Operator
    /// @return toTnft          the TVL for the T-NFT holder
    /// @return toBnft          the TVL for the B-NFT holder
    /// @return toTreasury      the TVL for the Treasury
    function getRewardsPayouts(
        uint256 _validatorId,
        uint256 _beaconBalance
    ) public view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        address etherfiNode = etherfiNodeAddress[_validatorId];
        return
            IEtherFiNode(etherfiNode).getStakingRewardsPayouts(
                _beaconBalance + etherfiNode.balance,
                stakingRewardsSplit,
                SCALE
            );
    }

    /// @notice Fetches the full withdraw payouts
    /// @param _validatorId id of the validator associated to etherfi node
    /// @return toNodeOperator  the TVL for the Node Operator
    /// @return toTnft          the TVL for the T-NFT holder
    /// @return toBnft          the TVL for the B-NFT holder
    /// @return toTreasury      the TVL for the Treasury
    function getFullWithdrawalPayouts(uint256 _validatorId) 
        public view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        require(isExited(_validatorId), "validator node is not exited");

        // The full withdrawal payouts should be equal to the total TVL of the validator
        // 'beaconBalance' should be 0 since the validator must be in 'withdrawal_done' status
        // - it will get provably verified once we have EIP 4788
        return calculateTVL(_validatorId, 0);
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
        return  IEtherFiNode(etherfiNode).calculateTVL(
                    _beaconBalance,
                    stakingRewardsSplit,
                    SCALE
                );
    }

    /// @notice Fetches if the specified validator has been exited
    /// @return The bool value representing if the validator has been exited
    function isExited(uint256 _validatorId) public view returns (bool) {
        return phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.EXITED;
    }

    /// @notice Fetches if the specified validator has been withdrawn
    /// @return The bool value representing if the validator has been withdrawn
    function isFullyWithdrawn(uint256 _validatorId) public view returns (bool) {
        return phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN;
    }

    /// @notice Fetches if the specified validator has been evicted
    /// @return The bool value representing if the validator has been evicted
    function isEvicted(uint256 _validatorId) public view returns (bool) {
        return phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.EVICTED;
    }

    /// @notice Fetches the address of the implementation contract currently being used by the proxy
    /// @return The address of the currently used implementation contract
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyStakingManagerContract() {
        require(msg.sender == stakingManagerContract, "Only staking manager contract function");
        _;
    }

    modifier amountsEqualScale(uint64 _treasury, uint64 _nodeOperator, uint64 _tnft, uint64 _bnft) {
        require(_treasury + _nodeOperator + _tnft + _bnft == SCALE, "Amounts not equal to 1000000");
        _;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "Caller is not the admin");
        _;
    }
}

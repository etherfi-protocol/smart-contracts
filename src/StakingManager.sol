// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ITNFT.sol";
import "./interfaces/IBNFT.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IDepositContract.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/INodeOperatorManager.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IPausable.sol";
import "./TNFT.sol";
import "./BNFT.sol";
import "./EtherFiNode.sol";
import "./LiquidityPool.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/proxy/beacon/IBeaconUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./libraries/DepositRootGenerator.sol";


contract StakingManager is
    Initializable,
    IStakingManager,
    IBeaconUpgradeable,
    IPausable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    
    uint128 public maxBatchDepositSize;
    uint128 public stakeAmount;

    address public etherFiNodeImplementation;
    address public liquidityPoolContract;

    bool public DEPRECATED_isFullStakeEnabled;
    bytes32 public DEPRECATED_merkleRoot;

    ITNFT public TNFTInterfaceInstance;
    IBNFT public BNFTInterfaceInstance;
    IAuctionManager public auctionManager;
    IDepositContract public depositContractEth2;
    IEtherFiNodesManager public nodesManager;
    UpgradeableBeacon private upgradableBeacon;

    mapping(uint256 => StakerInfo) public bidIdToStakerInfo;

    address public DEPRECATED_admin;
    address public nodeOperatorManager;
    mapping(address => bool) public DEPRECATED_admins;

    RoleRegistry public roleRegistry;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant STAKING_MANAGER_ADMIN_ROLE = keccak256("STAKING_MANAGER_ADMIN_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event StakeDeposit(address indexed staker, uint256 indexed bidId, address indexed withdrawSafe, bool restaked);
    event DepositCancelled(uint256 id);
    event ValidatorRegistered(address indexed operator, address indexed bNftOwner, address indexed tNftOwner, 
                              uint256 validatorId, bytes validatorPubKey, string ipfsHashForEncryptedValidatorKey);

    error IncorrectRole();

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize to set variables on deployment
    /// @dev Deploys NFT contracts internally to ensure ownership is set to this contract
    /// @dev AuctionManager Contract must be deployed first
    /// @param _auctionAddress The address of the auction contract for interaction
    function initialize(address _auctionAddress, address _depositContractAddress) external initializer {
        stakeAmount = 32 ether;
        maxBatchDepositSize = 25;

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        auctionManager = IAuctionManager(_auctionAddress);
        depositContractEth2 = IDepositContract(_depositContractAddress);
    }

    function initializeOnUpgrade(address _nodeOperatorManager, address _etherFiAdmin) external onlyOwner {
        DEPRECATED_admin = address(0);
        nodeOperatorManager = _nodeOperatorManager;
        DEPRECATED_admins[_etherFiAdmin] = true;
    }

    function initializeV2dot5(address _roleRegistry) external onlyOwner {
        require(address(roleRegistry) == address(0x00), "already initialized");

        // TODO: compile list of values in DEPRECATED_admins to clear out
        roleRegistry = RoleRegistry(_roleRegistry);
    }
    
    /// @notice Allows depositing multiple stakes at once
    /// @dev Function gets called from the liquidity pool as part of the BNFT staker flow
    /// @param _candidateBidIds IDs of the bids to be matched with each stake
    /// @param _enableRestaking Eigen layer integration check to identify if restaking is possible
    /// @param _validatorIdToShareWithdrawalSafe the validator ID to use for the withdrawal safe
    /// @return Array of the bid IDs that were processed and assigned
    function batchDepositWithBidIds(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators, address _tnftHolder, address _bnftHolder, bool _enableRestaking, uint256 _validatorIdToShareWithdrawalSafe)
        public whenNotPaused nonReentrant returns (uint256[] memory)
    {
        require(msg.sender == liquidityPoolContract, "Incorrect Caller");
        require(_candidateBidIds.length >= _numberOfValidators && _numberOfValidators <= maxBatchDepositSize, "WRONG_PARAMS");
        require(auctionManager.numberOfActiveBids() >= _numberOfValidators, "NOT_ENOUGH_BIDS");

        return _processDeposits(_candidateBidIds, _numberOfValidators, _tnftHolder, _bnftHolder, _enableRestaking, _validatorIdToShareWithdrawalSafe);
    }

    /// @notice Creates validator object, mints NFTs, sets NB variables and deposits 1 ETH into beacon chain
    /// @dev Function gets called from the LP and is used in the BNFT staking flow
    /// @param _validatorId Array of IDs of the validator to register
    /// @param _bNftRecipient Array of BNFT recipients
    /// @param _tNftRecipient Array of TNFT recipients
    /// @param _depositData Array of data structures to hold all data needed for depositing to the beacon chain
    function batchRegisterValidators(
        uint256[] calldata _validatorId,
        address _bNftRecipient,
        address _tNftRecipient,
        DepositData[] calldata _depositData
    ) public payable whenNotPaused nonReentrant {
        require(msg.sender == liquidityPoolContract, "INCORRECT_CALLER");
        require(_validatorId.length <= maxBatchDepositSize && _validatorId.length == _depositData.length, "WRONG_PARAMS");
        require(msg.value == _validatorId.length * 1 ether, "DEPOSIT_AMOUNT_MISMATCH");

        for (uint256 x; x < _validatorId.length; ++x) {
            _registerValidator(_validatorId[x], _bNftRecipient, _tNftRecipient, _depositData[x], 1 ether);
        }
    }

    /// @notice Approves validators and deposits the remaining 31 ETH into the beacon chain
    /// @dev This gets called by the LP and only will only happen when the oracle has confirmed that the withdraw credentials for the 
    ///         validators are correct. This prevents a front-running attack.
    /// @param _validatorId validator IDs to approve
    /// @param _pubKey the pubkeys for each validator
    /// @param _signature the signature for the 31 ETH transaction which was submitted in the register phase
    /// @param _depositDataRootApproval the deposit data root for the 31 ETH transaction which was submitted in the register phase
    function batchApproveRegistration(
        uint256[] memory _validatorId, 
        bytes[] calldata _pubKey,
        bytes[] calldata _signature,
        bytes32[] calldata _depositDataRootApproval
    ) external payable {
        require(msg.sender == liquidityPoolContract, "INCORRECT_CALLER");

        for (uint256 x; x < _validatorId.length; ++x) {
            nodesManager.setValidatorPhase(_validatorId[x], IEtherFiNode.VALIDATOR_PHASE.LIVE);
            // Deposit to the Beacon Chain
            bytes memory withdrawalCredentials = nodesManager.getWithdrawalCredentials(_validatorId[x]);
            bytes32 beaconChainDepositRoot = depositRootGenerator.generateDepositRoot(_pubKey[x], _signature[x], withdrawalCredentials, 31 ether);
            bytes32 registeredDataRoot = _depositDataRootApproval[x];
            require(beaconChainDepositRoot == registeredDataRoot, "WRONG_DEPOSIT_DATA_ROOT");
            depositContractEth2.deposit{value: 31 ether}(_pubKey[x], withdrawalCredentials, _signature[x], beaconChainDepositRoot);
        }
    }

    /// @notice Cancels deposits for validators registered in the BNFT flow
    /// @dev Validators can be cancelled at any point before the full 32 ETH is deposited into the beacon chain. Validators which have
    ///         already gone through the 'registered' phase will lose 1 ETH which is stuck in the beacon chain and will serve as a penalty for
    ///         cancelling late. We need to update the number of validators each source has spun up to keep the target weight calculation correct.
    /// @param _validatorIds validators to cancel
    /// @param _bnftHolder address of the bNFT holder who initiated the transaction. Used for verification
    function batchCancelDeposit(uint256[] calldata _validatorIds, address _bnftHolder) public whenNotPaused nonReentrant {
        require(msg.sender == liquidityPoolContract, "INCORRECT_CALLER");

        for (uint256 x; x < _validatorIds.length; ++x) { 
            if(nodesManager.phase(_validatorIds[x]) == IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL) {
                uint256 nftTokenId = _validatorIds[x];
                TNFTInterfaceInstance.burnFromCancelBNftFlow(nftTokenId);
                BNFTInterfaceInstance.burnFromCancelBNftFlow(nftTokenId);
            }
            _cancelDeposit(_validatorIds[x], _bnftHolder);
        }
    }

    /// @dev create a new proxy instance of the etherFiNode withdrawal safe contract.
    /// @param _createEigenPod whether or not to create an associated eigenPod contract.
    function instantiateEtherFiNode(bool _createEigenPod) external returns (address) {
        require(msg.sender == address(nodesManager), "INCORRECT_CALLER");

        BeaconProxy proxy = new BeaconProxy(address(upgradableBeacon), "");
        address node = address(proxy);
        IEtherFiNode(node).initialize(address(nodesManager));
        if (_createEigenPod) {
            IEtherFiNode(node).createEigenPod();
        }
        return node;
    }

    error ALREADY_SET();

    /// @notice Sets the EtherFi node manager contract
    /// @param _nodesManagerAddress address of the manager contract being set
    function setEtherFiNodesManagerAddress(address _nodesManagerAddress) public onlyOwner {
        if (address(nodesManager) != address(0)) revert ALREADY_SET();
        nodesManager = IEtherFiNodesManager(_nodesManagerAddress);
    }

    /// @notice Sets the Liquidity pool contract address
    /// @param _liquidityPoolAddress address of the liquidity pool contract being set
    function setLiquidityPoolAddress(address _liquidityPoolAddress) public onlyOwner {
        if (address(liquidityPoolContract) != address(0)) revert ALREADY_SET();

        liquidityPoolContract = _liquidityPoolAddress;
    }

    /// @notice Sets the max number of deposits allowed at a time
    /// @param _newMaxBatchDepositSize the max number of deposits allowed
    function setMaxBatchDepositSize(uint128 _newMaxBatchDepositSize) public {
        if (!roleRegistry.hasRole(STAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        maxBatchDepositSize = _newMaxBatchDepositSize;
    }

    function registerEtherFiNodeImplementationContract(address _etherFiNodeImplementationContract) public onlyOwner {
        if (address(upgradableBeacon) != address(0) || address(etherFiNodeImplementation) != address(0)) revert ALREADY_SET();
        require(_etherFiNodeImplementationContract != address(0), "ZERO_ADDRESS");

        etherFiNodeImplementation = _etherFiNodeImplementationContract;
        upgradableBeacon = new UpgradeableBeacon(etherFiNodeImplementation);      
    }

    /// @notice Instantiates the TNFT interface
    /// @param _tnftAddress Address of the TNFT contract
    function registerTNFTContract(address _tnftAddress) public onlyOwner {
        if (address(TNFTInterfaceInstance) != address(0)) revert ALREADY_SET();

        TNFTInterfaceInstance = ITNFT(_tnftAddress);
    }

    /// @notice Instantiates the BNFT interface
    /// @param _bnftAddress Address of the BNFT contract
    function registerBNFTContract(address _bnftAddress) public onlyOwner {
        if (address(BNFTInterfaceInstance) != address(0)) revert ALREADY_SET();

        BNFTInterfaceInstance = IBNFT(_bnftAddress);
    }

    /// @notice Upgrades the etherfi node
    /// @param _newImplementation The new address of the etherfi node
    function upgradeEtherFiNode(address _newImplementation) public onlyOwner {
        require(_newImplementation != address(0), "ZERO_ADDRESS");
        
        upgradableBeacon.upgradeTo(_newImplementation);
        etherFiNodeImplementation = _newImplementation;
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
    
    function setNodeOperatorManager(address _nodeOperateManager) external {
        if (!roleRegistry.hasRole(STAKING_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        require(_nodeOperateManager != address(0), "ZERO_ADDRESS");

        nodeOperatorManager = _nodeOperateManager;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _processDeposits(
        uint256[] calldata _candidateBidIds, 
        uint256 _numberOfDeposits,
        address _tnftHolder,
        address _bnftHolder,
        bool _enableRestaking,
        uint256 _validatorIdToShareWithdrawalSafe
    ) internal returns (uint256[] memory){
        uint256[] memory processedBidIds = new uint256[](_numberOfDeposits);
        uint256 processedBidIdsCount = 0;

        for (uint256 i = 0;
            i < _candidateBidIds.length && processedBidIdsCount < _numberOfDeposits;
            ++i) {
            uint256 bidId = _candidateBidIds[i];
            address bidStaker = bidIdToStakerInfo[bidId].staker;
            address operator = auctionManager.getBidOwner(bidId);
            if (bidStaker == address(0) && auctionManager.isBidActive(bidId)) {
                // Verify the node operator who has been selected is approved to run validators using the specific source of funds.
                // See more info in Node Operator manager around approving operators for different source types
                auctionManager.updateSelectedBidInformation(bidId);
                processedBidIds[processedBidIdsCount] = bidId;
                processedBidIdsCount++;
                _processDeposit(bidId, _tnftHolder, _bnftHolder, _enableRestaking, _validatorIdToShareWithdrawalSafe);
            }
        }

        // resize the processedBidIds array to the actual number of processed bid IDs
        assembly {
            mstore(processedBidIds, processedBidIdsCount)
        }

        return processedBidIds;
    }

    /// @notice Creates validator object, mints NFTs, sets NB variables and deposits into beacon chain
    /// @param _validatorId ID of the validator to register
    /// @param _bNftRecipient The address to receive the minted B-NFT
    /// @param _tNftRecipient The address to receive the minted T-NFT
    /// @param _depositData Data structure to hold all data needed for depositing to the beacon chain
    /// however, instead of the validator key, it will include the IPFS hash
    /// containing the validator key encrypted by the corresponding node operator's public key
    function _registerValidator(
        uint256 _validatorId, 
        address _bNftRecipient, 
        address _tNftRecipient, 
        DepositData calldata _depositData, 
        uint256 _depositAmount
    ) internal {
        require(bidIdToStakerInfo[_validatorId].staker == _bNftRecipient, "INCORRECT_BNFT_RECIPIENT");
        bytes memory withdrawalCredentials = nodesManager.getWithdrawalCredentials(_validatorId);
        bytes32 depositDataRoot = depositRootGenerator.generateDepositRoot(_depositData.publicKey, _depositData.signature, withdrawalCredentials, _depositAmount);
        require(depositDataRoot == _depositData.depositDataRoot, "WRONG_ROOT");

        bytes32 fullHash = keccak256(abi.encode(_validatorId, msg.sender, _tNftRecipient, _bNftRecipient));
        bytes10 truncatedHash = bytes10(fullHash);
        require(truncatedHash == bidIdToStakerInfo[_validatorId].hash, "INCORRECT_HASH");

        if(_tNftRecipient == liquidityPoolContract) {
            // Deposits are split into two (1 ETH, 31 ETH). The latter is by the ether.fi Oracle
            nodesManager.setValidatorPhase(_validatorId, IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL);
        } else {
            // Deposit 32 ETH at once
            nodesManager.setValidatorPhase(_validatorId, IEtherFiNode.VALIDATOR_PHASE.LIVE);
        }

        // Deposit to the Beacon Chain
        depositContractEth2.deposit{value: _depositAmount}(_depositData.publicKey, withdrawalCredentials, _depositData.signature, depositDataRoot);

        nodesManager.incrementNumberOfValidators(1);
        auctionManager.processAuctionFeeTransfer(_validatorId);
        
        // Let validatorId = nftTokenId
        uint256 nftTokenId = _validatorId;
        TNFTInterfaceInstance.mint(_tNftRecipient, nftTokenId);
        BNFTInterfaceInstance.mint(_bNftRecipient, nftTokenId);

        emit ValidatorRegistered(
            auctionManager.getBidOwner(_validatorId),
            _bNftRecipient,
            _tNftRecipient,
            _validatorId,
            _depositData.publicKey,
            _depositData.ipfsHashForEncryptedValidatorKey
        );
    }

    /// @notice Update the state of the contract now that a deposit has been made
    /// @param _bidId The bid that won the right to the deposit
    function _processDeposit(uint256 _bidId, address _tnftHolder, address _bnftHolder, bool _enableRestaking, uint256 _validatorIdToShareWithdrawalSafe) internal {
        // Compute the keccak256 hash of the input data
        bytes32 fullHash = keccak256(abi.encode(_bidId, msg.sender, _tnftHolder, _bnftHolder));
        bytes10 truncatedHash = bytes10(fullHash);
        
        bidIdToStakerInfo[_bidId] = StakerInfo(_bnftHolder, 0, truncatedHash);
        uint256 validatorId = _bidId;

        // register a withdrawalSafe for this bid/validator, creating a new one if necessary
        address etherfiNode;
        if (_validatorIdToShareWithdrawalSafe == 0) {
            etherfiNode = nodesManager.allocateEtherFiNode(_enableRestaking);
        } else {
            require(TNFTInterfaceInstance.ownerOf(_validatorIdToShareWithdrawalSafe) == msg.sender, "WRONG_TNFT_OWNER"); // T-NFT owner must be the same
            require(BNFTInterfaceInstance.ownerOf(_validatorIdToShareWithdrawalSafe) == _bnftHolder, "WRONG_BNFT_OWNER");
            require(auctionManager.getBidOwner(_validatorIdToShareWithdrawalSafe) == auctionManager.getBidOwner(_bidId), "WRONG_BID_OWNER");
            etherfiNode = nodesManager.etherfiNodeAddress(_validatorIdToShareWithdrawalSafe);
            nodesManager.updateEtherFiNode(_validatorIdToShareWithdrawalSafe);
        }
        nodesManager.registerValidator(validatorId, _enableRestaking, etherfiNode);

        emit StakeDeposit(msg.sender, _bidId, etherfiNode, _enableRestaking);
    }

    /// @notice Cancels a users stake
    /// @param _validatorId the ID of the validator deposit to cancel
    function _cancelDeposit(uint256 _validatorId, address _bnftHolder) internal {
        require(bidIdToStakerInfo[_validatorId].staker != address(0), "NO_DEPOSIT_EXIST");
        require(bidIdToStakerInfo[_validatorId].staker == _bnftHolder, "INCORRECT_BNFT_HOLDER");

        bidIdToStakerInfo[_validatorId].staker = address(0);
        nodesManager.unregisterValidator(_validatorId);

        // Call function in auction contract to re-initiate the bid that won
        auctionManager.reEnterAuction(_validatorId);

        bool isFullStake = (msg.sender != liquidityPoolContract);
        if (isFullStake) {
            _refundDeposit(msg.sender, stakeAmount);
        }

        emit DepositCancelled(_validatorId);
    }

    /// @notice Refunds the depositor their staked ether for a specific stake
    /// @dev called internally from cancelStakingManager or when the time runs out for calling registerValidator
    /// @param _depositOwner address of the user being refunded
    /// @param _amount the amount to refund the depositor
    function _refundDeposit(address _depositOwner, uint256 _amount) internal {
        uint256 balanace = address(this).balance;
        (bool sent, ) = _depositOwner.call{value: _amount}("");
        require(sent && address(this).balance == balanace - _amount, "SendFail");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetches the address of the beacon contract for future EtherFiNodes (withdrawal safes)
    function getEtherFiNodeBeacon() external view returns (address) {
        return address(upgradableBeacon);
    }

    function bidIdToStaker(uint256 id) external view returns (address) {
        return bidIdToStakerInfo[id].staker;
    }

    /// @notice Fetches the address of the implementation contract currently being used by the proxy
    /// @return the address of the currently used implementation contract
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    /// @notice Fetches the address of the implementation contract currently being used by the beacon proxy
    /// @return the address of the currently used implementation contract
    function implementation() public view override returns (address) {
        return upgradableBeacon.implementation();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
}

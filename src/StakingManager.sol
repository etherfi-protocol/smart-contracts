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
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    
    uint128 public maxBatchDepositSize;
    uint128 public stakeAmount;

    address public implementationContract;
    address public liquidityPoolContract;

    bool public DEPRECATED_isFullStakeEnabled;
    bytes32 public merkleRoot;

    ITNFT public TNFTInterfaceInstance;
    IBNFT public BNFTInterfaceInstance;
    IAuctionManager public auctionManager;
    IDepositContract public depositContractEth2;
    IEtherFiNodesManager public nodesManager;
    UpgradeableBeacon private upgradableBeacon;

    mapping(uint256 => StakerInfo) public bidIdToStakerInfo;

    address public DEPRECATED_admin;
    address public nodeOperatorManager;
    mapping(address => bool) public admins;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event StakeDeposit(address indexed staker, uint256 indexed bidId, address indexed withdrawSafe, bool restaked);
    event DepositCancelled(uint256 id);
    event ValidatorRegistered(address indexed operator, address indexed bNftOwner, address indexed tNftOwner, 
                              uint256 validatorId, bytes validatorPubKey, string ipfsHashForEncryptedValidatorKey);
    event StakeSource(uint256 bidId, ILiquidityPool.SourceOfFunds source);

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
        admins[_etherFiAdmin] = true;
    }
    
    /// @notice Allows depositing multiple stakes at once
    /// @dev Function gets called from the liquidity pool as part of the BNFT staker flow
    /// @param _candidateBidIds IDs of the bids to be matched with each stake
    /// @param _staker the address of the BNFT player who originated the call to the LP
    /// @param _source the staking type that the funds are sourced from (EETH / ETHER_FAN), see natspec for allocateSourceOfFunds()
    /// @param _enableRestaking Eigen layer integration check to identify if restaking is possible
    /// @param _validatorIdToShareWithdrawalSafe the validator ID to use for the withdrawal safe
    /// @return Array of the bid IDs that were processed and assigned
    function batchDepositWithBidIds(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators, address _staker, address _tnftHolder, address _bnftHolder, ILiquidityPool.SourceOfFunds _source, bool _enableRestaking, uint256 _validatorIdToShareWithdrawalSafe)
        public whenNotPaused nonReentrant returns (uint256[] memory)
    {
        require(msg.sender == liquidityPoolContract, "Incorrect Caller");
        require(_candidateBidIds.length >= _numberOfValidators && _numberOfValidators <= maxBatchDepositSize, "WRONG_PARAMS");
        require(auctionManager.numberOfActiveBids() >= _numberOfValidators, "NOT_ENOUGH_BIDS");

        return _processDeposits(_candidateBidIds, _numberOfValidators, _staker, _tnftHolder, _bnftHolder, _source, _enableRestaking, _validatorIdToShareWithdrawalSafe);
    }

    /// @notice Creates validator object, mints NFTs, sets NB variables and deposits 1 ETH into beacon chain
    /// @dev Function gets called from the LP and is used in the BNFT staking flow
    /// @param _depositRoot The fetched root of the Beacon Chain
    /// @param _validatorId Array of IDs of the validator to register
    /// @param _bNftRecipient Array of BNFT recipients
    /// @param _tNftRecipient Array of TNFT recipients
    /// @param _depositData Array of data structures to hold all data needed for depositing to the beacon chain
    /// @param _staker address of the BNFT holder who initiated the transaction
    function batchRegisterValidators(
        bytes32 _depositRoot,
        uint256[] calldata _validatorId,
        address _bNftRecipient,
        address _tNftRecipient,
        DepositData[] calldata _depositData,
        address _staker
    ) public payable whenNotPaused nonReentrant verifyDepositState(_depositRoot) {
        require(msg.sender == liquidityPoolContract, "INCORRECT_CALLER");
        require(_validatorId.length <= maxBatchDepositSize && _validatorId.length == _depositData.length, "WRONG_PARAMS");
        require(msg.value == _validatorId.length * 1 ether, "DEPOSIT_AMOUNT_MISMATCH");

        for (uint256 x; x < _validatorId.length; ++x) {
            require(bidIdToStakerInfo[_validatorId[x]].sourceOfFund == ILiquidityPool.SourceOfFunds.EETH, "Wrong flow");
            _registerValidator(_validatorId[x], _bNftRecipient, _tNftRecipient, _depositData[x], _staker, 1 ether);
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
    /// @param _caller address of the bNFT holder who initiated the transaction. Used for verification
    function batchCancelDepositAsBnftHolder(uint256[] calldata _validatorIds, address _caller) public whenNotPaused nonReentrant {
        require(msg.sender == liquidityPoolContract, "INCORRECT_CALLER");

        for (uint256 x; x < _validatorIds.length; ++x) { 
            ILiquidityPool.SourceOfFunds source = bidIdToStakerInfo[_validatorIds[x]].sourceOfFund;
            require(source != ILiquidityPool.SourceOfFunds.DELEGATED_STAKING, "Wrong flow");

            if(nodesManager.phase(_validatorIds[x]) == IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL) {
                uint256 nftTokenId = _validatorIds[x];
                TNFTInterfaceInstance.burnFromCancelBNftFlow(nftTokenId);
                BNFTInterfaceInstance.burnFromCancelBNftFlow(nftTokenId);
            }

            _cancelDeposit(_validatorIds[x], _caller);
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
    function setMaxBatchDepositSize(uint128 _newMaxBatchDepositSize) public onlyAdmin {
        maxBatchDepositSize = _newMaxBatchDepositSize;
    }

    function registerEtherFiNodeImplementationContract(address _etherFiNodeImplementationContract) public onlyOwner {
        if (address(upgradableBeacon) != address(0) || address(implementationContract) != address(0)) revert ALREADY_SET();
        require(_etherFiNodeImplementationContract != address(0), "ZERO_ADDRESS");

        implementationContract = _etherFiNodeImplementationContract;
        upgradableBeacon = new UpgradeableBeacon(implementationContract);      
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
        implementationContract = _newImplementation;
    }

    function pauseContract() external onlyAdmin { _pause(); }
    function unPauseContract() external onlyAdmin { _unpause(); }

    /// @notice Updates the address of the admin
    /// @param _address the new address to set as admin
    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        require(_address != address(0), "ZERO_ADDRESS");
        admins[_address] = _isAdmin;
    }
    
    function setNodeOperatorManager(address _nodeOperateManager) external onlyAdmin {
        require(_nodeOperateManager != address(0), "ZERO_ADDRESS");
        nodeOperatorManager = _nodeOperateManager;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------

    function _processDeposits(
        uint256[] calldata _candidateBidIds, 
        uint256 _numberOfDeposits,
        address _staker,
        address _tnftHolder,
        address _bnftHolder,
        ILiquidityPool.SourceOfFunds _source,
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
                require(_verifyNodeOperator(operator, _source), "INVALID_OPERATOR");
                auctionManager.updateSelectedBidInformation(bidId);
                processedBidIds[processedBidIdsCount] = bidId;
                processedBidIdsCount++;
                _processDeposit(bidId, _staker, _tnftHolder, _bnftHolder, _enableRestaking, _source, _validatorIdToShareWithdrawalSafe);
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
    /// @param _staker User who has begun the registration chain of transactions
    /// however, instead of the validator key, it will include the IPFS hash
    /// containing the validator key encrypted by the corresponding node operator's public key
    function _registerValidator(
        uint256 _validatorId, 
        address _bNftRecipient, 
        address _tNftRecipient, 
        DepositData calldata _depositData, 
        address _staker,
        uint256 _depositAmount
    ) internal {
        require(bidIdToStakerInfo[_validatorId].staker == _staker, "INCORRECT_CALLER");
        bytes memory withdrawalCredentials = nodesManager.getWithdrawalCredentials(_validatorId);
        bytes32 depositDataRoot = depositRootGenerator.generateDepositRoot(_depositData.publicKey, _depositData.signature, withdrawalCredentials, _depositAmount);
        require(depositDataRoot == _depositData.depositDataRoot, "WRONG_ROOT");

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
    function _processDeposit(uint256 _bidId, address _staker, address _tnftHolder, address _bnftHolder, bool _enableRestaking, ILiquidityPool.SourceOfFunds _source, uint256 _validatorIdToShareWithdrawalSafe) internal {
        bidIdToStakerInfo[_bidId] = StakerInfo(_staker, _source);
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

        emit StakeDeposit(_staker, _bidId, etherfiNode, _enableRestaking);
        emit StakeSource(_bidId, _source);
    }

    /// @notice Cancels a users stake
    /// @param _validatorId the ID of the validator deposit to cancel
    function _cancelDeposit(uint256 _validatorId, address _caller) internal {
        require(bidIdToStakerInfo[_validatorId].staker != address(0), "NO_DEPOSIT_EXIST");
        require(bidIdToStakerInfo[_validatorId].staker == _caller, "INCORRECT_CALLER");

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

    /// @notice Checks if an operator is approved for a specified source of funds
    /// @dev Operators do not need to be approved for delegated_staking type
    /// @param _operator address of the operator being checked
    /// @param _source the source of funds the operator is being checked for
    /// @return approved whether the operator is approved for the source type
    function _verifyNodeOperator(address _operator, ILiquidityPool.SourceOfFunds _source) internal view returns (bool approved) {
        if(uint256(ILiquidityPool.SourceOfFunds.DELEGATED_STAKING) == uint256(_source)) {
            approved = true;
        } else {
            approved = INodeOperatorManager(nodeOperatorManager).isEligibleToRunValidatorsForSourceOfFund(_operator, _source);
        }
    }

    function _requireAdmin() internal view virtual {
        require(admins[msg.sender], "NOT_ADMIN");
    }

    function _verifyDepositState(bytes32 _depositRoot) internal view virtual {
        // disable deposit root check if none provided
        if (_depositRoot != 0x0000000000000000000000000000000000000000000000000000000000000000) {
            bytes32 onchainDepositRoot = depositContractEth2.get_deposit_root();
            require(_depositRoot == onchainDepositRoot, "DEPOSIT_ROOT_CHANGED");
        }
    }

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

    modifier verifyDepositState(bytes32 _depositRoot) {
        _verifyDepositState(_depositRoot);
        _;
    }

    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }
}

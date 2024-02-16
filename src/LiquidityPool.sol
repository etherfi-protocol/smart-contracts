// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IRegulationsManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IMembershipManager.sol";
import "./interfaces/ITNFT.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IEtherFiAdmin.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/ILiquifier.sol";

contract LiquidityPool is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILiquidityPool {
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IStakingManager public stakingManager;
    IEtherFiNodesManager public nodesManager;
    IRegulationsManager public DEPRECATED_regulationsManager;
    IMembershipManager public membershipManager;
    ITNFT public tNft;
    IeETH public eETH; 

    bool public DEPRECATED_eEthliquidStakingOpened;

    uint128 public totalValueOutOfLp;
    uint128 public totalValueInLp;

    address public DEPRECATED_admin;

    uint32 public numPendingDeposits; // number of deposits that have not been registered yet

    address public DEPRECATED_bNftTreasury;
    IWithdrawRequestNFT public withdrawRequestNFT;

    BnftHolder[] public bnftHolders;
    uint128 public maxValidatorsPerOwner;
    uint128 public DEPRECATED_schedulingPeriodInSeconds;

    HoldersUpdate public DEPRECATED_holdersUpdate;

    mapping(address => bool) public admins;
    mapping(SourceOfFunds => FundStatistics) public fundStatistics;
    mapping(uint256 => bytes32) public depositDataRootForApprovalDeposits;
    address public etherFiAdminContract;
    bool public whitelistEnabled;
    mapping(address => bool) public whitelisted;
    mapping(address => BnftHoldersIndex) public bnftHoldersIndexes;

    bool public restakeBnftDeposits;
    uint128 public ethAmountLockedForWithdrawal;
    bool public paused;

    IAuctionManager public auctionManager;
    ILiquifier public liquifier;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event Paused(address account);
    event Unpaused(address account);

    event Deposit(address indexed sender, uint256 amount, SourceOfFunds source, address referral);
    event Withdraw(address indexed sender, address recipient, uint256 amount, SourceOfFunds source);
    event UpdatedWhitelist(address userAddress, bool value);
    event BnftHolderDeregistered(address user, uint256 index);
    event BnftHolderRegistered(address user, uint256 index);
    event UpdatedSchedulingPeriod(uint128 newPeriodInSeconds);
    event ValidatorRegistered(uint256 indexed validatorId, bytes signature, bytes pubKey, bytes32 depositRoot);
    event ValidatorApproved(uint256 indexed validatorId);
    event ValidatorRegistrationCanceled(uint256 indexed validatorId);
    event Rebase(uint256 totalEthLocked, uint256 totalEEthShares);
    event WhitelistStatusUpdated(bool value);


    error IncorrectCaller();
    error InvalidAmount();
    error InvalidParams();
    error DataNotSet();
    error InsufficientLiquidity();
    error SendFail();

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        if (msg.value > type(uint128).max) revert InvalidAmount();
        totalValueOutOfLp -= uint128(msg.value);
        totalValueInLp += uint128(msg.value);
    }

    function initialize(address _eEthAddress, address _stakingManagerAddress, address _nodesManagerAddress, address _membershipManagerAddress, address _tNftAddress, address _etherFiAdminContract, address _withdrawRequestNFT) external initializer {
        if (_eEthAddress == address(0) || _stakingManagerAddress == address(0) || _nodesManagerAddress == address(0) || _membershipManagerAddress == address(0) || _tNftAddress == address(0)) revert DataNotSet();
        
        __Ownable_init();
        __UUPSUpgradeable_init();

        eETH = IeETH(_eEthAddress);
        stakingManager = IStakingManager(_stakingManagerAddress);
        nodesManager = IEtherFiNodesManager(_nodesManagerAddress);
        membershipManager = IMembershipManager(_membershipManagerAddress);
        tNft = ITNFT(_tNftAddress);

        paused = true;
        whitelistEnabled = true;
        restakeBnftDeposits = false;
        ethAmountLockedForWithdrawal = 0;
        maxValidatorsPerOwner = 30;

        etherFiAdminContract = _etherFiAdminContract;
        withdrawRequestNFT = IWithdrawRequestNFT(_withdrawRequestNFT);

        admins[_etherFiAdminContract] = true;
    }

    function initializeOnUpgrade(address _auctionManager, address _liquifier) external onlyOwner { 
        require(_auctionManager != address(0) && _liquifier != address(0), "Invalid params");

        auctionManager = IAuctionManager(_auctionManager);
        liquifier = ILiquifier(_liquifier);
    }

    // Used by eETH staking flow
    function deposit() external payable returns (uint256) {
        return deposit(address(0));
    }

    function deposit(address _referral) public payable whenNotPaused returns (uint256) {
        require(_isWhitelisted(msg.sender), "Invalid User");

        emit Deposit(msg.sender, msg.value, SourceOfFunds.EETH, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    function depositToRecipient(address _recipient, uint256 _amount, address _referral) public whenNotPaused returns (uint256) {
        require(msg.sender == address(liquifier), "Incorrect Caller");

        emit Deposit(_recipient, _amount, SourceOfFunds.EETH, _referral);

        return _deposit(_recipient, 0, _amount);
    }

    // Used by ether.fan staking flow
    function deposit(address _user, address _referral) external payable whenNotPaused returns (uint256) {
        require(msg.sender == address(membershipManager), "Incorrect Caller");
        require(_user == address(membershipManager) || _isWhitelisted(_user), "Invalid User");

        emit Deposit(msg.sender, msg.value, SourceOfFunds.ETHER_FAN, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    /// @notice withdraw from pool
    /// @dev Burns user balance from msg.senders account & Sends equal amount of ETH back to the recipient
    /// @param _recipient the recipient who will receives the ETH
    /// @param _amount the amount to withdraw from contract
    /// it returns the amount of shares burned
    function withdraw(address _recipient, uint256 _amount) external whenNotPaused returns (uint256) {
        uint256 share = sharesForWithdrawalAmount(_amount);
        require(msg.sender == address(withdrawRequestNFT) || msg.sender == address(membershipManager), "Incorrect Caller");
        if (totalValueInLp < _amount || (msg.sender == address(withdrawRequestNFT) && ethAmountLockedForWithdrawal < _amount) || eETH.balanceOf(msg.sender) < _amount) revert InsufficientLiquidity();
        if (_amount > type(uint128).max || _amount == 0 || share == 0) revert InvalidAmount();

        totalValueInLp -= uint128(_amount);
        if (msg.sender == address(withdrawRequestNFT)) {
            ethAmountLockedForWithdrawal -= uint128(_amount);
        }

        eETH.burnShares(msg.sender, share);

        _sendFund(_recipient, _amount);

        return share;
    }

    /// @notice request withdraw from pool and receive a WithdrawRequestNFT
    /// @dev Transfers the amount of eETH from msg.senders account to the WithdrawRequestNFT contract & mints an NFT to the msg.sender
    /// @param recipient address that will be issued the NFT
    /// @param amount requested amount to withdraw from contract
    /// @return uint256 requestId of the WithdrawRequestNFT
    function requestWithdraw(address recipient, uint256 amount) public whenNotPaused returns (uint256) {
        uint256 share = sharesForAmount(amount);
        if (amount > type(uint96).max || amount == 0 || share == 0) revert InvalidAmount();

        // transfer shares to WithdrawRequestNFT contract from this contract
        eETH.transferFrom(msg.sender, address(withdrawRequestNFT), amount);

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient, 0);
       
        emit Withdraw(msg.sender, recipient, amount, SourceOfFunds.EETH);

        return requestId;
    }

    /// @notice request withdraw from pool with signed permit data and receive a WithdrawRequestNFT
    /// @dev accepts PermitInput signed data to approve transfer of eETH (EIP-2612) so withdraw request can happen in 1 tx
    /// @param _owner address that will be issued the NFT
    /// @param _amount requested amount to withdraw from contract
    /// @param _permit signed permit data to approve transfer of eETH
    /// @return uint256 requestId of the WithdrawRequestNFT
    function requestWithdrawWithPermit(address _owner, uint256 _amount, PermitInput calldata _permit)
        external
        whenNotPaused
        returns (uint256)
    {
        eETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s);
        return requestWithdraw(_owner, _amount);
    }

    /// @notice request withdraw of some or all of the eETH backing a MembershipNFT and receive a WithdrawRequestNFT
    /// @dev Transfers the amount of eETH from MembershipManager to the WithdrawRequestNFT contract & mints an NFT to the recipient
    /// @param recipient address that will be issued the NFT
    /// @param amount requested amount to withdraw from contract
    /// @param fee the burn fee to be paid by the recipient when the withdrawal is claimed (WithdrawRequestNFT.claimWithdraw)
    /// @return uint256 requestId of the WithdrawRequestNFT
    function requestMembershipNFTWithdraw(address recipient, uint256 amount, uint256 fee) public whenNotPaused returns (uint256) {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        uint256 share = sharesForAmount(amount);
        if (amount > type(uint96).max || amount == 0 || share == 0) revert InvalidAmount();

        // transfer shares to WithdrawRequestNFT contract
        eETH.transferFrom(msg.sender, address(withdrawRequestNFT), amount);

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient, fee);

        emit Withdraw(msg.sender, recipient, amount, SourceOfFunds.ETHER_FAN);

        return requestId;
    }

    // [Staking flow]
    // Step 1: allocate validators; create withdrawal safe contracts
    // Step 2: create the keys using the desktop app
    // Step 3: register the validator keys
    // Step 4: wait for the oracle to approve


    // Step 1 for {B-NFT staker, Operation Solo Staker} flows
    /// @param _candidateBidIds validator IDs that have been matched with the BNFT holder on the FE
    /// @param _numberOfValidators how many validators the user wants to spin up. This can be less than the candidateBidIds length. 
    ///         we may have more Ids sent in than needed to spin up incase some ids fail.
    /// @return Array of bids that were successfully processed.
    function batchDepositAsBnftHolder(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators) external payable whenNotPaused returns (uint256[] memory) {
        uint32 index = bnftHoldersIndexes[msg.sender].index;
        require(bnftHoldersIndexes[msg.sender].registered && bnftHolders[index].holder == msg.sender, "Incorrect Caller");        
        require(msg.value == _numberOfValidators * 2 ether, "Deposit 2 ETH per validator");
        require(totalValueInLp + msg.value >= 32 ether * _numberOfValidators, "Not enough balance");
        require(_numberOfValidators <= maxValidatorsPerOwner, "Exceeded max validators per owner");
    
        //Funds in the LP can come from our membership strategy or the eEth staking strategy. We select which source of funds will
        //be used for spinning up these deposited ids. See the function for more detail on how we do this.
        SourceOfFunds _source = allocateSourceOfFunds();
        fundStatistics[_source].numberOfValidators += uint32(_numberOfValidators);

        //We then call the Staking Manager contract which handles the rest of the logic
        uint256[] memory newValidators = stakingManager.batchDepositWithBidIds(_candidateBidIds, _numberOfValidators, msg.sender, _source, restakeBnftDeposits);

        numPendingDeposits += uint32(newValidators.length);

        //Sometimes not all the validators get deposited successfully. We need to check if there were remaining IDs that were not successful
        //and refund the BNFT player their 2 ETH for each ID
        if (_numberOfValidators > newValidators.length) {
            uint256 returnAmount = 2 ether * (_numberOfValidators - newValidators.length);
            _sendFund(msg.sender, returnAmount);
        }
        
        return newValidators;
    }

    // Step 3 for {Permission-less Node Staking, B-NFT staker, Operation Solo Staker} flows
    /// @notice BNFT players register validators they have deposited. This triggers a 2 ETH transaction to the beacon chain.
    /// @dev This function can only be called by a BNFT player on IDs that have been deposited.  
    /// @param _depositRoot This is the deposit root of the beacon chain. Can send in 0x00 to bypass this check in future
    /// @param _validatorIds The ids of the validators to register
    /// @param _registerValidatorDepositData As in the solo staking flow, the BNFT player must send in a deposit data object (see ILiquidityPool for struct data)
    ///         to register the validators. However, the signature and deposit data root must be for a 2 ETH deposit
    /// @param _depositDataRootApproval The deposit data roots for each validator for the 30 ETH transaction which will happen in the approval
    ///         step. See the Staking Manager for details.
    /// @param _signaturesForApprovalDeposit Much like the deposit data root. This is the signature for each validator for the 30 ETH 
    ///         transaction which will happen in the approval step.
    function batchRegisterAsBnftHolder(
        bytes32 _depositRoot,
        uint256[] calldata _validatorIds,
        IStakingManager.DepositData[] calldata _registerValidatorDepositData,
        bytes32[] calldata _depositDataRootApproval,
        bytes[] calldata _signaturesForApprovalDeposit
    ) external whenNotPaused {
        require(_validatorIds.length == _registerValidatorDepositData.length && _validatorIds.length == _depositDataRootApproval.length && _validatorIds.length == _signaturesForApprovalDeposit.length, "lengths differ");

        numPendingDeposits -= uint32(_validatorIds.length);
        stakingManager.batchRegisterValidators{value: 2 ether * _validatorIds.length}(_depositRoot, _validatorIds, msg.sender, address(this), _registerValidatorDepositData, msg.sender);
        
        //For each validator, we need to store the deposit data root of the 30 ETH transaction so it is accessible in the approve function
        for(uint256 i; i < _validatorIds.length; i++) {
            depositDataRootForApprovalDeposits[_validatorIds[i]] = _depositDataRootApproval[i];
            emit ValidatorRegistered(_validatorIds[i], _signaturesForApprovalDeposit[i], _registerValidatorDepositData[i].publicKey, _depositDataRootApproval[i]);
        }
    }

    /// @notice Approves validators and triggers the 30 ETH transaction to the beacon chain (rest of the stake).
    /// @dev This gets called by the Oracle and only when it has confirmed the withdraw credentials of the 2 ETH deposit in the registration
    ///         phase match the withdraw credentials stored on the beacon chain. This prevents a front-running attack.
    /// @param _validatorIds The IDs of the validators to be approved
    /// @param _pubKey The pubKey for each validator being spun up.
    /// @param _signature The signatures for each validator for the 30 ETH transaction that were emitted in the register phase
    function batchApproveRegistration(
        uint256[] memory _validatorIds, 
        bytes[] calldata _pubKey,
        bytes[] calldata _signature
    ) external onlyAdmin whenNotPaused {
        require(_validatorIds.length == _pubKey.length && _validatorIds.length == _signature.length, "lengths differ");

        //Fetches the deposit data root of each validator and uses it in the approval call to the Staking Manager
        bytes32[] memory depositDataRootApproval = new bytes32[](_validatorIds.length);
        for(uint256 i; i < _validatorIds.length; i++) {
            depositDataRootApproval[i] = depositDataRootForApprovalDeposits[_validatorIds[i]];
            delete depositDataRootForApprovalDeposits[_validatorIds[i]];        

            emit ValidatorApproved(_validatorIds[i]);
        }

        totalValueOutOfLp += uint128(30 ether * _validatorIds.length);
        totalValueInLp -= uint128(30 ether * _validatorIds.length);

        stakingManager.batchApproveRegistration{value: 30 ether * _validatorIds.length}(_validatorIds, _pubKey, _signature, depositDataRootApproval);
    }

    /// @notice Cancels a BNFT players deposits (whether validator is registered or deposited. Just not live on beacon chain)
    /// @dev This is called only in the BNFT player flow
    /// @param _validatorIds The IDs to be cancelled
    function batchCancelDeposit(uint256[] calldata _validatorIds) external whenNotPaused {
        _batchCancelDeposit(_validatorIds, msg.sender);
    }

    function batchCancelDepositByAdmin(uint256[] calldata _validatorIds, address _bnftStaker) external whenNotPaused onlyAdmin {
        _batchCancelDeposit(_validatorIds, _bnftStaker);
    }

    function _batchCancelDeposit(uint256[] calldata _validatorIds, address _bnftStaker) internal {
        uint256 poolBalance = address(this).balance;
        
        uint256 cnts = 0;
        uint256 returnAmount;
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            if(nodesManager.phase(_validatorIds[i]) == IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL) {
                emit ValidatorRegistrationCanceled(_validatorIds[i]);
            } else {
                cnts += 1;
            }
        }

        returnAmount = cnts * 2 ether;
        numPendingDeposits -= uint32(cnts);
        stakingManager.batchCancelDepositAsBnftHolder(_validatorIds, _bnftStaker);

        _sendFund(_bnftStaker, returnAmount);
        assert (poolBalance == address(this).balance + returnAmount);
    }

    /// @notice The admin can register an address to become a BNFT holder. This adds them to the bnftHolders array
    /// @dev BNFT players reach out to Etherfi externally and then Etherfi will register them
    /// @param _user The address of the BNFT player to register
    function registerAsBnftHolder(address _user) public onlyAdmin {      
        require(!bnftHoldersIndexes[_user].registered, "Already registered");  

        //We hold the users address and latest deposit timestamp in an object to make sure a user doesnt deposit twice in one scheduling period
        BnftHolder memory bnftHolder = BnftHolder({
            holder: _user,
            timestamp: 0
        });

        uint256 index = bnftHolders.length;

        bnftHolders.push(bnftHolder);
        bnftHoldersIndexes[_user] = BnftHoldersIndex({
            registered: true,
            index: uint32(index)
        });

        emit BnftHolderRegistered(_user, index);
    }

    /// @notice Removes a BNFT player from the bnftHolders array and means they are no longer eligible to be selected
    /// @dev We allow either the user themselves or admins to remove BNFT players
    /// @param _bNftHolder Address of the BNFT player to remove
    function deRegisterBnftHolder(address _bNftHolder) external {
        require(bnftHoldersIndexes[_bNftHolder].registered, "Not registered");
        uint256 index = bnftHoldersIndexes[_bNftHolder].index;
        require(admins[msg.sender] || msg.sender == bnftHolders[index].holder, "Incorrect Caller");
        
        uint256 endIndex = bnftHolders.length - 1;
        address endUser = bnftHolders[endIndex].holder;

        //Swap the end BNFT player with the BNFT player being removed
        bnftHolders[index] = bnftHolders[endIndex];
        bnftHoldersIndexes[endUser].index = uint32(index);
        
        //Pop the last user as we have swapped them around
        bnftHolders.pop();
        delete bnftHoldersIndexes[_bNftHolder];

        emit BnftHolderDeregistered(_bNftHolder, index);
    }

    /// @notice Send the exit requests as the T-NFT holder
    function sendExitRequests(uint256[] calldata _validatorIds) external onlyAdmin {
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            uint256 validatorId = _validatorIds[i];
            nodesManager.sendExitRequest(validatorId);
        }
    }

    /// @notice Rebase by ether.fi
    function rebase(int128 _accruedRewards) public {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        totalValueOutOfLp = uint128(int128(totalValueOutOfLp) + _accruedRewards);

        emit Rebase(getTotalPooledEther(), eETH.totalShares());
    }

    /// @notice Whether or not nodes created via bNFT deposits should be restaked
    function setRestakeBnftDeposits(bool _restake) external onlyAdmin {
        restakeBnftDeposits = _restake;
    }

    /// @notice Updates the address of the admin
    /// @param _address the new address to set as admin
    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    function pauseContract() external onlyAdmin {
        paused = true;
        emit Paused(_msgSender());
    }

    function unPauseContract() external onlyAdmin {
        paused = false;
        emit Unpaused(_msgSender());
    }

    /// @notice Sets the max number of validators a BNFT can spin up in a batch
    /// @param _newSize the number to set it to
    function setNumValidatorsToSpinUpInBatch(uint128 _newSize) external onlyAdmin {
        maxValidatorsPerOwner = _newSize;
    }

    /// @notice Sets our targeted ratio of validators for each of the fund sources
    /// @dev Fund sources are different ways where the LP receives funds. Currently, there is just through EETH staking and ETHER_FAN (membership manager)
    /// @param _eEthWeight The target weight for eEth
    /// @param _etherFanWeight The target weight for EtherFan
    function setStakingTargetWeights(uint32 _eEthWeight, uint32 _etherFanWeight) external onlyAdmin {
        if (_eEthWeight + _etherFanWeight != 100) revert InvalidParams();

        fundStatistics[SourceOfFunds.EETH].targetWeight = _eEthWeight;
        fundStatistics[SourceOfFunds.ETHER_FAN].targetWeight = _etherFanWeight;
    }

    function updateWhitelistedAddresses(address[] calldata _users, bool _value) external onlyAdmin {
        for (uint256 i = 0; i < _users.length; i++) {
            whitelisted[_users[i]] = _value;

            emit UpdatedWhitelist(_users[i], _value);
        }
    }

    function updateWhitelistStatus(bool _value) external onlyAdmin {
        whitelistEnabled = _value;

        emit WhitelistStatusUpdated(_value);
    }

    /// @notice Decreases the number of validators for a certain source of fund
    /// @dev When a user deposits, we increment the number of validators in the allocated source object. However, when a BNFT player cancels 
    ///         their deposits, we need to decrease this again.
    /// @param numberOfEethValidators How many eEth validators to decrease
    /// @param numberOfEtherFanValidators How many etherFan validators to decrease
    function decreaseSourceOfFundsValidators(uint32 numberOfEethValidators, uint32 numberOfEtherFanValidators) external {
        if (msg.sender != address(stakingManager)) revert IncorrectCaller();

        fundStatistics[SourceOfFunds.EETH].numberOfValidators -= numberOfEethValidators;
        fundStatistics[SourceOfFunds.ETHER_FAN].numberOfValidators -= numberOfEtherFanValidators;
    }

    function addEthAmountLockedForWithdrawal(uint128 _amount) external {
        if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();

        ethAmountLockedForWithdrawal += _amount;
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    function _deposit(address _recipient, uint256 _amountInLp, uint256 _amountOutOfLp) internal returns (uint256) {
        totalValueInLp += uint128(_amountInLp);
        totalValueOutOfLp += uint128(_amountOutOfLp);
        uint256 amount = _amountInLp + _amountOutOfLp;
        uint256 share = _sharesForDepositAmount(amount);
        if (amount > type(uint128).max || amount == 0 || share == 0) revert InvalidAmount();

        eETH.mintShares(_recipient, share);

        return share;
    }

    function _sendFund(address _recipient, uint256 _amount) internal {
        if (_amount == 0) return;
        uint256 balanace = address(this).balance;
        (bool sent, ) = _recipient.call{value: _amount}("");
        assert (sent && address(this).balance == balanace - _amount);
    }

    function _isWhitelisted(address _user) internal view returns (bool) {
        return (!whitelistEnabled || whitelisted[_user]);
    }

    function _sharesForDepositAmount(uint256 _depositAmount) internal view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther() - _depositAmount;
        if (totalPooledEther == 0) {
            return _depositAmount;
        }
        return (_depositAmount * eETH.totalShares()) / totalPooledEther;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Selects a source of funds to be used for the deposits
    /// @dev The LP has two ways of accumulating funds, through eEth staking and through the ether fan page (membership manager).
    ///         We want to manipulate which funds we use per deposit. Example, if someone is making 2 deposits, we want to select where the 60 ETH
    ///         should come from. The funds will all be held in the LP but we are storing how many validators are spun up per source on the contract.
    ///         We simply check which of the sources is below their target allocation and allocate the deposits to it.
    /// @return The chosen source of funds (EETH or ETHER_FAN)
    function allocateSourceOfFunds() public view returns (SourceOfFunds) {
        if (fundStatistics[SourceOfFunds.EETH].numberOfValidators == 0) {
            return SourceOfFunds.EETH;
        }
        if (fundStatistics[SourceOfFunds.ETHER_FAN].numberOfValidators == 0) {
            return SourceOfFunds.ETHER_FAN;
        }

        uint256 validatorRatio = (fundStatistics[SourceOfFunds.EETH].numberOfValidators * 10_000) / fundStatistics[SourceOfFunds.ETHER_FAN].numberOfValidators;
        uint256 weightRatio = (fundStatistics[SourceOfFunds.EETH].targetWeight * 10_000) / fundStatistics[SourceOfFunds.ETHER_FAN].targetWeight;

        return validatorRatio > weightRatio ? SourceOfFunds.ETHER_FAN : SourceOfFunds.EETH;
    }

    function getTotalEtherClaimOf(address _user) external view returns (uint256) {
        uint256 staked;
        uint256 totalShares = eETH.totalShares();
        if (totalShares > 0) {
            staked = (getTotalPooledEther() * eETH.shares(_user)) / totalShares;
        }
        return staked;
    }

    function getTotalPooledEther() public view returns (uint256) {
        return totalValueOutOfLp + totalValueInLp;
    }

    function sharesForAmount(uint256 _amount) public view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther();
        if (totalPooledEther == 0) {
            return 0;
        }
        return (_amount * eETH.totalShares()) / totalPooledEther;
    }

    /// @dev withdrawal rounding errors favor the protocol by rounding up
    function sharesForWithdrawalAmount(uint256 _amount) public view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther();
        if (totalPooledEther == 0) {
            return 0;
        }

        // ceiling division so rounding errors favor the protocol
        uint256 numerator = _amount * eETH.totalShares();
        return (numerator + totalPooledEther - 1) / totalPooledEther;
    }

    function amountForShare(uint256 _share) public view returns (uint256) {
        uint256 totalShares = eETH.totalShares();
        if (totalShares == 0) {
            return 0;
        }
        return (_share * getTotalPooledEther()) / totalShares;
    }

    function getImplementation() external view returns (address) {return _getImplementation();}

    function _requireAdmin() internal view virtual {
        require(admins[msg.sender], "Not admin");
    }

    function _requireNotPaused() internal view virtual {
        require(!paused, "Pausable: paused");
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }
}

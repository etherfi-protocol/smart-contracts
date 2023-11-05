// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

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

    uint32 public numPendingDeposits; // number of deposits to the staking manager, which needs 'registerValidator'

    address public DEPRECATED_bNftTreasury;
    IWithdrawRequestNFT public withdrawRequestNFT;

    BnftHolder[] public bnftHolders;
    uint128 public maxValidatorsPerOwner;
    uint128 public schedulingPeriodInSeconds;

    HoldersUpdate public holdersUpdate;

    mapping(address => bool) public admins;
    mapping(SourceOfFunds => FundStatistics) public fundStatistics;
    mapping(uint256 => bytes32) public depositDataRootForApprovalDeposits;
    address public etherFiAdminContract;
    bool public whitelistEnabled;
    mapping(address => bool) public whitelisted;
    mapping(address => BnftHoldersIndex) public bnftHoldersIndexes;

    // TODO(Dave): Before we go to mainnet consider packing this with other variables
    bool public restakeBnftDeposits;
    uint128 public ethAmountLockedForWithdrawal;
    bool public paused;

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
    event ValidatorRegistered(uint256 validatorId, bytes signature, bytes pubKey, bytes32 depositRoot);
    event ValidatorApproved(uint256 validatorId);
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

    function initialize(address _eEthAddress, address _stakingManagerAddress, address _nodesManagerAddress, address _membershipManagerAddress, address _tNftAddress) external initializer {
        if (_eEthAddress == address(0) || _stakingManagerAddress == address(0) || _nodesManagerAddress == address(0) || _membershipManagerAddress == address(0) || _tNftAddress == address(0)) revert DataNotSet();
        
        __Ownable_init();
        __UUPSUpgradeable_init();

        eETH = IeETH(_eEthAddress);
        stakingManager = IStakingManager(_stakingManagerAddress);
        nodesManager = IEtherFiNodesManager(_nodesManagerAddress);
        membershipManager = IMembershipManager(_membershipManagerAddress);
        tNft = ITNFT(_tNftAddress);
    }

    /// @notice Allows us to set needed variable state in phase 2
    /// @dev This data and functions are used to help with our staking router process. This helps us balance the use of funds
    ///         being allocated to deposits. It also means we are able to give permissions to certain operators to run deposits only
    ///         only from specific deposits
    /// @param _schedulingPeriod the time we want between scheduling periods
    /// @param _eEthNumVal the number of validators to set for eEth
    /// @param _etherFanNumVal the number of validators to set for ether fan
    function initializeOnUpgrade(uint128 _schedulingPeriod, uint32 _eEthNumVal, uint32 _etherFanNumVal, address _etherFiAdminContract, address _withdrawRequestNFT) external onlyOwner { 
        require(_etherFiAdminContract != address(0) && _withdrawRequestNFT != address(0), "No zero addresses");

        paused = false;
        restakeBnftDeposits = false;
        ethAmountLockedForWithdrawal = 0;
        maxValidatorsPerOwner = 30;
        
        //Sets what scheduling period we will start with       
        schedulingPeriodInSeconds = _schedulingPeriod;

        //Allows us to begin with a predefined number of validators
        fundStatistics[SourceOfFunds.EETH].numberOfValidators = _eEthNumVal;
        fundStatistics[SourceOfFunds.ETHER_FAN].numberOfValidators = _etherFanNumVal;

        etherFiAdminContract = _etherFiAdminContract;
        withdrawRequestNFT = IWithdrawRequestNFT(_withdrawRequestNFT);

        admins[_etherFiAdminContract] = true;
    }

    // Used by eETH staking flow
    function deposit() external payable returns (uint256) {
        return deposit(address(0));
    }

    function deposit(address _referral) public payable whenNotPaused returns (uint256) {
        require(_isWhitelisted(msg.sender), "Invalid User");

        emit Deposit(msg.sender, msg.value, SourceOfFunds.EETH, _referral);

        return _deposit();
    }

    // Used by ether.fan staking flow
    function deposit(address _user, address _referral) external payable whenNotPaused returns (uint256) {
        if (msg.sender != address(membershipManager)) {
            revert IncorrectCaller();
        }
        require(_user == address(membershipManager) || _isWhitelisted(_user), "Invalid User");

        emit Deposit(msg.sender, msg.value, SourceOfFunds.ETHER_FAN, _referral);

        return _deposit();
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

        (bool sent, ) = _recipient.call{value: _amount}("");
        if (!sent) revert SendFail();

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

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient, 0);
        // transfer shares to WithdrawRequestNFT contract from this contract
        eETH.transferFrom(msg.sender, address(withdrawRequestNFT), amount);

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

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient, fee);
        // transfer shares to WithdrawRequestNFT contract
        eETH.transferFrom(msg.sender, address(withdrawRequestNFT), amount);

        emit Withdraw(msg.sender, recipient, amount, SourceOfFunds.ETHER_FAN);

        return requestId;
    } 

    error AboveMaxAllocation();

    /// @notice Allows a BNFT player to deposit their 2 ETH and pair with 30 ETH from the LP
    /// @dev This function has multiple dependencies that need to be followed before this function will succeed. 
    /// @param _candidateBidIds validator IDs that have been matched with the BNFT holder on the FE
    /// @param _numberOfValidators how many validators the user wants to spin up. This can be less than the candidateBidIds length. 
    ///         we may have more Ids sent in than needed to spin up incase some ids fail.
    /// @return Array of bids that were successfully processed.
    function batchDepositAsBnftHolder(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators) external payable whenNotPaused returns (uint256[] memory){
        //Checking which indexes form the schedule for the current scheduling period.
        (uint256 firstIndex, uint128 lastIndex) = dutyForWeek();
        uint32 index = bnftHoldersIndexes[msg.sender].index;

        //Need to make sure the BNFT player is assigned for the current period
        //See function for details
        require(isAssigned(firstIndex, lastIndex, index), "Not assigned");
        require(bnftHolders[index].timestamp < uint32(getCurrentSchedulingStartTimestamp()), "Already deposited");
        require(msg.value == _numberOfValidators * 2 ether, "Deposit 2 ETH per validator");
        require(totalValueInLp + msg.value >= 32 ether * _numberOfValidators, "Not enough balance");

        //BNFT players are eligible to spin up anything up to the max amount of validators allowed (maxValidatorsPerOwner),
        if(_numberOfValidators > maxValidatorsPerOwner) revert AboveMaxAllocation();
    
        //Funds in the LP can come from our membership strategy or the eEth staking strategy. We select which source of funds will
        //be used for spinning up these deposited ids. See the function for more detail on how we do this.
        SourceOfFunds _source = allocateSourceOfFunds();
        fundStatistics[_source].numberOfValidators += uint32(_numberOfValidators);

        uint256 amountFromLp = 30 ether * _numberOfValidators;
        if (amountFromLp > type(uint128).max) revert InvalidAmount();

        totalValueOutOfLp += uint128(amountFromLp);
        totalValueInLp -= uint128(amountFromLp);
        numPendingDeposits += uint32(_numberOfValidators);

        bnftHolders[index].timestamp = uint32(block.timestamp);

        //We then call the Staking Manager contract which handles the rest of the logic
        uint256[] memory newValidators = stakingManager.batchDepositWithBidIds{value: 32 ether * _numberOfValidators}(_candidateBidIds, msg.sender, _source, restakeBnftDeposits);
        
        //Sometimes not all the validators get deposited successfully. We need to check if there were remaining IDs that were not successful
        //and refund the BNFT player their 2 ETH for each ID
        if (_numberOfValidators > newValidators.length) {
            uint256 returnAmount = 2 ether * (_numberOfValidators - newValidators.length);
            totalValueOutOfLp += uint128(returnAmount);
            totalValueInLp -= uint128(returnAmount);
            numPendingDeposits -= uint32(_numberOfValidators - newValidators.length);

            (bool sent, ) = msg.sender.call{value: returnAmount}("");
            if (!sent) revert SendFail();
        }
        
        return newValidators;
    }

    /// @notice BNFT players register validators they have deposited. This triggers a 1 ETH transaction to the beacon chain.
    /// @dev This function can only be called by a BNFT player on IDs that have been deposited.  
    /// @param _depositRoot This is the deposit root of the beacon chain. Can send in 0x00 to bypass this check in future
    /// @param _validatorIds The ids of the validators to register
    /// @param _registerValidatorDepositData As in the solo staking flow, the BNFT player must send in a deposit data object (see ILiquidityPool for struct data)
    ///         to register the validators. However, the signature and deposit data root must be for a 1 ETH deposit
    /// @param _depositDataRootApproval The deposit data roots for each validator for the 31 ETH transaction which will happen in the approval
    ///         step. See the Staking Manager for details.
    /// @param _signaturesForApprovalDeposit Much like the deposit data root. This is the signature for each validator for the 31 ETH 
    ///         transaction which will happen in the approval step.
    function batchRegisterAsBnftHolder(
        bytes32 _depositRoot,
        uint256[] calldata _validatorIds,
        IStakingManager.DepositData[] calldata _registerValidatorDepositData,
        bytes32[] calldata _depositDataRootApproval,
        bytes[] calldata _signaturesForApprovalDeposit
    ) external whenNotPaused {
        require(_validatorIds.length == _registerValidatorDepositData.length && _validatorIds.length == _depositDataRootApproval.length && _validatorIds.length == _signaturesForApprovalDeposit.length, "lengths differ");

        stakingManager.batchRegisterValidators(_depositRoot, _validatorIds, msg.sender, address(this), _registerValidatorDepositData, msg.sender);
        
        //For each validator, we need to store the deposit data root of the 31 ETH transaction so it is accessible in the approve function
        for(uint256 i; i < _validatorIds.length; i++) {
            depositDataRootForApprovalDeposits[_validatorIds[i]] = _depositDataRootApproval[i];
            emit ValidatorRegistered(_validatorIds[i], _signaturesForApprovalDeposit[i], _registerValidatorDepositData[i].publicKey, _depositDataRootApproval[i]);
        }
    }

    /// @notice Approves validators and triggers the 31 ETH transaction to the beacon chain (rest of the stake).
    /// @dev This gets called by the Oracle and only when it has confirmed the withdraw credentials of the 1 ETH deposit in the registration
    ///         phase match the withdraw credentials stored on the beacon chain. This prevents a front-running attack.
    /// @param _validatorIds The IDs of the validators to be approved
    /// @param _pubKey The pubKey for each validator being spun up.
    /// @param _signature The signatures for each validator for the 31 ETH transaction that were emitted in the register phase
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

        numPendingDeposits -= uint32(_validatorIds.length);
        stakingManager.batchApproveRegistration(_validatorIds, _pubKey, _signature, depositDataRootApproval);
    }

    /// @notice Cancels a BNFT players deposits (whether validator is registered or deposited. Just not live on beacon chain)
    /// @dev This is called only in the BNFT player flow
    /// @param _validatorIds The IDs to be cancelled
    function batchCancelDeposit(uint256[] calldata _validatorIds) external whenNotPaused {
        uint256 returnAmount;

        //Due to the way we handle our totalValueOutOfLP calculations, we need to update the data before we call the Staking Manager
        //For this reason, we first need to check which phase each validator is in. Because if a bNFT cancels a validator that has 
        //already been registered, they only receive 1 ETH back because the other 1 ETH is in the beacon chain. Those funds will be lost
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            if(nodesManager.phase(_validatorIds[i]) == IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL) {
                returnAmount += 1 ether;
            } else {
                returnAmount += 2 ether;
            }
        }

        totalValueOutOfLp += uint128(returnAmount);
        numPendingDeposits -= uint32(_validatorIds.length);
        stakingManager.batchCancelDepositAsBnftHolder(_validatorIds, msg.sender);
        totalValueInLp -= uint128(returnAmount);
        
        (bool sent, ) = address(msg.sender).call{value: returnAmount}("");
        if (!sent) revert SendFail();
    }

    /// @notice The admin can register an address to become a BNFT holder. This adds them to the bnftHolders array
    /// @dev BNFT players reach out to Etherfi externally and then Etherfi will register them
    /// @param _user The address of the BNFT player to register
    function registerAsBnftHolder(address _user) public onlyAdmin {      
        require(!bnftHoldersIndexes[_user].registered, "Already registered");  

        //We update the holdersUpdate data for help in calculation of the duty for the week.
        _checkHoldersUpdateStatus();

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

    /// @notice Calculate which BNFT players are currently scheduled and assigned to deposit as a BNFT player.
    ///         We don't hold any data, just have the function return a start and finish index of the selected users in the array.
    ///         When a user deposits, it calls this function and checks if the user depositing fits inside the first and last index returnd
    ///         by this function. The indices can wrap around as well. Lets look at an example of a BNFT array with size 10.
    ///
    ///         Example:
    ///         [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]  => firstIndex = 7
    ///                                         => lastIndex = 2
    ///         Therefore: the selected range would be users [7, 8, 9, 0, 1, 2]. We use the isAssigned function to check if the user is in the selected indices.
    ///
    /// @return The first index that has been chosen in the array of BNFT holders
    /// @return The last index that has been chosen in the array of BNFT holders
    function dutyForWeek() public view returns (uint256, uint128) {
        // Early termindation if there are no validators to spin up
        uint32 numValidatorsToSpinUp = IEtherFiAdmin(etherFiAdminContract).numValidatorsToSpinUp();
        if(maxValidatorsPerOwner == 0 || numValidatorsToSpinUp == 0 || numValidatorsToSpinUp / maxValidatorsPerOwner == 0) {
            return (0,0);
        }

        // Fetches a random index in the array. We will use this as the start index.
        uint256 index = _getSlotIndex();

        // Get the number of BNFT holders we need to spin up the validators
        uint128 size = numValidatorsToSpinUp / maxValidatorsPerOwner;

        // We use this function to fetch what the last index in the selection will be.
        uint128 lastIndex = _fetchLastIndex(size, index);

        return (index, lastIndex);
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

    /// @notice Sets the max number of validators a BNFT can spin up in a given scheduling period
    /// @param _newSize the number to set it to
    function setNumValidatorsToSpinUpPerSchedulePerBnftHolder(uint128 _newSize) external onlyAdmin {
        maxValidatorsPerOwner = _newSize;
    }

    /// @notice This sets how many seconds will be in a scheduling period for BNFT players
    /// @dev This time period gets used in the dutyForWeek function.
    /// @param _schedulingPeriodInSeconds The number of seconds to set as the new time period
    function setSchedulingPeriodInSeconds(uint128 _schedulingPeriodInSeconds) external onlyAdmin {
        schedulingPeriodInSeconds = _schedulingPeriodInSeconds;

        emit UpdatedSchedulingPeriod(_schedulingPeriodInSeconds);
    }

    /// @notice View function to tell other functions how many users are currently eligible for selection
    /// @dev If no-one has registered in the current scheduling period then we return the length of the array otherwise,
    ///         we return the length of the array before the newly registered BNFT players
    /// @return numberOfActiveSlots The number of BNFT holders eligible for selection
    function numberOfActiveSlots() public view returns (uint32 numberOfActiveSlots) {
        numberOfActiveSlots = uint32(bnftHolders.length);
        if(holdersUpdate.timestamp > uint32(getCurrentSchedulingStartTimestamp())) {
            numberOfActiveSlots = holdersUpdate.startOfSlotNumOwners;
        }
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

    function _deposit() internal returns (uint256) {
        totalValueInLp += uint128(msg.value);
        uint256 share = _sharesForDepositAmount(msg.value);
        if (msg.value > type(uint128).max || msg.value == 0 || share == 0) revert InvalidAmount();

        eETH.mintShares(msg.sender, share);

        return share;
    }

    /// @notice We use this to update our holders struct. This stores how many BNFT players are currently eligible to be selected.
    ///         For example, if a BNFT holder has just registered, they are not eligible for selection until the next scheduling period starts.
    /// @dev This struct helps us keep dutyForWeek stateless. It keeps track of the timestamp which is used in numberOfActiveSlots.
    function _checkHoldersUpdateStatus() internal {
        if(holdersUpdate.timestamp < uint32(getCurrentSchedulingStartTimestamp())) {
            holdersUpdate.startOfSlotNumOwners = uint32(bnftHolders.length);
        }
        holdersUpdate.timestamp = uint32(block.timestamp);
    }

    /// @notice Uses a generic random number generated to calculate a starting index in the bNFT holder array
    /// @dev We feel that because a user is not eligible to be selected in the period they are registered, we do not need a more secure 
    ///         random number generator. Fetching the random number in advance wont help a user manipulate the protocol.
    /// @return A starting index for dutyForWeek to use.
    function _getSlotIndex() internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp / schedulingPeriodInSeconds))) % numberOfActiveSlots();
    }

    /// @notice Explain to an end user what this does
    /// @dev Explain to a developer any extra details
    /// @param _size how many BNFT players will be needed to fill the allotment 
    /// @param _index The first index that we need to start from
    /// @return lastIndex the last index to be used in the selection for the current schedule
    function _fetchLastIndex(uint128 _size, uint256 _index) internal view returns (uint128 lastIndex){
        uint32 numSlots = numberOfActiveSlots();
        uint128 tempLastIndex = uint128(_index) + _size - 1;
        lastIndex = (tempLastIndex + uint128(numSlots)) % uint128(numSlots);
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
        uint256 validatorRatio = (fundStatistics[SourceOfFunds.EETH].numberOfValidators * 10_000) / fundStatistics[SourceOfFunds.ETHER_FAN].numberOfValidators;
        uint256 weightRatio = (fundStatistics[SourceOfFunds.EETH].targetWeight * 10_000) / fundStatistics[SourceOfFunds.ETHER_FAN].targetWeight;

        return validatorRatio > weightRatio ? SourceOfFunds.ETHER_FAN : SourceOfFunds.EETH;
    }

    /// @notice Fetching the starting timestamp of the current scheduling period
    /// @return The timestamp of the begging of the current scheduling period
    function getCurrentSchedulingStartTimestamp() public view returns (uint256) {
        return block.timestamp - (block.timestamp % schedulingPeriodInSeconds);
    }

    /// @notice Checks whether the BNFT player with _index is assigned
    /// @dev Because we allow a sliding window type selection, we use strict conditions to check whether the provided index is 
    ///         inside the first and last index.
    /// @param _firstIndex The index of the first selected BNFT holder
    /// @param _lastIndex The index of the last selected BNFT holder
    /// @param _index The index of the BNFT we are checking
    /// @return Bool value if the BNFT player is assigned or not
    function isAssigned(uint256 _firstIndex, uint128 _lastIndex, uint256 _index) public view returns (bool) {
        if(_lastIndex < _firstIndex) {
            return (_index <= _lastIndex) || (_index >= _firstIndex && _index < numberOfActiveSlots());
        }else {
            return _index >= _firstIndex && _index <= _lastIndex;
        }
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

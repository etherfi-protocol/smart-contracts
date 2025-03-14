// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IRegulationsManager.sol";
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
import "./RoleRegistry.sol";

import "./EtherFiRedemptionManager.sol";


contract LiquidityPool is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILiquidityPool {
    using SafeERC20 for IERC20;
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

    address public feeRecipient;

    uint32 public numPendingDeposits; // number of validator deposits, which needs 'registerValidator'

    address public DEPRECATED_bNftTreasury;
    IWithdrawRequestNFT public withdrawRequestNFT;

    BnftHolder[] public DEPRECATED_bnftHolders;
    uint128 public DEPRECATED_maxValidatorsPerOwner;
    uint128 public DEPRECATED_schedulingPeriodInSeconds;

    HoldersUpdate public DEPRECATED_holdersUpdate;

    mapping(address => bool) public DEPRECATED_admins;
    mapping(SourceOfFunds => FundStatistics) public DEPRECATED_fundStatistics;
    mapping(uint256 => bytes32) public depositDataRootForApprovalDeposits;
    address public etherFiAdminContract;
    bool public DEPRECATED_whitelistEnabled;
    mapping(address => bool) public DEPRECATED_whitelisted;
    mapping(address => ValidatorSpawner) public validatorSpawner;

    bool public restakeBnftDeposits;
    uint128 public ethAmountLockedForWithdrawal;
    bool public paused;
    IAuctionManager public auctionManager;
    ILiquifier public liquifier;

    bool private DEPRECATED_isLpBnftHolder;

    EtherFiRedemptionManager public etherFiRedemptionManager;

    RoleRegistry public roleRegistry;
    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant LIQUIDITY_POOL_ADMIN_ROLE = keccak256("LIQUIDITY_POOL_ADMIN_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event Paused(address account);
    event Unpaused(address account);

    event Deposit(address indexed sender, uint256 amount, SourceOfFunds source, address referral);
    event Withdraw(address indexed sender, address recipient, uint256 amount, SourceOfFunds source);
    event UpdatedWhitelist(address userAddress, bool value);
    event UpdatedTreasury(address newTreasury); 
    event UpdatedFeeRecipient(address newFeeRecipient);
    event BnftHolderDeregistered(address user, uint256 index);
    event BnftHolderRegistered(address user, uint256 index);
    event ValidatorSpawnerRegistered(address user);
    event ValidatorSpawnerUnregistered(address user);
    event ValidatorRegistered(uint256 indexed validatorId, bytes signature, bytes pubKey, bytes32 depositRoot);
    event ValidatorApproved(uint256 indexed validatorId);
    event ValidatorRegistrationCanceled(uint256 indexed validatorId);
    event Rebase(uint256 totalEthLocked, uint256 totalEEthShares);
    event ProtocolFeePaid(uint128 protocolFees);
    event WhitelistStatusUpdated(bool value);

    error IncorrectCaller();
    error InvalidAmount();
    error DataNotSet();
    error InsufficientLiquidity();
    error SendFail();
    error IncorrectRole();

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
        restakeBnftDeposits = false;
        ethAmountLockedForWithdrawal = 0;
        etherFiAdminContract = _etherFiAdminContract;
        withdrawRequestNFT = IWithdrawRequestNFT(_withdrawRequestNFT);
        DEPRECATED_isLpBnftHolder = false;
    }

    function initializeOnUpgrade(address _auctionManager, address _liquifier) external onlyOwner { 
        require(_auctionManager != address(0) && _liquifier != address(0) && address(auctionManager) == address(0) && address(liquifier) == address(0), "Invalid");

        auctionManager = IAuctionManager(_auctionManager);
        liquifier = ILiquifier(_liquifier);
    }

    // Note: Call this function when no validators to approve
    function initializeVTwoDotFourNine(address _roleRegistry, address _etherFiRedemptionManager) external onlyOwner {
        require(address(etherFiRedemptionManager) == address(0) && _etherFiRedemptionManager != address(0), "Invalid");
        require(address(roleRegistry) == address(0x00), "already initialized");

        etherFiRedemptionManager = EtherFiRedemptionManager(payable(_etherFiRedemptionManager)); 
        roleRegistry = RoleRegistry(_roleRegistry);

        //correct splits
        uint128 tvl = uint128(getTotalPooledEther());
        totalValueInLp = uint128(address(this).balance);
        totalValueOutOfLp = tvl - totalValueInLp;

        if(tvl != getTotalPooledEther()) revert();
    }
    
    // Used by eETH staking flow
    function deposit() external payable returns (uint256) {
        return deposit(address(0));
    }

    // Used by eETH staking flow
    function deposit(address _referral) public payable whenNotPaused returns (uint256) {
        emit Deposit(msg.sender, msg.value, SourceOfFunds.EETH, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    // Used by eETH staking flow through Liquifier contract; deVamp or to pay protocol fees
    function depositToRecipient(address _recipient, uint256 _amount, address _referral) public whenNotPaused returns (uint256) {
        require(msg.sender == address(liquifier) || msg.sender == address(etherFiAdminContract), "Incorrect Caller");

        emit Deposit(_recipient, _amount, SourceOfFunds.EETH, _referral);

        return _deposit(_recipient, 0, _amount);
    }

    // Used by ether.fan staking flow
    function deposit(address _user, address _referral) external payable whenNotPaused returns (uint256) {
        require(msg.sender == address(membershipManager), "Incorrect Caller");

        emit Deposit(msg.sender, msg.value, SourceOfFunds.ETHER_FAN, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    /// @notice withdraw from pool
    /// @dev Burns user share from msg.senders account & Sends equivalent amount of ETH back to the recipient
    /// @param _recipient the recipient who will receives the ETH
    /// @param _amount the amount to withdraw from contract
    /// it returns the amount of shares burned
    function withdraw(address _recipient, uint256 _amount) external whenNotPaused returns (uint256) {
        uint256 share = sharesForWithdrawalAmount(_amount);
        require(msg.sender == address(withdrawRequestNFT) || msg.sender == address(membershipManager) || msg.sender == address(etherFiRedemptionManager), "Incorrect Caller");
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
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(withdrawRequestNFT), amount);

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
        try eETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
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
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(withdrawRequestNFT), amount);

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient, fee);

        emit Withdraw(msg.sender, recipient, amount, SourceOfFunds.ETHER_FAN);

        return requestId;
    }

    // [Liquidty Pool Staking flow]
    // Step 1: [Deposit] initiate spinning up the validators & allocate withdrawal safe contracts
    // Step 2: (Off-chain) create the keys using the desktop app
    // Step 3: [Register] register the validator keys sending 1 ETH to the eth deposit contract
    // Step 4: wait for the oracle to approve and send the rest 31 ETH to the eth deposit contract

    /// Step 1. [Deposit]
    /// @param _candidateBidIds validator IDs that have been matched with the BNFT holder on the FE
    /// @param _numberOfValidators how many validators the user wants to spin up. This can be less than the candidateBidIds length. 
    function batchDeposit(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators) external whenNotPaused returns (uint256[] memory) {
        return batchDeposit(_candidateBidIds, _numberOfValidators, 0);
    }

    /// @param _candidateBidIds the bid IDs of the node operators that the spawner wants to spin up validators for
    /// @param _numberOfValidators how many validators the user wants to spin up; `len(_candidateBidIds)` must be >= `_numberOfValidators`
    /// @param _validatorIdToShareSafeWith the validator ID of the validator that the spawner wants to shafe the withdrawal safe with
    /// @return Array of bid IDs that were successfully processed.
    function batchDeposit(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators, uint256 _validatorIdToShareSafeWith) public whenNotPaused returns (uint256[] memory) {
        address tnftHolder = address(this);
        address bnftHolder = address(this);

        require(validatorSpawner[msg.sender].registered, "Incorrect Caller");        
        require(totalValueInLp  >= 32 ether * _numberOfValidators, "Not enough balance");

        uint256[] memory newValidators = stakingManager.batchDepositWithBidIds(_candidateBidIds, _numberOfValidators, msg.sender, tnftHolder, bnftHolder, SourceOfFunds.EETH, restakeBnftDeposits, _validatorIdToShareSafeWith);
        numPendingDeposits += uint32(newValidators.length);
        
        return newValidators;
    }

    /// Step 3. [Register]
    /// @notice register validators' keys and trigger a 1 ETH transaction to the beacon chain.
    /// @param _validatorIds the ids of the validators to register
    /// @param _registerValidatorDepositData the signature and deposit data root for a 1 ETH deposit
    /// @param _depositDataRootApproval the root hash of the deposit data for the 31 ETH deposit which will happen in the approval step
    /// @param _signaturesForApprovalDeposit the signature for the 31 ETH deposit which will happen in the approval step.
    function batchRegister(
        bytes32 _depositRoot,
        uint256[] calldata _validatorIds,
        IStakingManager.DepositData[] calldata _registerValidatorDepositData,
        bytes32[] calldata _depositDataRootApproval,
        bytes[] calldata _signaturesForApprovalDeposit
    ) external whenNotPaused {
        address _bnftRecipient = address(this);

        require(validatorSpawner[msg.sender].registered, "Incorrect Caller");        
        require(_validatorIds.length == _registerValidatorDepositData.length && _validatorIds.length == _depositDataRootApproval.length && _validatorIds.length == _signaturesForApprovalDeposit.length, "lengths differ");
        
        numPendingDeposits -= uint32(_validatorIds.length);

        // As the LP is the B-nft holder, the 1 ether (for each validator) is taken from the LP
        uint256 outboundEthAmountFromLp = 1 ether * _validatorIds.length;
        _accountForEthSentOut(outboundEthAmountFromLp);

        stakingManager.batchRegisterValidators{value: outboundEthAmountFromLp}(_depositRoot, _validatorIds, _bnftRecipient, address(this), _registerValidatorDepositData, msg.sender);
        
        for(uint256 i; i < _validatorIds.length; i++) {
            depositDataRootForApprovalDeposits[_validatorIds[i]] = _depositDataRootApproval[i];
            emit ValidatorRegistered(_validatorIds[i], _signaturesForApprovalDeposit[i], _registerValidatorDepositData[i].publicKey, _depositDataRootApproval[i]);
        }
    }

    //. Step 4. [Approve]
    /// @notice Approves validators and triggers the 31 ETH deposit to the beacon chain
    /// @dev This gets called by the Oracle only when it has confirmed the withdraw credentials of the 1 ETH deposit in the registration
    ///         phase match the withdraw credentials stored on the beacon chain. This prevents a front-running attack.
    /// @param _validatorIds the IDs of the validators to be approved
    /// @param _pubKey the pubKey for each validator being spun up.
    /// @param _signature the signatures for each validator for the 31 ETH deposit that were emitted in the register phase
    function batchApproveRegistration(
        uint256[] memory _validatorIds, 
        bytes[] calldata _pubKey,
        bytes[] calldata _signature
    ) external whenNotPaused {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        require(_validatorIds.length == _pubKey.length && _validatorIds.length == _signature.length, "lengths differ");

        bytes32[] memory depositDataRootApproval = new bytes32[](_validatorIds.length);
        for(uint256 i; i < _validatorIds.length; i++) {
            depositDataRootApproval[i] = depositDataRootForApprovalDeposits[_validatorIds[i]];
            delete depositDataRootForApprovalDeposits[_validatorIds[i]];        

            emit ValidatorApproved(_validatorIds[i]);
        }

        // As the LP is the T-NFT holder, the 31 ETH is taken from the LP for each validator
        uint256 outboundEthAmountFromLp = 31 ether * _validatorIds.length;
        _accountForEthSentOut(outboundEthAmountFromLp);

        stakingManager.batchApproveRegistration{value: outboundEthAmountFromLp}(_validatorIds, _pubKey, _signature, depositDataRootApproval);
    }

    /// @notice Cancels the process
    /// @param _validatorIds the IDs to be cancelled
    /// Note that if the spawner cancels the flow after the registration (where the 1 ETH deposit is made), the 1 ETH refund must be made manually
    /// Until then the 1 ETH is considered as a loss
    /// Be careful not to cancel the registration after the approval phase
    function batchCancelDeposit(uint256[] calldata _validatorIds) external whenNotPaused {
        address bnftHolder = address(this);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            if(nodesManager.phase(_validatorIds[i]) == IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL) {
                totalValueOutOfLp -= 1 ether;

                emit ValidatorRegistrationCanceled(_validatorIds[i]);
            }
            else numPendingDeposits -= 1;
        }

        stakingManager.batchCancelDepositAsBnftHolder(_validatorIds, msg.sender);
    }

    /// @notice The admin can register an address to become a BNFT holder
    /// @param _user The address of the Validator Spawner to register
    function registerValidatorSpawner(address _user) public {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        require(!validatorSpawner[_user].registered, "Already registered");  

        validatorSpawner[_user] = ValidatorSpawner({registered: true});

        emit ValidatorSpawnerRegistered(_user);
    }

    /// @notice Removes a Validator Spawner
    /// @param _user the address of the Validator Spawner to remove
    function unregisterValidatorSpawner(address _user) external {
        require(validatorSpawner[_user].registered, "Not registered");
        require(roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender), "Incorrect Caller");
        
        delete validatorSpawner[_user];

        emit ValidatorSpawnerUnregistered(_user);
    }

    /// @notice Send the exit requests as the T-NFT holder of the LiquidityPool validators
    function sendExitRequests(uint256[] calldata _validatorIds) external {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        
        nodesManager.batchSendExitRequest(_validatorIds);
    }

    /// @notice Rebase by ether.fi
    function rebase(int128 _accruedRewards) public {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        totalValueOutOfLp = uint128(int128(totalValueOutOfLp) + _accruedRewards);

        emit Rebase(getTotalPooledEther(), eETH.totalShares());
    }
    /// @notice pay protocol fees including 5% to treaury, 5% to node operator and ethfund bnft holders
    /// @param _protocolFees The amount of protocol fees to pay in ether
    function payProtocolFees(uint128 _protocolFees) external {
        if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();   
        emit ProtocolFeePaid(_protocolFees);
        depositToRecipient(feeRecipient, _protocolFees, address(0));
    }

    /// @notice Set the fee recipient address
    /// @param _feeRecipient The address to set as the fee recipient
    function setFeeRecipient(address _feeRecipient) external {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        feeRecipient = _feeRecipient;
        emit UpdatedFeeRecipient(_feeRecipient);
    }

    /// @notice Whether or not nodes created via bNFT deposits should be restaked
    function setRestakeBnftDeposits(bool _restake) external {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        restakeBnftDeposits = _restake;
    }

    // Pauses the contract
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        if (paused) revert("Pausable: already paused");
        
        paused = true;
        emit Paused(msg.sender);
    }

    // Unpauses the contract
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (!paused) revert("Pausable: not paused");

        paused = false;
        emit Unpaused(msg.sender);
    }

    // Deprecated, just existing not to touch EtherFiAdmin contract
    function setStakingTargetWeights(uint32 _eEthWeight, uint32 _etherFanWeight) external {
    }

    function addEthAmountLockedForWithdrawal(uint128 _amount) external {
        if (!(msg.sender == address(etherFiAdminContract))) revert IncorrectCaller();

        ethAmountLockedForWithdrawal += _amount;
    }

    function burnEEthShares(uint256 shares) external {
        if (msg.sender != address(etherFiRedemptionManager) && msg.sender != address(withdrawRequestNFT)) revert IncorrectCaller();
        eETH.burnShares(msg.sender, shares);
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

    function _sharesForDepositAmount(uint256 _depositAmount) internal view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther() - _depositAmount;
        if (totalPooledEther == 0) {
            return _depositAmount;
        }
        return (_depositAmount * eETH.totalShares()) / totalPooledEther;
    }

    function _sendFund(address _recipient, uint256 _amount) internal {
        uint256 balance = address(this).balance;
        (bool sent, ) = _recipient.call{value: _amount}("");
        require(sent && address(this).balance >= balance - _amount, "SendFail");
    }

    function _accountForEthSentOut(uint256 _amount) internal {
        totalValueOutOfLp += uint128(_amount);
        totalValueInLp -= uint128(_amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

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

    function _requireNotPaused() internal view virtual {
        require(!paused, "Pausable: paused");
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }
}

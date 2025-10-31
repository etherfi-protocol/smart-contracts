// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./EtherFiRedemptionManager.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/ILiquifier.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IRoleRegistry.sol";

contract LiquidityPool is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILiquidityPool {
    using SafeERC20 for IERC20;

    address public constant MEMBERSHIP_MANAGER = 0x3d320286E014C3e1ce99Af6d6B00f0C1D63E3000;
    address public constant ETHERFI_ADMIN_CONTRACT = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    address public constant LIQUIFIER = 0x9FFDF407cDe9a93c47611799DA23924Af3EF764F;
    address public constant ETHERFI_REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;

    IStakingManager public constant stakingManager = IStakingManager(0x25e821b7197B146F7713C3b89B6A4D83516B912d);
    IRoleRegistry public constant roleRegistry = IRoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);
    IEtherFiNodesManager public constant nodesManager = IEtherFiNodesManager(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F);
    IeETH public constant eETH = IeETH(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
    IWithdrawRequestNFT public constant withdrawRequestNFT = IWithdrawRequestNFT(0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c);

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IStakingManager public DEPRECATED_stakingManager;
    IEtherFiNodesManager public DEPRECATED_nodesManager;
    address public DEPRECATED_regulationsManager;
    address public DEPRECATED_membershipManager;
    address public DEPRECATED_TNFT;
    IeETH public DEPRECATED_eETH; 
    bool public DEPRECATED_eEthliquidStakingOpened;

    uint128 public totalValueOutOfLp;
    uint128 public totalValueInLp;
    address public feeRecipient;
    uint32 public numPendingDeposits; // number of validator deposits, which needs 'registerValidator'

    address public DEPRECATED_bNftTreasury;
    IWithdrawRequestNFT public DEPRECATED_withdrawRequestNFT;
    BnftHolder[] public DEPRECATED_bnftHolders;
    uint128 public DEPRECATED_maxValidatorsPerOwner;
    uint128 public DEPRECATED_schedulingPeriodInSeconds;
    HoldersUpdate public DEPRECATED_holdersUpdate;
    mapping(address => bool) public DEPRECATED_admins;
    mapping(SourceOfFunds => FundStatistics) public DEPRECATED_fundStatistics;
    
    mapping(uint256 => bytes32) public depositDataRootForApprovalDeposits;
    
    address public DEPRECATED_etherFiAdminContract;
    bool public DEPRECATED_whitelistEnabled;
    mapping(address => bool) public DEPRECATED_whitelisted;
    
    mapping(address => ValidatorSpawner) public validatorSpawner;
    bool public restakeBnftDeposits;
    uint128 public ethAmountLockedForWithdrawal;
    bool public paused;

    address public DEPRECATED_auctionManager;
    ILiquifier public DEPRECATED_liquifier;
    bool private DEPRECATED_isLpBnftHolder;
    EtherFiRedemptionManager public DEPRECATED_etherFiRedemptionManager;
    IRoleRegistry public DEPRECATED_roleRegistry;

    uint256 public validatorSizeWei;
    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant LIQUIDITY_POOL_ADMIN_ROLE = keccak256("LIQUIDITY_POOL_ADMIN_ROLE");
    bytes32 public constant LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE = keccak256("LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE");
    bytes32 public constant LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE = keccak256("LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE");

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
    event ValidatorExitRequested(uint256 indexed validatorId);

    error IncorrectCaller();
    error InvalidAmount();
    error DataNotSet();
    error InsufficientLiquidity();
    error SendFail();
    error IncorrectRole();
    error InvalidEtherFiNode();
    error InvalidValidatorSize();
    error AlreadyPaused();
    error NotPaused();
    error AlreadyRegistered();
    error NotRegistered();

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
        if (msg.sender != LIQUIFIER && msg.sender != ETHERFI_ADMIN_CONTRACT) revert IncorrectCaller();

        emit Deposit(_recipient, _amount, SourceOfFunds.EETH, _referral);

        return _deposit(_recipient, 0, _amount);
    }

    // Used by ether.fan staking flow
    function deposit(address _user, address _referral) external payable whenNotPaused returns (uint256) {
        if (msg.sender != MEMBERSHIP_MANAGER) revert IncorrectCaller();

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
        if (msg.sender != address(withdrawRequestNFT) && msg.sender != MEMBERSHIP_MANAGER && msg.sender != ETHERFI_REDEMPTION_MANAGER) revert IncorrectCaller();
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
        if (msg.sender != MEMBERSHIP_MANAGER) revert IncorrectCaller();
        uint256 share = sharesForAmount(amount);
        if (amount > type(uint96).max || amount == 0 || share == 0) revert InvalidAmount();

        // transfer shares to WithdrawRequestNFT contract
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(withdrawRequestNFT), amount);

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient, fee);

        emit Withdraw(msg.sender, recipient, amount, SourceOfFunds.ETHER_FAN);

        return requestId;
    }


    //---------------------------------------------------------------------------
    //---------------------- Staking/Deposit Flow -------------------------------
    //---------------------------------------------------------------------------

    // [Liquidty Pool Staking flow]
    // Step 1: (Off-chain) create the keys using the desktop app
    // Step 2: register validator deposit data for later confirmation from the oracle before the 1eth deposit
    // Step 3: create validators with 1 eth deposits to official deposit contract
    // Step 4: oracle approves and funds the remaining balance for the validator

    /// @notice claim bids and send 1 eth deposits to deposit contract to create the provided validators.
    /// @dev step 2 of staking flow
    function batchRegister(
        IStakingManager.DepositData[] calldata _depositData,
        uint256[] calldata _bidIds,
        address _etherFiNode
    ) external whenNotPaused {
        if (!validatorSpawner[msg.sender].registered) revert NotRegistered();
        stakingManager.registerBeaconValidators(_depositData, _bidIds, _etherFiNode);
    }

    function batchCreateBeaconValidators(
        IStakingManager.DepositData[] calldata _depositData,
        uint256[] calldata _bidIds,
        address _etherFiNode
    ) external whenNotPaused {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE, msg.sender)) revert IncorrectRole();

        // liquidity pool supplies 1 eth per validator
        uint256 outboundEthAmountFromLp = 1 ether * _bidIds.length;
        _accountForEthSentOut(outboundEthAmountFromLp);

        stakingManager.createBeaconValidators{value: outboundEthAmountFromLp}(_depositData, _bidIds, _etherFiNode);
    }

    /// @notice send remaining eth to deposit contract to activate the provided validators
    /// @dev step 3 of staking flow. This version exists to remain compatible with existing callers.
    ///   future services should use confirmAndFundBeaconValidators()
     function batchApproveRegistration(
        uint256[] memory _validatorIds,
        bytes[] calldata _pubkeys,
        bytes[] calldata _signatures
    ) external whenNotPaused {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE, msg.sender)) revert IncorrectRole();
        if (validatorSizeWei < 32 ether || validatorSizeWei > 2048 ether) revert InvalidValidatorSize();

        // all validators provided should belong to same node
        IEtherFiNode etherFiNode = IEtherFiNode(nodesManager.etherfiNodeAddress(_validatorIds[0]));
        address eigenPod = address(etherFiNode.getEigenPod());
        bytes memory withdrawalCredentials = nodesManager.addressToCompoundingWithdrawalCredentials(eigenPod);

        // we have already deposited the initial amount to create the validator on the beacon chain
        uint256 remainingEthPerValidator = validatorSizeWei - stakingManager.initialDepositAmount();

        // In order to maintain compatibility with current callers in this upgrade
        // need to construct data from old format
        IStakingManager.DepositData[] memory depositData = new IStakingManager.DepositData[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            // enforce that all validators are part of same node
            if (address(etherFiNode) != address(nodesManager.etherfiNodeAddress(_validatorIds[i]))) revert InvalidEtherFiNode();

            bytes32 confirmDepositDataRoot = stakingManager.generateDepositDataRoot(
                _pubkeys[i],
                _signatures[i],
                withdrawalCredentials,
                remainingEthPerValidator
            );
            IStakingManager.DepositData memory confirmDepositData = IStakingManager.DepositData({
                publicKey: _pubkeys[i],
                signature: _signatures[i],
                depositDataRoot: confirmDepositDataRoot,
                ipfsHashForEncryptedValidatorKey: ""
            });
            depositData[i] = confirmDepositData;
        }

        uint256 outboundEthAmountFromLp = remainingEthPerValidator * _validatorIds.length;
        _accountForEthSentOut(outboundEthAmountFromLp);

        stakingManager.confirmAndFundBeaconValidators{value: outboundEthAmountFromLp}(depositData, validatorSizeWei);
    }

    /// @notice send remaining eth to deposit contract to activate the provided validators
    /// @dev step 3 of staking flow
    function confirmAndFundBeaconValidators(
        IStakingManager.DepositData[] calldata _depositData,
        uint256 _validatorSizeWei
    ) external whenNotPaused {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE, msg.sender)) revert IncorrectRole();
        if (_validatorSizeWei < 32 ether || _validatorSizeWei > 2048 ether) revert InvalidValidatorSize();

        // we have already deposited the initial amount to create the validator on the beacon chain
        uint256 remainingEthPerValidator = _validatorSizeWei - stakingManager.initialDepositAmount();

        uint256 outboundEthAmountFromLp = remainingEthPerValidator * _depositData.length;
        _accountForEthSentOut(outboundEthAmountFromLp);

        stakingManager.confirmAndFundBeaconValidators{value: outboundEthAmountFromLp}(_depositData, _validatorSizeWei);
    }

    /// @dev set the size of validators created when caling batchApproveRegistration().
    ///   In a future upgrade this will be a parameter to that call but was done like this to
    ///   to limit changes to other dependent contracts
    function setValidatorSizeWei(uint256 _validatorSizeWei) external {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (_validatorSizeWei < 32 ether || _validatorSizeWei > 2048 ether) revert InvalidValidatorSize();
        validatorSizeWei = _validatorSizeWei;
    }

    /// @notice The admin can register an address to become a BNFT holder
    /// @param _user The address of the Validator Spawner to register
    function registerValidatorSpawner(address _user) public {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (validatorSpawner[_user].registered) revert AlreadyRegistered();  

        validatorSpawner[_user] = ValidatorSpawner({registered: true});

        emit ValidatorSpawnerRegistered(_user);
    }

    /// @notice Removes a Validator Spawner
    /// @param _user the address of the Validator Spawner to remove
    function unregisterValidatorSpawner(address _user) external {
        if (!validatorSpawner[_user].registered) revert NotRegistered();
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        delete validatorSpawner[_user];

        emit ValidatorSpawnerUnregistered(_user);
    }

    /// @notice Send the exit requests as the T-NFT holder of the LiquidityPool validators
    function DEPRECATED_sendExitRequests(uint256[] calldata _validatorIds) external {
        if (!roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            emit ValidatorExitRequested(_validatorIds[i]);
        }
    }

    /// @notice Rebase by ether.fi
    function rebase(int128 _accruedRewards) public {
        if (msg.sender != MEMBERSHIP_MANAGER) revert IncorrectCaller();
        totalValueOutOfLp = uint128(int128(totalValueOutOfLp) + _accruedRewards);

        emit Rebase(getTotalPooledEther(), eETH.totalShares());
    }

    /// @notice pay protocol fees including 5% to treaury, 5% to node operator and ethfund bnft holders
    /// @param _protocolFees The amount of protocol fees to pay in ether
    function payProtocolFees(uint128 _protocolFees) external {
        if (msg.sender != ETHERFI_ADMIN_CONTRACT) revert IncorrectCaller();   
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
        if (paused) revert AlreadyPaused();

        paused = true;
        emit Paused(msg.sender);
    }

    // Unpauses the contract
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (!paused) revert NotPaused();

        paused = false;
        emit Unpaused(msg.sender);
    }

    // Deprecated, just existing not to touch EtherFiAdmin contract
    function setStakingTargetWeights(uint32 _eEthWeight, uint32 _etherFanWeight) external {
    }

    function addEthAmountLockedForWithdrawal(uint128 _amount) external {
        if (msg.sender != ETHERFI_ADMIN_CONTRACT) revert IncorrectCaller();

        ethAmountLockedForWithdrawal += _amount;
    }

    function burnEEthShares(uint256 shares) external {
        if (msg.sender != ETHERFI_REDEMPTION_MANAGER && msg.sender != address(withdrawRequestNFT)) revert IncorrectCaller();
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
        if (!sent || address(this).balance < balance - _amount) revert SendFail();
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
        if (paused) revert AlreadyPaused();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }
}

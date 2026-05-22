// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./utils/PausableUntil.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/ILiquifier.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IEtherFiRedemptionManager.sol";
import "./interfaces/IRoleRegistry.sol";
import "./interfaces/IPriorityWithdrawalQueue.sol";
import "./interfaces/IBlacklister.sol";
import "./utils/ReentrancyGuardNamespaced.sol";

contract LiquidityPool is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardNamespaced, PausableUntil, ILiquidityPool {
    using SafeERC20 for IERC20;
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IStakingManager private DEPRECATED_stakingManager;
    IEtherFiNodesManager private DEPRECATED_nodesManager;
    address private DEPRECATED_regulationsManager;
    address private DEPRECATED_membershipManager;
    address private DEPRECATED_TNFT;
    IeETH private DEPRECATED_eETH;

    bool private DEPRECATED_eEthliquidStakingOpened;

    uint128 public totalValueOutOfLp;
    uint128 public totalValueInLp;

    address public feeRecipient;

    uint32 private DEPRECATED_numPendingDeposits; // number of validator deposits, which needs 'registerValidator'

    address private DEPRECATED_bNftTreasury;
    IWithdrawRequestNFT private DEPRECATED_withdrawRequestNFT;

    BnftHolder[] private DEPRECATED_bnftHolders;
    uint128 private DEPRECATED_maxValidatorsPerOwner;
    uint128 private DEPRECATED_schedulingPeriodInSeconds;

    HoldersUpdate private DEPRECATED_holdersUpdate;

    mapping(address => bool) private DEPRECATED_admins;
    mapping(SourceOfFunds => FundStatistics) private DEPRECATED_fundStatistics;
    mapping(uint256 => bytes32) private DEPRECATED_depositDataRootForApprovalDeposits;
    address private DEPRECATED_etherFiAdminContract;
    bool private DEPRECATED_whitelistEnabled;
    mapping(address => bool) private DEPRECATED_whitelisted;
    mapping(address => ValidatorSpawner) public validatorSpawner;

    bool private DEPRECATED_restakeBnftDeposits;
    uint128 private DEPRECATED_ethAmountLockedForWithdrawal;
    bool public paused;
    address private DEPRECATED_auctionManager;
    ILiquifier private DEPRECATED_liquifier;

    bool private DEPRECATED_isLpBnftHolder;

    IEtherFiRedemptionManager private DEPRECATED_etherFiRedemptionManager;

    IRoleRegistry private DEPRECATED_roleRegistry;
    uint256 public validatorSizeWei;
    uint256 public maxWithdrawAmount;
    uint256 public minWithdrawAmount;
    bool public escrowMigrationCompleted;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  IMMUTABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IStakingManager public immutable stakingManager;
    IEtherFiNodesManager public immutable nodesManager;
    IeETH public immutable eETH;
    IWithdrawRequestNFT public immutable withdrawRequestNFT;
    ILiquifier public immutable liquifier;
    IEtherFiRedemptionManager public immutable etherFiRedemptionManager;
    IRoleRegistry public immutable roleRegistry;
    IPriorityWithdrawalQueue public immutable priorityWithdrawalQueue;
    IBlacklister public immutable blacklister;
    address public immutable etherFiAdminContract;
    address public immutable membershipManager;
    uint256 public immutable minAmountForShare;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    uint256 public constant SHARE_UNIT = 1e18;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event Paused();
    event Unpaused();

    event Deposit(address indexed sender, uint256 amount, SourceOfFunds source, address referral);
    event Withdraw(address indexed sender, address recipient, uint256 amount, SourceOfFunds source);
    event EEthSharesBurnedForNonETHWithdrawal(uint256 amountSharesToBurn, uint256 withdrawalValueInETH);
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
    event MinWithdrawAmountSet(uint256 minWithdrawAmount);
    event MaxWithdrawAmountSet(uint256 maxWithdrawAmount);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    error IncorrectCaller();
    error InvalidAmount();
    error InvalidWithdrawalAmount();
    error InvalidShareAmount();
    error DataNotSet();
    error InsufficientLiquidity();
    error SendFail();
    error IncorrectRole();
    error InvalidValidatorSize();
    error InvalidArrayLengths();
    error InvalidAmountForShare();
    error InvalidRate();
    error AlreadyMigrated();
    error MigrationNotComplete();
    error AlreadyRegistered();
    error NotRegistered();
    error ContractPaused();

    struct ConstructorAddresses {
        address stakingManager;
        address nodesManager;
        address eETH;
        address withdrawRequestNFT;
        address liquifier;
        address etherFiRedemptionManager;
        address roleRegistry;
        address priorityWithdrawalQueue;
        address blacklister;
        address etherFiAdminContract;
        address membershipManager;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(ConstructorAddresses memory _constructorAddresses, uint256 _minAmountForShare) {
        stakingManager = IStakingManager(_constructorAddresses.stakingManager);
        nodesManager = IEtherFiNodesManager(_constructorAddresses.nodesManager);
        eETH = IeETH(_constructorAddresses.eETH);
        withdrawRequestNFT = IWithdrawRequestNFT(_constructorAddresses.withdrawRequestNFT);
        liquifier = ILiquifier(_constructorAddresses.liquifier);
        etherFiRedemptionManager = IEtherFiRedemptionManager(payable(_constructorAddresses.etherFiRedemptionManager));
        roleRegistry = IRoleRegistry(_constructorAddresses.roleRegistry);
        priorityWithdrawalQueue = IPriorityWithdrawalQueue(_constructorAddresses.priorityWithdrawalQueue);
        blacklister = IBlacklister(_constructorAddresses.blacklister);
        etherFiAdminContract = _constructorAddresses.etherFiAdminContract;
        membershipManager = _constructorAddresses.membershipManager;
        minAmountForShare = _minAmountForShare;
        _disableInitializers();
    }

    receive() external payable {
        if (msg.value > type(uint128).max) revert InvalidAmount();
        totalValueOutOfLp -= uint128(msg.value);
        totalValueInLp += uint128(msg.value);
        _checkTotalValueInLp();
        _checkMinAmountForShare();
    }

    function initialize(address _eEthAddress, address _stakingManagerAddress, address _nodesManagerAddress, address _membershipManagerAddress, address _tNftAddress, address _etherFiAdminContract, address _withdrawRequestNFT) external initializer {
        if (_eEthAddress == address(0) || _stakingManagerAddress == address(0) || _nodesManagerAddress == address(0) || _membershipManagerAddress == address(0) || _tNftAddress == address(0)) revert DataNotSet();
        
        __Ownable_init();
        __UUPSUpgradeable_init();
        paused = true;
    }

    /// @notice One-shot post-upgrade migration that sweeps existing locked ETH from LP to WithdrawRequestNFT and PriorityWithdrawalQueue.
    function initializeOnUpgradeV2() external onlyOwner {
        if (escrowMigrationCompleted) revert AlreadyMigrated();

        uint128 nftLocked   = DEPRECATED_ethAmountLockedForWithdrawal;
        uint128 queueLocked = address(priorityWithdrawalQueue) != address(0)
            ? uint128(priorityWithdrawalQueue.ethAmountLockedForPriorityWithdrawal())
            : 0;

        uint128 totalLocked = nftLocked + queueLocked;
        if (totalLocked > 0) {
            if (totalValueInLp < totalLocked) revert InsufficientLiquidity();
            totalValueInLp    -= totalLocked;
            totalValueOutOfLp += totalLocked;

            if (nftLocked > 0) {
                DEPRECATED_ethAmountLockedForWithdrawal = 0;
                _sendFund(address(withdrawRequestNFT), nftLocked);
            }
            if (queueLocked > 0) _sendFund(address(priorityWithdrawalQueue), queueLocked);
        }

        _checkTotalValueInLp();
        _checkMinAmountForShare();
        escrowMigrationCompleted = true;
    }

    // Used by eETH staking flow
    function deposit() external payable returns (uint256) {
        return deposit(address(0));
    }

    // Used by eETH staking flow
    function deposit(address _referral) public payable nonReentrant whenNotPaused nonBlacklisted returns (uint256) {
        emit Deposit(msg.sender, msg.value, SourceOfFunds.EETH, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    // Used by eETH staking flow through Liquifier contract; deVamp or to pay protocol fees
    function depositToRecipient(address _recipient, uint256 _amount, address _referral) public nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != address(liquifier) && msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
        blacklister.nonBlacklisted(_recipient);

        emit Deposit(_recipient, _amount, SourceOfFunds.EETH, _referral);

        return _deposit(_recipient, 0, _amount);
    }

    // Used by ether.fan staking flow
    function deposit(address _user, address _referral) external payable nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        blacklister.nonBlacklisted(_user);

        emit Deposit(msg.sender, msg.value, SourceOfFunds.ETHER_FAN, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    /// @notice Burns shares and pays ETH. For NFT/queue callers, ETH is paid by the caller from its own segregated balance; LP only does accounting. Other callers receive ETH from LP.
    /// @notice Live-rate withdraw for membershipManager and etherFiRedemptionManager.
    ///         Burns shares at the live rate and pays ETH from the LP to `_recipient`.
    function withdraw(address _recipient, uint256 _amount) external nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != address(membershipManager) && msg.sender != address(etherFiRedemptionManager)) {
            revert IncorrectCaller();
        }
        uint256 share = sharesForWithdrawalAmount(_amount);
        if (eETH.balanceOf(msg.sender) < _amount) revert InsufficientLiquidity();
        if (_amount > type(uint128).max || _amount == 0 || share == 0) revert InvalidAmount();
        if (totalValueInLp < _amount) revert InsufficientLiquidity();
        totalValueInLp -= uint128(_amount);
        eETH.burnShares(msg.sender, share);

        _sendFund(_recipient, _amount);

        _checkTotalValueInLp();
        _checkMinAmountForShare();

        return share;
    }

    /// @notice Settles a finalized claim for withdrawRequestNFT or priorityWithdrawalQueue against
    ///         the rate snapshotted at finalize/fulfill time. Caller supplies the rate; LP derives
    ///         the share burn from it. ETH was already segregated to the caller at finalize/fulfill
    ///         via `addEthAmountLockedForWithdrawal` / `transferLockedEthForPriority`, so LP only
    ///         performs accounting (burn + `totalValueOutOfLp -=`); the caller pays the user from
    ///         its own balance.
    /// @dev    `_rate == 0` is rejected — callers (WRNFT / Queue) are responsible for resolving
    ///         any pre-upgrade legacy snapshot to a live rate locally via `amountPerShareCeil()`
    ///         before invoking this function. Single codepath: one ceiling math expression.
    function withdraw(uint256 _amount, uint256 _rate) external nonReentrant returns (uint256) {
        if (msg.sender != address(withdrawRequestNFT) && msg.sender != address(priorityWithdrawalQueue)) {
            revert IncorrectCaller();
        }
        if (_amount > type(uint128).max || _amount == 0) revert InvalidAmount();
        if (_rate == 0) revert InvalidRate();

        uint256 share = Math.mulDiv(_amount, SHARE_UNIT, _rate, Math.Rounding.Up); // rounding favors the protocol
        if (share == 0) revert InvalidAmount();
        if (eETH.shares(msg.sender) < share) revert InsufficientLiquidity();

        totalValueOutOfLp -= uint128(_amount);
        eETH.burnShares(msg.sender, share);
        _checkMinAmountForShare();

        return share;
    }

    /// @notice request withdraw from pool and receive a WithdrawRequestNFT
    /// @dev Transfers the amount of eETH from msg.senders account to the WithdrawRequestNFT contract & mints an NFT to the msg.sender
    /// @param recipient address that will be issued the NFT
    /// @param amount requested amount to withdraw from contract
    /// @return uint256 requestId of the WithdrawRequestNFT
    function requestWithdraw(address recipient, uint256 amount) public nonReentrant whenNotPaused nonBlacklisted returns (uint256) {
        blacklister.nonBlacklisted(recipient);
        if (amount == 0) revert InvalidWithdrawalAmount();
        if (amount < minWithdrawAmount || amount > maxWithdrawAmount) revert InvalidWithdrawalAmount();
        uint256 share = sharesForAmount(amount);
        if (share == 0) revert InvalidShareAmount();

        // transfer shares to WithdrawRequestNFT contract from this contract
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(withdrawRequestNFT), amount);

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient);
       
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
        nonBlacklisted
        returns (uint256)
    {
        try eETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
        return requestWithdraw(_owner, _amount);
    }

    /// @notice request withdraw of some or all of the eETH backing a MembershipNFT and receive a WithdrawRequestNFT
    /// @dev Transfers the amount of eETH from MembershipManager to the WithdrawRequestNFT contract & mints an NFT to the recipient
    /// @param recipient address that will be issued the NFT
    /// @param amount requested amount to withdraw from contract
    /// @param fee fee amount not used anymore, only kept to maintain compatibility with existing code
    /// @return uint256 requestId of the WithdrawRequestNFT
    function requestMembershipNFTWithdraw(address recipient, uint256 amount, uint256 fee) public nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        uint256 share = sharesForAmount(amount);
        if (amount > type(uint96).max || amount == 0 || share == 0) revert InvalidAmount();

        // transfer shares to WithdrawRequestNFT contract
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(withdrawRequestNFT), amount);

        uint256 requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient);

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
        if (!validatorSpawner[msg.sender].registered) revert IncorrectCaller();
        stakingManager.registerBeaconValidators(_depositData, _bidIds, _etherFiNode);
    }

    function batchCreateBeaconValidators(
        IStakingManager.DepositData[] calldata _depositData,
        uint256[] calldata _bidIds,
        address _etherFiNode
    ) external nonReentrant whenNotPaused {
        if (!roleRegistry.hasRole(roleRegistry.ORACLE_OPERATIONS_ROLE(), msg.sender)) revert IncorrectRole();

        // liquidity pool supplies 1 eth per validator
        uint256 outboundEthAmountFromLp = stakingManager.INITIAL_DEPOSIT_AMOUNT() * _bidIds.length;
        stakingManager.createBeaconValidators{value: outboundEthAmountFromLp}(_depositData, _bidIds, _etherFiNode);

        _accountForEthSentOut(outboundEthAmountFromLp);
    }

    /// @notice send remaining eth to deposit contract to activate the provided validators
    /// @dev step 3 of staking flow. This version exists to remain compatible with existing callers.
    ///   future services should use confirmAndFundBeaconValidators()
     function batchApproveRegistration(
        uint256[] memory _validatorIds,
        bytes[] calldata _pubkeys,
        bytes[] calldata _signatures
    ) external nonReentrant whenNotPaused {
        if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
        if (validatorSizeWei < stakingManager.MIN_VALIDATOR_SIZE_WEI() || validatorSizeWei > stakingManager.MAX_VALIDATOR_SIZE_WEI()) revert InvalidValidatorSize();
        if (_validatorIds.length == 0 || _validatorIds.length != _pubkeys.length || _validatorIds.length != _signatures.length) revert InvalidArrayLengths();

        // we have already deposited the initial amount to create the validator on the beacon chain
        uint256 remainingEthPerValidator = validatorSizeWei - stakingManager.INITIAL_DEPOSIT_AMOUNT();

        // In order to maintain compatibility with current callers in this upgrade
        // need to construct data from old format
        IStakingManager.DepositData[] memory depositData = new IStakingManager.DepositData[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            IEtherFiNode etherFiNode = IEtherFiNode(nodesManager.etherfiNodeAddress(_validatorIds[i]));
            address eigenPod = address(etherFiNode.getEigenPod());
            bytes memory withdrawalCredentials = nodesManager.addressToCompoundingWithdrawalCredentials(eigenPod);

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
        stakingManager.confirmAndFundBeaconValidators{value: outboundEthAmountFromLp}(depositData, validatorSizeWei);

        _accountForEthSentOut(outboundEthAmountFromLp);
    }

    /// @notice send remaining eth to deposit contract to activate the provided validators
    /// @dev step 3 of staking flow
    function confirmAndFundBeaconValidators(
        IStakingManager.DepositData[] calldata _depositData,
        uint256 _validatorSizeWei
    ) external nonReentrant whenNotPaused {
        if (!roleRegistry.hasRole(roleRegistry.ORACLE_OPERATIONS_ROLE(), msg.sender)) revert IncorrectRole();
        if (_validatorSizeWei < stakingManager.MIN_VALIDATOR_SIZE_WEI() || _validatorSizeWei > stakingManager.MAX_VALIDATOR_SIZE_WEI()) revert InvalidValidatorSize();

        // we have already deposited the initial amount to create the validator on the beacon chain
        uint256 remainingEthPerValidator = _validatorSizeWei - stakingManager.INITIAL_DEPOSIT_AMOUNT();

        uint256 outboundEthAmountFromLp = remainingEthPerValidator * _depositData.length;
        stakingManager.confirmAndFundBeaconValidators{value: outboundEthAmountFromLp}(_depositData, _validatorSizeWei);

        _accountForEthSentOut(outboundEthAmountFromLp);
    }

    /// @dev set the size of validators created when caling batchApproveRegistration().
    ///   In a future upgrade this will be a parameter to that call but was done like this to
    ///   to limit changes to other dependent contracts
    function setValidatorSizeWei(uint256 _validatorSizeWei) external onlyAdmin {
        if (_validatorSizeWei < stakingManager.MIN_VALIDATOR_SIZE_WEI() || _validatorSizeWei > stakingManager.MAX_VALIDATOR_SIZE_WEI()) revert InvalidValidatorSize();
        validatorSizeWei = _validatorSizeWei;
    }

    /// @notice The admin can register an address to become a BNFT holder
    /// @param _user The address of the Validator Spawner to register
    function registerValidatorSpawner(address _user) public onlyAdmin {
        if (validatorSpawner[_user].registered) revert AlreadyRegistered();  

        validatorSpawner[_user] = ValidatorSpawner({registered: true});

        emit ValidatorSpawnerRegistered(_user);
    }

    /// @notice Removes a Validator Spawner
    /// @param _user the address of the Validator Spawner to remove
    function unregisterValidatorSpawner(address _user) external onlyOperations {
        if (!validatorSpawner[_user].registered) revert NotRegistered();

        delete validatorSpawner[_user];

        emit ValidatorSpawnerUnregistered(_user);
    }

    /// @notice Send the exit requests as the T-NFT holder of the LiquidityPool validators
    function DEPRECATED_sendExitRequests(uint256[] calldata _validatorIds) external onlyAdmin {

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            emit ValidatorExitRequested(_validatorIds[i]);
        }
    }

    /// @notice Rebase by ether.fi
    function rebase(int128 _accruedRewards) public {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        totalValueOutOfLp = uint128(int128(totalValueOutOfLp) + _accruedRewards);

        _checkMinAmountForShare();

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
    function setFeeRecipient(address _feeRecipient) external onlyAdmin {
        feeRecipient = _feeRecipient;
        emit UpdatedFeeRecipient(_feeRecipient);
    }

    // Pauses the contract
    function pauseContract() external onlyOperations {
        if (paused) revert("Pausable: already paused");

        paused = true;
        emit Paused();
    }

    // Unpauses the contract
    function unPauseContract() external onlyOperations {
        if (!paused) revert("Pausable: not paused");

        paused = false;
        emit Unpaused();
    }

    // Pauses contract until MAX_PAUSE_DURATION
    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    // Unpauses contract from pauseUntil
    function unpauseContractUntil() external onlyOperations {
        _unpauseUntil();
    }

    /// @notice Sets the pause duration for the contract
    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    function setMinWithdrawAmount(uint256 _minWithdrawAmount) external onlyOperations {
        minWithdrawAmount = _minWithdrawAmount;
        emit MinWithdrawAmountSet(_minWithdrawAmount);
    }

    function setMaxWithdrawAmount(uint256 _maxWithdrawAmount) external onlyOperations {
        if (_maxWithdrawAmount ==0 || _maxWithdrawAmount < minWithdrawAmount) revert InvalidAmount();
        maxWithdrawAmount = _maxWithdrawAmount;
        emit MaxWithdrawAmountSet(_maxWithdrawAmount);
    }

    /// @notice Locks ETH for finalized NFT withdrawals by transferring from LP to WithdrawRequestNFT. TVL preserved by InLp/OutOfLp rebalance; share rate unchanged.
    function addEthAmountLockedForWithdrawal(uint128 _amount) external {
        if (msg.sender != address(etherFiAdminContract) && msg.sender != address(withdrawRequestNFT)) revert IncorrectCaller();
        if (!escrowMigrationCompleted) revert MigrationNotComplete();
        if (totalValueInLp < _amount) revert InsufficientLiquidity();

        totalValueInLp     -= _amount;
        totalValueOutOfLp  += _amount;

        _sendFund(address(withdrawRequestNFT), _amount);

        _checkTotalValueInLp();
        _checkMinAmountForShare();
    }

    /// @notice Locks ETH for the priority withdrawal queue by transferring from LP to the queue contract. TVL preserved by InLp/OutOfLp rebalance.
    function transferLockedEthForPriority(uint128 _amount) external {
        if (msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        if (!escrowMigrationCompleted) revert MigrationNotComplete();
        if (totalValueInLp < _amount) revert InsufficientLiquidity();

        totalValueInLp     -= _amount;
        totalValueOutOfLp  += _amount;

        _sendFund(address(priorityWithdrawalQueue), _amount);

        _checkTotalValueInLp();
        _checkMinAmountForShare();
    }

    /// @notice Returns ETH from the priority queue back to LP on a finalized cancel. Inverse of transferLockedEthForPriority.
    function returnLockedEth(uint128 _amount) external payable {
        if (msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        if (msg.value != _amount || _amount == 0) revert InvalidAmount();
        totalValueOutOfLp -= uint128(_amount);
        totalValueInLp    += uint128(_amount);

        _checkTotalValueInLp();
        _checkMinAmountForShare();
    }

    function burnEEthShares(uint256 shares) external {
        if (msg.sender != address(etherFiRedemptionManager) && msg.sender != address(withdrawRequestNFT) && msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        eETH.burnShares(msg.sender, shares);
        _checkMinAmountForShare();
    }

    function burnEEthSharesForNonETHWithdrawal(uint256 _amountSharesToBurn, uint256 _withdrawalValueInETH) external {
        uint256 share = sharesForWithdrawalAmount(_withdrawalValueInETH);
        if (msg.sender != address(etherFiRedemptionManager)) revert IncorrectCaller();
        if (_amountSharesToBurn == 0 || _withdrawalValueInETH == 0) revert InvalidAmount();

        // Verify the share price will not go down
        if (share > _amountSharesToBurn) revert InvalidAmount();

        totalValueOutOfLp -= uint128(_withdrawalValueInETH);

        eETH.burnShares(msg.sender, _amountSharesToBurn);
        _checkMinAmountForShare();
        emit EEthSharesBurnedForNonETHWithdrawal(_amountSharesToBurn, _withdrawalValueInETH);
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

        _checkTotalValueInLp();
        _checkMinAmountForShare();

        return share;
    }

    function _sharesForDepositAmount(uint256 _depositAmount) internal view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther() - _depositAmount;
        if (totalPooledEther == 0) {
            return _depositAmount;
        }
        return Math.mulDiv(_depositAmount, eETH.totalShares(), totalPooledEther, Math.Rounding.Down);
    }

    function _sendFund(address _recipient, uint256 _amount) internal {
        uint256 balance = address(this).balance;
        (bool sent, ) = _recipient.call{value: _amount}("");
        if (!sent || address(this).balance < balance - _amount) revert SendFail();
    }

    function _accountForEthSentOut(uint256 _amount) internal {
        totalValueOutOfLp += uint128(_amount);
        totalValueInLp -= uint128(_amount);
        _checkTotalValueInLp();
        _checkMinAmountForShare();
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
            staked = Math.mulDiv(getTotalPooledEther(), eETH.shares(_user), totalShares, Math.Rounding.Down);
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
        return Math.mulDiv(_amount, eETH.totalShares(), totalPooledEther, Math.Rounding.Down);
    }

    /// @dev withdrawal rounding errors favor the protocol by rounding up
    function sharesForWithdrawalAmount(uint256 _amount) public view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther();
        if (totalPooledEther == 0) {
            return 0;
        }

        // ceiling division so rounding errors favor the protocol
        return Math.mulDiv(_amount, eETH.totalShares(), totalPooledEther, Math.Rounding.Up);
    }

    function amountForShare(uint256 _share) public view returns (uint256) {
        uint256 totalShares = eETH.totalShares();
        if (totalShares == 0) {
            return 0;
        }
        return Math.mulDiv(_share, getTotalPooledEther(), totalShares, Math.Rounding.Down);
    }

    /// @notice ETH value of `1e18` shares, rounded UP. Single source of truth for the rate
    ///         snapshotted by segregated callers (WithdrawRequestNFT / PriorityWithdrawalQueue)
    ///         at finalize/fulfill. Ceiling rounding keeps the frozen rate >= `amountForShare`'s
    ///         floor value so the round-trips at claim time satisfy:
    ///         `shareOfEEth * rate / 1e18 >= amountForShare(shareOfEEth)` (solvency check) and
    ///         `ceil(amount * 1e18 / rate) <= shareOfEEth` (burn-bounded-by-request).
    function amountPerShareCeil() public view returns (uint256) {
        uint256 totalShares = eETH.totalShares();
        if (totalShares == 0) return 0;
        return Math.mulDiv(SHARE_UNIT, getTotalPooledEther(), totalShares, Math.Rounding.Up);
    }

    function _checkTotalValueInLp() internal view {
        if (totalValueInLp > address(this).balance) revert InsufficientLiquidity();
    }

    function _checkMinAmountForShare() internal view {
        if (amountForShare(SHARE_UNIT) < minAmountForShare) revert InvalidAmountForShare();
    }

    function getImplementation() external view returns (address) {return _getImplementation();}

    function _requireNotPaused() internal view virtual {
        if (paused) revert ContractPaused();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        _requireNotPaused();
        _requireNotPausedUntil();
        _;
    }

    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }


    modifier onlyAdmin() {
        roleRegistry.onlyOperatingTimelock(msg.sender);
        _;
    }

    modifier onlyOperations() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }

    modifier onlyGuardian() {
        roleRegistry.onlyGuardian(msg.sender);
        _;
    }

    modifier onlyEtherFiAdmin() {
        if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
        _;
    }
}

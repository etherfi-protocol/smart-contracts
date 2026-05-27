// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/staking/interfaces/IStakingManager.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/deposits/interfaces/ILiquifier.sol";
import "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";
import "@etherfi/withdrawals/interfaces/IEtherFiRedemptionManager.sol";
import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/utils/ReentrancyGuardNamespaced.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/PausableUntil.sol";

contract LiquidityPool is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardNamespaced, PausableUntil, RolesLibrary, ILiquidityPool {
    using SafeERC20 for IERC20;
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    // deprecated storage slots
    uint256[6] private __gap_0;

    uint128 public totalValueOutOfLp;
    uint128 public totalValueInLp;
    address public feeRecipient;

    // deprecated storage slots
    uint32 private __gap_1;
    uint256[10] private __gap_2;

    mapping(address => ValidatorSpawner) public validatorSpawner;

    // deprecated storage slots
    uint8 private __gap_3;
    uint128 private DEPRECATED_ethAmountLockedForWithdrawal;
    bool public paused;

    // deprecated storage slots
    uint256[4] private __gap_4;

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
    error InvalidValidatorSize();
    error InvalidAmountForShare();
    error InvalidRate();
    error AlreadyMigrated();
    error MigrationNotComplete();
    error AlreadyRegistered();
    error NotRegistered();
    error ContractPaused();
    error EETHRateDeflation();
    error AlreadyPaused();
    error NotPaused();

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
    constructor(ConstructorAddresses memory _constructorAddresses, uint256 _minAmountForShare) RolesLibrary(_constructorAddresses.roleRegistry) {
        stakingManager = IStakingManager(_constructorAddresses.stakingManager);
        nodesManager = IEtherFiNodesManager(_constructorAddresses.nodesManager);
        eETH = IeETH(_constructorAddresses.eETH);
        withdrawRequestNFT = IWithdrawRequestNFT(_constructorAddresses.withdrawRequestNFT);
        liquifier = ILiquifier(_constructorAddresses.liquifier);
        etherFiRedemptionManager = IEtherFiRedemptionManager(payable(_constructorAddresses.etherFiRedemptionManager));
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
        _checkInvariants();
    }

    function initialize(address _eEthAddress, address _stakingManagerAddress, address _nodesManagerAddress, address _membershipManagerAddress, address _tNftAddress, address _etherFiAdminContract, address _withdrawRequestNFT) external initializer {
        if (_eEthAddress == address(0) || _stakingManagerAddress == address(0) || _nodesManagerAddress == address(0) || _membershipManagerAddress == address(0) || _tNftAddress == address(0)) revert DataNotSet();
        
        __Ownable_init();
        __UUPSUpgradeable_init();
        paused = true;
    }

    /// @notice One-shot post-upgrade migration that sweeps existing locked ETH from LP to WithdrawRequestNFT and PriorityWithdrawalQueue.
    function initializeOnUpgradeV2() external onlyUpgradeTimelock {
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

        _checkInvariants();
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
    function withdraw(address _recipient, uint256 _amount) external nonReentrant whenNotPaused nonDecreasingRate returns (uint256) {
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

        _checkInvariants();

        return share;
    }

    /// @notice Settles a finalized claim for withdrawRequestNFT or priorityWithdrawalQueue.
    ///         Caller supplies the snapshotted rate and the request's share allocation;
    ///         LP derives the share burn defensively from both inputs and current live rate.
    ///
    /// @dev    Three guards bound caller-supplied inputs without trusting any single one:
    ///         (1) `_amount <= _shareOfEEth * _rate / SHARE_UNIT` — caps `_amount` at the
    ///             rate-implied value of `_shareOfEEth`. Defeats isolated `_amount` inflation
    ///             when `_rate` is honest. (Does NOT catch proportional `_amount`/`_rate`
    ///             co-inflation — see residual below.)
    ///         (2) Burn at `max(amount/_rate, amount/live)` shares — Lido-pattern worse-for-
    ///             protocol clamp. An inflated `_rate` is silently floored to live; the protocol
    ///             burns at the honest live rate regardless of what the caller passed.
    ///         (3) Share burn capped at `_shareOfEEth` — per-call cap on burn. Un-DoSes
    ///             legitimate down-rebase claims (where `amount/live > shareOfEEth`).
    ///
    /// @dev    `_shareOfEEth` MUST be the request-time share snapshot, not a live-derived value.
    ///         If a future caller refactor breaks this invariant, Guard 3's cap silently loosens.
    ///         LP cannot independently verify this — the caller (WRN / PWQ) is trusted to pass
    ///         the snapshot honestly. The downstream `eETH.shares(msg.sender) < share` solvency
    ///         check is the only bound against caller-asserted `_shareOfEEth` exceeding the
    ///         caller's actual share holdings; it does NOT enforce a per-request bound.
    ///
    /// @dev    Residual: a caller corrupted in MULTIPLE inputs simultaneously (e.g. proportional
    ///         `_amount` and `_rate` inflation) can bypass Guard 1 and Guard 2. The remaining
    ///         bound is `eETH.shares(msg.sender)` (aggregate caller holdings), not per-request.
    ///         This is the documented limit of LP-local defense; tighter bounds would require
    ///         a per-request ledger on the LP side.
    ///
    ///         ETH was already segregated to the caller at finalize/fulfill via
    ///         `addEthAmountLockedForWithdrawal` / `transferLockedEthForPriority`; LP only
    ///         performs accounting (burn + `totalValueOutOfLp -=`).
    function withdraw(uint256 _amount, uint256 _rate, uint256 _shareOfEEth) external nonReentrant returns (uint256) {
        if (msg.sender != address(withdrawRequestNFT) && msg.sender != address(priorityWithdrawalQueue)) {
            revert IncorrectCaller();
        }
        if (_amount > type(uint128).max || _amount == 0) revert InvalidAmount();
        if (_rate == 0) revert InvalidRate();

        // Guard 1: amount-cap against rate-implied entitlement of the request's allocation.
        uint256 amountCap = Math.mulDiv(_shareOfEEth, _rate, SHARE_UNIT, Math.Rounding.Down);
        if (_amount > amountCap) revert InvalidAmount();

        // Guard 2: burn at the worse-for-protocol rate (the higher share count).
        uint256 shareAtFrozen = Math.mulDiv(_amount, SHARE_UNIT, _rate, Math.Rounding.Up);
        uint256 shareAtLive = Math.mulDiv(_amount, SHARE_UNIT, amountPerShareCeil(), Math.Rounding.Up);
        uint256 share = shareAtFrozen > shareAtLive ? shareAtFrozen : shareAtLive;

        // Guard 3: cap at the caller-asserted per-request allocation.
        if (share > _shareOfEEth) share = _shareOfEEth;

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

        return _requestWithdraw(recipient, amount, share, SourceOfFunds.EETH);
    }

    /// @notice request withdraw from pool with signed permit data and receive a WithdrawRequestNFT
    /// @dev accepts PermitInput signed data to approve transfer of eETH (EIP-2612) so withdraw request can happen in 1 tx
    /// @param _owner address that will be issued the NFT
    /// @param _amount requested amount to withdraw from contract
    /// @param _permit signed permit data to approve transfer of eETH
    /// @return uint256 requestId of the WithdrawRequestNFT
    function requestWithdrawWithPermit(address _owner, uint256 _amount, PermitInput calldata _permit) external returns (uint256)
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

        return _requestWithdraw(recipient, amount, share, SourceOfFunds.ETHER_FAN);
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
    ) external nonReentrant whenNotPaused onlyOracleOperations {
        // liquidity pool supplies 1 eth per validator
        uint256 outboundEthAmountFromLp = stakingManager.INITIAL_DEPOSIT_AMOUNT() * _bidIds.length;
        stakingManager.createBeaconValidators{value: outboundEthAmountFromLp}(_depositData, _bidIds, _etherFiNode);

        _accountForEthSentOut(outboundEthAmountFromLp);
    }

    /// @notice send remaining eth to deposit contract to activate the provided validators
    /// @dev step 3 of staking flow. Callable directly by oracle ops, or by EtherFiAdmin
    ///      when forwarding from `executeValidatorApprovalTask` (which gates oracle ops at
    ///      its own entry point and tracks task completion on-chain). Both upstream paths
    ///      enforce oracle-ops authorization, so accepting EtherFiAdmin here doesn't widen
    ///      the auth surface.
    function confirmAndFundBeaconValidators(
        IStakingManager.DepositData[] calldata _depositData,
        uint256 _validatorSizeWei
    ) external nonReentrant whenNotPaused {
        if (msg.sender != address(etherFiAdminContract)) roleRegistry.onlyOracleOperations(msg.sender);
        _requireValidValidatorSize(_validatorSizeWei);

        // we have already deposited the initial amount to create the validator on the beacon chain
        uint256 remainingEthPerValidator = _validatorSizeWei - stakingManager.INITIAL_DEPOSIT_AMOUNT();

        uint256 outboundEthAmountFromLp = remainingEthPerValidator * _depositData.length;
        stakingManager.confirmAndFundBeaconValidators{value: outboundEthAmountFromLp}(_depositData, _validatorSizeWei);

        _accountForEthSentOut(outboundEthAmountFromLp);
    }

    /// @dev set the size of validators created when EtherFiAdmin.executeValidatorApprovalTask
    ///   forwards into confirmAndFundBeaconValidators(). In a future upgrade this will be a
    ///   parameter to that call but was done like this to limit changes to other dependent contracts.
    function setValidatorSizeWei(uint256 _validatorSizeWei) external onlyAdmin {
        _requireValidValidatorSize(_validatorSizeWei);
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
    function unregisterValidatorSpawner(address _user) external onlyOperatingMultisig {
        if (!validatorSpawner[_user].registered) revert NotRegistered();

        delete validatorSpawner[_user];

        emit ValidatorSpawnerUnregistered(_user);
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
    function pauseContract() external onlyOperatingMultisig {
        if (paused) revert AlreadyPaused();

        paused = true;
        emit Paused();
    }

    // Unpauses the contract
    function unPauseContract() external onlyOperatingMultisig {
        if (!paused) revert NotPaused();

        paused = false;
        emit Unpaused();
    }

    // Pauses contract until MAX_PAUSE_DURATION
    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    // Unpauses contract from pauseUntil
    function unpauseContractUntil() external onlyOperatingMultisig {
        _unpauseUntil();
    }

    /// @notice Sets the pause duration for the contract
    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    function setMinWithdrawAmount(uint256 _minWithdrawAmount) external onlyOperatingMultisig {
        if (_minWithdrawAmount > maxWithdrawAmount) revert InvalidAmount();
        minWithdrawAmount = _minWithdrawAmount;
        emit MinWithdrawAmountSet(_minWithdrawAmount);
    }

    function setMaxWithdrawAmount(uint256 _maxWithdrawAmount) external onlyOperatingMultisig {
        if (_maxWithdrawAmount == 0 || _maxWithdrawAmount < minWithdrawAmount) revert InvalidAmount();
        maxWithdrawAmount = _maxWithdrawAmount;
        emit MaxWithdrawAmountSet(_maxWithdrawAmount);
    }

    /// @notice Locks ETH for finalized NFT withdrawals by transferring from LP to WithdrawRequestNFT. TVL preserved by InLp/OutOfLp rebalance; share rate unchanged.
    function addEthAmountLockedForWithdrawal(uint128 _amount) external {
        if (msg.sender != address(etherFiAdminContract) && msg.sender != address(withdrawRequestNFT)) revert IncorrectCaller();
        _lockEth(address(withdrawRequestNFT), _amount);
    }

    /// @notice Locks ETH for the priority withdrawal queue by transferring from LP to the queue contract. TVL preserved by InLp/OutOfLp rebalance.
    function transferLockedEthForPriority(uint128 _amount) external {
        if (msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        _lockEth(address(priorityWithdrawalQueue), _amount);
    }

    /// @notice Returns ETH from the priority queue back to LP on a finalized cancel. Inverse of transferLockedEthForPriority.
    function returnLockedEth(uint128 _amount) external payable {
        if (msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        if (msg.value != _amount || _amount == 0) revert InvalidAmount();
        totalValueOutOfLp -= uint128(_amount);
        totalValueInLp    += uint128(_amount);

        _checkInvariants();
    }

    function burnEEthShares(uint256 shares) external nonDecreasingRate {
        if (msg.sender != address(etherFiRedemptionManager) && msg.sender != address(withdrawRequestNFT) && msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        eETH.burnShares(msg.sender, shares);
        _checkMinAmountForShare();
    }

    function burnEEthSharesForNonETHWithdrawal(uint256 _amountSharesToBurn, uint256 _withdrawalValueInETH) external nonDecreasingRate {
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

    function _deposit(address _recipient, uint256 _amountInLp, uint256 _amountOutOfLp) internal nonDecreasingRate returns (uint256) {
        totalValueInLp += uint128(_amountInLp);
        totalValueOutOfLp += uint128(_amountOutOfLp);
        uint256 amount = _amountInLp + _amountOutOfLp;
        uint256 share = _sharesForDepositAmount(amount);
        if (amount > type(uint128).max || amount == 0 || share == 0) revert InvalidAmount();

        eETH.mintShares(_recipient, share);

        _checkInvariants();

        return share;
    }

    /// @dev Shared tail for requestWithdraw / requestMembershipNFTWithdraw: moves `amount` eETH
    ///      from the caller to the WithdrawRequestNFT, mints the request NFT, and emits Withdraw.
    function _requestWithdraw(address recipient, uint256 amount, uint256 share, SourceOfFunds source) internal returns (uint256 requestId) {
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(withdrawRequestNFT), amount);
        requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient);
        emit Withdraw(msg.sender, recipient, amount, source);
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

    /// @dev Shared body for `addEthAmountLockedForWithdrawal` and `transferLockedEthForPriority`.
    ///      Both move ETH out of LP into a segregated escrow (WRNFT or PQ) while keeping TVL
    ///      invariant by rebalancing `totalValueInLp` -> `totalValueOutOfLp`. Caller-gating
    ///      lives in the two external entry points.
    function _lockEth(address _dest, uint128 _amount) internal {
        if (!escrowMigrationCompleted) revert MigrationNotComplete();
        if (totalValueInLp < _amount) revert InsufficientLiquidity();
        totalValueInLp    -= _amount;
        totalValueOutOfLp += _amount;
        _sendFund(_dest, _amount);
        _checkInvariants();
    }

    function _accountForEthSentOut(uint256 _amount) internal {
        totalValueOutOfLp += uint128(_amount);
        totalValueInLp -= uint128(_amount);
        _checkInvariants();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

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

    function _checkInvariants() internal view {
        _checkTotalValueInLp();
        _checkMinAmountForShare();
    }

    function getImplementation() external view returns (address) {return _getImplementation();}

    function _requireValidValidatorSize(uint256 _validatorSizeWei) internal view {
        if (_validatorSizeWei < stakingManager.MIN_VALIDATOR_SIZE_WEI() || _validatorSizeWei > stakingManager.MAX_VALIDATOR_SIZE_WEI()) revert InvalidValidatorSize();
    }

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

    modifier onlyEtherFiAdmin() {
        if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
        _;
    }

    /// @notice Invariant — the eETH exchange rate
    ///         (`totalPooledEther / totalShares`) does not decrease across
    ///         this call. Snapshots (P0, S0) before the function body, then
    ///         (P1, S1) after, and asserts `P1 * S0 >= P0 * S1` (the
    ///         cross-multiplied form of `P1/S1 >= P0/S0`, integer-exact).
    ///
    ///         APPLIED to every share-changing entry point where the rate
    ///         is supposed to stay equal or move UP by construction:
    ///           - deposit() / depositToRecipient / deposit(user, ref)
    ///             — proportional mint, floor-rounded shares (rate up)
    ///           - withdraw(address, uint256)
    ///             — live-rate burn, ceil-rounded shares (rate up)
    ///           - burnEEthShares
    ///             — share-only burn, no P-side change (rate up)
    ///           - burnEEthSharesForNonETHWithdrawal
    ///             — already locally checks rate non-decrease; modifier is
    ///               belt-and-suspenders
    ///
    ///         INTENTIONALLY NOT applied to:
    ///           - withdraw(uint256, uint256, uint256) — frozen-rate finalized claim,
    ///             rate-drop bounded by the three-guard design at that function's
    ///             docblock (WRN/PQ-only)
    ///           - rebase() — oracle path, rate-change bounded by
    ///             EtherFiAdmin._validateRebaseApr's APR cap
    ///
    ///         These two are the only intentional rate-changing paths.
    ///         Anything else that drops the rate trips the modifier.
    ///
    ///         Overflow note: P, S each fit in uint128 in any plausible
    ///         protocol state; P*S ≈ 1.4e52 ≪ uint256 max. Safe by inspection.
    ///
    ///         Implementation note: the snapshot / check pair lives in two
    ///         internal view helpers so the body isn't duplicated at every
    ///         site Solidity inlines this modifier into. Same semantics,
    ///         ~1 KB smaller runtime.
    modifier nonDecreasingRate() {
        (uint256 P0, uint256 S0) = _snapRate();
        _;
        _checkRateNonDec(P0, S0);
    }

    function _snapRate() internal view returns (uint256 P, uint256 S) {
        P = getTotalPooledEther();
        S = eETH.totalShares();
    }

    function _checkRateNonDec(uint256 P0, uint256 S0) internal view {
        (uint256 P1, uint256 S1) = _snapRate();
        // Bootstrap exempt (no rate before/after to compare).
        if (S0 != 0 && S1 != 0 && P1 * S0 < P0 * S1) revert EETHRateDeflation();
    }
}

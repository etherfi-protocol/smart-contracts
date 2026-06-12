// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/staking/interfaces/IStakingManager.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/deposits/interfaces/ILiquifier.sol";
import "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";
import "@etherfi/withdrawals/interfaces/IEtherFiRedemptionManager.sol";
import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/DeprecatedOZOwnable.sol";

contract LiquidityPool is Initializable, DeprecatedOZOwnable, UUPSUpgradeable, ReentrancyGuardTransient, PausableUntil, ILiquidityPool {
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
    
    //deprecated storage slots
    uint256[5] private __gap_3;

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

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    uint256 public constant SHARE_UNIT = 1e18;

    // Hard cap on how far a single rebase may INCREASE TVL (rewards), in bps of TVL.
    // 25 bps ≈ 1 month of reward accrual at 3% APR — there is no legitimate reason for a
    // single report to raise the rate by more than this, so it is a fixed invariant (not
    // governance-configurable). Bounds a buggy/compromised rebase caller at the share-rate
    // chokepoint regardless of the oracle-side checks.
    uint256 public constant MAX_POSITIVE_REBASE_BPS = 25;
    uint256 private constant REBASE_BPS_DENOMINATOR = 10_000;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event Deposit(address indexed sender, uint256 amount, SourceOfFunds source, address referral);
    event Withdraw(address indexed sender, address recipient, uint256 amount, SourceOfFunds source);
    event EEthSharesBurnedForNonETHWithdrawal(uint256 amountSharesToBurn, uint256 withdrawalValueInETH);
    event UpdatedFeeRecipient(address newFeeRecipient);
    event ValidatorSpawnerRegistered(address user);
    event ValidatorSpawnerUnregistered(address user);
    event ValidatorRegistered(uint256 indexed validatorId, bytes signature, bytes pubKey, bytes32 depositRoot);
    event Rebase(uint256 totalEthLocked, uint256 totalEEthShares);
    event ProtocolFeePaid(uint128 protocolFees);
    event MinWithdrawAmountSet(uint256 minWithdrawAmount);
    event MaxWithdrawAmountSet(uint256 maxWithdrawAmount);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error IncorrectCaller();
    error InvalidAmount();
    error InvalidWithdrawalAmount();
    error InvalidShareAmount();
    error InsufficientLiquidity();
    error SendFail();
    error InvalidValidatorSize();
    error RebaseExceedsPositiveCap();
    error AlreadyMigrated();
    error MigrationNotComplete();
    error AlreadyRegistered();
    error NotRegistered();
    error EETHRateDeflation();

    //--------------------------------------------------------------------------------------
    //----------------------------  CONSTRUCTOR  ------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _constructorAddresses The addresses of the contracts to use
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(ConstructorAddresses memory _constructorAddresses) RolesLibrary(_constructorAddresses.roleRegistry) {
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
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the Liquidity Pool
     */
    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    /**
    * @notice One-shot post-upgrade migration that sweeps existing locked ETH from LP to WithdrawRequestNFT and PriorityWithdrawalQueue.
    * @dev Only callable by the upgrade timelock
    */
    function initializeOnUpgradeV2() external onlyUpgradeTimelock {
        if (escrowMigrationCompleted) revert AlreadyMigrated();

        // Legacy `ethAmountLockedForWithdrawal` was a uint128 packed at bit offset 8
        // (byte 1) of __gap_3[0]; read it out directly from that slot.
        uint128 nftLocked;
        assembly {
            nftLocked := and(shr(8, sload(__gap_3.slot)), 0xffffffffffffffffffffffffffffffff)
        }
        uint128 queueLocked = address(priorityWithdrawalQueue) != address(0)
            ? uint128(priorityWithdrawalQueue.ethAmountLockedForPriorityWithdrawal())
            : 0;

        uint128 totalLocked = nftLocked + queueLocked;
        if (totalLocked > 0) {
            if (totalValueInLp < totalLocked) revert InsufficientLiquidity();
            totalValueInLp    -= totalLocked;
            totalValueOutOfLp += totalLocked;

            if (nftLocked > 0) {
                // zero the legacy uint128 (bits 8..135 of __gap_3[0]), preserving its slot neighbours
                assembly {
                    let slot := __gap_3.slot
                    sstore(slot, and(sload(slot), not(shl(8, 0xffffffffffffffffffffffffffffffff))))
                }
                _sendFund(address(withdrawRequestNFT), nftLocked);
            }
            if (queueLocked > 0) _sendFund(address(priorityWithdrawalQueue), queueLocked);
        }

        _checkTotalValueInLp();
        escrowMigrationCompleted = true;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECEIVE FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Receive ETH
     */
    receive() external payable {
        if (msg.value > type(uint128).max) revert InvalidAmount();
        totalValueOutOfLp -= uint128(msg.value);
        totalValueInLp += uint128(msg.value);
        _checkTotalValueInLp();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  DEPOSIT FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Deposit ETH into the Liquidity Pool
     * @return uint256 The amount of eETH minted to the caller
     * @dev Used by eETH staking flow
     */
    function deposit() external payable returns (uint256) {
        return deposit(address(0));
    }

    /**
     * @notice Deposit ETH into the Liquidity Pool
     * @param _referral The address of the referral
     * @return uint256 The amount of eETH minted to the caller
     * @dev Used by eETH staking flow
     */
    function deposit(address _referral) public payable nonReentrant whenNotPaused nonBlacklisted returns (uint256) {
        emit Deposit(msg.sender, msg.value, SourceOfFunds.EETH, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    /**
     * @notice Deposit ETH into the Liquidity Pool
     * @param _recipient The address of the recipient
     * @param _amount The amount of ETH to deposit
     * @param _referral The address of the referral
     * @return uint256 The amount of eETH minted to the caller
     * @dev Used by eETH staking flow through Liquifier contract; deVamp or to pay protocol fees
     */
    function depositToRecipient(address _recipient, uint256 _amount, address _referral) public nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != address(liquifier) && msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
        blacklister.nonBlacklisted(_recipient);

        emit Deposit(_recipient, _amount, SourceOfFunds.EETH, _referral);

        return _deposit(_recipient, 0, _amount);
    }

    /**
     * @notice Deposit ETH into the Liquidity Pool
     * @param _user The address of the user
     * @param _referral The address of the referral
     * @return uint256 The amount of eETH minted to the caller
     * @dev Used by ether.fan staking flow
     */
    function deposit(address _user, address _referral) external payable nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        blacklister.nonBlacklisted(_user);

        emit Deposit(msg.sender, msg.value, SourceOfFunds.ETHER_FAN, _referral);

        return _deposit(msg.sender, msg.value, 0);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  WITHDRAW FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Burns shares and pays ETH. For NFT/queue callers, ETH is paid by the caller from its own segregated balance; LP only does accounting. Other callers receive ETH from LP.
     * @param _recipient The address of the recipient
     * @param _amount The amount of ETH to withdraw
     * @return uint256 The amount of eETH burned
     * @dev Only callable by the membership manager or the etherFi redemption manager
     * Live rate withdraw for membershipManager and etherFiRedemptionManager.
     * Burns shares at the live rate and pays ETH from the LP to `_recipient`.
     */
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

        _checkTotalValueInLp();

        return share;
    }

    /**
     * @notice Settles a finalized claim for withdrawRequestNFT or priorityWithdrawalQueue.
     * @param _amount The amount of ETH paid to the claimer; the credit removed from `totalValueOutOfLp`.
     * @param _share The full share allocation of the request, burned in its entirety.
     * @dev Only callable by the withdrawRequestNFT or the priorityWithdrawalQueue.
     * The caller (WRN / PWQ) supplies the request's full share snapshot and the ETH amount to pay;
     * LP burns the full `_share` and unwinds the matching `_amount` from `totalValueOutOfLp`.
     * Burning the full share (rather than a rate-derived subset) removes the dust/remainder
     * that the prior rate-based burn left behind, so no separate remainder-handling flow is needed.
     * `_share` MUST be the request-time share snapshot; LP cannot independently verify this and
     * trusts the caller to pass it honestly. The `eETH.shares(msg.sender) < _share` solvency check
     * is the only bound against the caller burning more than its actual holdings.
     * ETH was already segregated to the caller at finalize/fulfill via
     * `addEthAmountLockedForWithdrawal` / `transferLockedEthForPriority`; LP only
     * performs accounting (burn + `totalValueOutOfLp -=`).
     * A negative rebase that drops `totalValueOutOfLp` below `_amount` reverts the claim
     * (finalized-withdrawal DoS, bounded by EtherFiAdmin's rebase-APR cap).
    */
    function withdraw(uint256 _amount, uint256 _share) external nonReentrant {
        if (msg.sender != address(withdrawRequestNFT) && msg.sender != address(priorityWithdrawalQueue)) {
            revert IncorrectCaller();
        }
        if (_amount > type(uint128).max || _amount == 0 || _share == 0) revert InvalidAmount();

        totalValueOutOfLp -= uint128(_amount);
        eETH.burnShares(msg.sender, _share);
    }

    /**
     * @notice request withdraw from pool and receive a WithdrawRequestNFT
     * @param recipient The address of the recipient
     * @param amount The amount of ETH to withdraw
     * @return uint256 The requestId of the WithdrawRequestNFT
     * @dev Transfers the amount of eETH from msg.senders account to the WithdrawRequestNFT contract & mints an NFT to the msg.sender
     */
    function requestWithdraw(address recipient, uint256 amount) public nonReentrant whenNotPaused nonBlacklisted returns (uint256) {
        blacklister.nonBlacklisted(recipient);
        if (amount == 0) revert InvalidWithdrawalAmount();
        if (amount < minWithdrawAmount || amount > maxWithdrawAmount) revert InvalidWithdrawalAmount();
        uint256 share = sharesForAmount(amount);
        if (share == 0) revert InvalidShareAmount();

        return _requestWithdraw(recipient, amount, share, SourceOfFunds.EETH);
    }

    /**
     * @notice request withdraw from pool with signed permit data and receive a WithdrawRequestNFT
     * @param _owner The address of the owner
     * @param _amount The amount of ETH to withdraw
     * @param _permit The permit data to approve transfer of eETH
     * @return uint256 The requestId of the WithdrawRequestNFT
     * @dev accepts PermitInput signed data to approve transfer of eETH (EIP-2612) so withdraw request can happen in 1 tx
     */
    function requestWithdrawWithPermit(address _owner, uint256 _amount, PermitInput calldata _permit) external returns (uint256)
    {
        try eETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
        return requestWithdraw(_owner, _amount);
    }

    /**
     * @notice request withdraw of some or all of the eETH backing a MembershipNFT and receive a WithdrawRequestNFT
     * @param recipient The address of the recipient
     * @param amount The amount of ETH to withdraw
     * @param fee The fee amount not used anymore, only kept to maintain compatibility with existing code
     * @return uint256 The requestId of the WithdrawRequestNFT
     * @dev Transfers the amount of eETH from MembershipManager to the WithdrawRequestNFT contract & mints an NFT to the recipient
     */
    function requestMembershipNFTWithdraw(address recipient, uint256 amount, uint256 fee) public nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != address(membershipManager)) revert IncorrectCaller();
        uint256 share = sharesForAmount(amount);
        if (amount > type(uint96).max || amount == 0 || share == 0) revert InvalidAmount();

        return _requestWithdraw(recipient, amount, share, SourceOfFunds.ETHER_FAN);
    }


    //--------------------------------------------------------------------------------------
    //---------------------- STAKING FLOW FUNCTIONS -------------------------------------
    //--------------------------------------------------------------------------------------
    // [Liquidity Pool Staking flow]
    // Step 1: (Off-chain) create the keys using the desktop app
    // Step 2: register validator deposit data for later confirmation from the oracle before the 1eth deposit
    // Step 3: create validators with 1 eth deposits to official deposit contract
    // Step 4: oracle approves and funds the remaining balance for the validator
    /**
     * @notice claim bids and send 1 eth deposits to deposit contract to create the provided validators.
     * @param _depositData The deposit data for the validators
     * @param _bidIds The bid ids for the validators
     * @param _etherFiNode The etherFi node for the validators
     * @dev step 2 of staking flow
     */
    function batchRegister(
        IStakingManager.DepositData[] calldata _depositData,
        uint256[] calldata _bidIds,
        address _etherFiNode
    ) external whenNotPaused {
        if (!validatorSpawner[msg.sender].registered) revert IncorrectCaller();
        stakingManager.registerBeaconValidators(_depositData, _bidIds, _etherFiNode);
    }

    /**
     * @notice create validators with 1 eth deposits to official deposit contract
     * @param _depositData The deposit data for the validators
     * @param _bidIds The bid ids for the validators
     * @param _etherFiNode The etherFi node for the validators
     * @dev step 3 of staking flow
     */
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

    /**
     * @notice send remaining eth to deposit contract to activate the provided validators
     * @param _depositData The deposit data for the validators
     * @param _validatorSizeWei The size of the validators
     * @dev step 3 of staking flow. Callable directly by oracle ops, or by EtherFiAdmin
     *      when forwarding from `executeValidatorApprovalTask` (which gates oracle ops at
     *      its own entry point and tracks task completion on-chain). Both upstream paths
     *      enforce oracle-ops authorization, so accepting EtherFiAdmin here doesn't widen
     *      the auth surface.
    */
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

    /**
     * @notice The admin can register an address to become a BNFT holder
     * @param _user The address of the Validator Spawner to register
     * @dev The admin can register an address to become a BNFT holder
     */
    function registerValidatorSpawner(address _user) public onlyAdmin {
        if (validatorSpawner[_user].registered) revert AlreadyRegistered();  
        validatorSpawner[_user] = ValidatorSpawner({registered: true});
        emit ValidatorSpawnerRegistered(_user);
    }

    /**
     * @notice Removes a Validator Spawner
     * @param _user the address of the Validator Spawner to remove
     * @dev Removes a Validator Spawner
     */
    function unregisterValidatorSpawner(address _user) external onlyOperatingMultisig {
        if (!validatorSpawner[_user].registered) revert NotRegistered();
        delete validatorSpawner[_user];
        emit ValidatorSpawnerUnregistered(_user);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  OPERATIONAL FUNCTIONS  -------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Rebase by ether.fi and pay protocol fees in a single oracle-driven step
     * @param _accruedRewards The amount of rewards to rebase
     * @param _protocolFees The amount of protocol fees to pay in ether. Minted to feeRecipient after the rebase.
     * @dev Only callable by the etherFiAdminContract
     */
    function rebase(int128 _accruedRewards, uint128 _protocolFees) external {
        if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();

        // Positive (reward) upper bound, enforced at the share-rate chokepoint regardless
        // of who calls rebase. A single rebase cannot increase TVL by more than
        // MAX_POSITIVE_REBASE_BPS of pre-rebase TVL. Defense-in-depth alongside the
        // oracle-side negative cap in EtherFiAdmin; the negative side is intentionally not
        // re-checked here (the oracle path owns it and bounds it tighter). Guarded on the
        // positive branch: for a negative _accruedRewards, uint128(_accruedRewards) would
        // reinterpret the sign bit as a huge unsigned value and spuriously trip the cap.
        if (_accruedRewards > 0) {
            uint256 maxIncrease = (getTotalPooledEther() * MAX_POSITIVE_REBASE_BPS) / REBASE_BPS_DENOMINATOR;
            if (uint256(uint128(_accruedRewards)) > maxIncrease) revert RebaseExceedsPositiveCap();
        }

        totalValueOutOfLp = uint128(int128(totalValueOutOfLp) + _accruedRewards);
        emit Rebase(getTotalPooledEther(), eETH.totalShares());

        if (_protocolFees > 0) {
            emit ProtocolFeePaid(_protocolFees);
            depositToRecipient(feeRecipient, _protocolFees, address(0));
        }
    }

    /**
     * @notice Locks ETH for finalized NFT withdrawals by transferring from LP to WithdrawRequestNFT. TVL preserved by InLp/OutOfLp rebalance; share rate unchanged.
     * @param _amount The amount of ETH to lock
     * @dev Only callable by the etherFiAdminContract or the withdrawRequestNFT
     */
    function addEthAmountLockedForWithdrawal(uint128 _amount) external {
        if (msg.sender != address(etherFiAdminContract) && msg.sender != address(withdrawRequestNFT)) revert IncorrectCaller();
        _lockEth(address(withdrawRequestNFT), _amount);
    }

    /**
     * @notice Locks ETH for the priority withdrawal queue by transferring from LP to the queue contract. TVL preserved by InLp/OutOfLp rebalance.
     * @param _amount The amount of ETH to lock
     * @dev Only callable by the priorityWithdrawalQueue
     */
    function transferLockedEthForPriority(uint128 _amount) external {
        if (msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        _lockEth(address(priorityWithdrawalQueue), _amount);
    }

    /**
     * @notice Burns eETH shares
     * @param shares The amount of eETH shares to burn
     * @dev Only callable by the etherFiRedemptionManager, the withdrawRequestNFT or the priorityWithdrawalQueue
     */
    function burnEEthShares(uint256 shares) external nonDecreasingRate {
        if (msg.sender != address(etherFiRedemptionManager) && msg.sender != address(withdrawRequestNFT) && msg.sender != address(priorityWithdrawalQueue)) revert IncorrectCaller();
        eETH.burnShares(msg.sender, shares);
    }

    /**
     * @notice Burns eETH shares for non-ETH withdrawal
     * @param _amountSharesToBurn The amount of eETH shares to burn
     * @param _withdrawalValueInETH The amount of ETH to withdraw
     * @dev Only callable by the etherFiRedemptionManager
     */
    function burnEEthSharesForNonETHWithdrawal(uint256 _amountSharesToBurn, uint256 _withdrawalValueInETH) external nonDecreasingRate {
        uint256 share = sharesForWithdrawalAmount(_withdrawalValueInETH);
        if (msg.sender != address(etherFiRedemptionManager)) revert IncorrectCaller();
        if (_amountSharesToBurn == 0 || _withdrawalValueInETH == 0) revert InvalidAmount();

        // Verify the share price will not go down
        if (share > _amountSharesToBurn) revert InvalidAmount();

        totalValueOutOfLp -= uint128(_withdrawalValueInETH);

        eETH.burnShares(msg.sender, _amountSharesToBurn);
        emit EEthSharesBurnedForNonETHWithdrawal(_amountSharesToBurn, _withdrawalValueInETH);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  SETTER FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice set the size of validators created when EtherFiAdmin.executeValidatorApprovalTask
     * @param _validatorSizeWei The size of the validators
     * @dev set the size of validators created when EtherFiAdmin.executeValidatorApprovalTask
     *      forwards into confirmAndFundBeaconValidators(). In a future upgrade this will be a
     *      parameter to that call but was done like this to limit changes to other dependent contracts.
     */
    function setValidatorSizeWei(uint256 _validatorSizeWei) external onlyAdmin {
        _requireValidValidatorSize(_validatorSizeWei);
        validatorSizeWei = _validatorSizeWei;
    }

    /**
     * @notice Set the fee recipient address
     * @param _feeRecipient The address to set as the fee recipient
     * @dev Only callable by the admin
     */
    function setFeeRecipient(address _feeRecipient) external onlyAdmin {
        feeRecipient = _feeRecipient;
        emit UpdatedFeeRecipient(_feeRecipient);
    }

    /**
     * @notice Set the minimum withdraw amount
     * @param _minWithdrawAmount The minimum withdraw amount
     * @dev Only callable by the operating multisig
     */
    function setMinWithdrawAmount(uint256 _minWithdrawAmount) external onlyOperatingMultisig {
        if (_minWithdrawAmount > maxWithdrawAmount) revert InvalidAmount();
        minWithdrawAmount = _minWithdrawAmount;
        emit MinWithdrawAmountSet(_minWithdrawAmount);
    }

    /**
     * @notice Set the maximum withdraw amount
     * @param _maxWithdrawAmount The maximum withdraw amount
     * @dev Only callable by the operating multisig
     */
    function setMaxWithdrawAmount(uint256 _maxWithdrawAmount) external onlyOperatingMultisig {
        if (_maxWithdrawAmount == 0 || _maxWithdrawAmount < minWithdrawAmount) revert InvalidAmount();
        maxWithdrawAmount = _maxWithdrawAmount;
        emit MaxWithdrawAmountSet(_maxWithdrawAmount);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Deposits ETH into the Liquidity Pool
     * @param _recipient The address of the recipient
     * @param _amountInLp The amount of ETH to deposit into the Liquidity Pool
     * @param _amountOutOfLp The amount of ETH to deposit into the Liquidity Pool
     */
    function _deposit(address _recipient, uint256 _amountInLp, uint256 _amountOutOfLp) internal nonDecreasingRate returns (uint256) {
        totalValueInLp += uint128(_amountInLp);
        totalValueOutOfLp += uint128(_amountOutOfLp);
        uint256 amount = _amountInLp + _amountOutOfLp;
        uint256 share = _sharesForDepositAmount(amount);
        if (amount > type(uint128).max || amount == 0 || share == 0) revert InvalidAmount();

        eETH.mintShares(_recipient, share);

        _checkTotalValueInLp();

        return share;
    }

    /**
     * @notice Shared tail for requestWithdraw / requestMembershipNFTWithdraw: moves `amount` eETH
     * @param recipient The address of the recipient
     * @param amount The amount of eETH to move
     * @param share The share of eETH to move
     * @param source The source of the eETH
     * @return requestId The requestId of the WithdrawRequestNFT
     */
    function _requestWithdraw(address recipient, uint256 amount, uint256 share, SourceOfFunds source) internal returns (uint256 requestId) {
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(withdrawRequestNFT), amount);
        requestId = withdrawRequestNFT.requestWithdraw(uint96(amount), uint96(share), recipient);
        emit Withdraw(msg.sender, recipient, amount, source);
    }

    /**
     * @notice Calculates the shares for a deposit amount
     * @param _depositAmount The amount of ETH to deposit
     * @return uint256 The shares for the deposit amount
     */
    function _sharesForDepositAmount(uint256 _depositAmount) internal view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther() - _depositAmount;
        if (totalPooledEther == 0) {
            return _depositAmount;
        }
        return Math.mulDiv(_depositAmount, eETH.totalShares(), totalPooledEther, Math.Rounding.Down);
    }

    /**
     * @notice Sends ETH to a recipient
     * @param _recipient The address of the recipient
     * @param _amount The amount of ETH to send
     */
    function _sendFund(address _recipient, uint256 _amount) internal {
        uint256 balance = address(this).balance;
        (bool sent, ) = _recipient.call{value: _amount}("");
        if (!sent || address(this).balance < balance - _amount) revert SendFail();
    }

    /**
     * @notice Shared body for `addEthAmountLockedForWithdrawal` and `transferLockedEthForPriority`.
     * @param _dest The address of the recipient
     * @param _amount The amount of ETH to send
     * @dev Both move ETH out of LP into a segregated escrow (WRNFT or PQ) while keeping TVL
     *      invariant by rebalancing `totalValueInLp` -> `totalValueOutOfLp`. Caller-gating
     *      lives in the two external entry points.
     */
    function _lockEth(address _dest, uint128 _amount) internal {
        if (!escrowMigrationCompleted) revert MigrationNotComplete();
        if (totalValueInLp < _amount) revert InsufficientLiquidity();
        totalValueInLp    -= _amount;
        totalValueOutOfLp += _amount;
        _sendFund(_dest, _amount);
        _checkTotalValueInLp();
    }

    /**
     * @notice Accounts for ETH sent out
     * @param _amount The amount of ETH to send out
     * @dev Accounts for ETH sent out by the WithdrawRequestNFT or the PriorityWithdrawalQueue
     */
    function _accountForEthSentOut(uint256 _amount) internal {
        totalValueOutOfLp += uint128(_amount);
        totalValueInLp -= uint128(_amount);
        _checkTotalValueInLp();
    }

    /**
     * @notice Checks if the total value in LP is greater than the balance of the contract
     */
    function _checkTotalValueInLp() internal view {
        if (totalValueInLp > address(this).balance) revert InsufficientLiquidity();
    }

    /**
     * @notice Snaps the rate
     * @return P The total pooled ether
     * @return S The total shares
     */
    function _snapRate() internal view returns (uint256 P, uint256 S) {
        P = getTotalPooledEther();
        S = eETH.totalShares();
    }

    /**
     * @notice Checks if the rate is non-decreasing
     * @param P0 The total pooled ether before the rate is snapped
     * @param S0 The total shares before the rate is snapped
     */
    function _checkRateNonDec(uint256 P0, uint256 S0) internal view {
        (uint256 P1, uint256 S1) = _snapRate();
        // Bootstrap exempt (no rate before/after to compare).
        if (S0 != 0 && S1 != 0 && P1 * S0 < P0 * S1) revert EETHRateDeflation();
    }

    /**
     * @notice Checks if the validator size is valid
     * @param _validatorSizeWei The validator size
     */
    function _requireValidValidatorSize(uint256 _validatorSizeWei) internal view {
        if (_validatorSizeWei < stakingManager.MIN_VALIDATOR_SIZE_WEI() || _validatorSizeWei > stakingManager.MAX_VALIDATOR_SIZE_WEI()) revert InvalidValidatorSize();
    }

    /**
     * @notice Authorizes the upgrade of the contract
     * @param newImplementation The new implementation address
     * @dev Only callable by the upgrade timelock
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Gets the total ether claim of a user
     * @param _user The address of the user
     * @return uint256 The total ether claim of the user
     */
    function getTotalEtherClaimOf(address _user) external view returns (uint256) {
        uint256 staked;
        uint256 totalShares = eETH.totalShares();
        if (totalShares > 0) {
            staked = Math.mulDiv(getTotalPooledEther(), eETH.shares(_user), totalShares, Math.Rounding.Down);
        }
        return staked;
    }

    /**
     * @notice Gets the total pooled ether
     * @return uint256 The total pooled ether
     */
    function getTotalPooledEther() public view returns (uint256) {
        return totalValueOutOfLp + totalValueInLp;
    }

    /**
     * @notice Gets the shares for an amount
     * @param _amount The amount of ETH
     * @return uint256 The shares for the amount
     */
    function sharesForAmount(uint256 _amount) public view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther();
        if (totalPooledEther == 0) {
            return 0;
        }
        return Math.mulDiv(_amount, eETH.totalShares(), totalPooledEther, Math.Rounding.Down);
    }

    /**
     * @notice Gets the shares for a withdrawal amount
     * @param _amount The amount of ETH to withdraw
     * @return uint256 The shares for the withdrawal amount
     * @dev withdrawal rounding errors favor the protocol by rounding up
     */
    function sharesForWithdrawalAmount(uint256 _amount) public view returns (uint256) {
        uint256 totalPooledEther = getTotalPooledEther();
        if (totalPooledEther == 0) {
            return 0;
        }

        // ceiling division so rounding errors favor the protocol
        return Math.mulDiv(_amount, eETH.totalShares(), totalPooledEther, Math.Rounding.Up);
    }

    /**
     * @notice Gets the amount for a share
     * @param _share The share of eETH
     * @return uint256 The amount for the share
     */
    function amountForShare(uint256 _share) public view returns (uint256) {
        uint256 totalShares = eETH.totalShares();
        if (totalShares == 0) {
            return 0;
        }
        return Math.mulDiv(_share, getTotalPooledEther(), totalShares, Math.Rounding.Down);
    }

    /**
     * @notice Gets the amount per share ceil
     * @return uint256 The amount per share ceil
     * @dev ETH value of `1e18` shares, rounded UP. Single source of truth for the rate
     *      snapshotted by segregated callers (WithdrawRequestNFT / PriorityWithdrawalQueue)
     *      at finalize/fulfill. Ceiling rounding keeps the frozen rate >= `amountForShare`'s
     *      floor value so the round-trips at claim time satisfy:
     *      `shareOfEEth * rate / 1e18 >= amountForShare(shareOfEEth)` (solvency check) and
     *      `ceil(amount * 1e18 / rate) <= shareOfEEth` (burn-bounded-by-request).
     */
    function amountPerShareCeil() public view returns (uint256) {
        uint256 totalShares = eETH.totalShares();
        if (totalShares == 0) return 0;
        return Math.mulDiv(SHARE_UNIT, getTotalPooledEther(), totalShares, Math.Rounding.Up);
    }

    /**
     * @notice Gets the implementation address
     * @return address The implementation address
     */
    function getImplementation() external view returns (address) {return _getImplementation();}

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the caller is not blacklisted
     * @dev Only callable by the blacklister
     */
    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the etherFiAdminContract
     * @dev Only callable by the etherFiAdminContract
     */
    modifier onlyEtherFiAdmin() {
        if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
        _;
    }

    /**
     * @notice Modifier to check if the eETH exchange rate is non-decreasing
     * @dev Invariant — the eETH exchange rate
     *      (`totalPooledEther / totalShares`) does not decrease across
     *      this call. Snapshots (P0, S0) before the function body, then
     *      (P1, S1) after, and asserts `P1 * S0 >= P0 * S1` (the
     *      cross-multiplied form of `P1/S1 >= P0/S0`, integer-exact).
     *
     *         APPLIED to every share-changing entry point where the rate
     *         is supposed to stay equal or move UP by construction:
     *           - deposit() / depositToRecipient / deposit(user, ref)
     *             — proportional mint, floor-rounded shares (rate up)
     *           - withdraw(address, uint256)
     *             — live-rate burn, ceil-rounded shares (rate up)
     *           - burnEEthShares
     *             — share-only burn, no P-side change (rate up)
     *           - burnEEthSharesForNonETHWithdrawal
     *             — already locally checks rate non-decrease; modifier is
     *               belt-and-suspenders
     *
     *         INTENTIONALLY NOT applied to:
     *           - withdraw(uint256, uint256, uint256) — frozen-rate finalized claim,
     *             rate-drop bounded by the three-guard design at that function's
     *             docblock (WRN/PQ-only)
     *           - rebase() — oracle path, rate-change bounded by
     *             EtherFiAdmin._validateRebaseApr's APR cap
     *
     *         These two are the only intentional rate-changing paths.
     *         Anything else that drops the rate trips the modifier.
     *
     *         Overflow note: P, S each fit in uint128 in any plausible
     *         protocol state; P*S ≈ 1.4e52 ≪ uint256 max. Safe by inspection.
     *
     *         Implementation note: the snapshot / check pair lives in two
     *         internal view helpers so the body isn't duplicated at every
     *         site Solidity inlines this modifier into. Same semantics,
     *         ~1 KB smaller runtime.   
     */
    modifier nonDecreasingRate() {
        (uint256 P0, uint256 S0) = _snapRate();
        _;
        _checkRateNonDec(P0, S0);
    }
}

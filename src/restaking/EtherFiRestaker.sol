/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "@etherfi/deposits/Liquifier.sol";
import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";

import "@etherfi/eigenlayer-interfaces/IStrategyManager.sol";
import "@etherfi/eigenlayer-interfaces/IDelegationManager.sol";
import "@etherfi/eigenlayer-interfaces/IRewardsCoordinator.sol";

import "@etherfi/deposits/interfaces/ILiquifier.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/governance/rate-limiting/interfaces/IEtherFiRateLimiter.sol";
import "@etherfi/restaking/interfaces/IEtherFiRestaker.sol";

contract EtherFiRestaker is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, RolesLibrary, IEtherFiRestaker {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    // deprecated storage slots
    uint256[8] private __gap_0;

    mapping(address => TokenInfo) public tokenInfos;

    EnumerableSet.Bytes32Set private withdrawalRootsSet;
    
    // deprecated storage slots
    uint256 private __gap_1;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    IRewardsCoordinator public immutable rewardsCoordinator;
    ILiquidityPool public immutable liquidityPool;
    ILiquifier public immutable liquifier;
    ILidoWithdrawalQueue public immutable lidoWithdrawalQueue;
    ILido public immutable lido;
    IDelegationManager public immutable eigenLayerDelegationManager;
    IStrategyManager public immutable eigenLayerStrategyManager;
    IEtherFiRateLimiter public immutable rateLimiter;
    address public immutable etherFiRedemptionManager;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    bytes32 public constant STETH_REQUEST_WITHDRAWAL_LIMIT_ID = keccak256("STETH_REQUEST_WITHDRAWAL_LIMIT_ID");
    bytes32 public constant QUEUE_WITHDRAWALS_LIMIT_ID        = keccak256("QUEUE_WITHDRAWALS_LIMIT_ID");
    bytes32 public constant DEPOSIT_INTO_STRATEGY_LIMIT_ID    = keccak256("DEPOSIT_INTO_STRATEGY_LIMIT_ID");
    /// @dev Suggested gas stipend for contract receiving ETH to perform a few
    /// storage reads and writes, but low enough to prevent griefing.
    uint256 internal constant GAS_STIPEND_NO_GRIEF = 100_000;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event QueuedStEthWithdrawals(uint256[] _reqIds);
    event CompletedStEthQueuedWithdrawals(uint256[] _reqIds);
    event CompletedQueuedWithdrawal(bytes32 _withdrawalRoot);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error NotEnoughBalance();
    error IncorrectAmount();
    error EthTransferFailed();
    error IncorrectCaller();
    error InsufficientBalance();
    error NotTheOwner();
    error AlreadyClaimed();
    error AmountOverflowsUint64Gwei();
    error WithdrawalRootNotFound();

    //--------------------------------------------------------------------------------------
    //-------------------------------------  CONSTRUCTOR  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _liquidityPool The address of the liquidity pool
     * @param _liquifier The address of the liquifier
     * @param _rewardsCoordinator The address of the rewards coordinator
     * @param _etherFiRedemptionManager The address of the etherFi redemption manager
     * @param _roleRegistry The address of the role registry
     * @param _rateLimiter The address of the rate limiter
     * @param _eigenLayerStrategyManager The address of the eigenLayer strategy manager
     * @param _eigenLayerDelegationManager The address of the eigenLayer delegation manager
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address _liquidityPool,
        address _liquifier,
        address _rewardsCoordinator,
        address _etherFiRedemptionManager,
        address _roleRegistry,
        address _rateLimiter,
        address _eigenLayerStrategyManager,
        address _eigenLayerDelegationManager
    ) RolesLibrary(_roleRegistry) {
        liquidityPool = ILiquidityPool(payable(_liquidityPool));
        liquifier = ILiquifier(payable(_liquifier));
        lido = liquifier.lido();
        lidoWithdrawalQueue = liquifier.lidoWithdrawalQueue();
        eigenLayerStrategyManager = IStrategyManager(_eigenLayerStrategyManager);
        eigenLayerDelegationManager = IDelegationManager(_eigenLayerDelegationManager);
        rewardsCoordinator = IRewardsCoordinator(_rewardsCoordinator);
        etherFiRedemptionManager = _etherFiRedemptionManager;
        rateLimiter = IEtherFiRateLimiter(_rateLimiter);
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the EtherFiRestaker
     * @param _liquidityPool The address of the liquidity pool
     * @param _liquifier The address of the liquifier
     */
    function initialize(address _liquidityPool, address _liquifier) initializer external {
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        (,, IStrategy strategy,,,,,,,,) = liquifier.tokenInfos(address(lido));
        tokenInfos[address(lido)] = TokenInfo({
            elStrategy: strategy
        });
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECEIVE FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Receive ETH
     */
    receive() external payable {}

    //--------------------------------------------------------------------------------------
    //----------------------------  STETH MANAGEMENT FUNCTIONS  ----------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Transfer stETH to a recipient for instant withdrawal
     * @param recipient The address to receive stETH
     * @param amount The amount of stETH to transfer
     */
    function transferStETH(address recipient, uint256 amount) external {
        if(msg.sender != etherFiRedemptionManager) revert IncorrectCaller();
        if (amount > lido.balanceOf(address(this))) revert InsufficientBalance();
        IERC20(address(lido)).safeTransfer(recipient, amount);
    }

    /**
     * @notice Initiate the redemption of stETH for ETH
     * @return The request ids
     */
    function stEthRequestWithdrawal() external returns (uint256[] memory) {
        uint256 amount = lido.balanceOf(address(this));
        return stEthRequestWithdrawal(amount);
    }

    /**
     * @notice Request for a specific amount of stETH holdings
     * @param _amount the amount of stETH to request
     * @return The request ids
     */
    function stEthRequestWithdrawal(uint256 _amount) public onlyExecutorOperations returns (uint256[] memory) {
        rateLimiter.consume(STETH_REQUEST_WITHDRAWAL_LIMIT_ID, _amountToGwei(_amount));

        uint256 minAmount = lidoWithdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT();
        uint256 maxAmount = lidoWithdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();

        if (_amount < minAmount) revert IncorrectAmount();
        if (_amount > lido.balanceOf(address(this))) revert NotEnoughBalance();

        uint256 numReqs = (_amount + maxAmount - 1) / maxAmount;
        uint256[] memory reqAmounts = new uint256[](numReqs);
        for (uint256 i = 0; i < numReqs; i++) {
            reqAmounts[i] = (i == numReqs - 1) ? _amount - i * maxAmount : maxAmount;
        }

        // Ensure the last request meets MIN_STETH_WITHDRAWAL_AMOUNT
        // If too small and we have multiple requests, reduce the penultimate to increase the last
        if (numReqs > 1 && reqAmounts[numReqs - 1] < minAmount) {
            uint256 deficit = minAmount - reqAmounts[numReqs - 1];
            reqAmounts[numReqs - 2] -= deficit;
            reqAmounts[numReqs - 1] = minAmount;
        }

        IERC20(lido).safeIncreaseAllowance(address(lidoWithdrawalQueue), _amount);
        uint256[] memory reqIds = lidoWithdrawalQueue.requestWithdrawals(reqAmounts, address(this));

        emit QueuedStEthWithdrawals(reqIds);

        return reqIds;
    }

    /**
     * @notice Claim a batch of withdrawal requests if they are finalized sending the ETH to the this contract back
     * @param _requestIds array of request ids to claim
     * @param _hints checkpoint hint for each id. Can be obtained with `findCheckpointHints()`
     */
    function stEthClaimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external onlyHousekeepingOperations {
        lidoWithdrawalQueue.claimWithdrawals(_requestIds, _hints);

        _withdrawEther();

        emit CompletedStEthQueuedWithdrawals(_requestIds);
    }

    /**
     * @notice Send the ETH back to the liquidity pool
     */
    function withdrawEther() public onlyHousekeepingOperations {
        _withdrawEther();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  RESTAKING FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Set the claimer of the restaking rewards of this contract
     * @param _claimer The address of the claimer
     */
    function setRewardsClaimer(address _claimer) external onlyAdmin {
        rewardsCoordinator.setClaimerFor(_claimer);
    }

    /**
     * @notice Delegate to an AVS operator
     * @param operator The address of the operator
     * @param approverSignatureAndExpiry The signature and expiry of the approver
     * @param approverSalt The salt of the approver
     */
    function delegateTo(
        address operator,
        IDelegationManager.SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external onlyOperatingMultisig {
        eigenLayerDelegationManager.delegateTo(operator, approverSignatureAndExpiry, approverSalt);
    }

    /**
     * @notice Undelegate from the current AVS operator & un-restake all
     * @return The withdrawal roots
     */
    function undelegate() external onlyOperatingMultisig returns (bytes32[] memory) {
        bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.undelegate(address(this));

        for (uint256 i = 0; i < withdrawalRoots.length; i++) {
            withdrawalRootsSet.add(withdrawalRoots[i]);
        }

        return withdrawalRoots;
    }

    /**
     * @notice Deposit the token in holding into the restaking strategy
     * @param token The address of the token
     * @param amount The amount of token to deposit
     * @return The shares deposited
     */
    function depositIntoStrategy(address token, uint256 amount) external onlyExecutorOperations returns (uint256) {
        rateLimiter.consume(DEPOSIT_INTO_STRATEGY_LIMIT_ID, _amountToGwei(amount));

        IERC20(token).safeIncreaseAllowance(address(eigenLayerStrategyManager), amount);

        IStrategy strategy = tokenInfos[token].elStrategy;
        uint256 shares = eigenLayerStrategyManager.depositIntoStrategy(strategy, IERC20(token), amount);

        return shares;
    }

    /**
     * @notice Queue withdrawals for un-restaking the token
     * @param token The address of the token
     * @param amount The amount of token to withdraw
     * @return The withdrawal roots
     */
    function queueWithdrawals(address token, uint256 amount) public onlyExecutorOperations returns (bytes32[] memory) {
        rateLimiter.consume(QUEUE_WITHDRAWALS_LIMIT_ID, _amountToGwei(amount));

        uint256 shares = getEigenLayerRestakingStrategy(token).underlyingToSharesView(amount);
        bytes32[] memory withdrawalRoots = _queueWithdrawalsByShares(token, shares);

        for (uint256 i = 0; i < withdrawalRoots.length; i++) {
            withdrawalRootsSet.add(withdrawalRoots[i]);
        }

        return withdrawalRoots;
    }

    /**
     * @notice Complete the specified `queuedWithdrawals`
     * @param _queuedWithdrawals The QueuedWithdrawals to complete
     * @param _tokens Array of tokens for each QueuedWithdrawal
     */
    function completeQueuedWithdrawals(
        IDelegationManager.Withdrawal[] memory _queuedWithdrawals,
        IERC20[][] memory _tokens
    ) external onlyHousekeepingOperations {
        uint256 num = _queuedWithdrawals.length;
        bool[] memory receiveAsTokens = new bool[](num);
        for (uint256 i = 0; i < num; i++) {
            bytes32 withdrawalRoot = eigenLayerDelegationManager.calculateWithdrawalRoot(_queuedWithdrawals[i]);
            emit CompletedQueuedWithdrawal(withdrawalRoot);

            /// so that the shares withdrawn from the specified strategies are sent to the caller
            receiveAsTokens[i] = true;
            if (!withdrawalRootsSet.remove(withdrawalRoot)) revert WithdrawalRootNotFound();
        }

        /// it will update the erc20 balances of this contract
        eigenLayerDelegationManager.completeQueuedWithdrawals(_queuedWithdrawals, _tokens, receiveAsTokens);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  PAUSING FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Pause the contract
     */
    function pauseContract() external onlyOperatingMultisig {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unPauseContract() external onlyOperatingMultisig {
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    /**
     * @notice Convert wei to gwei for rate-limiter buckets, with overflow check.
     * @param amountWei The amount of wei to convert
     * @return The amount of gwei
     * @dev Rounds up so that any non-zero wei amount consumes at least 1 gwei from
     * the bucket — prevents sub-gwei dust from bypassing the rate limiter.
     */
    function _amountToGwei(uint256 amountWei) internal pure returns (uint64) {
        uint256 amountGwei = (amountWei + 1e9 - 1) / 1e9;
        if (amountGwei > type(uint64).max) revert AmountOverflowsUint64Gwei();
        return uint64(amountGwei);
    }

    /**
     * @notice Queue withdrawals for un-restaking the token
     * @param _token The address of the token
     * @param _shares The shares of the token to withdraw
     * @return The withdrawal roots
     */
    function _queueWithdrawalsByShares(address _token, uint256 _shares) internal returns (bytes32[] memory) {
        IDelegationManagerTypes.QueuedWithdrawalParams[] memory params = new IDelegationManagerTypes.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);

        strategies[0] = tokenInfos[_token].elStrategy;
        shares[0] = _shares;
        params[0] = IDelegationManagerTypes.QueuedWithdrawalParams({
            strategies: strategies,
            depositShares: shares,
            __deprecated_withdrawer: address(this)
        });

        return eigenLayerDelegationManager.queueWithdrawals(params);
    }

    /**
     * @notice Send the ETH back to the liquidity pool
     */
    function _withdrawEther() internal {
        uint256 amountToLiquidityPool = Math.min(address(this).balance, liquidityPool.totalValueOutOfLp());
        (bool sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: GAS_STIPEND_NO_GRIEF}("");
        if (!sent) revert EthTransferFailed();
    }

    /**
     * @notice Authorize the upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //--------------------------------  GETTERS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Enumerate the pending withdrawal roots
     * @return The pending withdrawal roots
     */
    function pendingWithdrawalRoots() external view returns (bytes32[] memory) {
        return withdrawalRootsSet.values();
    }

    /**
     * @notice Check if a withdrawal is pending for a given withdrawal root
     * @param _withdrawalRoot The withdrawal root to check
     * @return The boolean value indicating if the withdrawal is pending
     */
    function isPendingWithdrawal(bytes32 _withdrawalRoot) external view returns (bool) {
        return withdrawalRootsSet.contains(_withdrawalRoot);
    }

    /**
     * @notice Check if the contract is delegated
     * @return The boolean value indicating if the contract is delegated
     */
    function isDelegated() external view returns (bool) {
        return eigenLayerDelegationManager.isDelegated(address(this));
    }

    /**
     * @notice Get the total pooled ether
     * @return total the total pooled ether
     */
    function getTotalPooledEther() external view returns (uint256 total) {
        total = address(this).balance + getTotalPooledEther(address(lido));
    }

    /**
     * @notice Get the total pooled ether for a given token
     * @param _token The address of the token
     * @return The total pooled ether
     */
    function getTotalPooledEther(address _token) public view returns (uint256) {
        (uint256 restaked, uint256 unrestaking, uint256 holding, uint256 pendingForWithdrawals) = getTotalPooledEtherSplits(_token);
        return restaked + unrestaking + holding + pendingForWithdrawals;
    }

    /**
     * @notice Get the restaked amount for a given token
     * @param _token The address of the token
     * @return The restaked amount
     */
    function getRestakedAmount(address _token) public view returns (uint256) {
        TokenInfo memory info = tokenInfos[_token];
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = info.elStrategy;

        // get the shares locked in the EigenPod
        // - `withdrawableShares` reflects the slashing on 'depositShares'
        (uint256[] memory withdrawableShares, ) = eigenLayerDelegationManager.getWithdrawableShares(address(this), strategies);

        // convert the share amount to the token's balance amount
        uint256 restaked = info.elStrategy.sharesToUnderlyingView(withdrawableShares[0]);

        return restaked;
    }

    /**
     * @notice Get the EigenLayer restaking strategy for a given token
     * @param _token The address of the token
     * @return The EigenLayer restaking strategy
     */
    function getEigenLayerRestakingStrategy(address _token) public view returns (IStrategy) {
        return tokenInfos[_token].elStrategy;
    }

    /**
     * @notice Get the total pooled ether splits for a given token
     * @param _token The address of the token
     * @return restaked The amount of token restaked in EigenLayer
     * @return unrestaking The amount of token restaked in EigenLayer pending for withdrawals
     * @return holding The amount of token held by this contract
     * @return pendingForWithdrawals The amount of token pending for withdrawal
     * @dev Deposited (restaked) ETH can have 3 states:
     * - restaked in EigenLayer & pending for withdrawals
     * - non-restaked & held by this contract
     * - non-restaked & not held by this contract & pending for withdrawals
     */
    function getTotalPooledEtherSplits(address _token) public view returns (
        uint256 restaked,
        uint256 unrestaking,
        uint256 holding,
        uint256 pendingForWithdrawals
    ) {
        TokenInfo memory info = tokenInfos[_token];
        if (info.elStrategy != IStrategy(address(0))) {
            uint256 restakedTokenAmount = getRestakedAmount(_token);
            uint256 unrestakingTokenAmount = getAmountInEigenLayerPendingForWithdrawals(_token);
            restaked = liquifier.quoteByFairValue(_token, restakedTokenAmount);
            unrestaking = liquifier.quoteByFairValue(_token, unrestakingTokenAmount);
        }
        holding = liquifier.quoteByFairValue(_token, IERC20(_token).balanceOf(address(this)));
        pendingForWithdrawals = liquifier.quoteByFairValue(_token, getAmountPendingForRedemption(_token));
    }

    /**
     * @notice Get the amount of token restaked in EigenLayer pending for withdrawals
     * @param _token The address of the token
     * @return The amount of token restaked in EigenLayer pending for withdrawals
     */
    function getAmountInEigenLayerPendingForWithdrawals(address _token) public view returns (uint256) {
        TokenInfo memory info = tokenInfos[_token];
        if (info.elStrategy == IStrategy(address(0))) return 0;

        // Calculate by summing up shares from all pending withdrawals for this token
        uint256 totalShares = 0;
        (IDelegationManager.Withdrawal[] memory queuedWithdrawals, ) = eigenLayerDelegationManager.getQueuedWithdrawals(address(this));
        for (uint256 i = 0; i < queuedWithdrawals.length; i++) {
            bytes32 withdrawalRoot = eigenLayerDelegationManager.calculateWithdrawalRoot(queuedWithdrawals[i]);
            (IDelegationManager.Withdrawal memory withdrawal, uint256[] memory shares) = eigenLayerDelegationManager.getQueuedWithdrawal(withdrawalRoot);

            // Check if this withdrawal involves the specified token
            for (uint256 j = 0; j < withdrawal.strategies.length; j++) {
                address token = address(withdrawal.strategies[j].underlyingToken());
                if (token == _token && info.elStrategy == withdrawal.strategies[j]) {
                    totalShares += shares[j];
                }
            }
        }

        return info.elStrategy.sharesToUnderlyingView(totalShares);
    }

    /**
     * @notice Get the amount of token pending for redemption. e.g., pending in Lido's withdrawal queue
     * @param _token The address of the token
     * @return The amount of token pending for redemption
     */
    function getAmountPendingForRedemption(address _token) public view returns (uint256) {
        uint256 total = 0;
        if (_token == address(lido)) {
            uint256[] memory stEthWithdrawalRequestIds = lidoWithdrawalQueue.getWithdrawalRequests(address(this));
            ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = lidoWithdrawalQueue.getWithdrawalStatus(stEthWithdrawalRequestIds);
            for (uint256 i = 0; i < statuses.length; i++) {
                if (statuses[i].owner != address(this)) revert NotTheOwner();
                if (statuses[i].isClaimed) revert AlreadyClaimed();
                total += statuses[i].amountOfStETH;
            }
        }
        return total;
    }
}

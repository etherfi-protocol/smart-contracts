/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./Liquifier.sol";
import "./LiquidityPool.sol";

import "./eigenlayer-interfaces/IStrategyManager.sol";
import "./eigenlayer-interfaces/IDelegationManager.sol";

contract EtherFiRestaker is Initializable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct TokenInfo {
        // EigenLayer
        IStrategy elStrategy;
        uint256 elSharesInPendingForWithdrawals;
    }

    LiquidityPool public liquidityPool;
    Liquifier public liquifier;
    address public etherFiRestakeManager;
    ILido public lido;
    IDelegationManager public eigenLayerDelegationManager;
    IStrategyManager public eigenLayerStrategyManager;

    mapping(address => TokenInfo) public tokenInfos;
    
    EnumerableSet.Bytes32Set private withdrawalRootsSet;
    mapping(bytes32 => IDelegationManager.Withdrawal) public withdrawalRootToWithdrawal;

    event CompletedQueuedWithdrawal(bytes32 _withdrawalRoot);

     /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initialize to set variables on deployment
    function initialize(address _liquidityPool, address _liquifier, address _manager) initializer external {

        liquidityPool = LiquidityPool(payable(_liquidityPool));
        liquifier = Liquifier(payable(_liquifier));
        etherFiRestakeManager = _manager;

        lido = liquifier.lido();

        eigenLayerStrategyManager = liquifier.eigenLayerStrategyManager();
        eigenLayerDelegationManager = liquifier.eigenLayerDelegationManager();

        (,, IStrategy strategy,,,,,,,,) = liquifier.tokenInfos(address(lido));
        tokenInfos[address(lido)] = TokenInfo({
            elStrategy: strategy,
            elSharesInPendingForWithdrawals: 0
        });
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                    EigenLayer Restaking                                    |
    // |--------------------------------------------------------------------------------------------|
    
    /// @notice delegate to an AVS operator
    function delegateTo(address operator, IDelegationManager.SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt) external managerOnly {
        eigenLayerDelegationManager.delegateTo(operator, approverSignatureAndExpiry, approverSalt);
    }

    /// @notice undelegate from the current AVS operator & un-restake all
    function undelegate() external managerOnly returns (bytes32[] memory) {
        // Un-restake all assets
        // Currently, only stETH is supported
        TokenInfo memory info = tokenInfos[address(lido)];
        uint256 shares = eigenLayerStrategyManager.stakerStrategyShares(address(this), info.elStrategy);

        _queueWithdrawalsByShares(address(lido), shares);

        bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.undelegate(address(this));
        assert(withdrawalRoots.length == 0);

        return withdrawalRoots;
    }

    /// @notice deposit the balance of the token in into the restaking strategy
    function depositIntoStrategy(address token) external managerOnly returns (uint256) {
        // using `balanceOf` instead of passing the amount param from `EtherFiRestakeManager.depositIntoStrategy` to avoid 1-2 wei corner case on stETH transfers
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeApprove(address(eigenLayerStrategyManager), amount);

        IStrategy strategy = tokenInfos[token].elStrategy;
        uint256 shares = eigenLayerStrategyManager.depositIntoStrategy(strategy, IERC20(token), amount);

        return shares;
    }

    /// @notice queue withdrawals for un-restaking the token
    /// Made easy for operators
    /// @param token the token to withdraw
    /// @param amount the amount of token to withdraw
    function queueWithdrawals(address token, uint256 amount) public managerOnly returns (bytes32[] memory) {
        uint256 shares = getEigenLayerRestakingStrategy(token).underlyingToSharesView(amount);
        return _queueWithdrawalsByShares(token, shares);
    }

    /// Advanced version
    /// @notice queue withdrawals with custom parameters for un-restaking multiple tokens
    /// @param queuedWithdrawalParams Array of withdrawal parameters including strategies, share amounts, and withdrawer
    function queueWithdrawalsAdvanced(IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams) public managerOnly returns (bytes32[] memory) {
        uint256 currentNonce = eigenLayerDelegationManager.cumulativeWithdrawalsQueued(address(this));
        
        bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.queueWithdrawals(queuedWithdrawalParams);
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](queuedWithdrawalParams.length);

        for (uint256 i = 0; i < queuedWithdrawalParams.length; i++) {
            withdrawals[i] = IDelegationManager.Withdrawal({
                staker: address(this),
                delegatedTo: eigenLayerDelegationManager.delegatedTo(address(this)),
                withdrawer: address(this),
                nonce: currentNonce + i,
                startBlock: uint32(block.number),
                strategies: queuedWithdrawalParams[i].strategies,
                shares: queuedWithdrawalParams[i].shares
            });

            require(eigenLayerDelegationManager.calculateWithdrawalRoot(withdrawals[i]) == withdrawalRoots[i], "INCORRECT_WITHDRAWAL_ROOT");
            require(eigenLayerDelegationManager.pendingWithdrawals(withdrawalRoots[i]), "WITHDRAWAL_NOT_PENDING");

            for (uint256 j = 0; j < queuedWithdrawalParams[i].strategies.length; j++) {
                address token = address(queuedWithdrawalParams[i].strategies[j].underlyingToken());
                tokenInfos[token].elSharesInPendingForWithdrawals += queuedWithdrawalParams[i].shares[j];
            }

            withdrawalRootToWithdrawal[withdrawalRoots[i]] = withdrawals[i];
            withdrawalRootsSet.add(withdrawalRoots[i]);
        }

        return withdrawalRoots;
    }

    /// @notice Complete the queued withdrawals that are ready to be withdrawn
    /// @param max_cnt the maximum number of withdrawals to complete
    function completeQueuedWithdrawals(uint256 max_cnt) external managerOnly {
        bytes32[] memory withdrawalRoots = pendingWithdrawalRoots();

        // process the first `max_cnt` withdrawals
        uint256 num_to_process = _min(max_cnt, withdrawalRoots.length);

        IDelegationManager.Withdrawal[] memory _queuedWithdrawals = new IDelegationManager.Withdrawal[](num_to_process);
        IERC20[][] memory _tokens = new IERC20[][](num_to_process);
        uint256[] memory _middlewareTimesIndexes = new uint256[](num_to_process);

        uint256 cnt = 0;
        for (uint256 i = 0; i < num_to_process; i++) {
            IDelegationManager.Withdrawal memory withdrawal = withdrawalRootToWithdrawal[withdrawalRoots[i]];

            uint256 withdrawalDelay = eigenLayerDelegationManager.getWithdrawalDelay(withdrawal.strategies);

            if (withdrawal.startBlock + withdrawalDelay <= block.number) {
                IERC20[] memory tokens = new IERC20[](withdrawal.strategies.length);
                for (uint256 j = 0; j < withdrawal.strategies.length; j++) {
                    tokens[j] = withdrawal.strategies[j].underlyingToken();    

                    assert(tokenInfos[address(tokens[j])].elStrategy == withdrawal.strategies[j]);

                    tokenInfos[address(tokens[j])].elSharesInPendingForWithdrawals -= withdrawal.shares[j];
                }

                _queuedWithdrawals[cnt] = withdrawal;
                _tokens[cnt] = tokens;
                _middlewareTimesIndexes[cnt] = 0;
                cnt += 1;
            }
        }

        if (cnt == 0) return;

        assembly {
            mstore(_queuedWithdrawals, cnt)
            mstore(_tokens, cnt)
            mstore(_middlewareTimesIndexes, cnt)
        }

        completeQueuedWithdrawalsAdvanced(_queuedWithdrawals, _tokens, _middlewareTimesIndexes);
    }

    /// Advanced version
    /// @notice Used to complete the specified `queuedWithdrawals`. The function caller must match `queuedWithdrawals[...].withdrawer`
    /// @param _queuedWithdrawals The QueuedWithdrawals to complete.
    /// @param _tokens Array of tokens for each QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single array.
    /// @param _middlewareTimesIndexes One index to reference per QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single index.
    /// @dev middlewareTimesIndex should be calculated off chain before calling this function by finding the first index that satisfies `slasher.canWithdraw`
    function completeQueuedWithdrawalsAdvanced(IDelegationManager.Withdrawal[] memory _queuedWithdrawals, IERC20[][] memory _tokens, uint256[] memory _middlewareTimesIndexes) public managerOnly {
        uint256 num = _queuedWithdrawals.length;
        bool[] memory receiveAsTokens = new bool[](num);
        for (uint256 i = 0; i < num; i++) {
            bytes32 withdrawalRoot = eigenLayerDelegationManager.calculateWithdrawalRoot(_queuedWithdrawals[i]);
            emit CompletedQueuedWithdrawal(withdrawalRoot);

            /// so that the shares withdrawn from the specified strategies are sent to the caller
            receiveAsTokens[i] = true;
            withdrawalRootsSet.remove(withdrawalRoot);
        }

        /// it will update the erc20 balances of this contract
        eigenLayerDelegationManager.completeQueuedWithdrawals(_queuedWithdrawals, _tokens, _middlewareTimesIndexes, receiveAsTokens);

        /// transfer tokens back to manager
        for (uint256 i = 0; i < _queuedWithdrawals.length; ++i) {
            for (uint256 j = 0; j < _tokens[i].length; ++j) {
                _tokens[i][j].transfer(etherFiRestakeManager, _tokens[i][j].balanceOf(address(this)));
            }
        }
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                    VIEW functions                                          |
    // |--------------------------------------------------------------------------------------------|
    
    /// @notice Enumerate the pending withdrawal roots
    function pendingWithdrawalRoots() public view returns (bytes32[] memory) {
        return withdrawalRootsSet.values();
    }

    /// @notice Check if a withdrawal is pending for a given withdrawal root
    function isPendingWithdrawal(bytes32 _withdrawalRoot) external view returns (bool) {
        return withdrawalRootsSet.contains(_withdrawalRoot);
    }

    /// @notice The total amount of assets controlled by this contract in wei
    /// @dev Only considers stETH. Will need modification to support additional tokens
    function getTotalPooledEther() public view returns (uint256) {
        (uint256 restaked, uint256 unrestaking) = getTotalPooledEtherSplits(address(lido));
        return restaked + unrestaking;
    }

    /// @notice The assets held by this contract in Eigenlayer split between restaked and pending for un-restaking
    /// @dev Only considers stETH. Will need modification to support additional tokens
    function getTotalPooledEtherSplits() public view returns (uint256 restaked, uint256 unrestaking) {
        (restaked, unrestaking) = getTotalPooledEtherSplits(address(lido));
        return (restaked, unrestaking);
    }

    function getTotalPooledEtherSplits(address _token) public view returns (uint256 restaked, uint256 unrestaking) {
        TokenInfo memory info = tokenInfos[_token];
        if (info.elStrategy != IStrategy(address(0))) {
            uint256 restakedTokenAmount = getRestakedAmount(_token);
            restaked = liquifier.quoteByFairValue(_token, restakedTokenAmount); /// restaked & pending for withdrawals
            unrestaking = getEthAmountInEigenLayerPendingForWithdrawals(_token);
        }
    }

    function getRestakedAmount(address _token) public view returns (uint256) {
        TokenInfo memory info = tokenInfos[_token];
        uint256 shares = eigenLayerStrategyManager.stakerStrategyShares(address(this), info.elStrategy);
        uint256 restaked = info.elStrategy.sharesToUnderlyingView(shares);
        return restaked;
    }

    function getEigenLayerRestakingStrategy(address _token) public view returns (IStrategy) {
        return tokenInfos[_token].elStrategy;
    }

    function getEthAmountInEigenLayerPendingForWithdrawals(address _token) public view returns (uint256) {
        TokenInfo memory info = tokenInfos[_token];
        if (info.elStrategy == IStrategy(address(0))) return 0;
        uint256 amount = info.elStrategy.sharesToUnderlyingView(info.elSharesInPendingForWithdrawals);
        return amount;
    }

    // INTERNAL functions
    function _queueWithdrawalsByShares(address token, uint256 shares) internal returns (bytes32[] memory) {
        IStrategy strategy = tokenInfos[token].elStrategy;
        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = strategy;
        uint256[] memory sharesArr = new uint256[](1);
        sharesArr[0] = shares;

        params[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: sharesArr,
            withdrawer: address(this)
        });

        return queueWithdrawalsAdvanced(params);
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    receive() external payable {}

    modifier managerOnly() {
        require(msg.sender == etherFiRestakeManager, "NOT_MANAGER");
        _;
    }
}

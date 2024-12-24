/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./Liquifier.sol";
import "./LiquidityPool.sol";

import "./eigenlayer-interfaces/IStrategyManager.sol";
import "./eigenlayer-interfaces/IDelegationManager.sol";

contract EtherFiRestaker is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct TokenInfo {
        // EigenLayer
        IStrategy elStrategy;
        uint256 elSharesInPendingForWithdrawals;
    }

    LiquidityPool public liquidityPool;
    Liquifier public liquifier;
    ILidoWithdrawalQueue public lidoWithdrawalQueue;
    ILido public lido;
    IDelegationManager public eigenLayerDelegationManager;
    IStrategyManager public eigenLayerStrategyManager;

    mapping(address => bool) public pausers;
    mapping(address => bool) public admins;

    mapping(address => TokenInfo) public tokenInfos;
    
    EnumerableSet.Bytes32Set private withdrawalRootsSet;
    mapping(bytes32 => IDelegationManager.Withdrawal) public withdrawalRootToWithdrawal;


    event QueuedStEthWithdrawals(uint256[] _reqIds);
    event CompletedStEthQueuedWithdrawals(uint256[] _reqIds);
    event CompletedQueuedWithdrawal(bytes32 _withdrawalRoot);

    error NotEnoughBalance();
    error IncorrectAmount();
    error StrategyShareNotEnough();
    error EthTransferFailed();
    error AlreadyRegistered();
    error NotRegistered();
    error WrongOutput();
    error IncorrectCaller();

     /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initialize to set variables on deployment
    function initialize(address _liquidityPool, address _liquifier) initializer external {
        __Ownable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        liquidityPool = LiquidityPool(payable(_liquidityPool));
        liquifier = Liquifier(payable(_liquifier));

        lido = liquifier.lido();
        lidoWithdrawalQueue = liquifier.lidoWithdrawalQueue();

        eigenLayerStrategyManager = liquifier.eigenLayerStrategyManager();
        eigenLayerDelegationManager = liquifier.eigenLayerDelegationManager();

        (,, IStrategy strategy,,,,,,,,) = liquifier.tokenInfos(address(lido));
        tokenInfos[address(lido)] = TokenInfo({
            elStrategy: strategy,
            elSharesInPendingForWithdrawals: 0
        });
    }

    receive() external payable {}

    // |--------------------------------------------------------------------------------------------|
    // |                                   Handling Lido's stETH                                    |
    // |--------------------------------------------------------------------------------------------|

    /// Initiate the redemption of stETH for ETH 
    /// @notice Request for all stETH holdings
    function stEthRequestWithdrawal() external onlyAdmin returns (uint256[] memory) {
        uint256 amount = lido.balanceOf(address(this));
        return stEthRequestWithdrawal(amount);
    }

    /// @notice Request for a specific amount of stETH holdings
    /// @param _amount the amount of stETH to request
    function stEthRequestWithdrawal(uint256 _amount) public onlyAdmin returns (uint256[] memory) {
        if (_amount < lidoWithdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT()) revert IncorrectAmount();
        if (_amount > lido.balanceOf(address(this))) revert NotEnoughBalance();

        uint256 maxAmount = lidoWithdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 numReqs = (_amount + maxAmount - 1) / maxAmount;
        uint256[] memory reqAmounts = new uint256[](numReqs);
        for (uint256 i = 0; i < numReqs; i++) {
            reqAmounts[i] = (i == numReqs - 1) ? _amount - i * maxAmount : maxAmount;
        }
        lido.approve(address(lidoWithdrawalQueue), _amount);
        uint256[] memory reqIds = lidoWithdrawalQueue.requestWithdrawals(reqAmounts, address(this));

        emit QueuedStEthWithdrawals(reqIds);

        return reqIds;
    }

    /// @notice Claim a batch of withdrawal requests if they are finalized sending the ETH to the this contract back
    /// @param _requestIds array of request ids to claim
    /// @param _hints checkpoint hint for each id. Can be obtained with `findCheckpointHints()`
    function stEthClaimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external onlyAdmin {
        uint256 balance = address(this).balance;
        lidoWithdrawalQueue.claimWithdrawals(_requestIds, _hints);

        withdrawEther();

        emit CompletedStEthQueuedWithdrawals(_requestIds);
    }

    // Send the ETH back to the liquidity pool
    function withdrawEther() public onlyAdmin {
        uint256 amountToLiquidityPool = address(this).balance;
        (bool sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: 20000}("");
        require(sent, "ETH_SEND_TO_LIQUIDITY_POOL_FAILED");
    }

    // |--------------------------------------------------------------------------------------------|
    // |                                    EigenLayer Restaking                                    |
    // |--------------------------------------------------------------------------------------------|
    
    // delegate to an AVS operator
    function delegateTo(address operator, IDelegationManager.SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt) external onlyAdmin {
        eigenLayerDelegationManager.delegateTo(operator, approverSignatureAndExpiry, approverSalt);
    }

    // undelegate from the current AVS operator & un-restake all
    function undelegate() external onlyAdmin returns (bytes32[] memory) {
        revert("FIX BELOW");

        // Un-restake all assets
        // Currently, only stETH is supported
        // TokenInfo memory info = tokenInfos[address(lido)];
        // uint256 shares = eigenLayerStrategyManager.stakerStrategyShares(address(this), info.elStrategy);

        // _queueWithdrawlsByShares(address(lido), shares);

        // bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.undelegate(address(this));
        // assert(withdrawalRoots.length == 0);

        // return withdrawalRoots;
    }

    // deposit the token in holding into the restaking strategy
    function depositIntoStrategy(address token, uint256 amount) external onlyAdmin returns (uint256) {
        IERC20(token).safeApprove(address(eigenLayerStrategyManager), amount);

        IStrategy strategy = tokenInfos[token].elStrategy;
        uint256 shares = eigenLayerStrategyManager.depositIntoStrategy(strategy, IERC20(token), amount);

        return shares;
    }

    /// queue withdrawals for un-restaking the token
    /// Made easy for operators
    /// @param token the token to withdraw
    /// @param amount the amount of token to withdraw
    function queueWithdrawals(address token, uint256 amount) public onlyAdmin returns (bytes32[] memory) {
        uint256 shares = getEigenLayerRestakingStrategy(token).underlyingToSharesView(amount);
        return _queueWithdrawlsByShares(token, shares);
    }

    /// Advanced version
    function queueWithdrawals(IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams) public onlyAdmin returns (bytes32[] memory) {
        revert("FIX BELOW");
        // uint256 currentNonce = eigenLayerDelegationManager.cumulativeWithdrawalsQueued(address(this));
        
        // bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.queueWithdrawals(queuedWithdrawalParams);
        // IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](queuedWithdrawalParams.length);

        // for (uint256 i = 0; i < queuedWithdrawalParams.length; i++) {
        //     withdrawals[i] = IDelegationManager.Withdrawal({
        //         staker: address(this),
        //         delegatedTo: eigenLayerDelegationManager.delegatedTo(address(this)),
        //         withdrawer: address(this),
        //         nonce: currentNonce + i,
        //         startBlock: uint32(block.number),
        //         strategies: queuedWithdrawalParams[i].strategies,
        //         shares: queuedWithdrawalParams[i].shares
        //     });

        //     require(eigenLayerDelegationManager.calculateWithdrawalRoot(withdrawals[i]) == withdrawalRoots[i], "INCORRECT_WITHDRAWAL_ROOT");
        //     require(eigenLayerDelegationManager.pendingWithdrawals(withdrawalRoots[i]), "WITHDRAWAL_NOT_PENDING");

        //     for (uint256 j = 0; j < queuedWithdrawalParams[i].strategies.length; j++) {
        //         address token = address(queuedWithdrawalParams[i].strategies[j].underlyingToken());
        //         tokenInfos[token].elSharesInPendingForWithdrawals += queuedWithdrawalParams[i].shares[j];
        //     }

        //     withdrawalRootToWithdrawal[withdrawalRoots[i]] = withdrawals[i];
        //     withdrawalRootsSet.add(withdrawalRoots[i]);
        // }

        // return withdrawalRoots;
    }

    /// @notice Complete the queued withdrawals that are ready to be withdrawn
    /// @param max_cnt the maximum number of withdrawals to complete
    function completeQueuedWithdrawals(uint256 max_cnt) external onlyAdmin {
        revert("FIX BELOW");
        // bytes32[] memory withdrawalRoots = pendingWithdrawalRoots();

        // // process the first `max_cnt` withdrawals
        // uint256 num_to_process = _min(max_cnt, withdrawalRoots.length);

        // IDelegationManager.Withdrawal[] memory _queuedWithdrawals = new IDelegationManager.Withdrawal[](num_to_process);
        // IERC20[][] memory _tokens = new IERC20[][](num_to_process);
        // uint256[] memory _middlewareTimesIndexes = new uint256[](num_to_process);

        // uint256 cnt = 0;
        // for (uint256 i = 0; i < num_to_process; i++) {
        //     IDelegationManager.Withdrawal memory withdrawal = withdrawalRootToWithdrawal[withdrawalRoots[i]];

        //     uint256 withdrawalDelay = eigenLayerDelegationManager.getWithdrawalDelay(withdrawal.strategies);

        //     if (withdrawal.startBlock + withdrawalDelay <= block.number) {
        //         IERC20[] memory tokens = new IERC20[](withdrawal.strategies.length);
        //         for (uint256 j = 0; j < withdrawal.strategies.length; j++) {
        //             tokens[j] = withdrawal.strategies[j].underlyingToken();    

        //             assert(tokenInfos[address(tokens[j])].elStrategy == withdrawal.strategies[j]);

        //             tokenInfos[address(tokens[j])].elSharesInPendingForWithdrawals -= withdrawal.shares[j];
        //         }

        //         _queuedWithdrawals[cnt] = withdrawal;
        //         _tokens[cnt] = tokens;
        //         _middlewareTimesIndexes[cnt] = 0;
        //         cnt += 1;
        //     }
        // }

        // if (cnt == 0) return;

        // assembly {
        //     mstore(_queuedWithdrawals, cnt)
        //     mstore(_tokens, cnt)
        //     mstore(_middlewareTimesIndexes, cnt)
        // }

        // completeQueuedWithdrawals(_queuedWithdrawals, _tokens, _middlewareTimesIndexes);
    }

    /// Advanced version
    /// @notice Used to complete the specified `queuedWithdrawals`. The function caller must match `queuedWithdrawals[...].withdrawer`
    /// @param _queuedWithdrawals The QueuedWithdrawals to complete.
    /// @param _tokens Array of tokens for each QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single array.
    /// @param _middlewareTimesIndexes One index to reference per QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single index.
    /// @dev middlewareTimesIndex should be calculated off chain before calling this function by finding the first index that satisfies `slasher.canWithdraw`
    function completeQueuedWithdrawals(IDelegationManager.Withdrawal[] memory _queuedWithdrawals, IERC20[][] memory _tokens, uint256[] memory _middlewareTimesIndexes) public onlyAdmin {
        revert("FIX BELOW");
        // uint256 num = _queuedWithdrawals.length;
        // bool[] memory receiveAsTokens = new bool[](num);
        // for (uint256 i = 0; i < num; i++) {
        //     bytes32 withdrawalRoot = eigenLayerDelegationManager.calculateWithdrawalRoot(_queuedWithdrawals[i]);
        //     emit CompletedQueuedWithdrawal(withdrawalRoot);

        //     /// so that the shares withdrawn from the specified strategies are sent to the caller
        //     receiveAsTokens[i] = true;
        //     withdrawalRootsSet.remove(withdrawalRoot);
        // }

        // /// it will update the erc20 balances of this contract
        // eigenLayerDelegationManager.completeQueuedWithdrawals(_queuedWithdrawals, _tokens, _middlewareTimesIndexes, receiveAsTokens);
    }

    /// Enumerate the pending withdrawal roots
    function pendingWithdrawalRoots() public view returns (bytes32[] memory) {
        return withdrawalRootsSet.values();
    }

    /// Check if a withdrawal is pending for a given withdrawal root
    function isPendingWithdrawal(bytes32 _withdrawalRoot) external view returns (bool) {
        return withdrawalRootsSet.contains(_withdrawalRoot);
    }


    // |--------------------------------------------------------------------------------------------|
    // |                                    VIEW functions                                        |
    // |--------------------------------------------------------------------------------------------|
    function getTotalPooledEther() public view returns (uint256 total) {
        total = address(this).balance + getTotalPooledEther(address(lido));
    }

    function getTotalPooledEther(address _token) public view returns (uint256) {
        (uint256 restaked, uint256 unrestaking, uint256 holding, uint256 pendingForWithdrawals) = getTotalPooledEtherSplits(_token);
        return restaked + unrestaking + holding + pendingForWithdrawals;
    }
    
    function getRestakedAmount(address _token) public view returns (uint256) {
        revert("FIX BELOW");
        // TokenInfo memory info = tokenInfos[_token];
        // uint256 shares = eigenLayerStrategyManager.stakerStrategyShares(address(this), info.elStrategy);
        // uint256 restaked = info.elStrategy.sharesToUnderlyingView(shares);
        // return restaked;
    }

    function getEigenLayerRestakingStrategy(address _token) public view returns (IStrategy) {
        return tokenInfos[_token].elStrategy;
    }

    /// each asset in holdings can have 3 states:
    /// - in Eigenlayer, either restaked or pending for un-restaking
    /// - non-restaked & held by this contract
    /// - non-restaked & not held by this contract & pending in redemption for ETH
    function getTotalPooledEtherSplits(address _token) public view returns (uint256 restaked, uint256 unrestaking, uint256 holding, uint256 pendingForWithdrawals) {
        TokenInfo memory info = tokenInfos[_token];
        if (info.elStrategy != IStrategy(address(0))) {
            uint256 restakedTokenAmount = getRestakedAmount(_token);
            restaked = liquifier.quoteByFairValue(_token, restakedTokenAmount); /// restaked & pending for withdrawals
            unrestaking = getEthAmountInEigenLayerPendingForWithdrawals(_token);
        }
        holding = liquifier.quoteByFairValue(_token, IERC20(_token).balanceOf(address(this))); /// eth value for erc20 holdings
        pendingForWithdrawals = getEthAmountPendingForRedemption(_token);
    }

    function getEthAmountInEigenLayerPendingForWithdrawals(address _token) public view returns (uint256) {
        TokenInfo memory info = tokenInfos[_token];
        if (info.elStrategy == IStrategy(address(0))) return 0;
        uint256 amount = info.elStrategy.sharesToUnderlyingView(info.elSharesInPendingForWithdrawals);
        return amount;
    }

    function getEthAmountPendingForRedemption(address _token) public view returns (uint256) {
        uint256 total = 0;
        if (_token == address(lido)) {
            uint256[] memory stEthWithdrawalRequestIds = lidoWithdrawalQueue.getWithdrawalRequests(address(this));
            ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses = lidoWithdrawalQueue.getWithdrawalStatus(stEthWithdrawalRequestIds);
            for (uint256 i = 0; i < statuses.length; i++) {
                require(statuses[i].owner == address(this), "Not the owner");
                require(!statuses[i].isClaimed, "Already claimed");
                total += statuses[i].amountOfStETH;
            }
        }
        return total;
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    function updatePauser(address _address, bool _isPauser) external onlyAdmin {
        pausers[_address] = _isPauser;
    }

    // Pauses the contract
    function pauseContract() external onlyPauser {
        _pause();
    }

    // Unpauses the contract
    function unPauseContract() external onlyAdmin {
        _unpause();
    }

    // INTERNAL functions
    function _queueWithdrawlsByShares(address token, uint256 shares) internal returns (bytes32[] memory) {
        revert("FIX BELOW");
        // IStrategy strategy = tokenInfos[token].elStrategy;
        // IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        // IStrategy[] memory strategies = new IStrategy[](1);
        // strategies[0] = strategy;
        // uint256[] memory sharesArr = new uint256[](1);
        // sharesArr[0] = shares;

        // params[0] = IDelegationManager.QueuedWithdrawalParams({
        //     strategies: strategies,
        //     shares: sharesArr,
        //     withdrawer: address(this)
        // });

        // return queueWithdrawals(params);
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _requireAdmin() internal view virtual {
        if (!(admins[msg.sender] || msg.sender == owner())) revert IncorrectCaller();
    }

    function _requirePauser() internal view virtual {
        if (!(pausers[msg.sender] || admins[msg.sender] || msg.sender == owner())) revert IncorrectCaller();
    }

    /* MODIFIER */
    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    modifier onlyPauser() {
        _requirePauser();
        _;
    }
}
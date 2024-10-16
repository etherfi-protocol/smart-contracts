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
        IStrategy strategy;
    }

    mapping(address => bool) public pausers;
    mapping(address => bool) public admins;
    mapping(address => TokenInfo) public tokenInfos;

    LiquidityPool public liquidityPool;
    Liquifier public liquifier;

    IDelegationManager public eigenLayerDelegationManager;
    IStrategyManager public eigenLayerStrategyManager;

    EnumerableSet.Bytes32Set private withdrawalRootsSet;
    mapping(bytes32 => IDelegationManager.Withdrawal) public withdrawalRootToWithdrawal;

    ILidoWithdrawalQueue public lidoWithdrawalQueue;
    ILido public lido;

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
            strategy: strategy
        });
    }

    receive() external payable {}

    /// Initiate the process for redemption of stETH 
    function stEthRequestWithdrawal() external onlyAdmin returns (uint256[] memory) {
        uint256 amount = lido.balanceOf(address(this));
        return stEthRequestWithdrawal(amount);
    }

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

        emit CompletedStEthQueuedWithdrawals(_requestIds);
    }

    // Send the redeemed ETH back to the liquidity pool & Send the fee to Treasury
    function withdrawEther() external onlyAdmin {
        uint256 amountToLiquidityPool = address(this).balance;
        (bool sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: 20000}("");
        require(sent, "ETH_SEND_TO_LIQUIDITY_POOL_FAILED");
    }

    //--------------------------- 
    // EigenLayer - Restaking   |
    //---------------------------
    function delegateTo(address operator, IDelegationManager.SignatureWithExpiry memory approverSignatureAndExpiry, bytes32 approverSalt) external onlyAdmin {
        eigenLayerDelegationManager.delegateTo(operator, approverSignatureAndExpiry, approverSalt);
    }

    function undelegate() external returns (bytes32[] memory withdrawalRoots) {
        bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.undelegate(address(this));

        return withdrawalRoots;
    }

    function depositIntoStrategy(address token, uint256 amount) external onlyAdmin returns (uint256) {
        IERC20(token).safeApprove(address(eigenLayerStrategyManager), amount);

        IStrategy strategy = tokenInfos[token].strategy;
        uint256 shares = eigenLayerStrategyManager.depositIntoStrategy(strategy, IERC20(token), amount);

        return shares;
    }

    function queueWithdrawals(address token, uint256 amount) external onlyAdmin returns (bytes32[] memory) {
        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = getEigenLayerRestakingStrategy(address(lido));
        uint256[] memory shares = new uint256[](1);
        shares[0] = strategies[0].underlyingToSharesView(amount);
        
        params[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: address(this)
        });

        return queueWithdrawals(params);
    }

    function queueWithdrawals(IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams) public onlyAdmin returns (bytes32[] memory) {
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

            withdrawalRootToWithdrawal[withdrawalRoots[i]] = withdrawals[i];
            withdrawalRootsSet.add(withdrawalRoots[i]);
        }

        return withdrawalRoots;
    }

    function completeQueuedWithdrawals() external onlyAdmin {
        bytes32[] memory withdrawalRoots = pendingWithdrawalRoots();

        IDelegationManager.Withdrawal[] memory _queuedWithdrawals = new IDelegationManager.Withdrawal[](withdrawalRoots.length);
        IERC20[][] memory _tokens = new IERC20[][](withdrawalRoots.length);
        uint256[] memory _middlewareTimesIndexes = new uint256[](withdrawalRoots.length);

        uint256 cnt = 0;
        for (uint256 i = 0; i < withdrawalRoots.length; i++) {
            IDelegationManager.Withdrawal memory withdrawal = withdrawalRootToWithdrawal[withdrawalRoots[i]];

            uint256 withdrawalDelay = eigenLayerDelegationManager.getWithdrawalDelay(withdrawal.strategies);

            if (withdrawal.startBlock + withdrawalDelay <= block.number) {
                IERC20[] memory tokens = new IERC20[](withdrawal.strategies.length);
                for (uint256 j = 0; j < withdrawal.strategies.length; j++) {
                    tokens[j] = withdrawal.strategies[j].underlyingToken();
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

        completeQueuedWithdrawals(_queuedWithdrawals, _tokens, _middlewareTimesIndexes);
    }

    /// @notice Used to complete the specified `queuedWithdrawals`. The function caller must match `queuedWithdrawals[...].withdrawer`
    /// @param _queuedWithdrawals The QueuedWithdrawals to complete.
    /// @param _tokens Array of tokens for each QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single array.
    /// @param _middlewareTimesIndexes One index to reference per QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single index.
    /// @dev middlewareTimesIndex should be calculated off chain before calling this function by finding the first index that satisfies `slasher.canWithdraw`
    function completeQueuedWithdrawals(IDelegationManager.Withdrawal[] memory _queuedWithdrawals, IERC20[][] memory _tokens, uint256[] memory _middlewareTimesIndexes) public onlyAdmin {
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
    }

    function pendingWithdrawalRoots() public view returns (bytes32[] memory) {
        return withdrawalRootsSet.values();
    }

    function isPendingWithdrawal(bytes32 _withdrawalRoot) external view returns (bool) {
        return withdrawalRootsSet.contains(_withdrawalRoot);
    }


    // VIEW
    function getTotalPooledEther() public view returns (uint256 total) {
        total = address(this).balance + getTotalPooledEther(address(lido));
    }

    function getTotalPooledEther(address _token) public view returns (uint256) {
        (uint256 restaked, uint256 holding, uint256 pendingForWithdrawals) = getTotalPooledEtherSplits(_token);
        return restaked + holding + pendingForWithdrawals;
    }
    
    function getRestakedAmount(address _token) public view returns (uint256) {
        TokenInfo memory info = tokenInfos[_token];
        uint256 shares = eigenLayerStrategyManager.stakerStrategyShares(address(this), info.strategy);
        uint256 restaked = info.strategy.sharesToUnderlyingView(shares);
        return restaked;
    }

    function getEigenLayerRestakingStrategy(address _token) public view returns (IStrategy) {
        return tokenInfos[_token].strategy;
    }

    /// deposited (restaked) ETH can have 3 states:
    /// - restaked in EigenLayer & pending for withdrawals
    /// - non-restaked & held by this contract
    /// - non-restaked & not held by this contract & pending for withdrawals
    function getTotalPooledEtherSplits(address _token) public view returns (uint256 restaked, uint256 holding, uint256 pendingForWithdrawals) {
        TokenInfo memory info = tokenInfos[_token];
        if (info.strategy != IStrategy(address(0))) {
            uint256 restakedTokenAmount = getRestakedAmount(_token);
            restaked = liquifier.quoteByFairValue(_token, restakedTokenAmount); /// restaked & pending for withdrawals
        }
        holding = liquifier.quoteByFairValue(_token, IERC20(_token).balanceOf(address(this))); /// eth value for erc20 holdings
        pendingForWithdrawals = getEthAmountPendingForWithdrawals(_token);
    }

    function getEthAmountPendingForWithdrawals(address _token) public view returns (uint256) {
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
    function unPauseContract() external onlyOwner {
        _unpause();
    }

    // INTERNAL functions

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
/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ILiquifier.sol";
import "./interfaces/ILiquidityPool.sol";


/// put (restaked) {stETH, cbETH, wbETH} and get eETH
contract Liquifier is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, ILiquifier {
    using SafeERC20 for IERC20;

    uint32 public eigenLayerWithdrawalClaimGasCost;
    uint32 public timeBoundCapRefreshInterval; // seconds

    bool public quoteStEthWithCurve;

    uint128 public accumulatedFee;

    mapping(address => TokenInfo) public tokenInfos;
    mapping(bytes32 => bool) public isRegisteredQueuedWithdrawals;
    mapping(address => bool) public admins;

    address public treasury;
    ILiquidityPool public liquidityPool;
    IEigenLayerStrategyManager public eigenLayerStrategyManager;
    ILidoWithdrawalQueue public lidoWithdrawalQueue;

    ICurvePool public cbEth_Eth_Pool;
    ICurvePool public wbEth_Eth_Pool;
    ICurvePool public stEth_Eth_Pool;

    IcbETH public cbEth;
    IwBETH public wbEth;
    ILido public lido;

    mapping(address => bool) public isDummyToken;

    event Liquified(address _user, uint256 _toEEthAmount, address _fromToken, bool _isRestaked);
    event RegisteredQueuedWithdrawal(bytes32 _withdrawalRoot, IStrategyManager.QueuedWithdrawal _queuedWithdrawal);
    event CompletedQueuedWithdrawal(bytes32 _withdrawalRoot);
    event QueuedStEthWithdrawals(uint256[] _reqIds);
    event CompletedStEthQueuedWithdrawals(uint256[] _reqIds);

    error StrategyShareNotEnough();
    error NotSupportedToken();
    error EthTransferFailed();
    error NotEnoughBalance();
    error AlreadyRegistered();
    error NotRegistered();


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initialize to set variables on deployment
    function initialize(address _treasury, address _liquidityPool, address _eigenLayerStrategyManager, address _lidoWithdrawalQueue, 
                        address _stEth, address _cbEth, address _wbEth, address _cbEth_Eth_Pool, address _wbEth_Eth_Pool, address _stEth_Eth_Pool,
                        uint32 _timeBoundCapRefreshInterval) initializer external {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        treasury = _treasury;
        liquidityPool = ILiquidityPool(_liquidityPool);
        lidoWithdrawalQueue = ILidoWithdrawalQueue(_lidoWithdrawalQueue);
        eigenLayerStrategyManager = IEigenLayerStrategyManager(_eigenLayerStrategyManager);

        lido = ILido(_stEth);
        cbEth = IcbETH(_cbEth);
        wbEth = IwBETH(_wbEth);
        cbEth_Eth_Pool = ICurvePool(_cbEth_Eth_Pool);
        wbEth_Eth_Pool = ICurvePool(_wbEth_Eth_Pool);
        stEth_Eth_Pool = ICurvePool(_stEth_Eth_Pool);
        
        timeBoundCapRefreshInterval = _timeBoundCapRefreshInterval;
        quoteStEthWithCurve = true;
        eigenLayerWithdrawalClaimGasCost = 150_000;
    }

    receive() external payable {}

    /// the users mint eETH given the queued withdrawal for their LRT with withdrawer == address(this)
    /// charge a small fixed amount fee to compensate for the gas cost for claim
    /// @param _queuedWithdrawal The QueuedWithdrawal to be used for the deposit. This is the proof that the user has the re-staked ETH and requested the withdrawals setting the Liquifier contract as the withdrawer.
    /// @param _referral The referral address
    /// @return mintedAmount the amount of eETH minted to the caller (= msg.sender)
    function depositWithQueuedWithdrawal(IStrategyManager.QueuedWithdrawal calldata _queuedWithdrawal, address _referral) external whenNotPaused nonReentrant returns (uint256) {
        bytes32 withdrawalRoot = verifyQueuedWithdrawal(msg.sender, _queuedWithdrawal);

        /// register it to prevent duplicate deposits with the same queued withdrawal
        isRegisteredQueuedWithdrawals[withdrawalRoot] = true;
        emit RegisteredQueuedWithdrawal(withdrawalRoot, _queuedWithdrawal);

        /// queue the strategy share for withdrawal
        uint256 amount = _enqueueForWithdrawal(_queuedWithdrawal.strategies, _queuedWithdrawal.shares);

        /// handle fee
        uint256 feeAmount = _queuedWithdrawal.strategies.length * getFeeAmount();
        amount -= feeAmount;
        accumulatedFee += uint128(feeAmount);
        
        /// mint eETH to the user
        uint256 eEthShare = liquidityPool.depositToRecipient(msg.sender, amount, _referral);

        return eEthShare;
    }

    /// Deposit Liquid Staking Token such as stETH and Mint eETH
    /// @param _token The address of the token to deposit
    /// @param _amount The amount of the token to deposit
    /// @param _referral The referral address
    /// @return mintedAmount the amount of eETH minted to the caller (= msg.sender)
    function depositWithERC20(address _token, uint256 _amount, address _referral) public whenNotPaused nonReentrant returns (uint256) {
        require(isTokenWhitelisted(_token), "NotWhitelisted");

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        
        uint256 dx = quoteByMarketValue(_token, _amount);

        // discount
        dx = (10000 - tokenInfos[_token].discountInBasisPoints) * dx / 10000;
        require(!isDepositCapReached(_token, dx), "CapReached");

        uint256 eEthShare = liquidityPool.depositToRecipient(msg.sender, dx, _referral);

        emit Liquified(msg.sender, dx, _token, false);

        _afterDeposit(_token, dx);
        return eEthShare;
    }

    function depositWithERC20WithPermit(address _token, uint256 _amount, address _referral, PermitInput calldata _permit) external whenNotPaused returns (uint256) {
        try IERC20Permit(_token).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
        return depositWithERC20(_token, _amount, _referral);
    }

    /// @notice Used to complete the specified `queuedWithdrawals`. The function caller must match `queuedWithdrawals[...].withdrawer`
    /// @param _queuedWithdrawals The QueuedWithdrawals to complete.
    /// @param _tokens Array of tokens for each QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single array.
    /// @param _middlewareTimesIndexes One index to reference per QueuedWithdrawal. See `completeQueuedWithdrawal` for the usage of a single index.
    /// @dev middlewareTimesIndex should be calculated off chain before calling this function by finding the first index that satisfies `slasher.canWithdraw`
    function completeQueuedWithdrawals(IStrategyManager.QueuedWithdrawal[] calldata _queuedWithdrawals, IERC20[][] calldata _tokens, uint256[] calldata _middlewareTimesIndexes) external onlyAdmin {
        uint256 num = _queuedWithdrawals.length;
        bool[] memory receiveAsTokens = new bool[](num);
        for (uint256 i = 0; i < num; i++) {
            _completeWithdrawals(_queuedWithdrawals[i]);

            /// so that the shares withdrawn from the specified strategies are sent to the caller
            receiveAsTokens[i] = true;
        }

        /// it will update the erc20 balances of this contract
        eigenLayerStrategyManager.completeQueuedWithdrawals(_queuedWithdrawals, _tokens, _middlewareTimesIndexes, receiveAsTokens);
    }

    /// Initiate the process for redemption of stETH 
    function stEthRequestWithdrawal() external onlyAdmin returns (uint256[] memory) {
        uint256 amount = lido.balanceOf(address(this));
        return stEthRequestWithdrawal(amount);
    }

    function stEthRequestWithdrawal(uint256 _amount) public onlyAdmin returns (uint256[] memory) {
        if (_amount < lidoWithdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT() || _amount < lido.balanceOf(address(this))) revert NotEnoughBalance();

        tokenInfos[address(lido)].ethAmountPendingForWithdrawals += uint128(_amount);

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
        uint256 newBalance = address(this).balance;

        // to prevent the underflow error
        uint128 dx = uint128(_min(newBalance - balance, tokenInfos[address(lido)].ethAmountPendingForWithdrawals));
        tokenInfos[address(lido)].ethAmountPendingForWithdrawals -= dx;

        emit CompletedStEthQueuedWithdrawals(_requestIds);
    }

    // Send the redeemed ETH back to the liquidity pool & Send the fee to Treasury
    function withdrawEther() external onlyAdmin {
        bool sent;

        if (accumulatedFee > 0.2 ether && address(this).balance >= accumulatedFee) {
            uint256 amountToTreasury = accumulatedFee;
            accumulatedFee = 0;
            (sent, ) = payable(treasury).call{value: amountToTreasury, gas: 5000}("");
            if (!sent) revert EthTransferFailed();
        }

        if (address(this).balance >= accumulatedFee) {
            uint256 amountToLiquidityPool = address(this).balance - accumulatedFee;
            (sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: 20000}("");
            if (!sent) revert EthTransferFailed();
        }
    }

    function updateWhitelistedToken(address _token, bool _isWhitelisted) external onlyOwner {
        tokenInfos[_token].isWhitelisted = _isWhitelisted;
    }

    function updateWhitelistedDummyToken(address _token, bool _isDummyToken) external onlyOwner {
        isDummyToken[_token] = _isDummyToken;
    }

    function updateDepositCap(address _token, uint32 _timeBoundCapInEther, uint32 _totalCapInEther, bool _refreshClock) external onlyOwner {
        tokenInfos[_token].timeBoundCapInEther = _timeBoundCapInEther;
        tokenInfos[_token].totalCapInEther = _totalCapInEther;

        if (_refreshClock) {
            tokenInfos[_token].timeBoundCapClockStartTime = uint32(block.timestamp);
            tokenInfos[_token].totalDepositedThisPeriod = 0;
        }
    }

    function updateDiscountInBasisPoints(address _token, uint16 _discountInBasisPoints) external onlyOwner {
        tokenInfos[_token].discountInBasisPoints = _discountInBasisPoints;
    }

    function updateEigenLayerWithdrawalClaimGasCost(uint32 _eigenLayerWithdrawalClaimGasCost) external onlyOwner {
        eigenLayerWithdrawalClaimGasCost = _eigenLayerWithdrawalClaimGasCost;
    }

    function registerToken(address _token, address _strategy, bool _isWhitelisted, uint16 _discountInBasisPoints, uint32 _timeBoundCapInEther, uint32 _totalCapInEther) external onlyOwner {
        if (_token != address(IStrategy(_strategy).underlyingToken())) revert NotSupportedToken();
        if (address(tokenInfos[_token].strategy) != address(0) || tokenInfos[_token].totalDeposited != 0) revert AlreadyRegistered();
        tokenInfos[_token] = TokenInfo(0, 0, IStrategy(_strategy), _isWhitelisted, _discountInBasisPoints, uint32(block.timestamp), _timeBoundCapInEther, _totalCapInEther, 0, 0);
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    function updateQuoteStEthWithCurve(bool _quoteStEthWithCurve) external onlyOwner {
        quoteStEthWithCurve = _quoteStEthWithCurve;
    }

    //Pauses the contract
    function pauseContract() external onlyAdmin {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyAdmin {
        _unpause();
    }

    function swapCbEthToEth(uint256 _amount, uint256 _minOutputAmount) external onlyAdmin returns (uint256) {
        if (_amount > cbEth.balanceOf(address(this))) revert NotEnoughBalance();
        cbEth.approve(address(cbEth_Eth_Pool), _amount);
        return cbEth_Eth_Pool.exchange_underlying(1, 0, _amount, _minOutputAmount);
    }

    function swapWbEthToEth(uint256 _amount, uint256 _minOutputAmount) external onlyAdmin returns (uint256) {
        if (_amount > wbEth.balanceOf(address(this))) revert NotEnoughBalance();
        wbEth.approve(address(wbEth_Eth_Pool), _amount);
        return wbEth_Eth_Pool.exchange(1, 0, _amount, _minOutputAmount);
    }

    function swapStEthToEth(uint256 _amount, uint256 _minOutputAmount) external onlyAdmin returns (uint256) {
        if (_amount > lido.balanceOf(address(this))) revert NotEnoughBalance();
        lido.approve(address(stEth_Eth_Pool), _amount);
        return stEth_Eth_Pool.exchange(1, 0, _amount, _minOutputAmount);
    }

    

    function swapDummyToEth(address _dummyToken) external payable onlyAdmin returns (uint256) {
        require(isDummyToken[_dummyToken], "!Dummy token");
        IERC20(_dummyToken).safeTransfer(msg.sender, msg.value);
        return msg.value;
    }

    /* VIEW FUNCTIONS */

    // Given the `_amount` of `_token` token, returns the equivalent amount of ETH 
    function quoteByFairValue(address _token, uint256 _amount) public view returns (uint256) {
        if (_token == address(lido)) return _amount * 1; /// 1:1 from stETH to eETH
        else if (_token == address(cbEth)) return _amount * cbEth.exchangeRate() / 1e18;
        else if (_token == address(wbEth)) return _amount * wbEth.exchangeRate() / 1e18;
        else if (isDummyToken[_token]) return _amount * 1; /// 1:1 from dummy token to eETH

        revert NotSupportedToken();
    }

    function quoteStrategyShareForDeposit(address _token, IStrategy _strategy, uint256 _share) public view returns (uint256) {
        uint256 tokenAmount = _strategy.sharesToUnderlyingView(_share);
        return quoteByMarketValue(_token, tokenAmount);
    }

    function quoteByMarketValue(address _token, uint256 _amount) public view returns (uint256) {
        if (_amount == 0) return 0;

        if (_token == address(lido)) {
            if (quoteStEthWithCurve) {
                return _min(_amount, ICurvePoolQuoter1(address(stEth_Eth_Pool)).get_dy(1, 0, _amount));
            } else {
                return _amount; /// 1:1 from stETH to eETH
            }
        } else if (_token == address(cbEth)) {
            return _min(_amount * cbEth.exchangeRate() / 1e18, ICurvePoolQuoter2(address(cbEth_Eth_Pool)).get_dy(1, 0, _amount));
        } else if (_token == address(wbEth)) {
            return _min(_amount * wbEth.exchangeRate() / 1e18, ICurvePoolQuoter1(address(wbEth_Eth_Pool)).get_dy(1, 0, _amount));
        } else if (isDummyToken[_token]) {
            return _amount; /// 1:1 from dummy token to eETH
        }
        revert NotSupportedToken();
    }

    function verifyQueuedWithdrawal(address _user, IStrategyManager.QueuedWithdrawal calldata _queuedWithdrawal) public view returns (bytes32) {
        require(_queuedWithdrawal.depositor == _user && _queuedWithdrawal.withdrawerAndNonce.withdrawer == address(this), "wrong depositor/withdrawer");
        for (uint256 i = 0; i < _queuedWithdrawal.strategies.length; i++) {
            address token = address(_queuedWithdrawal.strategies[i].underlyingToken());
            require(tokenInfos[token].isWhitelisted && tokenInfos[token].strategy == _queuedWithdrawal.strategies[i], "NotWhitelisted");
        }
        bytes32 withdrawalRoot = eigenLayerStrategyManager.calculateWithdrawalRoot(_queuedWithdrawal);
        require(eigenLayerStrategyManager.withdrawalRootPending(withdrawalRoot), "WrongQ");
        require(!isRegisteredQueuedWithdrawals[withdrawalRoot], "Deposited");

        return withdrawalRoot;
    }

    function isTokenWhitelisted(address _token) public view returns (bool) {
        return tokenInfos[_token].isWhitelisted;
    }

    function getFeeAmount() public view returns (uint256) {
        uint256 gasSpendings = eigenLayerWithdrawalClaimGasCost;
        uint256 feeAmount = gasSpendings * block.basefee;
        return feeAmount;
    }

    function getTotalPooledEther() public view returns (uint256) {
        return address(this).balance + getTotalPooledEther(address(lido)) + getTotalPooledEther(address(cbEth)) + getTotalPooledEther(address(wbEth)) - accumulatedFee;
    }

    /// deposited (restaked) ETH can have 3 states:
    /// - restaked in EigenLayer & pending for withdrawals
    /// - non-restaked & held by this contract
    /// - non-restaked & not held by this contract & pending for withdrawals
    function getTotalPooledEtherSplits(address _token) public view returns (uint256, uint256, uint256) {
        TokenInfo memory info = tokenInfos[_token];
        if (!isTokenWhitelisted(_token)) return (0, 0, 0);

        uint256 restaked = quoteByFairValue(_token, info.strategy.sharesToUnderlyingView(info.strategyShare)); /// restaked & pending for withdrawals
        uint256 holding = quoteByFairValue(_token, IERC20(_token).balanceOf(address(this))); /// eth value for erc20 holdings
        uint256 pendingForWithdrawals = info.ethAmountPendingForWithdrawals; /// eth pending for withdrawals
        return (restaked, holding, pendingForWithdrawals);
    }

    function getTotalPooledEther(address _token) public view returns (uint256) {
        (uint256 restaked, uint256 holding, uint256 pendingForWithdrawals) = getTotalPooledEtherSplits(_token);
        return restaked + holding + pendingForWithdrawals;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function timeBoundCap(address _token) public view returns (uint256) {
        return uint256(1 ether) * tokenInfos[_token].timeBoundCapInEther;
    }

    function totalCap(address _token) public view returns (uint256) {
        return uint256(1 ether) * tokenInfos[_token].totalCapInEther;
    }

    function totalDeposited(address _token) public view returns (uint256) {
        return tokenInfos[_token].totalDeposited;
    }

    function isDepositCapReached(address _token, uint256 _amount) public view returns (bool) {
        TokenInfo memory info = tokenInfos[_token];
        uint96 totalDepositedThisPeriod_ = info.totalDepositedThisPeriod;
        uint32 timeBoundCapClockStartTime_ = info.timeBoundCapClockStartTime;
        if (block.timestamp >= timeBoundCapClockStartTime_ + timeBoundCapRefreshInterval) {
            totalDepositedThisPeriod_ = 0;
        }
        return (totalDepositedThisPeriod_ + _amount > timeBoundCap(_token) || info.totalDeposited + _amount > totalCap(_token));
    }

    /* INTERNAL FUNCTIONS */
    function _enqueueForWithdrawal(IStrategy[] memory _strategies, uint256[] memory _shares) internal returns (uint256) {
        uint256 numStrategies = _strategies.length;
        uint256 amount = 0;
        for (uint256 i = 0; i < numStrategies; i++) {
            IStrategy strategy = _strategies[i];
            uint256 share = _shares[i];
            address token = address(strategy.underlyingToken());
            uint256 dx = quoteStrategyShareForDeposit(token, strategy, share);

            // discount
            dx = (10000 - tokenInfos[token].discountInBasisPoints) * dx / 10000;

            require(!isDepositCapReached(token, dx), "CapReached");

            amount += dx;
            tokenInfos[token].strategyShare += uint128(share);

            _afterDeposit(token, amount);

            emit Liquified(msg.sender, dx, token, true);
        }
        return amount;
    }
    
    function _completeWithdrawals(IStrategyManager.QueuedWithdrawal memory _queuedWithdrawal) internal {
        bytes32 withdrawalRoot = eigenLayerStrategyManager.calculateWithdrawalRoot(_queuedWithdrawal);
        if (!isRegisteredQueuedWithdrawals[withdrawalRoot]) revert NotRegistered();

        uint256 numStrategies = _queuedWithdrawal.strategies.length;
        for (uint256 i = 0; i < numStrategies; i++) {
            address token = address(_queuedWithdrawal.strategies[i].underlyingToken());
            uint128 share = uint128(_queuedWithdrawal.shares[i]);

            if (tokenInfos[token].strategyShare < share) revert StrategyShareNotEnough();
            tokenInfos[token].strategyShare -= share;
        }

        emit CompletedQueuedWithdrawal(withdrawalRoot);
    }

    function _afterDeposit(address _token, uint256 _amount) internal {
        TokenInfo storage info = tokenInfos[_token];
        if (block.timestamp >= info.timeBoundCapClockStartTime + timeBoundCapRefreshInterval) {
            info.totalDepositedThisPeriod = 0;
            info.timeBoundCapClockStartTime = uint32(block.timestamp);
        }
        info.totalDepositedThisPeriod += uint96(_amount);
        info.totalDeposited += uint96(_amount);
    }

     function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _requireAdmin() internal view virtual {
        require(admins[msg.sender] || msg.sender == owner(), "NotAdmin");
    }

    /* MODIFIER */
    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }
}

/// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

import "./interfaces/ILiquifier.sol";
import "./interfaces/ILiquidityPool.sol";


/// put (restaked) {stETH, cbETH, wbETH} and get eETH
contract Liquifier is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, ILiquifier {

    uint32 public depositCapClockStartTime;
    uint32 public depositCapPeriod; // seconds
    uint96 public depositCap;
    uint96 public totalDepositedThisPeriod;

    uint128 public accumulatedFee;

    uint32 internal constant EigenLayerWithdrawalClaimGasCost = 150_000;
    uint32 internal constant BALANCE_OFFSET = 0;

    mapping(address => TokenInfo) public tokenInfos;
    mapping(bytes32 => bool) public isRegisteredQueuedWithdrawals;
    mapping(address => bool) public admins;

    address public treasury;
    ILiquidityPool public liquidityPool;
    IEigenLayerStrategyManager public eigenLayerStrategyManager;
    ILidoWithdrawalQueue public lidoWithdrawalQueue;

    ICurvePool public cbEth_Eth_Pool;
    ICurvePool public wbEth_Eth_Pool;

    IcbETH public cbEth;
    IwBETH public wbEth;
    ILido public lido;

    event Liquified(address _user, uint256 _toEEthAmount, address _fromToken, bool _isRestaked);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initialize to set variables on deployment
    function initialize(address _treasury, address _liquidityPool, address _eigenLayerStrategyManager, address _lidoWithdrawalQueue, 
                        address _stEth, address _cbEth, address _wbEth, address _cbEth_Eth_Pool, address _wbEth_Eth_Pool,
                        uint96 _depositCap, uint32 _depositCapPeriod) initializer external {
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
        
        depositCap = _depositCap;
        depositCapPeriod = _depositCapPeriod;
        depositCapClockStartTime = uint32(block.timestamp);
    }

    receive() external payable {
        require(msg.sender == address(lidoWithdrawalQueue) || msg.sender == address(cbEth_Eth_Pool) || msg.sender == address(wbEth_Eth_Pool), "not allowed");
    }

    /// the users mint eETH given the queued withdrawal for their LRT with withdrawer == address(this)
    /// charge a small fixed amount fee to compensate for the gas cost for claim
    /// @param _queuedWithdrawal The QueuedWithdrawal to be used for the deposit. This is the proof that the user has the re-staked ETH and requested the withdrawals setting the Liquifier contract as the withdrawer.
    /// @param _referral The referral address
    /// @return mintedAmount the amount of eETH minted to the caller (= msg.sender)
    function depositWithQueuedWithdrawal(IStrategyManager.QueuedWithdrawal calldata _queuedWithdrawal, address _referral) external whenNotPaused nonReentrant returns (uint256) {
        bytes32 withdrawalRoot = verifyQueuedWithdrawal(msg.sender, _queuedWithdrawal);

        /// register it to prevent duplicate deposits with the same queued withdrawal
        isRegisteredQueuedWithdrawals[withdrawalRoot] = true;

        /// queue the strategy share for withdrawal
        uint256 amount = _enqueueForWithdrawal(_queuedWithdrawal.strategies, _queuedWithdrawal.shares);

        require(!isDepositCapReached(amount), "Deposit cap reached");

        /// handle fee
        uint256 feeAmount = _queuedWithdrawal.strategies.length * getFeeAmount();
        require(amount >= feeAmount + BALANCE_OFFSET, "less than the fee amount");
        amount -= feeAmount;
        accumulatedFee += uint128(feeAmount);

        /// to protect from over-commitment
        amount -= BALANCE_OFFSET;
        
        /// mint eETH to the user
        uint256 eEthShare = liquidityPool.depositToRecipient(msg.sender, amount, _referral);

        _afterDeposit(amount);
        return eEthShare;
    }

    /// Deposit Liquid Staking Token such as stETH and Mint eETH
    /// @param _token The address of the token to deposit
    /// @param _amount The amount of the token to deposit
    /// @param _referral The referral address
    /// @return mintedAmount the amount of eETH minted to the caller (= msg.sender)
    function depositWithERC20(address _token, uint256 _amount, address _referral) public whenNotPaused nonReentrant returns (uint256) {
        require(isTokenWhitelisted(_token), "token is not whitelisted");

        uint256 balance = tokenAmountToEthAmount(_token, IERC20(_token).balanceOf(address(this)));
        bool sent = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        require(sent, "erc20 transfer failed");
        uint256 newBalance = tokenAmountToEthAmount(_token, IERC20(_token).balanceOf(address(this)));
        uint256 dx = newBalance - balance;

        require(!isDepositCapReached(dx), "Deposit cap reached");

        require(_amount > BALANCE_OFFSET, "amount is too small");
        dx -= BALANCE_OFFSET;

        uint256 eEthShare = liquidityPool.depositToRecipient(msg.sender, dx, _referral);

        emit Liquified(msg.sender, dx, _token, false);

        _afterDeposit(dx);
        return eEthShare;
    }

    function depositWithERC20WithPermit(address _token, uint256 _amount, address _referral, PermitInput calldata _permit) external whenNotPaused returns (uint256) {
        IERC20Permit(_token).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s);
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
            _completeWithdrawals(_queuedWithdrawals[i].strategies, _queuedWithdrawals[i].shares);

            /// so that the shares withdrawn from the specified strategies are sent to the caller
            receiveAsTokens[i] = true;
        }

        /// it will update the erc20 balances of this contract
        eigenLayerStrategyManager.completeQueuedWithdrawals(_queuedWithdrawals, _tokens, _middlewareTimesIndexes, receiveAsTokens);
    }

    /// Initiate the process for redemption of stETH 
    function stEthRequestWithdrawal() external onlyAdmin returns (uint256[] memory) {
        uint256 amount = lido.balanceOf(address(this));
        require(amount >= lidoWithdrawalQueue.MIN_STETH_WITHDRAWAL_AMOUNT(), "not enough stETH");

        tokenInfos[address(lido)].ethAmountPendingForWithdrawals += uint128(amount);

        uint256 maxAmount = lidoWithdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT();
        uint256 numReqs = (amount + maxAmount - 1) / maxAmount;
        uint256[] memory reqAmounts = new uint256[](numReqs);
        for (uint256 i = 0; i < numReqs; i++) {
            reqAmounts[i] = (i == numReqs - 1) ? amount - i * maxAmount : maxAmount;
        }
        lido.approve(address(lidoWithdrawalQueue), amount);
        uint256[] memory reqIds = lidoWithdrawalQueue.requestWithdrawals(reqAmounts, address(this));
        return reqIds;
    }

    /// @notice Claim a batch of withdrawal requests if they are finalized sending the ETH to the this contract back
    /// @param _requestIds array of request ids to claim
    /// @param _hints checkpoint hint for each id. Can be obtained with `findCheckpointHints()`
    function stEthClaimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external onlyAdmin {
        uint256 balance = address(this).balance;
        lidoWithdrawalQueue.claimWithdrawals(_requestIds, _hints);
        uint256 newBalance = address(this).balance;

        tokenInfos[address(lido)].ethAmountPendingForWithdrawals -= uint128(newBalance - balance);
    }

    // Send the redeemed ETH back to the liquidity pool & Send the fee to Treasury
    function withdrawEther() external onlyAdmin {
        require(address(this).balance >= accumulatedFee, "not enough balance");
        bool sent;

        if (accumulatedFee > 0.2 ether) {
            uint256 amountToTreasury = accumulatedFee;
            accumulatedFee = 0;
            (sent, ) = payable(treasury).call{value: amountToTreasury, gas: 5000}("");
            require(sent, "failed to send ether");
        }

        uint256 amountToLiquidityPool = address(this).balance - accumulatedFee;
        (sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: 10000}("");
        require(sent, "failed to send ether");
    }

    function updateWhitelistedToken(address _tokenAddress, bool _isWhitelisted) external onlyOwner {
        tokenInfos[_tokenAddress].isWhitelisted = _isWhitelisted;
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    function updateDepositCap(uint96 _depositCap, uint32 _depositCapPeriod) external onlyOwner {
        depositCap = _depositCap;
        depositCapPeriod = _depositCapPeriod;
    }

    function registerToken(address _token, address _strategy, bool _isWhitelisted) external onlyOwner {
        require(_token == address(IStrategy(_strategy).underlyingToken()), "token mismatch");
        require(address(tokenInfos[_token].strategy) == address(0) && tokenInfos[_token].strategyShare == 0 && tokenInfos[_token].ethAmountPendingForWithdrawals == 0, "already registered");
        tokenInfos[_token] = TokenInfo(IStrategy(_strategy), 0, 0, _isWhitelisted);
    }

    function swapCbEthToEth(uint256 _amount, uint256 _minOutputAmount) external onlyAdmin returns (uint256) {
        cbEth.approve(address(cbEth_Eth_Pool), _amount);
        return cbEth_Eth_Pool.exchange_underlying(1, 0, _amount, _minOutputAmount);
    }

    function swapWbEthToEth(uint256 _amount, uint256 _minOutputAmount) external onlyAdmin returns (uint256) {
        wbEth.approve(address(wbEth_Eth_Pool), _amount);
        return wbEth_Eth_Pool.exchange(1, 0, _amount, _minOutputAmount);
    }

    /* VIEW FUNCTIONS */
    function strategyShareToEthAmount(address _token, IStrategy _strategy, uint256 _share) public view returns (uint256) {
        uint256 tokenAmount = _strategy.sharesToUnderlyingView(_share);
        return tokenAmountToEthAmount(_token, tokenAmount);
    }

    function tokenAmountToEthAmount(address _token, uint256 _amount) public view returns (uint256) {
        if (_token == address(lido)) return _amount * 1; /// 1:1 from stETH to eETH
        else if (_token == address(cbEth)) return _amount * cbEth.exchangeRate() / 1e18;
        else if (_token == address(wbEth)) return _amount * wbEth.exchangeRate() / 1e18;
        
        require(false, "not supported");
    }

    function verifyQueuedWithdrawal(address _user, IStrategyManager.QueuedWithdrawal calldata _queuedWithdrawal) public view returns (bytes32) {
        require(_queuedWithdrawal.depositor == _user, "not the owner of the queued withdrawal");
        require(_queuedWithdrawal.withdrawerAndNonce.withdrawer == address(this), "withdrawer != liquifier");
        for (uint256 i = 0; i < _queuedWithdrawal.strategies.length; i++) {
            address token = address(_queuedWithdrawal.strategies[i].underlyingToken());
            require(isTokenWhitelisted(token), "token is not whitelisted");
        }
        bytes32 withdrawalRoot = eigenLayerStrategyManager.calculateWithdrawalRoot(_queuedWithdrawal);
        require(eigenLayerStrategyManager.withdrawalRootPending(withdrawalRoot), "already claimed OR wrong queued withdrawal");
        require(!isRegisteredQueuedWithdrawals[withdrawalRoot], "already deposited");

        return withdrawalRoot;
    }

    function isTokenWhitelisted(address _token) public view returns (bool) {
        return tokenInfos[_token].isWhitelisted;
    }

    function getFeeAmount() public view returns (uint256) {
        uint256 gasSpendings = EigenLayerWithdrawalClaimGasCost;
        uint256 feeAmount = gasSpendings * block.basefee;
        return gasSpendings;
    }

    function getTotalPooledEther() public view returns (uint256) {
        uint256 total = address(this).balance;
        total += getTotalPooledEther(address(lido));
        total += getTotalPooledEther(address(cbEth));
        total += getTotalPooledEther(address(wbEth));
        total -= accumulatedFee;
        return total;
    }

    /// deposited (restaked) ETH can have 3 states:
    /// - restaked in EigenLayer & pending for withdrawals
    /// - non-restaked & held by this contract
    /// - non-restaked & not held by this contract & pending for withdrawals
    function getTotalPooledEtherSplits(address _token) public view returns (uint256, uint256, uint256) {
        TokenInfo memory info = tokenInfos[_token];
        if (!isTokenWhitelisted(_token)) return (0, 0, 0);

        uint256 restaked = tokenAmountToEthAmount(_token, info.strategy.sharesToUnderlyingView(info.strategyShare)); /// restaked & pending for withdrawals
        uint256 holding = tokenAmountToEthAmount(_token, IERC20(_token).balanceOf(address(this))); /// eth value for erc20 holdings
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

    function isDepositCapReached(uint256 _amount) public view returns (bool) {
        uint256 totalDepositedThisPeriod_ = totalDepositedThisPeriod;
        uint32 depositCapClockStartTime_ = depositCapClockStartTime;
        if (block.timestamp >= depositCapClockStartTime_ + depositCapPeriod) {
            totalDepositedThisPeriod_ = 0;
            depositCapClockStartTime_ = uint32(block.timestamp);
        }
        return (totalDepositedThisPeriod_ + _amount > depositCap);
    }

    /* INTERNAL FUNCTIONS */
    function _enqueueForWithdrawal(IStrategy[] memory _strategies, uint256[] memory _shares) internal returns (uint256) {
        uint256 numStrategies = _strategies.length;
        uint256 amount = 0;
        for (uint256 i = 0; i < numStrategies; i++) {
            IStrategy strategy = _strategies[i];
            uint256 share = _shares[i];
            address token = address(strategy.underlyingToken());
            uint256 dx = strategyShareToEthAmount(token, strategy, share);

            amount += dx;
            tokenInfos[token].strategyShare += uint128(share);

            emit Liquified(msg.sender, dx, token, true);
        }
        return amount;
    }

    function _completeWithdrawals(IStrategy[] memory _strategies, uint256[] memory _shares) internal {
        uint256 numStrategies = _strategies.length;
        for (uint256 i = 0; i < numStrategies; i++) {
            address token = address(_strategies[i].underlyingToken());
            uint128 share = uint128(_shares[i]);
            tokenInfos[token].strategyShare -= share;
        }
    }

    function _afterDeposit(uint256 _amount) internal {
        if (block.timestamp >= depositCapClockStartTime + depositCapPeriod) {
            totalDepositedThisPeriod = 0;
            depositCapClockStartTime = uint32(block.timestamp);
        }
        totalDepositedThisPeriod += uint96(_amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /* MODIFIER */
    modifier onlyAdmin() {
        require(admins[msg.sender], "Not admin");
        _;
    }
}
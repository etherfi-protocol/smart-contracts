/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/ILiquifier.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IBlacklister.sol";
import "./utils/PausableUntil.sol";
import "./utils/RolesLibrary.sol";

import "./eigenlayer-interfaces/IStrategyManager.sol";
import "./eigenlayer-interfaces/IDelegationManager.sol";

/// Go wild, spread eETH/weETH to the world
contract Liquifier is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, PausableUntil, ReentrancyGuardUpgradeable, ILiquifier, RolesLibrary {
    using SafeERC20 for IERC20;
    using Math for uint256;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    // deprecated storage slots
    uint32 private __gap_0;

    uint32 public timeBoundCapRefreshInterval; // seconds
    bool public quoteStEthWithCurve;

    // deprecated storage slots
    uint128 private __gap_1;

    mapping(address => TokenInfo) public tokenInfos;
    
    // deprecated storage slots
    uint256[15] private __gap_2;
    
    // To support L2 native minting of weETH
    IERC20[] public dummies;
    
    // deprecated storage slots
    uint256[3] private __gap_3;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public immutable liquidityPool;
    ILidoWithdrawalQueue public immutable lidoWithdrawalQueue;
    ILido public immutable lido;
    ICurvePool public immutable stEth_Eth_Pool;
    AggregatorV3Interface public immutable stEthPriceFeed;
    IBlacklister public immutable blacklister;

    address public immutable etherfiRestaker;
    address public immutable l1SyncPool;

    uint256 public immutable minDiscountRateInBps;
    uint256 public immutable stalePriceWindow;
    uint256 public immutable maxPriceDeviationInBps;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    uint256 public constant BASIS_POINT_SCALE = 10_000;
    uint256 public constant SHARE_UNIT = 1e18;
    uint32 public constant MAX_TIME_BOUND_CAP_IN_ETHER = 500_000_000;
    uint32 public constant MAX_TOTAL_CAP_IN_ETHER = 2_000_000_000;

    /// @dev Suggested gas stipend for contract receiving ETH to perform a few
    /// storage reads and writes, but low enough to prevent griefing.
    uint256 internal constant GAS_STIPEND_NO_GRIEF = 100_000;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event Liquified(address _user, uint256 _toEEthAmount, address _fromToken, bool _isRestaked);
    // This event is deprecated. will be removed in the next release.
    // event RegisteredQueuedWithdrawal(bytes32 _withdrawalRoot, IStrategyManager.DeprecatedStruct_QueuedWithdrawal _queuedWithdrawal);
    event RegisteredQueuedWithdrawal_V2(bytes32 _withdrawalRoot, IDelegationManager.Withdrawal _queuedWithdrawal);
    event CompletedQueuedWithdrawal(bytes32 _withdrawalRoot);
    event QueuedStEthWithdrawals(uint256[] _reqIds);
    event CompletedStEthQueuedWithdrawals(uint256[] _reqIds);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    error NotSupportedToken();
    error EthTransferFailed();
    error AlreadyRegistered();
    error IncorrectCaller();
    error InvalidDiscountRate();
    error InvalidDepositCap();
    error InvalidPriceWindow();
    error InvalidMaxPriceDeviationInBps();
    error InvalidLiquidityPool();
    error InvalidLidoWithdrawalQueue();
    error InvalidLido();
    error InvalidStEth_Eth_Pool();
    error InvalidPriceFeed();
    error InvalidBlacklister();
    error InvalidEtherfiRestaker();
    error InvalidL1SyncPool();
    error StalePriceFeed();
    error InvalidStEthPrice();
    error NotAllowed();
    error Capped();
    error AddressZero();
    error InvalidTotalSupply();

    struct ConstructorAddresses {
        address liquidityPool;
        address lidoWithdrawalQueue;
        address lido;
        address stEth_Eth_Pool;
        address roleRegistry;
        address stEthPriceFeed;
        address blacklister;
        address etherfiRestaker;
        address l1SyncPool;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  CONSTRUCTOR  ----------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(ConstructorAddresses memory _constructorAddresses, uint256 _minDiscountInBasisPoints, uint256 _stalePriceWindow, uint256 _maxPriceDeviationInBps) RolesLibrary(_constructorAddresses.roleRegistry) {
        if (_minDiscountInBasisPoints == 0 || _minDiscountInBasisPoints > BASIS_POINT_SCALE) revert InvalidDiscountRate();
        if (_stalePriceWindow == 0) revert InvalidPriceWindow();
        if (_maxPriceDeviationInBps == 0 || _maxPriceDeviationInBps > BASIS_POINT_SCALE) revert InvalidMaxPriceDeviationInBps();
        if (_constructorAddresses.liquidityPool == address(0)) revert InvalidLiquidityPool();
        if (_constructorAddresses.lidoWithdrawalQueue == address(0)) revert InvalidLidoWithdrawalQueue();
        if (_constructorAddresses.lido == address(0)) revert InvalidLido();
        if (_constructorAddresses.stEth_Eth_Pool == address(0)) revert InvalidStEth_Eth_Pool();
        if (_constructorAddresses.stEthPriceFeed == address(0)) revert InvalidPriceFeed();
        if (_constructorAddresses.blacklister == address(0)) revert InvalidBlacklister();
        if (_constructorAddresses.etherfiRestaker == address(0)) revert InvalidEtherfiRestaker();
        if (_constructorAddresses.l1SyncPool == address(0)) revert InvalidL1SyncPool();
        liquidityPool = ILiquidityPool(_constructorAddresses.liquidityPool);
        lidoWithdrawalQueue = ILidoWithdrawalQueue(_constructorAddresses.lidoWithdrawalQueue);
        lido = ILido(_constructorAddresses.lido);
        stEth_Eth_Pool = ICurvePool(_constructorAddresses.stEth_Eth_Pool);
        stEthPriceFeed = AggregatorV3Interface(_constructorAddresses.stEthPriceFeed);
        blacklister = IBlacklister(_constructorAddresses.blacklister);
        etherfiRestaker = _constructorAddresses.etherfiRestaker;
        l1SyncPool = _constructorAddresses.l1SyncPool;
        minDiscountRateInBps = _minDiscountInBasisPoints;
        stalePriceWindow = _stalePriceWindow;
        maxPriceDeviationInBps = _maxPriceDeviationInBps;
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice initialize to set variables on deployment
    function initialize(address _treasury, address _liquidityPool, address _eigenLayerStrategyManager, address _lidoWithdrawalQueue, 
                        address _stEth, address _stEth_Eth_Pool,
                        uint32 _timeBoundCapRefreshInterval) initializer external {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        timeBoundCapRefreshInterval = _timeBoundCapRefreshInterval;
    }

    receive() external payable {}

    /// Deposit Liquid Staking Token such as stETH and Mint eETH
    /// @param _token The address of the token to deposit
    /// @param _amount The amount of the token to deposit
    /// @param _referral The referral address
    /// @return mintedAmount the amount of eETH minted to the caller (= msg.sender)
    /// If the token is l2Eth, only the l2SyncPool can call this function
    function depositWithERC20(address _token, uint256 _amount, address _referral) public nonReentrant whenNotPaused nonBlacklisted returns (uint256) {        
        if (!isTokenWhitelisted(_token) || (tokenInfos[_token].isL2Eth && msg.sender != l1SyncPool)) revert NotAllowed();

        // Measure actual amount received to handle stETH's 1-2 wei rounding issue
        uint256 amountReceived;
        if (tokenInfos[_token].isL2Eth) {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
            amountReceived = IERC20(_token).balanceOf(address(this)) - balanceBefore;
        } else {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(etherfiRestaker));
            IERC20(_token).safeTransferFrom(msg.sender, address(etherfiRestaker), _amount);
            amountReceived = IERC20(_token).balanceOf(address(etherfiRestaker)) - balanceBefore;
        }

        // The L1SyncPool's `_anticipatedDeposit` should be the only place to mint the `token` and always send its entirety to the Liquifier contract
        if(tokenInfos[_token].isL2Eth) _L2SanityChecks(_token);
    
        uint256 dx = quoteByDiscountedValue(_token, amountReceived);
        if (isDepositCapReached(_token, dx)) revert Capped();

        uint256 eEthShare = liquidityPool.depositToRecipient(msg.sender, dx, _referral);

        emit Liquified(msg.sender, dx, _token, false);

        _afterDeposit(_token, dx);
        return eEthShare;
    }

    function depositWithERC20WithPermit(address _token, uint256 _amount, address _referral, PermitInput calldata _permit) external whenNotPaused nonBlacklisted returns (uint256) {
        try IERC20Permit(_token).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
        return depositWithERC20(_token, _amount, _referral);
    }

    // Send the redeemed ETH back to the liquidity pool & Send the fee to Treasury
    function withdrawEther() external onlyHousekeepingOperations {
        uint256 amountToLiquidityPool = _min(address(this).balance, liquidityPool.totalValueOutOfLp());
        (bool sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: GAS_STIPEND_NO_GRIEF}("");
        if (!sent) revert EthTransferFailed();
    }

    function sendToEtherFiRestaker(address _token, uint256 _amount) external onlyHousekeepingOperations {
        IERC20(_token).safeTransfer(etherfiRestaker, _amount);
    }

    function updateWhitelistedToken(address _token, bool _isWhitelisted) external onlyUpgradeTimelock {
        tokenInfos[_token].isWhitelisted = _isWhitelisted;
    }

    function updateDepositCap(address _token, uint32 _timeBoundCapInEther, uint32 _totalCapInEther) public onlyAdmin {
        if (_timeBoundCapInEther > MAX_TIME_BOUND_CAP_IN_ETHER || _totalCapInEther > MAX_TOTAL_CAP_IN_ETHER) revert InvalidDepositCap();
        tokenInfos[_token].timeBoundCapInEther = _timeBoundCapInEther;
        tokenInfos[_token].totalCapInEther = _totalCapInEther;
    }

    function registerToken(address _token, address _target, bool _isWhitelisted, uint16 _discountInBasisPoints, uint32 _timeBoundCapInEther, uint32 _totalCapInEther, bool _isL2Eth) external onlyUpgradeTimelock {
        if (_discountInBasisPoints < minDiscountRateInBps || _discountInBasisPoints > BASIS_POINT_SCALE) revert InvalidDiscountRate();
        if (_timeBoundCapInEther > MAX_TIME_BOUND_CAP_IN_ETHER || _totalCapInEther > MAX_TOTAL_CAP_IN_ETHER) revert InvalidDepositCap();
        if (tokenInfos[_token].timeBoundCapClockStartTime != 0) revert AlreadyRegistered();
        if (_isL2Eth) {
            if (_token == address(0) || _target != address(0)) revert AddressZero();
            dummies.push(IERC20(_token));
        } else {
            // _target = EigenLayer's Strategy contract
            if (_token != address(IStrategy(_target).underlyingToken())) revert NotSupportedToken();
        }
        tokenInfos[_token] = TokenInfo(0, 0, IStrategy(_target), _isWhitelisted, _discountInBasisPoints, uint32(block.timestamp), _timeBoundCapInEther, _totalCapInEther, 0, 0, _isL2Eth);
    }

    function updateTimeBoundCapRefreshInterval(uint32 _timeBoundCapRefreshInterval) external onlyAdmin {
        timeBoundCapRefreshInterval = _timeBoundCapRefreshInterval;
    }

    function updateDiscountInBasisPoints(address _token, uint16 _discountInBasisPoints) external onlyAdmin {
        if (_discountInBasisPoints < minDiscountRateInBps || _discountInBasisPoints > BASIS_POINT_SCALE) revert InvalidDiscountRate();
        tokenInfos[_token].discountInBasisPoints = _discountInBasisPoints;
    }

    function updateQuoteStEthWithCurve(bool _quoteStEthWithCurve) external onlyAdmin {
        quoteStEthWithCurve = _quoteStEthWithCurve;
    }

    //Pauses the contract
    function pauseContract() external onlyOperatingMultisig {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyOperatingMultisig {
        _unpause();
    }

    /// @notice Pauses the contract until MAX_PAUSE_DURATION
    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    /// @notice Unpauses the contract from pauseUntil
    function unpauseContractUntil() external onlyOperatingMultisig {
        _unpauseUntil();
    }

    /// @notice Sets the pause duration for the contract
    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    // ETH comes in, L2ETH is burnt
    function unwrapL2Eth(address _l2Eth) external payable nonReentrant returns (uint256) {
        if (msg.sender != l1SyncPool) revert IncorrectCaller();
        if (!isTokenWhitelisted(_l2Eth) || !tokenInfos[_l2Eth].isL2Eth) revert NotSupportedToken();
        _L2SanityChecks(_l2Eth);

        IERC20(_l2Eth).safeTransfer(msg.sender, msg.value);
        return msg.value;
    }

    /* VIEW FUNCTIONS */

    // Given the `_amount` of `_token` token, returns the equivalent amount of ETH 
    function quoteByFairValue(address _token, uint256 _amount) public view returns (uint256) {
        if (!isTokenWhitelisted(_token)) revert NotSupportedToken();

        if (_token == address(lido)) return _amount * 1; /// 1:1 from stETH to eETH
        else if (tokenInfos[_token].isL2Eth) return _amount * 1; /// 1:1 from l2Eth to eETH

        revert NotSupportedToken();
    }

    function quoteStrategyShareForDeposit(address _token, IStrategy _strategy, uint256 _share) public view returns (uint256) {
        uint256 tokenAmount = _strategy.sharesToUnderlyingView(_share);
        return quoteByMarketValue(_token, tokenAmount);
    }

    function quoteByMarketValue(address _token, uint256 _amount) public view returns (uint256 _marketValue) {
        if (!isTokenWhitelisted(_token)) revert NotSupportedToken();

        if (_token == address(lido)) {
            if (quoteStEthWithCurve) {
                // check market value from curve pool, stETH price is on avrage always lower than ETH (this is essentially the capital efficiency of the protocol)
                // if stETH price is temporarily larger than underlying ETH value, we set market value as 1:1 
                _marketValue = _min(_amount, ICurvePoolQuoter1(address(stEth_Eth_Pool)).get_dy(1, 0, _amount));

                // We also validate against chainlink price feed to ensure there's no significant price deviation 
                // If price feed is stale, we skip the check
                // If price feed is negative or deviation is too high, we do not allow the stETH deposit at all, something is wrong with the markets and deposit
                // via stETH will be blocked until it stablises (either because of underlying lido solvency/liquidity issue or oracle manipulation)
                (, int256 answer, , uint256 updatedAt,) = stEthPriceFeed.latestRoundData();
                if (answer <= 0) revert InvalidPriceFeed();
                if (updatedAt + stalePriceWindow < block.timestamp) revert StalePriceFeed();
                uint256 pricefeedValue = uint256(answer).mulDiv(_amount, SHARE_UNIT);
                uint256 deviation = pricefeedValue > _marketValue ? pricefeedValue - _marketValue : _marketValue - pricefeedValue;
                if (deviation.mulDiv(BASIS_POINT_SCALE, _marketValue) > maxPriceDeviationInBps) revert InvalidStEthPrice();
            } else {
                _marketValue = _amount; /// 1:1 from stETH to eETH
            }
        } else if (tokenInfos[_token].isL2Eth) {
            // 1:1 for all dummy tokens
            _marketValue = _amount;
        } else {
            revert NotSupportedToken();
        }
    }

    // Calculates the amount of eETH that will be minted for a given token considering the discount rate
    function quoteByDiscountedValue(address _token, uint256 _amount) public view returns (uint256) {
        uint256 marketValue = quoteByMarketValue(_token, _amount);

        return (BASIS_POINT_SCALE - tokenInfos[_token].discountInBasisPoints).mulDiv(marketValue, BASIS_POINT_SCALE);
    }

    function isTokenWhitelisted(address _token) public view returns (bool) {
        return tokenInfos[_token].isWhitelisted;
    }

    function isL2Eth(address _token) public view returns (bool) {
        return tokenInfos[_token].isL2Eth;
    }

    function getTotalPooledEther() public view returns (uint256 total) {
        total = address(this).balance;
        for (uint256 i = 0; i < dummies.length; i++) {
            total += getTotalPooledEther(address(dummies[i]));
        }
    }

    /// deposited (restaked) ETH can have 3 states:
    /// - restaked in EigenLayer & pending for withdrawals
    /// - non-restaked & held by this contract
    /// - non-restaked & not held by this contract & pending for withdrawals
    function getTotalPooledEtherSplits(address _token) public view returns (uint256 restaked, uint256 holding, uint256 pendingForWithdrawals) {
        TokenInfo memory info = tokenInfos[_token];
        if (!isTokenWhitelisted(_token)) return (0, 0, 0);

        holding = quoteByFairValue(_token, IERC20(_token).balanceOf(address(this))); /// eth value for erc20 holdings
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
    function _afterDeposit(address _token, uint256 _amount) internal {
        TokenInfo storage info = tokenInfos[_token];
        if (block.timestamp >= info.timeBoundCapClockStartTime + timeBoundCapRefreshInterval) {
            info.totalDepositedThisPeriod = 0;
            info.timeBoundCapClockStartTime = uint32(block.timestamp);
        }
        info.totalDepositedThisPeriod += uint96(_amount);
        info.totalDeposited += uint96(_amount);
    }

    function _L2SanityChecks(address _token) internal view {
        if (IERC20(_token).totalSupply() != IERC20(_token).balanceOf(address(this))) revert InvalidTotalSupply();
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    function _requireNotPaused() internal override view {
        _requireNotPausedUntil();
        super._requireNotPaused();
    }

    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}

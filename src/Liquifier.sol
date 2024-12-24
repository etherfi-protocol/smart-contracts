/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ILiquifier.sol";
import "./interfaces/ILiquidityPool.sol";

import "./eigenlayer-interfaces/IStrategyManager.sol";
import "./eigenlayer-interfaces/IDelegationManager.sol";


/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via PancakeSwap V3
interface IPancackeV3SwapRouter {
    function WETH9() external returns (address);

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
}

interface IERC20Burnable is IERC20 {
    function burn(uint256 amount) external;
}

/// Go wild, spread eETH/weETH to the world
contract Liquifier is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, ILiquifier {
    using SafeERC20 for IERC20;

    uint32 public DEPRECATED_eigenLayerWithdrawalClaimGasCost;
    uint32 public timeBoundCapRefreshInterval; // seconds

    bool public quoteStEthWithCurve;

    uint128 public DEPRECATED_accumulatedFee;

    mapping(address => TokenInfo) public tokenInfos;
    mapping(bytes32 => bool) public isRegisteredQueuedWithdrawals;
    mapping(address => bool) public admins;

    address public treasury;
    ILiquidityPool public liquidityPool;
    IStrategyManager public eigenLayerStrategyManager;
    ILidoWithdrawalQueue public lidoWithdrawalQueue;

    ICurvePool public cbEth_Eth_Pool;
    ICurvePool public wbEth_Eth_Pool;
    ICurvePool public stEth_Eth_Pool;

    IcbETH public cbEth;
    IwBETH public wbEth;
    ILido public lido;

    IDelegationManager public eigenLayerDelegationManager;

    IPancackeV3SwapRouter pancakeRouter;

    mapping(string => bool) flags;
    
    // To support L2 native minting of weETH
    IERC20[] public dummies;
    address public l1SyncPool;

    mapping(address => bool) public pausers;

    address public etherfiRestaker;

    event Liquified(address _user, uint256 _toEEthAmount, address _fromToken, bool _isRestaked);
    event CompletedQueuedWithdrawal(bytes32 _withdrawalRoot);
    event QueuedStEthWithdrawals(uint256[] _reqIds);
    event CompletedStEthQueuedWithdrawals(uint256[] _reqIds);

    error StrategyShareNotEnough();
    error NotSupportedToken();
    error EthTransferFailed();
    error NotEnoughBalance();
    error AlreadyRegistered();
    error NotRegistered();
    error WrongOutput();
    error IncorrectCaller();
    error IncorrectAmount();

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
        DEPRECATED_eigenLayerWithdrawalClaimGasCost = 150_000;
    }

    function initializeOnUpgrade(address _etherfiRestaker) external onlyOwner {
        etherfiRestaker = _etherfiRestaker;
    }

    receive() external payable {}

    /// Deposit Liquid Staking Token such as stETH and Mint eETH
    /// @param _token The address of the token to deposit
    /// @param _amount The amount of the token to deposit
    /// @param _referral The referral address
    /// @return mintedAmount the amount of eETH minted to the caller (= msg.sender)
    /// If the token is l2Eth, only the l2SyncPool can call this function
    function depositWithERC20(address _token, uint256 _amount, address _referral) public whenNotPaused nonReentrant returns (uint256) {        
        require(isTokenWhitelisted(_token) && (!tokenInfos[_token].isL2Eth || msg.sender == l1SyncPool), "NOT_ALLOWED");

        if (tokenInfos[_token].isL2Eth) {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);     
        } else {
            IERC20(_token).safeTransferFrom(msg.sender, address(etherfiRestaker), _amount);
        }

        // The L1SyncPool's `_anticipatedDeposit` should be the only place to mint the `token` and always send its entirety to the Liquifier contract
        if(tokenInfos[_token].isL2Eth) _L2SanityChecks(_token);
    
        uint256 dx = quoteByDiscountedValue(_token, _amount);
        require(!isDepositCapReached(_token, dx), "CAPPED");

        uint256 eEthShare = liquidityPool.depositToRecipient(msg.sender, dx, _referral);

        emit Liquified(msg.sender, dx, _token, false);

        _afterDeposit(_token, dx);
        return eEthShare;
    }

    function depositWithERC20WithPermit(address _token, uint256 _amount, address _referral, PermitInput calldata _permit) external whenNotPaused returns (uint256) {
        try IERC20Permit(_token).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
        return depositWithERC20(_token, _amount, _referral);
    }

    // Send the redeemed ETH back to the liquidity pool & Send the fee to Treasury
    function withdrawEther() external onlyAdmin {
        uint256 amountToLiquidityPool = address(this).balance;
        (bool sent, ) = payable(address(liquidityPool)).call{value: amountToLiquidityPool, gas: 20000}("");
        if (!sent) revert EthTransferFailed();
    }

    function sendToEtherFiRestaker(address _token, uint256 _amount) external onlyAdmin {
        IERC20(_token).safeTransfer(etherfiRestaker, _amount);
    }

    function updateWhitelistedToken(address _token, bool _isWhitelisted) external onlyOwner {
        tokenInfos[_token].isWhitelisted = _isWhitelisted;
    }

    function updateDepositCap(address _token, uint32 _timeBoundCapInEther, uint32 _totalCapInEther) public onlyOwner {
        tokenInfos[_token].timeBoundCapInEther = _timeBoundCapInEther;
        tokenInfos[_token].totalCapInEther = _totalCapInEther;
    }
    
    function registerToken(address _token, address _target, bool _isWhitelisted, uint16 _discountInBasisPoints, uint32 _timeBoundCapInEther, uint32 _totalCapInEther, bool _isL2Eth) external onlyOwner {
        if (tokenInfos[_token].timeBoundCapClockStartTime != 0) revert AlreadyRegistered();
        if (_isL2Eth) {
            if (_token == address(0) || _target != address(0)) revert();
            dummies.push(IERC20(_token));
        } else {
            // _target = EigenLayer's Strategy contract
            if (_token != address(IStrategy(_target).underlyingToken())) revert NotSupportedToken();
        }
        tokenInfos[_token] = TokenInfo(0, 0, IStrategy(_target), _isWhitelisted, _discountInBasisPoints, uint32(block.timestamp), _timeBoundCapInEther, _totalCapInEther, 0, 0, _isL2Eth);
    }

    function updateTimeBoundCapRefreshInterval(uint32 _timeBoundCapRefreshInterval) external onlyOwner {
        timeBoundCapRefreshInterval = _timeBoundCapRefreshInterval;
    }

    function pauseDeposits(address _token) external onlyPauser {
        tokenInfos[_token].timeBoundCapInEther = 0;
        tokenInfos[_token].totalCapInEther = 0;
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    function updatePauser(address _address, bool _isPauser) external onlyAdmin {
        pausers[_address] = _isPauser;
    }

    function updateDiscountInBasisPoints(address _token, uint16 _discountInBasisPoints) external onlyAdmin {
        tokenInfos[_token].discountInBasisPoints = _discountInBasisPoints;
    }

    function updateQuoteStEthWithCurve(bool _quoteStEthWithCurve) external onlyAdmin {
        quoteStEthWithCurve = _quoteStEthWithCurve;
    }

    //Pauses the contract
    function pauseContract() external onlyPauser {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyOwner {
        _unpause();
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
        else if (_token == address(cbEth)) return _amount * cbEth.exchangeRate() / 1e18;
        else if (_token == address(wbEth)) return _amount * wbEth.exchangeRate() / 1e18;
        else if (tokenInfos[_token].isL2Eth) return _amount * 1; /// 1:1 from l2Eth to eETH

        revert NotSupportedToken();
    }

    function quoteStrategyShareForDeposit(address _token, IStrategy _strategy, uint256 _share) public view returns (uint256) {
        uint256 tokenAmount = _strategy.sharesToUnderlyingView(_share);
        return quoteByMarketValue(_token, tokenAmount);
    }

    function quoteByMarketValue(address _token, uint256 _amount) public view returns (uint256) {
        if (!isTokenWhitelisted(_token)) revert NotSupportedToken();

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
        } else if (tokenInfos[_token].isL2Eth) {
            // 1:1 for all dummy tokens
            return _amount;
        }

        revert NotSupportedToken();
    }

    // Calculates the amount of eETH that will be minted for a given token considering the discount rate
    function quoteByDiscountedValue(address _token, uint256 _amount) public view returns (uint256) {
        uint256 marketValue = quoteByMarketValue(_token, _amount);

        return (10000 - tokenInfos[_token].discountInBasisPoints) * marketValue / 10000;
    }

    function isTokenWhitelisted(address _token) public view returns (bool) {
        return tokenInfos[_token].isWhitelisted;
    }

    function isL2Eth(address _token) public view returns (bool) {
        return tokenInfos[_token].isL2Eth;
    }

    function getTotalPooledEther() public view returns (uint256 total) {
        total = address(this).balance + getTotalPooledEther(address(lido)) + getTotalPooledEther(address(cbEth)) + getTotalPooledEther(address(wbEth));
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

        if (info.strategy != IStrategy(address(0))) {
            restaked = quoteByFairValue(_token, info.strategy.sharesToUnderlyingView(info.strategyShare)); /// restaked & pending for withdrawals
        }
        holding = quoteByFairValue(_token, IERC20(_token).balanceOf(address(this))); /// eth value for erc20 holdings
        pendingForWithdrawals = info.ethAmountPendingForWithdrawals; /// eth pending for withdrawals
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
        if (IERC20(_token).totalSupply() != IERC20(_token).balanceOf(address(this))) revert();
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

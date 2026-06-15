// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/IWeETH.sol";
import "@etherfi/deposits/interfaces/ILiquifier.sol";
import "@etherfi/restaking/interfaces/IEtherFiRestaker.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZPausable.sol";
import "@etherfi/governance/utils/DeprecatedOZReentrancyGuard.sol";

import "@etherfi/governance/rate-limiting/libraries/BucketLimiter.sol";

import "@etherfi/withdrawals/interfaces/IEtherFiRedemptionManager.sol";
import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";

/*
    The contract allows instant redemption of eETH and weETH tokens to ETH or stETH with an exit fee.
    - It has the exit fee as a percentage of the total amount redeemed.
    - It has a rate limiter to limit the total amount that can be redeemed in a given time period.
*/

contract EtherFiRedemptionManager is Initializable, DeprecatedOZPausable, PausableUntil, DeprecatedOZReentrancyGuard, ReentrancyGuardTransient, UUPSUpgradeable, IEtherFiRedemptionManager {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev Suggested gas stipend for contract receiving ETH to perform a few
    /// storage reads and writes, but low enough to prevent griefing.
    uint256 internal constant GAS_STIPEND_NO_GRIEF = 100_000;
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    mapping(address => RedemptionInfo) public tokenToRedemptionInfo;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    address public immutable treasury;
    IeETH public immutable eEth;
    IWeETH public immutable weEth;
    ILiquidityPool public immutable liquidityPool;
    IEtherFiRestaker public immutable etherFiRestaker;
    ILido public immutable lido;
    IPriorityWithdrawalQueue public immutable priorityWithdrawalQueue;
    IBlacklister public immutable blacklister;

    uint256 public immutable maxExitFeeSplitToTreasuryInBps;
    uint256 public immutable maxExitFeeInBps;
    uint256 public immutable maxLowWatermarkInBpsOfTvl;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    uint256 private constant BUCKET_UNIT_SCALE = 1e12;
    uint256 private constant BASIS_POINT_SCALE = 1e4;

    //--------------------------------------------------------------------------------------
    //---------------------------------  EVENTS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    event Redeemed(address indexed receiver, uint256 redemptionAmount, uint256 feeAmountToTreasury, uint256 feeAmountToStakers, address token);
    event DustSwept(address indexed token, address indexed to, uint256 amount);

    //--------------------------------------------------------------------------------------
    //---------------------------------  ERRORS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    error InvalidAmount();
    error InvalidOutputToken();
    error ExceedsMaxExitFee();
    error ExceedsMaxLowWatermark();
    error ExceedsMaxExitFeeSplit();
    error InvalidNumSharesBurnt();
    error InvalidTotalShares();
    error TransferFailed();
    error InvalidLpBalance();
    error InvalidTotalValueOutOfLp();
    error InsufficientBalance();
    error ExceededRedeemable();
    error RateLimitExceeded();
    error AmountTooLarge();
    error InvalidRecipient();

    receive() external payable {}

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _liquidityPool The address of the liquidity pool
     * @param _eEth The address of the eETH token
     * @param _weEth The address of the weETH token
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address _liquidityPool, 
        address _eEth, address _weEth, 
        address _treasury, 
        address _roleRegistry, 
        address _etherFiRestaker, 
        address _priorityWithdrawalQueue, 
        address _blacklister, 
        uint256 _maxExitFeeSplitToTreasuryInBps, 
        uint256 _maxExitFeeInBps, 
        uint256 _maxLowWatermarkInBpsOfTvl)
        RolesLibrary(_roleRegistry)
    {
        if (_maxExitFeeSplitToTreasuryInBps > BASIS_POINT_SCALE || _maxExitFeeInBps > BASIS_POINT_SCALE || _maxLowWatermarkInBpsOfTvl > BASIS_POINT_SCALE) revert InvalidAmount();
        maxExitFeeSplitToTreasuryInBps = _maxExitFeeSplitToTreasuryInBps;
        maxExitFeeInBps = _maxExitFeeInBps;
        maxLowWatermarkInBpsOfTvl = _maxLowWatermarkInBpsOfTvl;
        treasury = _treasury;
        liquidityPool = ILiquidityPool(payable(_liquidityPool));
        eEth = IeETH(_eEth);
        weEth = IWeETH(_weEth); 
        etherFiRestaker = IEtherFiRestaker(payable(_etherFiRestaker));
        lido = etherFiRestaker.lido();
        priorityWithdrawalQueue = IPriorityWithdrawalQueue(_priorityWithdrawalQueue);
        blacklister = IBlacklister(_blacklister);

        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the EtherFiRedemptionManager
     */
    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function initializeTokenParameters(address[] memory _tokens, uint16[] memory _exitFeeSplitToTreasuryInBps, uint16[] memory _exitFeeInBps, uint16[] memory _lowWatermarkInBpsOfTvl, uint256[] memory _bucketCapacity, uint256[] memory _bucketRefillRate)  external onlyAdmin {
        for(uint256 i = 0; i < _exitFeeSplitToTreasuryInBps.length; i++) {
            if (_exitFeeSplitToTreasuryInBps[i] > maxExitFeeSplitToTreasuryInBps) revert ExceedsMaxExitFeeSplit();
            if (_exitFeeInBps[i] > maxExitFeeInBps) revert ExceedsMaxExitFee();
            if (_lowWatermarkInBpsOfTvl[i] > maxLowWatermarkInBpsOfTvl) revert ExceedsMaxLowWatermark();
            tokenToRedemptionInfo[address(_tokens[i])] = RedemptionInfo({
                limit: BucketLimiter.create(_convertToBucketUnit(_bucketCapacity[i], Math.Rounding.Down), _convertToBucketUnit(_bucketRefillRate[i], Math.Rounding.Down)),
                exitFeeSplitToTreasuryInBps: _exitFeeSplitToTreasuryInBps[i],
                exitFeeInBps: _exitFeeInBps[i],
                lowWatermarkInBpsOfTvl: _lowWatermarkInBpsOfTvl[i]
            });
        }
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  REDEEM FUNCTIONS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Redeems eETH for outputToken (ETH or stETH).
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed outputToken.
     * @param outputToken The token to redeem to (ETH or stETH).
     */
    function redeemEEth(uint256 eEthAmount, address receiver, address outputToken) public nonReentrant whenNotPaused nonBlacklisted(receiver) {
        _redeemEEth(eEthAmount, receiver, outputToken);
    }

    /**
     * @notice Redeems weETH for outputToken (ETH or stETH).
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed outputToken.
     * @param outputToken The token to redeem to (ETH or stETH).
     */
    function redeemWeEth(uint256 weEthAmount, address receiver, address outputToken) public nonReentrant whenNotPaused nonBlacklisted(receiver) {
        _redeemWeEth(weEthAmount, receiver, outputToken);
    }

    /**
     * @notice Redeems eETH for outputToken (ETH or stETH) with permit.
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed outputToken.
     * @param permit The permit params.
     * @param outputToken The token to redeem to (ETH or stETH).
     */
    function redeemEEthWithPermit(uint256 eEthAmount, address receiver, IeETH.PermitInput calldata permit, address outputToken) external nonReentrant whenNotPaused nonBlacklisted(receiver) {
        try eEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {}
        _redeemEEth(eEthAmount, receiver, outputToken);
    }

    /**
     * @notice Redeems weETH for outputToken (ETH or stETH).
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed outputToken.
     * @param permit The permit params.
     * @param outputToken The token to redeem to (ETH or stETH).
     */
    function redeemWeEthWithPermit(uint256 weEthAmount, address receiver, IWeETH.PermitInput calldata permit, address outputToken) external nonReentrant whenNotPaused nonBlacklisted(receiver) {
        try weEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s)  {} catch {}
        _redeemWeEth(weEthAmount, receiver, outputToken);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  ADMIN FUNCTIONS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Sets the maximum size of the bucket that can be consumed in a given time period.
     * @param capacity The capacity of the bucket.
     * @param token The token to set the capacity for
     */
    function setCapacity(uint256 capacity, address token) external onlyAdmin {
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether, which is practically enough
        uint64 bucketUnit = _convertToBucketUnit(capacity, Math.Rounding.Down);
        BucketLimiter.setCapacity(tokenToRedemptionInfo[token].limit, bucketUnit);
    }

    /**
     * @notice Sets the rate at which the bucket is refilled per second.
     * @param refillRate The rate at which the bucket is refilled per second.
     * @param token The token to set the refill rate for
     */
    function setRefillRatePerSecond(uint256 refillRate, address token) external onlyAdmin {
        // max refillRate = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether per second, which is practically enough
        uint64 bucketUnit = _convertToBucketUnit(refillRate, Math.Rounding.Down);
        BucketLimiter.setRefillRate(tokenToRedemptionInfo[token].limit, bucketUnit);
    }

    /**
     * @notice Sets the exit fee.
     * @param _exitFeeInBps The exit fee.
     * @param token The token to set the exit fee for
     */
    function setExitFeeBasisPoints(uint16 _exitFeeInBps, address token) external onlyAdmin {
        if (_exitFeeInBps > maxExitFeeInBps) revert ExceedsMaxExitFee();
        tokenToRedemptionInfo[token].exitFeeInBps = _exitFeeInBps;
    }

    /**
     * @notice Sets the low watermark in basis points of the total value of the liquidity pool.
     * @param _lowWatermarkInBpsOfTvl The low watermark in basis points of the total value of the liquidity pool.
     * @param token The token to set the low watermark for (ETH or stETH).
     */
    function setLowWatermarkInBpsOfTvl(uint16 _lowWatermarkInBpsOfTvl, address token) external onlyAdmin {
        if (_lowWatermarkInBpsOfTvl > maxLowWatermarkInBpsOfTvl) revert ExceedsMaxLowWatermark();
        tokenToRedemptionInfo[token].lowWatermarkInBpsOfTvl = _lowWatermarkInBpsOfTvl;
    }

    /**
     * @notice Sets the exit fee split to treasury in basis points.
     * @param _exitFeeSplitToTreasuryInBps The exit fee split to treasury in basis points.
     * @param token The token to set the exit fee split to treasury for (ETH or stETH).
     */
    function setExitFeeSplitToTreasuryInBps(uint16 _exitFeeSplitToTreasuryInBps, address token) external onlyAdmin {
        if (_exitFeeSplitToTreasuryInBps > maxExitFeeSplitToTreasuryInBps) revert ExceedsMaxExitFeeSplit();
        tokenToRedemptionInfo[token].exitFeeSplitToTreasuryInBps = _exitFeeSplitToTreasuryInBps;
    }

    /**
     * @notice Sweep dust accumulated in the adapter to a recipient.
     * @param _token Address of the ERC20 to sweep
     * @param _to Recipient of the swept tokens
     * @dev Each redemption strands 1-2 wei of eETH due to floor-rounding in both
     *      amountForShare (shares -> ETH) and wrap (ETH -> shares). This function
     *      lets operations recover the residual balance of any ERC20 left here.
     */
    function sweepDust(address _token, address _to) external onlyOperatingMultisig {
        if (_to == address(0)) revert InvalidRecipient();
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();
        IERC20(_token).safeTransfer(_to, balance);
        emit DustSwept(_token, _to, balance);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INTERNAL FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Processes ETH-specific redemption logic.
     * @param receiver The address to receive the redeemed ETH.
     * @param eEthAmountToReceiver The amount of ETH to receiver.
     * @param sharesToBurn The amount of eETH shares to burn.
     * @param feeShareToStakers The amount of eETH shares to burn for stakers.
     */
    function _processETHRedemption(
        address receiver,
        uint256 eEthAmountToReceiver,
        uint256 sharesToBurn,
        uint256 feeShareToStakers
    ) internal {
        uint256 prevBalance = address(this).balance;
        uint256 prevLpBalance = liquidityPool.totalValueInLp();
        uint256 totalEEthShare = eEth.totalShares();

        // Withdraw ETH from the liquidity pool
        if (liquidityPool.withdraw(address(this), eEthAmountToReceiver) != sharesToBurn) revert InvalidNumSharesBurnt();
        uint256 ethReceived = address(this).balance - prevBalance;

        // To Stakers by burning shares
        liquidityPool.burnEEthShares(feeShareToStakers);
        if (eEth.totalShares() < 1 gwei || eEth.totalShares() != totalEEthShare - (sharesToBurn + feeShareToStakers)) revert InvalidTotalShares();

        // To Receiver by transferring ETH, using gas 10k for additional safety
        (bool success, ) = receiver.call{value: ethReceived, gas: GAS_STIPEND_NO_GRIEF}("");
        if (!success) revert TransferFailed();

        // Make sure the liquidity pool balance is correct && total shares are correct
        if (liquidityPool.totalValueInLp() != prevLpBalance - ethReceived) revert InvalidLpBalance();
    }

    /**
     * @notice Processes stETH-specific redemption logic.
     * @param receiver The address to receive the redeemed stETH.
     * @param stEthAmountToReceiver The amount of stETH to receiver.
     * @param sharesToBurn The amount of eETH shares to burn.
     * @param feeShareToStakers The amount of eETH shares to burn for stakers.
     */
    function _processStETHRedemption(
        address receiver,
        uint256 stEthAmountToReceiver,
        uint256 sharesToBurn,
        uint256 feeShareToStakers
    ) internal {
        uint256 eEthAmountToReceiver = stEthAmountToReceiver; // 1 stETH = 1 eETH
        if (eEthAmountToReceiver > type(uint128).max || eEthAmountToReceiver == 0 || sharesToBurn == 0) revert InvalidAmount();
        uint256 totalEEthShare = eEth.totalShares();
        uint256 totalValueOutOfLpBefore = liquidityPool.totalValueOutOfLp();

        // Burn shares for non ETH withdrawal (stETH)
        // - sharesToBurn: eETH shares to burn for withdrawal
        // - feeShareToStakers: eETH shares to burn for stakers
        liquidityPool.burnEEthSharesForNonETHWithdrawal(sharesToBurn, eEthAmountToReceiver);
        liquidityPool.burnEEthShares(feeShareToStakers);

        // Validate total shares and total value out of lp
        if (eEth.totalShares() < 1 gwei || eEth.totalShares() != totalEEthShare - (sharesToBurn + feeShareToStakers)) revert InvalidTotalShares();
        if (liquidityPool.totalValueOutOfLp() != totalValueOutOfLpBefore - eEthAmountToReceiver) revert InvalidTotalValueOutOfLp();

        etherFiRestaker.transferStETH(receiver, eEthAmountToReceiver);
    }

    /**
     * @notice Redeems outputToken (ETH or stETH).
     * The receiver will receive the ETH or stETH after the exit fee.
     * The fee will be split between the treasury and the stakers.
     * - the portion to the treasury will be transferred to the treasury in eETH.
     * - the portion to the stakers will be distributed by burning eETH shares.
     * @param ethAmount The amount of outputToken to redeem after the exit fee.
     * @param eEthShares The total amount of eETH shares corresponding to the `ethAmount` (= liquidityPool.sharesForAmount(ethAmount))
     * @param eEthAmountToReceiver The amount of ETH or stETH to receiver.
     * @param eEthFeeAmountToTreasury The amount of eETH to treasury.
     * @param sharesToBurn The amount of eETH shares to burn.
     * @param feeShareToTreasury The amount of eETH to treasury.
     * @param outputToken The token to redeem (ETH or stETH).
     * @param receiver The address to receive the redeemed outputToken.
     */
    function _redeem(uint256 ethAmount, uint256 eEthShares, address receiver, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury, address outputToken) internal {
        _updateRateLimit(ethAmount, outputToken);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToStakers = eEthShareFee - feeShareToTreasury;
        uint256 feeAmountToStakers = liquidityPool.amountForShare(feeShareToStakers);

        // Common fee handling: Transfer to Treasury
        IERC20(address(eEth)).safeTransfer(treasury, eEthFeeAmountToTreasury);

        if(outputToken == ETH_ADDRESS) {
            _processETHRedemption(receiver, eEthAmountToReceiver, sharesToBurn, feeShareToStakers);
        } else if(outputToken == address(lido)) {
            _processStETHRedemption(receiver, eEthAmountToReceiver, sharesToBurn, feeShareToStakers);
        } else {
            revert InvalidOutputToken();
        }

        emit Redeemed(receiver, ethAmount, eEthFeeAmountToTreasury, feeAmountToStakers, outputToken);
    }

    /**
     * @notice Redeems eETH.
     * @param eEthAmount The amount of eETH to redeem.
     * @param receiver The address to receive the redeemed eETH.
     * @param outputToken The token to redeem to (ETH or stETH).
     */
    function _redeemEEth(uint256 eEthAmount, address receiver, address outputToken) internal {
        if (eEthAmount > eEth.balanceOf(msg.sender)) revert InsufficientBalance();
        if (!canRedeem(eEthAmount, outputToken)) revert ExceededRedeemable();

        (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) = _calcRedemption(eEthAmount, outputToken);

        IERC20(address(eEth)).safeTransferFrom(msg.sender, address(this), eEthAmount);

        _redeem(eEthAmount, eEthShares, receiver, eEthAmountToReceiver, eEthFeeAmountToTreasury, sharesToBurn, feeShareToTreasury, outputToken);
    }

    /**
     * @notice Redeems weETH.
     * @param weEthAmount The amount of weETH to redeem.
     * @param receiver The address to receive the redeemed weETH.
     * @param outputToken The token to redeem to (ETH or stETH).
     */
    function _redeemWeEth(uint256 weEthAmount, address receiver, address outputToken) internal {
        uint256 eEthAmount = weEth.getEETHByWeETH(weEthAmount);
        if (weEthAmount > weEth.balanceOf(msg.sender)) revert InsufficientBalance();
        if (!canRedeem(eEthAmount, outputToken)) revert ExceededRedeemable();

        (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) = _calcRedemption(eEthAmount, outputToken);

        IERC20(address(weEth)).safeTransferFrom(msg.sender, address(this), weEthAmount);
        weEth.unwrap(weEthAmount);

        _redeem(eEthAmount, eEthShares, receiver, eEthAmountToReceiver, eEthFeeAmountToTreasury, sharesToBurn, feeShareToTreasury, outputToken);
    }

    /**
     * @notice Updates the rate limit.
     * @param amount The amount to update the rate limit for.
     * @param token The token to update the rate limit for (ETH or stETH).
     */
    function _updateRateLimit(uint256 amount, address token) internal {
        uint64 bucketUnit = _convertToBucketUnit(amount, Math.Rounding.Up);
        if (!BucketLimiter.consume(tokenToRedemptionInfo[token].limit, bucketUnit)) revert RateLimitExceeded();
    }

    /**
     * @notice Converts the amount to a bucket unit.
     * @param amount The amount to convert to a bucket unit.
     * @param rounding The rounding mode.
     * @return The bucket unit.
     */
    function _convertToBucketUnit(uint256 amount, Math.Rounding rounding) internal pure returns (uint64) {
        if (amount >= type(uint64).max * BUCKET_UNIT_SCALE) revert AmountTooLarge();
        return (rounding == Math.Rounding.Up) ? SafeCast.toUint64((amount + BUCKET_UNIT_SCALE - 1) / BUCKET_UNIT_SCALE) : SafeCast.toUint64(amount / BUCKET_UNIT_SCALE);
    }

    /**
     * @notice Converts the bucket unit to an amount.
     * @param bucketUnit The bucket unit to convert to an amount.
     * @return The amount.
     */
    function _convertFromBucketUnit(uint64 bucketUnit) internal pure returns (uint256) {
        return bucketUnit * BUCKET_UNIT_SCALE;
    }

    /**
     * @notice Calculates the redemption amount.
     * @param ethAmount The amount of ETH to redeem.
     * @param token The token to redeem to (ETH or stETH).
     * @return eEthShares The amount of eETH shares to redeem.
     * @return eEthAmountToReceiver The amount of ETH to receiver.
     * @return eEthFeeAmountToTreasury The amount of eETH to treasury.
     * @return sharesToBurn The amount of eETH shares to burn.
     * @return feeShareToTreasury The amount of eETH shares to burn for stakers.
     */
    function _calcRedemption(uint256 ethAmount, address token) internal view returns (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) {
        eEthShares = liquidityPool.sharesForAmount(ethAmount);
        eEthAmountToReceiver = liquidityPool.amountForShare(eEthShares.mulDiv(BASIS_POINT_SCALE - tokenToRedemptionInfo[token].exitFeeInBps, BASIS_POINT_SCALE)); // ethShareToReceiver

        sharesToBurn = liquidityPool.sharesForWithdrawalAmount(eEthAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        feeShareToTreasury = eEthShareFee.mulDiv(tokenToRedemptionInfo[token].exitFeeSplitToTreasuryInBps, BASIS_POINT_SCALE);
        eEthFeeAmountToTreasury = liquidityPool.amountForShare(feeShareToTreasury);
    }

    /**
     * @notice Calculates the fee amount.
     * @param assets The amount of assets to calculate the fee for.
     * @param feeBasisPoints The fee basis points.
     * @return The fee amount.
     */
    function _fee(uint256 assets, uint256 feeBasisPoints) internal pure virtual returns (uint256) {
        return assets.mulDiv(feeBasisPoints, BASIS_POINT_SCALE, Math.Rounding.Up);
    }

    /**
     * @notice Authorizes the upgrade.
     * @param newImplementation The new implementation address.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //----------------------------  GETTERS  ------------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Returns the low watermark in basis points of the total value of the liquidity pool.
     * @param token The token to get the low watermark for (ETH or stETH).
     * @return The low watermark in basis points of the total value of the liquidity pool.
     * @dev if the contract has less than the low watermark, it will not allow any instant redemption.
     */
    function lowWatermarkInETH(address token) public view returns (uint256) {
        return liquidityPool.getTotalPooledEther().mulDiv(tokenToRedemptionInfo[token].lowWatermarkInBpsOfTvl, BASIS_POINT_SCALE);
    }

    /**
     * @notice Returns the instant liquidity amount for the given token.
     * @param token The token to get the instant liquidity amount for (ETH or stETH).
     * @return The instant liquidity amount.
     */
    function getInstantLiquidityAmount(address token) public view returns (uint256) {
        if(token == ETH_ADDRESS) {
            // Post-escrow-migration, locked ETH has physically left LP into the holder
            // contracts, so LP.balance already excludes it. No further subtraction needed.
            return liquidityPool.totalValueInLp();
        } else if (token == address(lido)) {
            return lido.balanceOf(address(etherFiRestaker));
        }
    }

    /**
     * @notice Returns the total amount that can be redeemed.
     * @param token The token to get the total redeemable amount for (ETH or stETH).
     * @return The total redeemable amount.
     */
    function totalRedeemableAmount(address token) external view returns (uint256) {
        uint256 liquidEthAmount = getInstantLiquidityAmount(token);
        uint256 lowWatermark = lowWatermarkInETH(token);

        if (liquidEthAmount < lowWatermark) {
            return 0;
        }
        uint256 availableAmount = liquidEthAmount - lowWatermark;
        uint64 consumableBucketUnits = BucketLimiter.consumable(tokenToRedemptionInfo[token].limit);
        uint256 consumableAmount = _convertFromBucketUnit(consumableBucketUnits);
        return Math.min(consumableAmount, availableAmount);
    }

    /**
     * @notice Returns whether the given amount can be redeemed.
     * @param amount The ETH or stETH amount to check
     * @param token The token to check to redeem
     * @return Whether the given amount can be redeemed.
     */
    function canRedeem(uint256 amount, address token) public view returns (bool) {
        uint256 liquidEthAmount = getInstantLiquidityAmount(token);
        uint256 lowWatermark = lowWatermarkInETH(token);
        if (liquidEthAmount  < lowWatermark) {
            return false;
        }
        uint256 availableAmount = liquidEthAmount - lowWatermark;
        if (availableAmount < amount) {
            return false;
        }
        uint64 bucketUnit = _convertToBucketUnit(amount, Math.Rounding.Up);
        bool consumable = BucketLimiter.canConsume(tokenToRedemptionInfo[token].limit, bucketUnit);
        return consumable && amount <= liquidEthAmount;
    }

    /**
     * @notice Preview taking an exit fee on redeem.
     * @param shares The amount of eETH shares to redeem.
     * @param token The token to redeem to (ETH or stETH).
     * @return The amount of ETH to receiver after the exit fee.
     */
    function previewRedeem(uint256 shares, address token) public view returns (uint256) {
        uint256 amountInEth = liquidityPool.amountForShare(shares);
        return amountInEth - _fee(amountInEth, tokenToRedemptionInfo[token].exitFeeInBps);
    }

    /**
     * @notice Returns the implementation address.
     * @return The implementation address.
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }   

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the receiver is not blacklisted.
     * @param receiver The address to check if it is blacklisted.
     */
    modifier nonBlacklisted(address receiver) {
        blacklister.nonBlacklisted(msg.sender);
        blacklister.nonBlacklisted(receiver);
        _;
    }
}

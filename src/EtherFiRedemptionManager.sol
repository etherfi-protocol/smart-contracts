// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IWeETH.sol";
import "./interfaces/ILiquifier.sol";
import "./EtherFiRestaker.sol";

import "lib/BucketLimiter.sol";

import "./RoleRegistry.sol";

/*
    The contract allows instant redemption of eETH and weETH tokens to ETH with an exit fee.
    - It has the exit fee as a percentage of the total amount redeemed.
    - It has a rate limiter to limit the total amount that can be redeemed in a given time period.
*/

struct RedemptionInfo {
    BucketLimiter.Limit limit;
    uint16 exitFeeSplitToTreasuryInBps;
    uint16 exitFeeInBps;
    uint16 lowWatermarkInBpsOfTvl;
}

contract EtherFiRedemptionManager is Initializable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 private constant BUCKET_UNIT_SCALE = 1e12;
    uint256 private constant BASIS_POINT_SCALE = 1e4;

    bytes32 public constant ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE");
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    RoleRegistry public immutable roleRegistry;
    address public immutable treasury;
    IeETH public immutable eEth;
    IWeETH public immutable weEth;
    ILiquidityPool public immutable liquidityPool;
    EtherFiRestaker public immutable etherFiRestaker;
    ILido public immutable lido;

    mapping(address => RedemptionInfo) public tokenToRedemptionInfo;


    event Redeemed(address indexed receiver, uint256 redemptionAmount, uint256 feeAmountToTreasury, uint256 feeAmountToStakers, address token);

    receive() external payable {}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _liquidityPool, address _eEth, address _weEth, address _treasury, address _roleRegistry, address _etherFiRestaker) {
        roleRegistry = RoleRegistry(_roleRegistry);
        treasury = _treasury;
        liquidityPool = ILiquidityPool(payable(_liquidityPool));
        eEth = IeETH(_eEth);
        weEth = IWeETH(_weEth); 
        etherFiRestaker = EtherFiRestaker(payable(_etherFiRestaker));
        lido = etherFiRestaker.lido();

        _disableInitializers();
    }

    function initialize(uint16 _exitFeeSplitToTreasuryInBps, uint16 _exitFeeInBps, uint16 _lowWatermarkInBpsOfTvl, uint256 _bucketCapacity, uint256 _bucketRefillRate) external initializer {
        require(_exitFeeInBps <= BASIS_POINT_SCALE, "INVALID");
        require(_exitFeeSplitToTreasuryInBps <= BASIS_POINT_SCALE, "INVALID");
        require(_lowWatermarkInBpsOfTvl <= BASIS_POINT_SCALE, "INVALID");

        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    function initializeTokenParameters(address[] memory _tokens, uint16[] memory _exitFeeSplitToTreasuryInBps, uint16[] memory _exitFeeInBps, uint16[] memory _lowWatermarkInBpsOfTvl, uint256[] memory _bucketCapacity, uint256[] memory _bucketRefillRate)  external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        for(uint256 i = 0; i < _exitFeeSplitToTreasuryInBps.length; i++) {
            tokenToRedemptionInfo[address(_tokens[i])] = RedemptionInfo({
                limit: BucketLimiter.create(_convertToBucketUnit(_bucketCapacity[i], Math.Rounding.Down), _convertToBucketUnit(_bucketRefillRate[i], Math.Rounding.Down)),
                exitFeeSplitToTreasuryInBps: _exitFeeSplitToTreasuryInBps[i],
                exitFeeInBps: _exitFeeInBps[i],
                lowWatermarkInBpsOfTvl: _lowWatermarkInBpsOfTvl[i]
            });
        }
    }

    /**
     * @notice Redeems eETH for stETH.
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed stETH.
     */
    function redeemEEthForStETH(uint256 eEthAmount, address receiver) public whenNotPaused nonReentrant {
        _redeemEEth(eEthAmount, receiver, address(lido));
    }

    /**
     * @notice Redeems weETH for stETH.
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed stETH.
     */
    function redeemWeEthForStETH(uint256 weEthAmount, address receiver) public whenNotPaused nonReentrant {
        _redeemWeEth(weEthAmount, receiver, address(lido));
    }

    /**
     * @notice Redeems eETH for stETH with permit.
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed stETH.
     * @param permit The permit params.
     */
    function redeemEEthForStETHWithPermit(uint256 eEthAmount, address receiver, IeETH.PermitInput calldata permit) external whenNotPaused nonReentrant {
        try eEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {}
        _redeemEEth(eEthAmount, receiver, address(lido));
    }

    /**
     * @notice Redeems weETH for stETH with permit.
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed stETH.
     * @param permit The permit params.
     */
    function redeemWeEthForStETHWithPermit(uint256 weEthAmount, address receiver, IWeETH.PermitInput calldata permit) external whenNotPaused nonReentrant {
        try weEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s)  {} catch {}
        _redeemWeEth(weEthAmount, receiver, address(lido));
    }

    /**
     * @notice Redeems eETH for ETH.
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     */
    function redeemEEth(uint256 eEthAmount, address receiver) public whenNotPaused nonReentrant {
        _redeemEEth(eEthAmount, receiver, ETH_ADDRESS);
    }

    /**
     * @notice Redeems weETH for ETH.
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     */
    function redeemWeEth(uint256 weEthAmount, address receiver) public whenNotPaused nonReentrant {
        _redeemWeEth(weEthAmount, receiver, ETH_ADDRESS);
    }

    /**
     * @notice Redeems eETH for ETH with permit.
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     * @param permit The permit params.
     */
    function redeemEEthWithPermit(uint256 eEthAmount, address receiver, IeETH.PermitInput calldata permit) external whenNotPaused nonReentrant {
        try eEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {}
        _redeemEEth(eEthAmount, receiver, ETH_ADDRESS);
    }

    /**
     * @notice Redeems weETH for ETH.
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     * @param permit The permit params.
     */
    function redeemWeEthWithPermit(uint256 weEthAmount, address receiver, IWeETH.PermitInput calldata permit) external whenNotPaused nonReentrant {
        try weEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s)  {} catch {}
        _redeemWeEth(weEthAmount, receiver, ETH_ADDRESS);
    }

    function _processETHRedemption(
        address receiver,
        uint256 eEthAmountToReceiver,
        uint256 sharesToBurn,
        uint256 feeShareToStakers
    ) internal {
        uint256 prevBalance = address(this).balance;
        uint256 prevLpBalance = address(liquidityPool).balance;
        uint256 totalEEthShare = eEth.totalShares();

        // Withdraw ETH from the liquidity pool
        require(liquidityPool.withdraw(address(this), eEthAmountToReceiver) == sharesToBurn, "invalid num shares burnt");
        uint256 ethReceived = address(this).balance - prevBalance;

        // To Stakers by burning shares
        liquidityPool.burnEEthShares(feeShareToStakers);
        require(eEth.totalShares() >= 1 gwei && eEth.totalShares() == totalEEthShare - (sharesToBurn + feeShareToStakers), "EtherFiRedemptionManager: Invalid total shares");

        // To Receiver by transferring ETH, using gas 10k for additional safety
        (bool success, ) = receiver.call{value: ethReceived, gas: 10_000}("");
        require(success, "EtherFiRedemptionManager: Transfer failed");

        // Make sure the liquidity pool balance is correct && total shares are correct
        require(address(liquidityPool).balance == prevLpBalance - ethReceived, "EtherFiRedemptionManager: Invalid liquidity pool balance");
    }

    /**
     * @notice Processes stETH-specific redemption logic.
     */
    function _processStETHRedemption(
        address receiver,
        uint256 eEthAmountToReceiver,
        uint256 feeShareToStakers
    ) internal {
        uint256 totalEEthShare = eEth.totalShares();

        // For stETH redemption, we only burn shares for fee handling, no ETH withdrawal needed
        // To Stakers by burning shares
        liquidityPool.burnEEthShares(feeShareToStakers);
        
        // Validate total shares (no sharesToBurn since we don't withdraw from LP for stETH)
        require(eEth.totalShares() >= 1 gwei && eEth.totalShares() == totalEEthShare - feeShareToStakers, "EtherFiRedemptionManager: Invalid total shares");

        etherFiRestaker.transferStETH(receiver, eEthAmountToReceiver);
    }

    /**
     * @notice Redeems ETH.
     * @param ethAmount The amount of ETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     */
    function _redeem(uint256 ethAmount, uint256 eEthShares, address receiver, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury, address outputToken) internal {
        _updateRateLimit(ethAmount, outputToken);
        {
        // Derive additionals
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToStakers = eEthShareFee - feeShareToTreasury;

        if(outputToken == ETH_ADDRESS) {
            _processETHRedemption(receiver, eEthAmountToReceiver, sharesToBurn, feeShareToStakers);
        } else if(outputToken == address(lido)) {
            _processStETHRedemption(receiver, eEthAmountToReceiver, feeShareToStakers);
        }
        // Common fee handling: Transfer to Treasury
        IERC20(address(eEth)).safeTransfer(treasury, eEthFeeAmountToTreasury);
        }

        emit Redeemed(receiver, ethAmount, eEthFeeAmountToTreasury, eEthAmountToReceiver, outputToken);
    }

    /**
     * @dev if the contract has less than the low watermark, it will not allow any instant redemption.
     */
    function lowWatermarkInETH(address token) public view returns (uint256) {
        return liquidityPool.getTotalPooledEther().mulDiv(tokenToRedemptionInfo[token].lowWatermarkInBpsOfTvl, BASIS_POINT_SCALE);
    }

    function getInstantLiquidityAmount(address token) public view returns (uint256) {
        if(token == ETH_ADDRESS) {
            return address(liquidityPool).balance - liquidityPool.ethAmountLockedForWithdrawal();
        } else if (token == address(lido)) {
            return lido.balanceOf(address(etherFiRestaker));
        }
    }

    /**
     * @dev Returns the total amount that can be redeemed.
     */
    function totalRedeemableAmount(address token) external view returns (uint256) {
        uint256 liquidEthAmount = getInstantLiquidityAmount(token);

        if (liquidEthAmount < lowWatermarkInETH(token)) {
            return 0;
        }
        uint64 consumableBucketUnits = BucketLimiter.consumable(tokenToRedemptionInfo[token].limit);
        uint256 consumableAmount = _convertFromBucketUnit(consumableBucketUnits);
        return Math.min(consumableAmount, liquidEthAmount);
    }

    /**
     * @dev Returns whether the given amount can be redeemed.
     * @param amount The ETH or eETH amount to check.
     */
    function canRedeem(uint256 amount, address token) public view returns (bool) {
        uint256 liquidEthAmount = getInstantLiquidityAmount(token);
        if (liquidEthAmount < lowWatermarkInETH(token)) {
            return false;
        }
        uint64 bucketUnit = _convertToBucketUnit(amount, Math.Rounding.Up);
        bool consumable = BucketLimiter.canConsume(tokenToRedemptionInfo[token].limit, bucketUnit);
        return consumable && amount <= liquidEthAmount;
    }

    /**
     * @dev Sets the maximum size of the bucket that can be consumed in a given time period.
     * @param capacity The capacity of the bucket.
     */
    function setCapacity(uint256 capacity, address token) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether, which is practically enough
        uint64 bucketUnit = _convertToBucketUnit(capacity, Math.Rounding.Down);
        BucketLimiter.setCapacity(tokenToRedemptionInfo[token].limit, bucketUnit);
    }

    /**
     * @dev Sets the rate at which the bucket is refilled per second.
     * @param refillRate The rate at which the bucket is refilled per second.
     */
    function setRefillRatePerSecond(uint256 refillRate, address token) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        // max refillRate = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether per second, which is practically enough
        uint64 bucketUnit = _convertToBucketUnit(refillRate, Math.Rounding.Down);
        BucketLimiter.setRefillRate(tokenToRedemptionInfo[token].limit, bucketUnit);
    }

    /**
     * @dev Sets the exit fee.
     * @param _exitFeeInBps The exit fee.
     */
    function setExitFeeBasisPoints(uint16 _exitFeeInBps, address token) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        require(_exitFeeInBps <= BASIS_POINT_SCALE, "INVALID");
        tokenToRedemptionInfo[token].exitFeeInBps = _exitFeeInBps;
    }

    function setLowWatermarkInBpsOfTvl(uint16 _lowWatermarkInBpsOfTvl, address token) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        require(_lowWatermarkInBpsOfTvl <= BASIS_POINT_SCALE, "INVALID");
        tokenToRedemptionInfo[token].lowWatermarkInBpsOfTvl = _lowWatermarkInBpsOfTvl;
    }

    function setExitFeeSplitToTreasuryInBps(uint16 _exitFeeSplitToTreasuryInBps, address token) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        require(_exitFeeSplitToTreasuryInBps <= BASIS_POINT_SCALE, "INVALID");
        tokenToRedemptionInfo[token].exitFeeSplitToTreasuryInBps = _exitFeeSplitToTreasuryInBps;
    }

    function pauseContract() external hasRole(roleRegistry.PROTOCOL_PAUSER()) {
        _pause();
    }

    function unPauseContract() external hasRole(roleRegistry.PROTOCOL_UNPAUSER()) {
        _unpause();
    }

    function _redeemEEth(uint256 eEthAmount, address receiver, address outputToken) internal {
        require(eEthAmount <= eEth.balanceOf(msg.sender), "EtherFiRedemptionManager: Insufficient balance");
        require(canRedeem(eEthAmount, outputToken), "EtherFiRedemptionManager: Exceeded total redeemable amount");

        (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) = _calcRedemption(eEthAmount, outputToken);

        IERC20(address(eEth)).safeTransferFrom(msg.sender, address(this), eEthAmount);

        _redeem(eEthAmount, eEthShares, receiver, eEthAmountToReceiver, eEthFeeAmountToTreasury, sharesToBurn, feeShareToTreasury, outputToken);
    }

    function _redeemWeEth(uint256 weEthAmount, address receiver, address outputToken) internal {
        uint256 eEthAmount = weEth.getEETHByWeETH(weEthAmount);
        require(weEthAmount <= weEth.balanceOf(msg.sender), "EtherFiRedemptionManager: Insufficient balance");
        require(canRedeem(eEthAmount, outputToken), "EtherFiRedemptionManager: Exceeded total redeemable amount");

        (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) = _calcRedemption(eEthAmount, outputToken);

        IERC20(address(weEth)).safeTransferFrom(msg.sender, address(this), weEthAmount);
        weEth.unwrap(weEthAmount);

        _redeem(eEthAmount, eEthShares, receiver, eEthAmountToReceiver, eEthFeeAmountToTreasury, sharesToBurn, feeShareToTreasury, outputToken);
    }


    function _updateRateLimit(uint256 amount, address token) internal {
        uint64 bucketUnit = _convertToBucketUnit(amount, Math.Rounding.Up);
        require(BucketLimiter.consume(tokenToRedemptionInfo[token].limit, bucketUnit), "BucketRateLimiter: rate limit exceeded");
    }

    function _convertToBucketUnit(uint256 amount, Math.Rounding rounding) internal pure returns (uint64) {
        require(amount < type(uint64).max * BUCKET_UNIT_SCALE, "EtherFiRedemptionManager: Amount too large");
        return (rounding == Math.Rounding.Up) ? SafeCast.toUint64((amount + BUCKET_UNIT_SCALE - 1) / BUCKET_UNIT_SCALE) : SafeCast.toUint64(amount / BUCKET_UNIT_SCALE);
    }

    function _convertFromBucketUnit(uint64 bucketUnit) internal pure returns (uint256) {
        return bucketUnit * BUCKET_UNIT_SCALE;
    }


    function _calcRedemption(uint256 ethAmount, address token) internal view returns (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) {
        eEthShares = liquidityPool.sharesForAmount(ethAmount);
        eEthAmountToReceiver = liquidityPool.amountForShare(eEthShares.mulDiv(BASIS_POINT_SCALE - tokenToRedemptionInfo[token].exitFeeInBps, BASIS_POINT_SCALE)); // ethShareToReceiver

        sharesToBurn = liquidityPool.sharesForWithdrawalAmount(eEthAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        feeShareToTreasury = eEthShareFee.mulDiv(tokenToRedemptionInfo[token].exitFeeSplitToTreasuryInBps, BASIS_POINT_SCALE);
        eEthFeeAmountToTreasury = liquidityPool.amountForShare(feeShareToTreasury);
    }

    /**
     * @dev Preview taking an exit fee on redeem. See {IERC4626-previewRedeem}.
     */
    // redeemable amount after exit fee
    function previewRedeem(uint256 shares, address token) public view returns (uint256) {
        uint256 amountInEth = liquidityPool.amountForShare(shares);
        return amountInEth - _fee(amountInEth, tokenToRedemptionInfo[token].exitFeeInBps);
    }

    function _fee(uint256 assets, uint256 feeBasisPoints) internal pure virtual returns (uint256) {
        return assets.mulDiv(feeBasisPoints, BASIS_POINT_SCALE, Math.Rounding.Up);
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _hasRole(bytes32 role, address account) internal view returns (bool) {
        require(roleRegistry.hasRole(role, account), "EtherFiRedemptionManager: Unauthorized");
    }

    modifier hasRole(bytes32 role) {
        _hasRole(role, msg.sender);
        _;
    }

}

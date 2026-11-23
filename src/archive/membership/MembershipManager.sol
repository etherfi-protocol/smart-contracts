// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/archive/membership/interfaces/IMembershipManager.sol";
import "@etherfi/archive/membership/interfaces/IMembershipNFT.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/Pausable.sol";
import "@etherfi/governance/utils/DeprecatedOZPausable.sol";

import "forge-std/console.sol";

contract MembershipManager is Initializable, OwnableUpgradeable, DeprecatedOZPausable, UUPSUpgradeable, IMembershipManager, Pausable {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    // deprecated storage slots
    uint256[5] private __gap_0;

    mapping (uint256 => uint256) public allTimeHighDepositAmount;
    mapping (uint256 => TokenDeposit) public tokenDeposits;
    mapping (uint256 => TokenData) public tokenData;
    TierDeposit[] public tierDeposits;
    TierData[] public tierData;

    uint16 public pointsBoostFactor; // + (X / 10000) more points, if staking rewards are sacrificed
    uint16 public pointsGrowthRate; // + (X / 10000) kwei points are earned per ETH per day
    uint56 public minDepositGwei;
    uint8  public maxDepositTopUpPercent;

    uint16 private mintFee; // fee = 0.001 ETH * 'mintFee'
    uint16 private burnFee; // fee = 0.001 ETH * 'burnFee'
    uint16 private upgradeFee; // fee = 0.001 ETH * 'upgradeFee'

    // deprecated storage slots
    uint16 private __gap_1;

    uint32 public topUpCooltimePeriod;
    uint32 public withdrawalLockBlocks;

    uint16 private fanBoostThreshold; // = 0.001 ETH * fanBoostThreshold
    uint16 private burnFeeWaiverPeriodInDays;

    // deprecated storage slots
    uint256[3] private __gap_2;

    TierVault[] public tierVaults;

    // deprecated storage slots
    uint160 private __gap_3;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------

    IeETH public immutable eETH;
    ILiquidityPool public immutable liquidityPool;
    IMembershipNFT public immutable membershipNFT;
    IBlacklister public immutable blacklister;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant FEE_UNIT = 0.001 ether;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event FundsMigrated(address indexed user, uint256 _tokenId, uint256 _amount, uint256 _eapPoints, uint40 _loyaltyPoints, uint40 _tierPoints);
    event NftUpdated(uint256 _tokenId, uint128 _amount, uint128 _amountSacrificedForBoostingPoints, uint40 _loyaltyPoints, uint40 _tierPoints, uint8 _tier, uint32 _prevTopUpTimestamp, uint96 _share);
    event NftUnwrappedForEEth(address indexed _user, uint256 indexed _tokenId, uint256 _amountOfEEth, uint40 _loyaltyPoints, uint256 _feeAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _eETH, address _liquidityPool, address _membershipNFT, address _roleRegistry, address _blacklister) RolesLibrary(_roleRegistry) {
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipNFT = IMembershipNFT(_membershipNFT);
        blacklister = IBlacklister(_blacklister);
        _disableInitializers();
    }

    receive() external payable {}

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    error Deprecated();
    error WrongVersion();
    error InvalidEAPRollover();

    error InvalidAmount();
    error InsufficientBalance();

    error ExceededMaxWithdrawal();
    error TierLimitExceeded();
    error OutOfBound();
    error WrongTokenMinted();
    error UnexpectedTier();
    error OnlyTokenOwner();
    error LengthMismatch();
    error TierVaultsNotEmpty();
    error AddressZero();
    error SendFail();

    event NftForceExited(address indexed _owner, uint256 indexed _tokenId, uint256 _amountOfEEth, uint256 _feeAmount);
    event RemainingFundsSwept(address indexed _recipient, uint256 _eEthAmount, uint256 _ethAmount);

    /// @notice Force-exits membership NFTs during the membership wind-down.
    /// @dev Burns each NFT from its owner and transfers the eETH backing it, minus the burn fee, to that owner.
    ///      The fee stays in this contract as eETH and leaves through {sweepRemainingFunds}.
    ///      The fee is capped at the NFT's value so every NFT can exit.
    /// @param _tokenIds The IDs of the membership NFTs to exit.
    /// @param _owners The current owner of each NFT, in the same order as `_tokenIds`.
    function forceExit(uint256[] calldata _tokenIds, address[] calldata _owners) external onlyOperatingMultisig {
        if (_tokenIds.length != _owners.length) revert LengthMismatch();
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            _forceExit(_tokenIds[i], _owners[i]);
        }
    }

    /// @notice Sends the eETH and ETH left in this contract to `_recipient` once every NFT has exited.
    /// @dev Reverts while any tier vault still has vault shares, i.e. while any membership NFT remains.
    /// @param _recipient The address that receives the remaining funds.
    function sweepRemainingFunds(address _recipient) external onlyOperatingMultisig {
        if (_recipient == address(0)) revert AddressZero();
        for (uint256 i = 0; i < tierVaults.length; i++) {
            if (tierVaults[i].totalVaultShares != 0) revert TierVaultsNotEmpty();
        }

        uint256 eEthAmount = eETH.balanceOf(address(this));
        uint256 ethAmount = address(this).balance;
        if (eEthAmount > 0) IERC20(address(eETH)).safeTransfer(_recipient, eEthAmount);
        if (ethAmount > 0) {
            (bool sent, ) = _recipient.call{value: ethAmount}("");
            if (!sent) revert SendFail();
        }

        emit RemainingFundsSwept(_recipient, eEthAmount, ethAmount);
    }

    /// @dev set how many blocks a token is locked from trading for after withdrawing
    function setWithdrawalLockBlocks(uint32 _blocks) external onlyOperatingMultisig {
        withdrawalLockBlocks = _blocks;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------
    function _forceExit(uint256 _tokenId, address _owner) internal {
        if (membershipNFT.balanceOfUser(_owner, _tokenId) != 1) revert OnlyTokenOwner();
        TokenData memory token = tokenData[_tokenId];
        if (token.version != 1) revert WrongVersion();

        uint256 eEthShare = eEthShareForVaultShare(token.tier, token.vaultShare);
        uint256 ethAmount = liquidityPool.amountForShare(eEthShare);
        uint256 feeAmount = hasMetBurnFeeWaiverPeriod(_tokenId) ? 0 : _min(uint256(burnFee) * FEE_UNIT, ethAmount);

        _decrementTierVaultV1(token.tier, eEthShare, token.vaultShare);
        delete tokenData[_tokenId];
        membershipNFT.burn(_owner, _tokenId, 1);

        if (ethAmount > feeAmount) IERC20(address(eETH)).safeTransfer(_owner, ethAmount - feeAmount);

        emit NftForceExited(_owner, _tokenId, ethAmount - feeAmount, feeAmount);
    }

    // V1
    function _decrementTierVaultV1(uint8 _tier, uint256 _eEthShare, uint256 _vaultShare) internal {
        tierVaults[_tier].totalVaultShares -= uint128(_vaultShare);
        tierVaults[_tier].totalPooledEEthShares -= uint128(_eEthShare);
    }

    function eEthShareForVaultShare(uint8 _tier, uint256 _vaultShare) public view returns (uint256) {
        uint256 amount;
        if (tierVaults[_tier].totalVaultShares == 0) {
            amount = 0;
        } else {
            amount = (_vaultShare * tierVaults[_tier].totalPooledEEthShares) / tierVaults[_tier].totalVaultShares;
        }
        return amount;
    }

    function vaultShareForEEthShare(uint8 _tier, uint256 _eEthShare) public view returns (uint256) {
        uint256 vaultShare;
        if (tierVaults[_tier].totalPooledEEthShares == 0) {
            vaultShare = _eEthShare;
        } else {
            vaultShare = (_eEthShare * tierVaults[_tier].totalVaultShares) / tierVaults[_tier].totalPooledEEthShares;
        }
        return vaultShare;
    }

    function ethAmountForVaultShare(uint8 _tier, uint256 _vaultShare) public view returns (uint256) {
        uint256 eEthShare = eEthShareForVaultShare(_tier, _vaultShare);
        return liquidityPool.amountForShare(eEthShare);
    }

    function vaultShareForEthAmount(uint8 _tier, uint256 _ethAmount) public view returns (uint256) {
        uint256 eEthshare = liquidityPool.sharesForAmount(_ethAmount);
        return vaultShareForEEthShare(_tier, eEthshare);
    }

    function fanBoostThresholdEthAmount() public view returns (uint256) {
        return uint256(fanBoostThreshold) * FEE_UNIT;
    }

    function hasMetBurnFeeWaiverPeriod(uint256 _tokenId) public view returns (bool) {
        uint256 stakingPeriod = membershipNFT.tierPointsOf(_tokenId) / 24;
        return stakingPeriod >= burnFeeWaiverPeriodInDays;
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    // Finds the corresponding for the tier points
    function tierForPoints(uint40 _tierPoints) public view returns (uint8) {
        uint8 tierId = 0;

        while (tierId < tierData.length && _tierPoints >= tierData[tierId].requiredTierPoints) {
            tierId++;
        }

        return tierId - 1;
    }

    function numberOfTiers() external view returns (uint8) {
        return uint8(tierData.length);
    }

    function minimumAmountForMint() external view returns (uint256) {
        return uint256(1 gwei) * minDepositGwei;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    // returns (mintFeeAmount, burnFeeAmount, upgradeFeeAmount)
    function getFees() external view returns (uint256 mintFeeAmount, uint256 burnFeeAmount, uint256 upgradeFeeAmount) {
        return (uint256(mintFee) * FEE_UNIT, uint256(burnFee) * FEE_UNIT, uint256(upgradeFee) * FEE_UNIT);
    }

    function rewardsGlobalIndex(uint8 _tier) external view returns (uint256) {
        return tierData[_tier].rewardsGlobalIndex;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

}

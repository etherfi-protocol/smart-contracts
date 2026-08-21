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

    function unwrapForEEthAndBurn(uint256 _tokenId) external whenNotPaused nonBlacklisted {
        _requireTokenOwner(_tokenId);

        uint40 loyaltyPoints = membershipNFT.loyaltyPointsOf(_tokenId);
        (uint256 totalBalance, uint256 feeAmount) = _withdrawAndBurn(_tokenId);

        // transfer 'eEthShares' of eETH to the owner
        IERC20(address(eETH)).safeTransfer(msg.sender, totalBalance - feeAmount);

        if (feeAmount > 0) {
            liquidityPool.withdraw(address(this), feeAmount);
        }

        emit NftUnwrappedForEEth(msg.sender, _tokenId, totalBalance - feeAmount, loyaltyPoints, feeAmount);
    }

    error ExceededMaxWithdrawal();
    error TierLimitExceeded();
    error OutOfBound();
    error WrongTokenMinted();
    error UnexpectedTier();
    error OnlyTokenOwner();

    /// @notice Requests exchange of membership points tokens for ETH.
    /// @dev decrements the amount of eETH backing the membership NFT and calls requestWithdraw on the liquidity pool
    /// @param _tokenId The ID of the membership NFT.
    /// @param _amount The amount of membership tokens to exchange.
    /// @return uint256 ID of the withdraw request NFT
    function requestWithdraw(uint256 _tokenId, uint256 _amount) external whenNotPaused nonBlacklisted returns (uint256) {
        _requireTokenOwner(_tokenId);

        // prevent transfers for several blocks after a withdrawal to prevent frontrunning
        membershipNFT.incrementLock(_tokenId, withdrawalLockBlocks);

        claim(_tokenId);
        if (!membershipNFT.isWithdrawable(_tokenId, _amount)) revert ExceededMaxWithdrawal();

        uint256 prevAmount = ethAmountForVaultShare(tokenData[_tokenId].tier, tokenData[_tokenId].vaultShare);
        _updateAllTimeHighDepositOf(_tokenId);
        _withdraw(_tokenId, _amount);
        _applyUnwrapPenalty(_tokenId, prevAmount, _amount);

        // send EETH to recipient before requesting withdraw?
        IERC20(address(eETH)).safeIncreaseAllowance(address(liquidityPool), _amount);
        uint256 withdrawTokenId = liquidityPool.requestMembershipNFTWithdraw(address(msg.sender), _amount, uint64(0));

        _emitNftUpdateEvent(_tokenId);
        return withdrawTokenId;
    }

    /// @notice request to withdraw the entire balance of this NFT and burn it
    /// @dev burns the NFT and calls requestWithdraw on the liquidity pool
    /// @param _tokenId ID of the membership NFT to liquidate
    /// @return uint256 ID of the withdraw request NFT
    function requestWithdrawAndBurn(uint256 _tokenId) external whenNotPaused nonBlacklisted returns (uint256) {
        _requireTokenOwner(_tokenId);

        (uint256 totalBalance, uint256 feeAmount) = _withdrawAndBurn(_tokenId);

        IERC20(address(eETH)).safeIncreaseAllowance(address(liquidityPool), totalBalance);
        uint256 withdrawTokenId = liquidityPool.requestMembershipNFTWithdraw(msg.sender, totalBalance, feeAmount);
        
        return withdrawTokenId;
    }

    /// @notice Claims {points, staking rewards} and update the tier, if needed.
    /// @param _tokenId The ID of the membership NFT.
    /// @dev This function allows users to claim the rewards + a new tier, if eligible.
    function claim(uint256 _tokenId) public whenNotPaused nonBlacklisted {
        _claimPoints(_tokenId);

        uint8 oldTier = tokenData[_tokenId].tier;
        uint8 newTier = membershipNFT.claimableTier(_tokenId);
        if (oldTier != newTier) {
            _claimTier(_tokenId, oldTier, newTier);
        }
        _emitNftUpdateEvent(_tokenId);
    }

    function claimBatch(uint256[] calldata _tokenIds) public whenNotPaused {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            claim(_tokenIds[i]);
        }
    }

    /// @dev set how many blocks a token is locked from trading for after withdrawing
    function setWithdrawalLockBlocks(uint32 _blocks) external onlyOperatingMultisig {
        withdrawalLockBlocks = _blocks;
    }

    //--------------------------------------------------------------------------------------
    //--------------------------  DEPRECATION MIGRATION  -----------------------------------
    //--------------------------------------------------------------------------------------

    error LengthMismatch();
    error NothingToSweep();
    error ZeroRecipient();
    error OnlySelf();
    error LegacyPositionsOutstanding();
    error EtherSweepFailed();
    error WorthlessPosition();

    event NftForceUnwrapped(address indexed holder, uint256 indexed tokenId, uint256 amountOfEEth);
    event NftForceUnwrapSkipped(address indexed holder, uint256 indexed tokenId, bytes reason);
    event ForceUnwrapHalted(uint256 stoppedAtIndex, uint256 batchLength);
    event ForceUnwrapBatchResult(uint256 batchLength, uint256 unwrapped, uint256 skipped);
    event UnbackedEEthSwept(address indexed recipient, uint256 amount);
    event EtherSwept(address indexed recipient, uint256 amount);

    /// @dev Gas kept in reserve per batch item so a starved item is reported as a skip rather than
    ///      consuming the outer frame. Covers the burn, the eETH transfer, and the event.
    uint256 private constant FORCE_UNWRAP_GAS_FLOOR = 400_000;

    /// @notice Burns membership NFTs and pays each holder the eETH backing its position.
    /// @param _holders The current holder of each token, in the same order as _tokenIds
    /// @param _tokenIds The membership NFTs to unwrap
    /// @dev Terminal migration step for deprecating this contract. MembershipNFT is ERC1155 with no
    ///      owner index, so holders are supplied by the caller and verified here against
    ///      balanceOfUser -- a wrong holder is skipped, never paid.
    /// @dev Each item is isolated so one failure cannot block the batch: a blacklisted holder fails
    ///      the eETH transfer, and a legacy row fails the version check. Every skip is emitted with
    ///      its revert reason for off-chain retry.
    /// @return unwrapped How many positions were burned and paid
    /// @return skipped How many were skipped, each with a NftForceUnwrapSkipped event naming why
    function forceUnwrapForEEth(address[] calldata _holders, uint256[] calldata _tokenIds)
        external
        onlyOperatingTimelock
        returns (uint256 unwrapped, uint256 skipped)
    {
        if (_holders.length != _tokenIds.length) revert LengthMismatch();

        uint256 i;
        for (i = 0; i < _holders.length; i++) {
            // Stop rather than revert: the items already unwrapped are valid work, and this call
            // sits behind a timelock, so discarding them would cost another full delay to redo.
            if (gasleft() < FORCE_UNWRAP_GAS_FLOOR) {
                // Without this the truncation is invisible -- a batch stopped at item 5 of 50 looks
                // exactly like a 5-item batch that ran to completion.
                emit ForceUnwrapHalted(i, _holders.length);
                break;
            }

            try this.forceUnwrapOne(_holders[i], _tokenIds[i]) {
                unwrapped++;
            } catch (bytes memory reason) {
                skipped++;
                emit NftForceUnwrapSkipped(_holders[i], _tokenIds[i], reason);
            }
        }

        // Reported rather than enforced. An earlier version reverted when nothing was unwrapped, to
        // catch a global precondition failing (eETH paused, this contract blacklisted). That was
        // worse on both counts: the revert discarded the very skip events that say why, and it
        // handed any holder a veto over a queued governance call -- transfer the NFT out before the
        // timelock ETA, the item skips, and a single-item retry batch reverts, burning a full delay
        // for the price of one ERC1155 transfer. Simulate the batch before queueing instead.
        emit ForceUnwrapBatchResult(_holders.length, unwrapped, skipped);
    }

    /// @notice Burns one membership NFT and pays its holder the eETH backing it.
    /// @dev External only so forceUnwrapForEEth can isolate each item behind try/catch; a revert
    ///      here rolls back just this token. Restricted to self-calls, so the timelock gate on the
    ///      batch entrypoint is the only way in.
    function forceUnwrapOne(address _holder, uint256 _tokenId) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (membershipNFT.balanceOfUser(_holder, _tokenId) != 1) revert OnlyTokenOwner();
        if (tokenData[_tokenId].version != 1) revert WrongVersion();

        uint8 tier = tokenData[_tokenId].tier;
        uint256 vaultShare = tokenData[_tokenId].vaultShare;

        // Decrement the vault by this token's exact recorded share. _withdraw would instead
        // round-trip share -> eth -> share, leaving a slice of the token's share stranded in
        // tierVaults after the token row is deleted.
        uint256 eEthShare = eEthShareForVaultShare(tier, vaultShare);
        uint256 amount = liquidityPool.amountForShare(eEthShare);

        // A position with recorded share that prices to nothing must not be destroyed for nothing.
        // eEthShareForVaultShare returns 0 for any input once a tier's totalPooledEEthShares hits
        // zero, and the burn below is unconditional, so without this the NFT is shredded and the
        // row deleted while the holder is paid 0 -- emitted as a successful unwrap. The sibling
        // voluntary path fails closed here via _withdraw's balance check; this one must too.
        if (amount == 0 && vaultShare != 0) revert WorthlessPosition();

        _decrementTierVaultV1(tier, eEthShare, vaultShare);
        delete tokenData[_tokenId];

        // Burns skip MembershipNFT._beforeTokenTransfer, so a transfer lock or an NFT-level
        // blacklist entry does not block this. eETH's own blacklist still applies to the transfer
        // below, which is why the caller isolates each item.
        membershipNFT.burn(_holder, _tokenId, 1);

        if (amount > 0) IERC20(address(eETH)).safeTransfer(_holder, amount);

        emit NftForceUnwrapped(_holder, _tokenId, amount);
    }

    /// @notice eETH still owed to unburned membership positions, in eETH.
    /// @dev Derived from the tier vaults rather than a running total, so it cannot drift from the
    ///      accounting the payouts actually consume.
    function outstandingEEthObligation() public view returns (uint256) {
        uint256 shares;
        for (uint256 t = 0; t < tierVaults.length; t++) {
            // A tier with no vault shares left has no holder who can draw from it:
            // eEthShareForVaultShare divides by totalVaultShares and every member share is zero,
            // so whatever pooled dust remains is unclaimable. Counting it as owed would put a
            // permanent floor under the obligation and make the residual unsweepable forever.
            if (tierVaults[t].totalVaultShares == 0) continue;
            shares += tierVaults[t].totalPooledEEthShares;
        }
        return liquidityPool.amountForShare(shares);
    }

    /// @notice eETH held by this contract beyond what unburned positions can claim.
    function unbackedEEth() public view returns (uint256) {
        uint256 balance = IERC20(address(eETH)).balanceOf(address(this));
        uint256 owed = outstandingEEthObligation();
        return balance > owed ? balance - owed : 0;
    }

    /// @notice Sweeps eETH that no membership position can claim.
    /// @param _recipient Where to send it, normally the treasury
    /// @return amount The eETH swept
    /// @dev Only ever moves the surplus over outstandingEEthObligation(), so it cannot take eETH
    ///      backing a position that has not been unwrapped yet. That bound is what makes this safe
    ///      to hold behind governance rather than requiring every holder to be paid out first.
    function sweepUnbackedEEth(address _recipient) external onlyOperatingTimelock returns (uint256) {
        if (_recipient == address(0)) revert ZeroRecipient();

        // outstandingEEthObligation() reads only the V1 tier vaults. V0 positions are permanently
        // unredeemable, so today they are owed nothing and every tierDeposits entry is zero. This
        // makes that assumption fail closed instead of silently treating V0 backing as surplus.
        // Both legs are checked: `shares` is derived from `amounts` and floors to zero for small
        // balances, so testing `shares` alone would pass a tier still holding V0 principal.
        for (uint256 t = 0; t < tierDeposits.length; t++) {
            if (tierDeposits[t].shares != 0 || tierDeposits[t].amounts != 0) revert LegacyPositionsOutstanding();
        }

        uint256 amount = unbackedEEth();
        if (amount == 0) revert NothingToSweep();

        IERC20(address(eETH)).safeTransfer(_recipient, amount);

        emit UnbackedEEthSwept(_recipient, amount);
        return amount;
    }

    /// @notice Sweeps the contract's ETH balance.
    /// @param _recipient Where to send it, normally the treasury
    /// @return amount The ETH swept
    /// @dev No membership position is ever denominated in ETH -- the balance is accumulated burn
    ///      fees, routed in by unwrapForEEthAndBurn, plus whatever `receive()` accepted. Without
    ///      this the migration strands that ETH with no exit short of another UUPS upgrade, which
    ///      is a higher-privilege and slower path than the sweep it should ship beside.
    function sweepEther(address _recipient) external onlyOperatingTimelock returns (uint256) {
        // Sweeping to self would succeed through receive(), leaving the balance untouched while
        // emitting an EtherSwept event claiming it moved -- and that event is the migration's only
        // audit trail.
        if (_recipient == address(0) || _recipient == address(this)) revert ZeroRecipient();

        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();

        (bool ok, ) = _recipient.call{value: amount}("");
        if (!ok) revert EtherSweepFailed();

        emit EtherSwept(_recipient, amount);
        return amount;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------
    function _withdrawAndBurn(uint256 _tokenId) internal returns (uint256, uint256) {
        if (tokenData[_tokenId].version != 1) revert WrongVersion();

        uint8 tier = tokenData[_tokenId].tier;
        uint256 vaultShare = tokenData[_tokenId].vaultShare;
        uint256 ethAmount = ethAmountForVaultShare(tier, vaultShare);
        uint256 feeAmount = hasMetBurnFeeWaiverPeriod(_tokenId) ? 0 : uint256(burnFee) * FEE_UNIT;
        if (ethAmount < feeAmount) revert InsufficientBalance();

        _withdraw(_tokenId, ethAmount);
        delete tokenData[_tokenId];

        membershipNFT.burn(msg.sender, _tokenId, 1);

        _emitNftUpdateEvent(_tokenId);

        return (ethAmount, feeAmount);
    }

    function _withdraw(uint256 _tokenId, uint256 _amount) internal {
        if (membershipNFT.valueOf(_tokenId) < _amount) revert InsufficientBalance();
        if (tokenData[_tokenId].version != 1) revert WrongVersion();

        uint8 tier = tokenData[_tokenId].tier;
        uint256 vaultShare = vaultShareForEthAmount(tier, _amount);
        uint256 eEthShare = liquidityPool.sharesForAmount(_amount);

        _decrementTierVaultV1(tier, eEthShare, vaultShare);
        _decrementTokenVaultShareV1(_tokenId, vaultShare);        
    }

    // V1
    function _decrementTokenVaultShareV1(uint256 _tokenId, uint256 _share) internal {
        tokenData[_tokenId].vaultShare -= uint96(_share);
    }

    function _incrementTierVaultV1(uint8 _tier, uint256 _eEthShare, uint256 _vaultShare) internal {
        tierVaults[_tier].totalVaultShares += uint128(_vaultShare);
        tierVaults[_tier].totalPooledEEthShares += uint128(_eEthShare);
    }

    function _decrementTierVaultV1(uint8 _tier, uint256 _eEthShare, uint256 _vaultShare) internal {
        tierVaults[_tier].totalVaultShares -= uint128(_vaultShare);
        tierVaults[_tier].totalPooledEEthShares -= uint128(_eEthShare);
    }

    function _claimTier(uint256 _tokenId) internal {
        uint8 oldTier = tokenData[_tokenId].tier;
        uint8 newTier = membershipNFT.claimableTier(_tokenId);
        _claimTier(_tokenId, oldTier, newTier);
    }

    function _claimTier(uint256 _tokenId, uint8 _curTier, uint8 _newTier) internal {
        if (tokenData[_tokenId].tier != _curTier) revert UnexpectedTier();
        if (_curTier == _newTier) {
            return;
        }
        
        uint256 prevVaultShare = tokenData[_tokenId].vaultShare;
        uint256 eEthShare = eEthShareForVaultShare(_curTier, prevVaultShare);
        uint256 newVaultShare = vaultShareForEEthShare(_newTier, eEthShare);

        _decrementTierVaultV1(_curTier, eEthShare, prevVaultShare);
        _incrementTierVaultV1(_newTier, eEthShare, newVaultShare);
        tokenData[_tokenId].vaultShare = uint96(newVaultShare);
        tokenData[_tokenId].tier = _newTier;
    }

    /// @notice Claims the accrued membership {loyalty, tier} points.
    /// @param _tokenId The ID of the membership NFT.
    function _claimPoints(uint256 _tokenId) internal {
        TokenData storage token = tokenData[_tokenId];
        token.baseLoyaltyPoints = membershipNFT.loyaltyPointsOf(_tokenId);
        token.baseTierPoints = membershipNFT.tierPointsOf(_tokenId);
        token.prevPointsAccrualTimestamp = uint32(block.timestamp);
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

    function _updateAllTimeHighDepositOf(uint256 _tokenId) internal {
        allTimeHighDepositAmount[_tokenId] = membershipNFT.allTimeHighDepositOf(_tokenId);
    }

    function _requireTokenOwner(uint256 _tokenId) internal view {
        if (membershipNFT.balanceOfUser(msg.sender, _tokenId) != 1) revert OnlyTokenOwner();
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    function _max(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _a : _b;
    }

    /// @notice Applies the unwrap penalty.
    /// @dev Always lose at least a tier, possibly more depending on percentage of deposit withdrawn
    /// @param _tokenId The ID of the membership NFT.
    /// @param _prevAmount The amount of ETH that the NFT was holding
    /// @param _withdrawalAmount The amount of ETH that is being withdrawn
    function _applyUnwrapPenalty(uint256 _tokenId, uint256 _prevAmount, uint256 _withdrawalAmount) internal {
        TokenData storage token = tokenData[_tokenId];
        uint8 prevTier = token.tier > 0 ? token.tier - 1 : 0;
        uint40 curTierPoints = token.baseTierPoints;

        // point deduction if we kick back to start of previous tier
        uint40 degradeTierPenalty = curTierPoints - tierData[prevTier].requiredTierPoints;

        // point deduction if scaled proportional to withdrawal amount
        uint256 ratio = (BASIS_POINTS_DENOMINATOR * _withdrawalAmount) / _prevAmount;
        uint40 scaledTierPointsPenalty = uint40((ratio * curTierPoints) / BASIS_POINTS_DENOMINATOR);

        uint40 penalty = uint40(_max(degradeTierPenalty, scaledTierPointsPenalty));

        token.baseTierPoints -= penalty;
        _claimTier(_tokenId);
    }

    function _emitNftUpdateEvent(uint256 _tokenId) internal {
        uint128 amount = uint128(membershipNFT.valueOf(_tokenId));
        TokenData memory token = tokenData[_tokenId];
        emit NftUpdated(_tokenId, amount, 0,
                        token.baseLoyaltyPoints, token.baseTierPoints, token.tier,
                        token.prevTopUpTimestamp, token.vaultShare);
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

    //--------------------------------------------------------------------------------------
    //------------------------------------  MODIFIER  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import "@etherfi/membership/interfaces/IMembershipManager.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Checkpoints.sol";
import "@etherfi/governance/utils/ReentrancyGuardNamespaced.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";

/// @title WithdrawRequestNFT — share-rate-freeze invariants
/// @notice
/// Once `finalizeRequests(lastRequestId)` runs, the rate used to compute the claim payout
/// for tokenIds <= lastRequestId is frozen at the rate snapshotted in that finalize batch.
/// Subsequent rebases do NOT move the claim payout — this is the H-02 fix.
///
/// Invariants:
///  I1. `_finalizationRates` keys are strictly increasing. Enforced by the
///      `requestId > lastFinalizedRequestId` guard in `finalizeRequests` and by
///      `Checkpoints.push` semantics.
///  I2. `_finalizationRates.lowerLookup(tokenId)` returns the rate of the smallest
///      finalize batch covering `tokenId`. For pre-upgrade legacy tokenIds, it returns 0
///      (the sentinel); the claim path locally substitutes `LP.amountPerShareCeil()` for
///      backwards compatibility with old semantics. LP itself rejects rate=0.
///  I3. For any finalized `tokenId`, `getClaimableAmount(tokenId)` is invariant under
///      `LP.rebase()` after the finalize block. Property-tested via
///      `test_invariant_claimAmountIndependentOfPostFinalizeRebase`.
///  I4. The rate snapshot uses ceiling rounding (`Math.mulDiv(1e18, TPE, TS, Up)`) so
///      `shareOfEEth * rate / 1e18 >= LP.amountForShare(shareOfEEth)` and
///      `ceil(amount * 1e18 / rate) <= shareOfEEth`. These keep solvency checks and
///      the share burn within the request's own share allocation.
contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardNamespaced, PausableUntil, RolesLibrary, IWithdrawRequestNFT {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;
    
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    // deprecated storage slots
    uint256[3] private __gap_0;

    mapping(uint256 => IWithdrawRequestNFT.WithdrawRequest) private _requests;

    // deprecated storage slots
    uint256 private __gap_1;

    uint32 public nextRequestId;
    uint32 public lastFinalizedRequestId;
    uint16 public shareRemainderSplitToTreasuryInBps;

    // deprecated storage slots
    uint80 private __gap_2;
    uint256 private __gap_3;

    uint256 public totalRemainderEEthShares;
    bool public paused;

    // deprecated storage slots
    uint160 private __gap_4;

    uint128 public ethAmountLockedForWithdrawal;
    // (requestId upperBound => amountPerShareCeil(1e18) at finalize time).
    // A value of 0 marks a "legacy" range that pre-dates the share-rate-freeze upgrade;
    // `_getClaimableAmount` locally substitutes `LP.amountPerShareCeil()` for those tokenIds,
    // preserving the pre-upgrade live-rate-at-claim semantics. LP itself rejects rate=0.
    Checkpoints.Trace224 private _finalizationRates;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IMembershipManager public immutable membershipManager;
    IBlacklister public immutable blacklister;

    uint256 public immutable minAcceptableShareRate;
    uint256 public immutable maxAcceptableShareRate;
    // this treasury address is set to ethfi buyback wallet address
    address public immutable treasury;
    address public immutable etherFiAdmin;

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    uint256 public constant BASIS_POINT_SCALE = 1e4;
    uint256 public constant SHARE_UNIT = 1e18;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event HandledRemainderOfClaimedWithdrawRequests(uint256 eEthAmountToTreasury, uint256 eEthAmountBurnt);

    event Paused();
    event Unpaused();

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    error IncorrectCaller();
    error AddressZero();
    error AlreadyPaused();
    error NotPaused();
    error EETHAmountCannotBeZero();
    error NotEnoughEEthRemainder();
    error FeeReturnFailed();
    error InvalidRequest();
    error ContractPaused();
    error RequestValid();
    error RequestNotValid();
    error RequestNotFound();
    error CannotUndoFinalization();
    error CannotFinalizeFutureRequests();
    error CannotInvalidateFinalizedRequest();
    error RequestAmountGreaterThanAvailableLiquidity();
    error InvalidShareRemainderSplit();
    error InvalidShareRate();
    error NotTheOwner();
    error InsufficientEscrow();
    error EthTransferFailed();
    error AlreadyClaimed();
    error RequestNotFinalized();
    error InvalidMinAcceptableShareRate();
    error InvalidMinMaxAcceptableShareRate();
    error AlreadyInitialized();
    error InvalidLiveRate();
    error BurnExceedsShares();
    error InvalidEEthShares();

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _treasury, address _eETH, address _liquidityPool, address _membershipManager, address _roleRegistry, address _blacklister,  address _etherFiAdmin, uint256 _minAcceptableShareRate, uint256 _maxAcceptableShareRate) RolesLibrary(_roleRegistry) {
        if (_minAcceptableShareRate == 0) revert InvalidMinAcceptableShareRate();
        if (_maxAcceptableShareRate <= _minAcceptableShareRate) revert InvalidMinMaxAcceptableShareRate();
        treasury = _treasury;
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipManager = IMembershipManager(_membershipManager);
        blacklister = IBlacklister(_blacklister);
        etherFiAdmin = _etherFiAdmin;
        minAcceptableShareRate = _minAcceptableShareRate;
        maxAcceptableShareRate = _maxAcceptableShareRate;
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------
    function initialize(address _liquidityPoolAddress, address _eEthAddress, address _membershipManagerAddress) initializer external {
        if (_liquidityPoolAddress == address(0) || _eEthAddress == address(0) || _membershipManagerAddress == address(0)) revert AddressZero();
        __ERC721_init("Withdraw Request NFT", "WithdrawRequestNFT");
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextRequestId = 1;
    }

    /// @notice One-time initializer for the share-rate-freeze upgrade.
    /// @dev Pushes a sentinel checkpoint at the current `lastFinalizedRequestId` with value 0.
    ///      Every requestId <= that key looks up to this sentinel (value 0), which the claim
    ///      path resolves locally to the live rate via `LP.amountPerShareCeil()` — preserving
    ///      legacy behavior for requests finalized before this upgrade. New finalizations push
    ///      real rate snapshots, so post-upgrade tokenIds always resolve to a non-zero rate.
    function initializeShareRateFreezeUpgrade() external onlyUpgradeTimelock {
        if (_finalizationRates.length() != 0) revert AlreadyInitialized();
        _finalizationRates.push(uint32(lastFinalizedRequestId), 0);
    }

    receive() external payable {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        ethAmountLockedForWithdrawal += uint128(msg.value);
        _checkEthAmountLockedForWithdrawal();
    }

    /// @notice creates a withdraw request and issues an associated NFT to the recipient
    /// @dev liquidity pool contract will call this function when a user requests withdraw
    /// @param amountOfEEth amount of eETH requested for withdrawal
    /// @param shareOfEEth share of eETH requested for withdrawal
    /// @param recipient address to recieve with WithdrawRequestNFT
    /// @return uint256 id of the withdraw request
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient) external onlyLiquidityPool whenNotPaused returns (uint256) {
        uint256 requestId = nextRequestId++;

        _requests[requestId] = IWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, true, 0);

        _safeMint(recipient, requestId);

        emit WithdrawRequestCreated(uint32(requestId), amountOfEEth, shareOfEEth, recipient, 0);
        return requestId;
    }

    function getClaimableAmount(uint256 tokenId) public view returns (uint256) {
        (uint256 amountToTransfer, ) = _getClaimableAmount(tokenId);
        return amountToTransfer;
    }

    /// @dev Returns `(amountToTransfer, frozenRate)`. `frozenRate` is the rate snapshotted
    ///      at the request's finalize batch. For pre-upgrade legacy requests (covered only by the
    ///      sentinel checkpoint with value 0), the live rate from `LP.amountPerShareCeil()` is
    ///      substituted locally — preserving legacy claim semantics (live-rate at claim). The
    ///      returned `frozenRate` is therefore guaranteed non-zero, which is what `LP.withdraw`
    ///      now requires (`InvalidRate` reverts on zero).
    function _getClaimableAmount(uint256 tokenId) internal view returns (uint256, uint224) {
        if (tokenId > lastFinalizedRequestId) revert RequestNotFinalized();
        if (ownerOf(tokenId) == address(0)) revert AlreadyClaimed();

        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];

        // Smallest checkpoint whose key >= tokenId — the finalization batch this request belongs to.
        uint224 frozenRate = _finalizationRates.lowerLookup(uint32(tokenId));
        if (frozenRate == 0) {
            // Pre-upgrade legacy request — sentinel returned 0. Fall back to the live rate so
            // claim semantics match the pre-upgrade behavior. New (post-upgrade) finalizations
            // always push a non-zero snapshot, so this branch only fires for legacy tokenIds.
            uint256 live = liquidityPool.amountPerShareCeil();
            if (live < minAcceptableShareRate || live > maxAcceptableShareRate) revert InvalidLiveRate();
            frozenRate = uint224(live);
        }

        uint256 amountForShares = Math.mulDiv(uint256(request.shareOfEEth), frozenRate, SHARE_UNIT);

        // send the lesser value of the originally requested amount of eEth or the frozen-rate value of the shares
        uint256 amountToTransfer = Math.min(request.amountOfEEth, amountForShares);
        return (amountToTransfer, frozenRate);
    }

    /// @notice called by the NFT owner to claim their ETH
    /// @dev burns the NFT and transfers ETH from the liquidity pool to the owner, withdraw request must be valid and finalized
    /// @param tokenId the id of the withdraw request and associated NFT
    function claimWithdraw(uint256 tokenId) external nonReentrant nonBlacklisted {
        return _claimWithdraw(tokenId, ownerOf(tokenId));
    }
    
    /// @dev Pays the recipient from this contract's own ETH balance (segregated at finalize via
    ///      LP.addEthAmountLockedForWithdrawal). Burns shares against the rate frozen at finalize
    ///      via `LP.withdraw(amount, rate)`. `_getClaimableAmount` always resolves `frozenRate` to
    ///      a non-zero value (live-rate fallback for pre-upgrade legacy ids), satisfying LP's
    ///      `InvalidRate` guard.
    function _claimWithdraw(uint256 tokenId, address recipient) internal {
        if (ownerOf(tokenId) != msg.sender) revert NotTheOwner();
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        if (!request.isValid) revert RequestNotValid();

        (uint256 amountToWithdraw, uint224 frozenRate) = _getClaimableAmount(tokenId);

        _burn(tokenId);
        delete _requests[tokenId];

        if (ethAmountLockedForWithdrawal < amountToWithdraw) revert InsufficientEscrow();
        ethAmountLockedForWithdrawal -= uint128(request.amountOfEEth);

        uint256 burnedShares = liquidityPool.withdraw(amountToWithdraw, uint256(frozenRate));
        // When `amountToWithdraw` was computed at `frozenRate` (or live rate, for legacy), the
        // round-trip ceiling division yields `burnedShares <= request.shareOfEEth` by construction;
        // the require both pins that invariant and protects the remainder bookkeeping below.
        if (burnedShares > request.shareOfEEth) revert BurnExceedsShares();
        totalRemainderEEthShares += request.shareOfEEth - burnedShares;

        (bool ok, ) = payable(recipient).call{value: amountToWithdraw}("");
        if (!ok) revert EthTransferFailed();

        _checkEthAmountLockedForWithdrawal();

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, burnedShares, recipient, 0);
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds) external nonReentrant nonBlacklisted {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i], ownerOf(tokenIds[i]));
        }
    }

    // Seize the request simply by transferring it to another recipient
    function seizeInvalidRequest(uint256 requestId, address recipient) external onlyUpgradeTimelock {
        if (_requests[requestId].isValid) revert RequestValid();
        if (!_exists(requestId)) revert RequestNotFound();

        _transfer(ownerOf(requestId), recipient, requestId);

        emit WithdrawRequestSeized(uint32(requestId));
    }

    function getRequest(uint256 requestId) external view returns (IWithdrawRequestNFT.WithdrawRequest memory) {
        return _requests[requestId];
    }

    function isFinalized(uint256 requestId) public view returns (bool) {
        return requestId <= lastFinalizedRequestId;
    }

    /// @notice Frozen `amountForShare(1e18)` for the finalization batch covering `tokenId`,
    ///         or 0 if `tokenId` predates the share-rate-freeze upgrade (live-rate fallback).
    function frozenRateFor(uint256 tokenId) external view returns (uint224) {
        return _finalizationRates.lowerLookup(uint32(tokenId));
    }

    /// @notice Number of finalization-rate checkpoints (including the legacy sentinel, if pushed).
    function finalizationRatesLength() external view returns (uint256) {
        return _finalizationRates.length();
    }

    function isValid(uint256 requestId) public view returns (bool) {
        if (!_exists(requestId)) revert RequestNotFound();
        return _requests[requestId].isValid;
    }

    function finalizeRequests(uint256 requestId) external {
        if (msg.sender != address(etherFiAdmin)) revert IncorrectCaller();
        if (requestId < lastFinalizedRequestId) revert CannotUndoFinalization();
        if (requestId >= nextRequestId) revert CannotFinalizeFutureRequests();

        // Snapshot the current share rate for the newly-finalized range (prev, requestId].
        // Skip on no-op finalize so the checkpoint trace stays compact.
        if (requestId > lastFinalizedRequestId) {
            uint256 rate = liquidityPool.amountPerShareCeil();
            if (rate < minAcceptableShareRate || rate > maxAcceptableShareRate) revert InvalidShareRate();
            _finalizationRates.push(uint32(requestId), uint224(rate));
        }

        lastFinalizedRequestId = uint32(requestId);
    }

    /// @dev Admin can only invalidate requests that have NOT been finalized yet
    function invalidateRequest(uint256 requestId) external onlyGuardian {
        if (requestId <= lastFinalizedRequestId) revert CannotInvalidateFinalizedRequest();
        if (!isValid(requestId)) revert RequestNotValid();
        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(uint32(requestId));
    }

    function validateRequest(uint256 requestId) external onlyAdmin {
        if (!_exists(requestId)) revert RequestNotFound();
        if (_requests[requestId].isValid) revert RequestValid();
        if (requestId <= lastFinalizedRequestId) {
            uint256 amount = _requests[requestId].amountOfEEth;
            if (amount > liquidityPool.totalValueInLp()) revert RequestAmountGreaterThanAvailableLiquidity();
            liquidityPool.addEthAmountLockedForWithdrawal(uint128(amount));
        }
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(uint32(requestId));
    }

    function updateShareRemainderSplitToTreasuryInBps(uint16 _shareRemainderSplitToTreasuryInBps) external onlyAdmin {
        if (_shareRemainderSplitToTreasuryInBps > BASIS_POINT_SCALE) revert InvalidShareRemainderSplit();
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
    }

    function pauseContract() external onlyOperatingMultisig {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused();
    }

    function unPauseContract() external onlyOperatingMultisig {
        if (!paused) revert NotPaused();


        paused = false;
        emit Unpaused();
    }

    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    function unpauseContractUntil() external onlyOperatingMultisig {
        _unpauseUntil();
    }

    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    /// @dev Handles the remainder of the eEth shares after the claim of the withdraw request
    /// the remainder eETH share for a request = request.shareOfEEth - request.amountOfEEth / (eETH amount to eETH shares rate)
    /// - Splits the remainder into two parts:
    ///  - Treasury: treasury gets a split of the remainder
    ///   - Burn: the rest of the remainder is burned
    /// @param _eEthAmount: the remainder of the eEth amount
    function handleRemainder(uint256 _eEthAmount) external onlyHousekeepingOperations {
        if (_eEthAmount == 0) revert EETHAmountCannotBeZero(); 
        if (getEEthRemainderAmount() < _eEthAmount) revert NotEnoughEEthRemainder();

        uint256 beforeEEthShares = eETH.shares(address(this));

        uint256 eEthAmountToTreasury = _eEthAmount.mulDiv(shareRemainderSplitToTreasuryInBps, BASIS_POINT_SCALE);
        uint256 eEthAmountToBurn = _eEthAmount - eEthAmountToTreasury;
        uint256 eEthSharesToBurn = liquidityPool.sharesForAmount(eEthAmountToBurn);
        uint256 eEthSharesToMoved = eEthSharesToBurn + liquidityPool.sharesForAmount(eEthAmountToTreasury);

        totalRemainderEEthShares -= eEthSharesToMoved;

        if (eEthAmountToTreasury > 0) IERC20(address(eETH)).safeTransfer(treasury, eEthAmountToTreasury);
        if (eEthSharesToBurn > 0) liquidityPool.burnEEthShares(eEthSharesToBurn);

        if (beforeEEthShares - eEthSharesToMoved != eETH.shares(address(this))) revert InvalidEEthShares();

        emit HandledRemainderOfClaimedWithdrawRequests(eEthAmountToTreasury, eEthAmountToBurn);

        // Sweep accumulated ETH back to treasury
        // In case of negative rebase, the ETH is stranded in the NFT contract
        uint256 strandedEth = address(this).balance > ethAmountLockedForWithdrawal
            ? address(this).balance - uint256(ethAmountLockedForWithdrawal)
            : 0;
        if (strandedEth > 0) {
            (bool ok, ) = payable(address(treasury)).call{value: strandedEth}("");
            if (!ok) revert FeeReturnFailed();
            _checkEthAmountLockedForWithdrawal();
        }
    }

    function getEEthRemainderAmount() public view returns (uint256) {
        return liquidityPool.amountForShare(totalRemainderEEthShares);
    }

    // the withdraw request NFT is transferrable
    // - if the request is valid, it can be transferred by the owner of the NFT
    // - if the request is invalid, it can be transferred only by the owner of the WithdarwRequestNFT contract
    // - the transfer is not allowed if the from or to is blacklisted
    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal override {
        blacklister.nonBlacklisted(from);
        blacklister.nonBlacklisted(to);
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 tokenId = firstTokenId + i;
            if (!_requests[tokenId].isValid && msg.sender != owner()) revert InvalidRequest();
        }
    }

    function _checkEthAmountLockedForWithdrawal() internal view {
        if (address(this).balance < ethAmountLockedForWithdrawal) revert InsufficientEscrow();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _requireNotPaused() internal view virtual {
        if (paused) revert ContractPaused();
    }

    modifier onlyLiquidityPool() {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        _;
    }

    modifier whenNotPaused() {
        _requireNotPaused();
        _requireNotPausedUntil();
        _;
    }

    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}

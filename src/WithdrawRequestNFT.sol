// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/IMembershipManager.sol";
import "./interfaces/IBlacklister.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Checkpoints.sol";
import "./RoleRegistry.sol";
import "./ReentrancyGuardNamespaced.sol";
import "./utils/PausableUntil.sol";



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
contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardNamespaced, PausableUntil, IWithdrawRequestNFT {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    uint256 private constant BASIS_POINT_SCALE = 1e4;
    uint256 private constant SHARE_UNIT = 1e18;
    // this treasury address is set to ethfi buyback wallet address
    address public immutable treasury;
    
    ILiquidityPool public liquidityPool;
    IeETH public eETH; 
    IMembershipManager public membershipManager;

    mapping(uint256 => IWithdrawRequestNFT.WithdrawRequest) private _requests;
    mapping(address => bool) public DEPRECATED_admins;

    uint32 public nextRequestId;
    uint32 public lastFinalizedRequestId;
    uint16 public shareRemainderSplitToTreasuryInBps;
    uint16 public _unused_gap;

    // inclusive
    uint32 public currentRequestIdToScanFromForShareRemainder;
    uint32 public lastRequestIdToScanUntilForShareRemainder;
    uint256 public aggregateSumOfEEthShare;

    uint256 public totalRemainderEEthShares;

    bool public paused;
    RoleRegistry public roleRegistry;

    uint128 public ethAmountLockedForWithdrawal;

    // (requestId upperBound => amountPerShareCeil(1e18) at finalize time).
    // A value of 0 marks a "legacy" range that pre-dates the share-rate-freeze upgrade;
    // `_getClaimableAmount` locally substitutes `LP.amountPerShareCeil()` for those tokenIds,
    // preserving the pre-upgrade live-rate-at-claim semantics. LP itself rejects rate=0.
    Checkpoints.Trace224 private _finalizationRates;

    bytes32 public constant WITHDRAW_REQUEST_NFT_ADMIN_ROLE = keccak256("WITHDRAW_REQUEST_NFT_ADMIN_ROLE");
    bytes32 public constant INVALIDATE_WITHDRAW_REQUEST_ROLE = keccak256("INVALIDATE_WITHDRAW_REQUEST_ROLE");
    bytes32 public constant IMPLICIT_FEE_CLAIMER_ROLE = keccak256("IMPLICIT_FEE_CLAIMER_ROLE");

    IBlacklister public immutable blacklister;

    uint256 public immutable minAcceptableShareRate;
    uint256 public immutable maxAcceptableShareRate;

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event HandledRemainderOfClaimedWithdrawRequests(uint256 eEthAmountToTreasury, uint256 eEthAmountBurnt);

    event Paused(address account);
    event Unpaused(address account);

    error IncorrectRole();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _treasury, address _blacklister, uint256 _minAcceptableShareRate, uint256 _maxAcceptableShareRate) {
        require(_maxAcceptableShareRate > _minAcceptableShareRate, "Invalid min and max acceptable share rate");
        treasury = _treasury;
        blacklister = IBlacklister(_blacklister);

        minAcceptableShareRate = _minAcceptableShareRate;
        maxAcceptableShareRate = _maxAcceptableShareRate;
        _disableInitializers();
    }

    function initialize(address _liquidityPoolAddress, address _eEthAddress, address _membershipManagerAddress) initializer external {
        require(_liquidityPoolAddress != address(0), "No zero addresses");
        require(_eEthAddress != address(0), "No zero addresses");
        __ERC721_init("Withdraw Request NFT", "WithdrawRequestNFT");
        __Ownable_init();
        __UUPSUpgradeable_init();

        liquidityPool = ILiquidityPool(_liquidityPoolAddress);
        eETH = IeETH(_eEthAddress);
        membershipManager = IMembershipManager(_membershipManagerAddress);
        nextRequestId = 1;
    }

    function initializeOnUpgrade(address _roleRegistry, uint16 _shareRemainderSplitToTreasuryInBps) external onlyOwner {
        require(address(roleRegistry) == address(0) && _roleRegistry != address(0), "Already initialized");
        require(_shareRemainderSplitToTreasuryInBps <= BASIS_POINT_SCALE, "INVALID");

        paused = true; // make sure the contract is paused after the upgrade
        roleRegistry = RoleRegistry(_roleRegistry);

        _unused_gap = 0;
        
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;

        currentRequestIdToScanFromForShareRemainder = 1;
        lastRequestIdToScanUntilForShareRemainder = nextRequestId - 1;

        aggregateSumOfEEthShare = 0;
        totalRemainderEEthShares = 0;
    }

    /// @notice One-time initializer for the share-rate-freeze upgrade.
    /// @dev Pushes a sentinel checkpoint at the current `lastFinalizedRequestId` with value 0.
    ///      Every requestId <= that key looks up to this sentinel (value 0), which the claim
    ///      path resolves locally to the live rate via `LP.amountPerShareCeil()` — preserving
    ///      legacy behavior for requests finalized before this upgrade. New finalizations push
    ///      real rate snapshots, so post-upgrade tokenIds always resolve to a non-zero rate.
    function initializeShareRateFreezeUpgrade() external onlyOwner {
        require(_finalizationRates.length() == 0, "already initialized");
        _finalizationRates.push(uint32(lastFinalizedRequestId), 0);
    }

    receive() external payable {
        require(msg.sender == address(liquidityPool), "Only LP");
        ethAmountLockedForWithdrawal += uint128(msg.value);
        _checkEthAmountLockedForWithdrawal();
    }

    /// @notice creates a withdraw request and issues an associated NFT to the recipient
    /// @dev liquidity pool contract will call this function when a user requests withdraw
    /// @param amountOfEEth amount of eETH requested for withdrawal
    /// @param shareOfEEth share of eETH requested for withdrawal
    /// @param recipient address to recieve with WithdrawRequestNFT
    /// @param fee fee to be subtracted from amount when recipient calls claimWithdraw
    /// @return uint256 id of the withdraw request
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient, uint256 fee) external onlyLiquidityPool whenNotPaused returns (uint256) {
        uint256 requestId = nextRequestId++;
        uint32 feeGwei = uint32(fee / 1 gwei);

        _requests[requestId] = IWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, true, feeGwei);

        _safeMint(recipient, requestId);

        emit WithdrawRequestCreated(uint32(requestId), amountOfEEth, shareOfEEth, recipient, fee);
        return requestId;
    }

    function getClaimableAmount(uint256 tokenId) public view returns (uint256) {
        (uint256 amountToTransfer, uint256 fee, ) = _getClaimableAmount(tokenId);
        return amountToTransfer - fee;
    }

    /// @dev Returns `(amountToTransfer, fee, frozenRate)`. `frozenRate` is the rate snapshotted
    ///      at the request's finalize batch. For pre-upgrade legacy requests (covered only by the
    ///      sentinel checkpoint with value 0), the live rate from `LP.amountPerShareCeil()` is
    ///      substituted locally — preserving legacy claim semantics (live-rate at claim). The
    ///      returned `frozenRate` is therefore guaranteed non-zero, which is what `LP.withdraw`
    ///      now requires (`InvalidRate` reverts on zero).
    function _getClaimableAmount(uint256 tokenId) internal view returns (uint256, uint256, uint224) {
        require(tokenId <= lastFinalizedRequestId, "Request is not finalized");
        require(ownerOf(tokenId) != address(0), "Already Claimed");

        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];

        // Smallest checkpoint whose key >= tokenId — the finalization batch this request belongs to.
        uint224 frozenRate = _finalizationRates.lowerLookup(uint32(tokenId));
        if (frozenRate == 0) {
            // Pre-upgrade legacy request — sentinel returned 0. Fall back to the live rate so
            // claim semantics match the pre-upgrade behavior. New (post-upgrade) finalizations
            // always push a non-zero snapshot, so this branch only fires for legacy tokenIds.
            uint256 live = liquidityPool.amountPerShareCeil();
            require(live > 0 && live <= type(uint224).max, "invalid live rate");
            frozenRate = uint224(live);
        }

        uint256 amountForShares = Math.mulDiv(uint256(request.shareOfEEth), frozenRate, SHARE_UNIT);

        // send the lesser value of the originally requested amount of eEth or the frozen-rate value of the shares
        uint256 amountToTransfer = Math.min(request.amountOfEEth, amountForShares);
        uint256 fee = uint256(request.feeGwei) * 1 gwei;
        return (amountToTransfer, fee, frozenRate);
    }

    /// @notice called by the NFT owner to claim their ETH
    /// @dev burns the NFT and transfers ETH from the liquidity pool to the owner minus any fee, withdraw request must be valid and finalized
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
        require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        require(request.isValid, "Request is not valid");

        (uint256 amountToTransfer, uint256 fee, uint224 frozenRate) = _getClaimableAmount(tokenId);
        uint256 amountToWithdraw = amountToTransfer - fee;

        _burn(tokenId);
        delete _requests[tokenId];

        require(ethAmountLockedForWithdrawal >= amountToTransfer, "insufficient escrow");
        ethAmountLockedForWithdrawal -= uint128(amountToTransfer);

        uint256 burnedShares = liquidityPool.withdraw(amountToWithdraw, uint256(frozenRate));
        // When `amountToWithdraw` was computed at `frozenRate` (or live rate, for legacy), the
        // round-trip ceiling division yields `burnedShares <= request.shareOfEEth` by construction;
        // the require both pins that invariant and protects the remainder bookkeeping below.
        require(burnedShares <= request.shareOfEEth, "burn exceeds shares");
        totalRemainderEEthShares += request.shareOfEEth - burnedShares;

        (bool ok, ) = payable(recipient).call{value: amountToWithdraw}("");
        require(ok, "ETH transfer failed");

        _checkEthAmountLockedForWithdrawal();

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, burnedShares, recipient, 0);
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds) external nonReentrant nonBlacklisted {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i], ownerOf(tokenIds[i]));
        }
    }

    // This function is used to aggregate the sum of the eEth shares of the requests that have not been claimed yet.
    // To be triggered during the upgrade to the new version of the contract.
    function aggregateSumEEthShareAmount(uint256 _numReqsToScan) external {
        require(!isScanOfShareRemainderCompleted(), "scan is completed");

        // [scanFrom, scanUntil]
        uint256 scanFrom = currentRequestIdToScanFromForShareRemainder;
        uint256 scanUntil = Math.min(lastRequestIdToScanUntilForShareRemainder, scanFrom + _numReqsToScan - 1);

        for (uint256 i = scanFrom; i <= scanUntil; i++) {
            if (!_exists(i)) continue;
            aggregateSumOfEEthShare += _requests[i].shareOfEEth;
        }

        currentRequestIdToScanFromForShareRemainder = uint32(scanUntil + 1);
        
        // When the scan is completed, update the `totalRemainderEEthShares` and reset the `aggregateSumOfEEthShare`
        if (isScanOfShareRemainderCompleted()) {
            totalRemainderEEthShares = eETH.shares(address(this)) - aggregateSumOfEEthShare;
            aggregateSumOfEEthShare = 0; // gone
        }
    }

    // Seize the request simply by transferring it to another recipient
    function seizeInvalidRequest(uint256 requestId, address recipient) external onlyOwner {
        require(!_requests[requestId].isValid, "Request is valid");
        require(_exists(requestId), "Request does not exist");

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
        require(_exists(requestId), "Request does not exist");
        return _requests[requestId].isValid;
    }

    function finalizeRequests(uint256 requestId) external onlyAdmin {
        require(requestId >= lastFinalizedRequestId, "Cannot undo finalization");
        require(requestId < nextRequestId, "Cannot finalize future requests");

        // Snapshot the current share rate for the newly-finalized range (prev, requestId].
        // Skip on no-op finalize so the checkpoint trace stays compact.
        if (requestId > lastFinalizedRequestId) {
            uint256 rate = liquidityPool.amountPerShareCeil();
            require(rate >= minAcceptableShareRate && rate <= maxAcceptableShareRate, "invalid rate");
            _finalizationRates.push(uint32(requestId), uint224(rate));
        }

        lastFinalizedRequestId = uint32(requestId);
    }

    /// @dev Admin can only invalidate requests that have NOT been finalized yet
    function invalidateRequest(uint256 requestId) external {
        if (!roleRegistry.hasRole(INVALIDATE_WITHDRAW_REQUEST_ROLE, msg.sender)) revert IncorrectRole();
        require(requestId > lastFinalizedRequestId, "Cannot invalidate finalized request");
        require(isValid(requestId), "Request is not valid");
        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(uint32(requestId));
    }

    function validateRequest(uint256 requestId) external onlyAdmin {
        require(_exists(requestId), "Request does not exist");
        require(!_requests[requestId].isValid, "Request is valid");
        if (requestId <= lastFinalizedRequestId) {
            uint256 amount = _requests[requestId].amountOfEEth;
            require(amount <= address(liquidityPool).balance, "Request amount is greater than available liquidity");
            liquidityPool.addEthAmountLockedForWithdrawal(uint128(amount));
        }
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(uint32(requestId));
    }

    function updateShareRemainderSplitToTreasuryInBps(uint16 _shareRemainderSplitToTreasuryInBps) external onlyOwner {
        require(_shareRemainderSplitToTreasuryInBps <= BASIS_POINT_SCALE, "INVALID");
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
    }

    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        if (paused) revert("Pausable: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (!paused) revert("Pausable: not paused");


        paused = false;
        emit Unpaused(msg.sender);
    }

    function pauseContractUntil() external {
        if (!roleRegistry.hasRole(roleRegistry.PAUSE_UNTIL_ROLE(), msg.sender)) revert IncorrectRole();
        _pauseUntil();
    }

    function unpauseContractUntil() external {
        if (!roleRegistry.hasRole(roleRegistry.UNPAUSE_UNTIL_ROLE(), msg.sender)) revert IncorrectRole();
        _unpauseUntil();
    }

    function setPauseUntilDuration(uint256 _pauseUntilDuration) external {
        if (!roleRegistry.hasRole(roleRegistry.PAUSE_DURATION_SETTER(), msg.sender)) revert IncorrectRole();
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    /// @dev Handles the remainder of the eEth shares after the claim of the withdraw request
    /// the remainder eETH share for a request = request.shareOfEEth - request.amountOfEEth / (eETH amount to eETH shares rate)
    /// - Splits the remainder into two parts:
    ///  - Treasury: treasury gets a split of the remainder
    ///   - Burn: the rest of the remainder is burned
    /// @param _eEthAmount: the remainder of the eEth amount
    function handleRemainder(uint256 _eEthAmount) external {
        if(!roleRegistry.hasRole(IMPLICIT_FEE_CLAIMER_ROLE, msg.sender)) revert IncorrectRole();
        require(_eEthAmount != 0, "EETH amount cannot be 0"); 
        require(isScanOfShareRemainderCompleted(), "Not all prev requests have been scanned");
        require(getEEthRemainderAmount() >= _eEthAmount, "Not enough eETH remainder");

        uint256 beforeEEthShares = eETH.shares(address(this));

        uint256 eEthAmountToTreasury = _eEthAmount.mulDiv(shareRemainderSplitToTreasuryInBps, BASIS_POINT_SCALE);
        uint256 eEthAmountToBurn = _eEthAmount - eEthAmountToTreasury;
        uint256 eEthSharesToBurn = liquidityPool.sharesForAmount(eEthAmountToBurn);
        uint256 eEthSharesToMoved = eEthSharesToBurn + liquidityPool.sharesForAmount(eEthAmountToTreasury);

        totalRemainderEEthShares -= eEthSharesToMoved;

        if (eEthAmountToTreasury > 0) IERC20(address(eETH)).safeTransfer(treasury, eEthAmountToTreasury);
        if (eEthSharesToBurn > 0) liquidityPool.burnEEthShares(eEthSharesToBurn);

        require (beforeEEthShares - eEthSharesToMoved == eETH.shares(address(this)), "Invalid eETH shares after remainder handling");

        emit HandledRemainderOfClaimedWithdrawRequests(eEthAmountToTreasury, eEthAmountToBurn);

        // Sweep accumulated fee ETH (surplus over locked counter) back to LP.
        // Fee ETH accrues because _claimWithdraw decrements by gross (amountOfEEth) but only
        // sends net (amountToWithdraw = amountOfEEth - fee) to the recipient.
        uint256 strandedFeeEth = address(this).balance > ethAmountLockedForWithdrawal
            ? address(this).balance - uint256(ethAmountLockedForWithdrawal)
            : 0;
        if (strandedFeeEth > 0) {
            (bool ok, ) = payable(address(liquidityPool)).call{value: strandedFeeEth}("");
            require(ok, "fee return failed");
            _checkEthAmountLockedForWithdrawal();
        }
    }

    function getEEthRemainderAmount() public view returns (uint256) {
        return liquidityPool.amountForShare(totalRemainderEEthShares);
    }

    function isScanOfShareRemainderCompleted() public view returns (bool) {
        return currentRequestIdToScanFromForShareRemainder == (lastRequestIdToScanUntilForShareRemainder + 1);
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
            require(_requests[tokenId].isValid || msg.sender == owner(), "INVALID_REQUEST");
        }
    }

    function _checkEthAmountLockedForWithdrawal() internal view {
        require(address(this).balance >= ethAmountLockedForWithdrawal, "Insufficient escrow");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _requireNotPaused() internal view virtual {
        require(!paused, "Pausable: paused");
    }

    modifier onlyAdmin() {
        require(roleRegistry.hasRole(WITHDRAW_REQUEST_NFT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        _;
    }

    modifier onlyLiquidityPool() {
        require(msg.sender == address(liquidityPool), "Caller is not the liquidity pool");
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

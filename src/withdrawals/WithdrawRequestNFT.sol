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

/**
 * @title WithdrawRequestNFT — share-rate-freeze invariants
 * @notice
 * @dev Once `finalizeRequests(lastRequestId)` runs, the rate used to compute the claim payout
 * for tokenIds <= lastRequestId is frozen at the rate snapshotted in that finalize batch.
 * Subsequent rebases do NOT move the claim payout — this is the H-02 fix.
 *
 *  Invariants:
 *   I1. `_finalizationRates` keys are strictly increasing. Enforced by the
 *        `requestId > lastFinalizedRequestId` guard in `finalizeRequests` and by
 *        `Checkpoints.push` semantics.
 *   I2. `_finalizationRates.lowerLookup(tokenId)` returns the rate of the smallest
 *        finalize batch covering `tokenId`. For pre-upgrade legacy tokenIds, it returns 0
 *        (the sentinel); the claim path locally substitutes `LP.amountPerShareCeil()` for
 *        backwards compatibility with old semantics. LP itself rejects rate=0.
 *   I3. For any finalized `tokenId`, `getClaimableAmount(tokenId)` is invariant under
 *        `LP.rebase()` after the finalize block. Property-tested via
 *        `test_invariant_claimAmountIndependentOfPostFinalizeRebase`.
 *   I4. The rate snapshot uses ceiling rounding (`Math.mulDiv(1e18, TPE, TS, Up)`) so
 *        `shareOfEEth * rate / 1e18 >= LP.amountForShare(shareOfEEth)` and
 *        `ceil(amount * 1e18 / rate) <= shareOfEEth`. These keep solvency checks and
 *        the share burn within the request's own share allocation.
 */
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
    error NotTheOwner();
    error InsufficientEscrow();
    error EthTransferFailed();
    error AlreadyClaimed();
    error RequestNotFinalized();
    error AlreadyInitialized();
    error NotInitialized();
    error BurnExceedsShares();
    error InvalidEEthShares();

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _treasury The address of the treasury.
     * @param _eETH The address of the eETH token.
     * @param _liquidityPool The address of the liquidity pool.
     * @param _membershipManager The address of the membership manager.
     * @param _roleRegistry The address of the role registry.
     * @param _blacklister The address of the blacklister.
     * @param _etherFiAdmin The address of the etherFi admin.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _treasury, address _eETH, address _liquidityPool, address _membershipManager, address _roleRegistry, address _blacklister,  address _etherFiAdmin) RolesLibrary(_roleRegistry) {
        treasury = _treasury;
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipManager = IMembershipManager(_membershipManager);
        blacklister = IBlacklister(_blacklister);
        etherFiAdmin = _etherFiAdmin;
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the contract
     * @param _liquidityPoolAddress The address of the liquidity pool.
     * @param _eEthAddress The address of the eETH token.
     * @param _membershipManagerAddress The address of the membership manager.
     */
    function initialize(address _liquidityPoolAddress, address _eEthAddress, address _membershipManagerAddress) initializer external {
        if (_liquidityPoolAddress == address(0) || _eEthAddress == address(0) || _membershipManagerAddress == address(0)) revert AddressZero();
        __ERC721_init("Withdraw Request NFT", "WithdrawRequestNFT");
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextRequestId = 1;
    }

    /**
     * @notice One-time initializer for the share-rate-freeze upgrade.
     * @dev Pushes a sentinel checkpoint at the current `lastFinalizedRequestId` with value 0.
     *      Every requestId <= that key looks up to this sentinel (value 0), which the claim
     *      path resolves locally to the live rate via `LP.amountPerShareCeil()` — preserving
     *      legacy behavior for requests finalized before this upgrade. New finalizations push
     *      real rate snapshots, so post-upgrade tokenIds always resolve to a non-zero rate.
     */
    function initializeShareRateFreezeUpgrade() external onlyUpgradeTimelock {
        if (_finalizationRates.length() != 0) revert AlreadyInitialized();
        _finalizationRates.push(uint32(lastFinalizedRequestId), 0);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECEIVE FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Receive ETH
     */
    receive() external payable {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        ethAmountLockedForWithdrawal += uint128(msg.value);
        _checkEthAmountLockedForWithdrawal();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  WITHDRAW FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Creates a withdraw request and issues an associated NFT to the recipient
     * @param amountOfEEth Amount of eETH requested for withdrawal
     * @param shareOfEEth Share of eETH requested for withdrawal
     * @param recipient Address to recieve with WithdrawRequestNFT
     * @return uint256 id of the withdraw request
     */
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient) external onlyLiquidityPool whenNotPaused returns (uint256) {
        uint256 requestId = nextRequestId++;

        _requests[requestId] = IWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, true, 0);

        _safeMint(recipient, requestId);

        emit WithdrawRequestCreated(uint32(requestId), amountOfEEth, shareOfEEth, recipient, 0);
        return requestId;
    }

    /**
     * @notice called by the NFT owner to claim their ETH
     * @param tokenId The ID of the withdrawal request
     * @dev burns the NFT and transfers ETH from the liquidity pool to the owner, withdraw request must be valid and finalized
     */
    function claimWithdraw(uint256 tokenId) external nonReentrant nonBlacklisted {
        return _claimWithdraw(tokenId, ownerOf(tokenId));
    }

    /**
     * @notice Claims multiple withdraw requests
     * @param tokenIds The IDs of the withdrawal requests
     * @dev burns the NFTs and transfers ETH from the liquidity pool to the owners, withdraw requests must be valid and finalized
     */
    function batchClaimWithdraw(uint256[] calldata tokenIds) external nonReentrant nonBlacklisted {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i], ownerOf(tokenIds[i]));
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  ADMIN FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Seizes a withdrawal request simply by transferring it to another recipient
     * @param requestId The ID of the withdrawal request
     * @param recipient The address of the recipient
     */
    function seizeInvalidRequest(uint256 requestId, address recipient) external onlyUpgradeTimelock {
        if (_requests[requestId].isValid) revert RequestValid();
        if (!_exists(requestId)) revert RequestNotFound();

        _transfer(ownerOf(requestId), recipient, requestId);

        emit WithdrawRequestSeized(uint32(requestId));
    }

    /**
     * @notice Updates the share remainder split to treasury in basis points
     * @param _shareRemainderSplitToTreasuryInBps The new share remainder split to treasury in basis points
     */
    function updateShareRemainderSplitToTreasuryInBps(uint16 _shareRemainderSplitToTreasuryInBps) external onlyAdmin {
        if (_shareRemainderSplitToTreasuryInBps > BASIS_POINT_SCALE) revert InvalidShareRemainderSplit();
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  OPERATIONAL FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Finalizes a withdrawal request
     * @param requestId The ID of the withdrawal request
     * @dev finalizes the withdrawal request
     */
    function finalizeRequests(uint256 requestId) external {
        if (msg.sender != address(etherFiAdmin)) revert IncorrectCaller();
        // Defends against the upgrade-ordering trap: if `initializeShareRateFreezeUpgrade`
        // has not yet pushed the sentinel, the first `finalizeRequests` would push a real
        // rate as the trace's first entry, causing every legacy tokenId to look up to that
        // rate instead of 0 — corrupting the live-rate fallback semantic for pre-upgrade
        // requests. Block until the sentinel is in place.
        if (_finalizationRates.length() == 0) revert NotInitialized();
        if (requestId < lastFinalizedRequestId) revert CannotUndoFinalization();
        if (requestId >= nextRequestId) revert CannotFinalizeFutureRequests();

        // Snapshot the current share rate for the newly-finalized range (prev, requestId].
        // Skip on no-op finalize so the checkpoint trace stays compact.
        if (requestId > lastFinalizedRequestId) {
            uint256 rate = liquidityPool.amountPerShareCeil();
            _finalizationRates.push(uint32(requestId), uint224(rate));
        }

        lastFinalizedRequestId = uint32(requestId);
    }

    /**
     * @notice Handles the remainder of the eEth shares after the claim of the withdraw request
     * @param _eEthAmount The remainder of the eEth amount
     * @dev handles the remainder of the eEth shares after the claim of the withdraw request
     *      the remainder eETH share for a request = request.shareOfEEth - request.amountOfEEth / (eETH amount to eETH shares rate)
     *      - Splits the remainder into two parts:
     *      - Treasury: treasury gets a split of the remainder
     *      - Burn: the rest of the remainder is burned
     */
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

    /**
     * @notice Invalidates a withdrawal request
     * @param requestId The ID of the withdrawal request
     * @dev Admin can only invalidate requests that have NOT been finalized yet
     */
    function invalidateRequest(uint256 requestId) external onlyGuardian {
        if (requestId <= lastFinalizedRequestId) revert CannotInvalidateFinalizedRequest();
        if (!isValid(requestId)) revert RequestNotValid();
        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(uint32(requestId));
    }

    /**
     * @notice Validates a withdrawal request
     * @param requestId The ID of the withdrawal request
     */
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

    //--------------------------------------------------------------------------------------
    //-----------------------------  PAUSING FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Pauses the contract
     */
    function pauseContract() external onlyOperatingMultisig {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused();
    }

    /**
     * @notice Unpauses the contract
     */
    function unPauseContract() external onlyOperatingMultisig {
        if (!paused) revert NotPaused();


        paused = false;
        emit Unpaused();
    }

    /**
     * @notice Pauses the contract until the pauseUntilDuration
     */
    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    /**
     * @notice Unpauses the contract from pauseUntil
     */
    function unpauseContractUntil() external onlyOperatingMultisig {
        _unpauseUntil();
    }

    /**
     * @notice Sets the pause duration for the contract
     * @param _pauseUntilDuration The new pause duration
     */
    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  INTERNAL FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Gets the claimable amount for a withdrawal request
     * @param tokenId The ID of the withdrawal request
     * @return amountToTransfer The amount of eETH that can be claimed
     * @return frozenRate The rate snapshotted at the request's finalize batch
     * @dev For pre-upgrade legacy requests (covered only by the sentinel checkpoint with value 0), 
     *      the live rate from `LP.amountPerShareCeil()` is substituted locally — preserving legacy 
     *      claim semantics (live-rate at claim). The returned `frozenRate` is therefore guaranteed 
     *      non-zero, which is what `LP.withdraw` now requires (`InvalidRate` reverts on zero).
     */
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
            // Bounds-check the live rate before adopting it — this path is the only one where
            // `frozenRate` was not already gated by `finalizeRequests`'s write-time check.
            uint256 live = liquidityPool.amountPerShareCeil();
            frozenRate = uint224(live);
        }

        uint256 amountForShares = Math.mulDiv(uint256(request.shareOfEEth), frozenRate, SHARE_UNIT);

        // send the lesser value of the originally requested amount of eEth or the frozen-rate value of the shares
        uint256 amountToTransfer = Math.min(request.amountOfEEth, amountForShares);
        return (amountToTransfer, frozenRate);
    }

    /**
     * @notice Pays the recipient from this contract's own ETH balance (segregated at finalize via
     * @param tokenId The ID of the withdrawal request
     * @param recipient The address of the recipient
     * @dev Burns shares against the rate frozen at finalize via `LP.withdraw(amount, rate)`. 
     *      `_getClaimableAmount` always resolves `frozenRate` to a non-zero value (live-rate fallback for pre-upgrade legacy ids), 
     *      satisfying LP's `InvalidRate` guard.
     */
    function _claimWithdraw(uint256 tokenId, address recipient) internal {
        if (ownerOf(tokenId) != msg.sender) revert NotTheOwner();
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        if (!request.isValid) revert RequestNotValid();

        (uint256 amountToWithdraw, uint224 frozenRate) = _getClaimableAmount(tokenId);

        _burn(tokenId);
        delete _requests[tokenId];

        if (ethAmountLockedForWithdrawal < amountToWithdraw) revert InsufficientEscrow();
        ethAmountLockedForWithdrawal -= uint128(request.amountOfEEth);

        uint256 burnedShares = liquidityPool.withdraw(amountToWithdraw, uint256(frozenRate), request.shareOfEEth);
        // LP caps `burnedShares <= request.shareOfEEth` (Guard 3). Defensive duplication.
        if (burnedShares > request.shareOfEEth) revert BurnExceedsShares();
        totalRemainderEEthShares += request.shareOfEEth - burnedShares;

        (bool ok, ) = payable(recipient).call{value: amountToWithdraw}("");
        if (!ok) revert EthTransferFailed();

        _checkEthAmountLockedForWithdrawal();

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, burnedShares, recipient, 0);
    }

    /**
     * @notice Before token transfer
     * @param from The address of the from
     * @param to The address of the to
     * @param firstTokenId The first token ID
     * @param batchSize The batch size
     * @dev the withdraw request NFT is transferrable
     *      - if the request is valid, it can be transferred by the owner of the NFT
     *      - if the request is invalid, it can be transferred only by the owner of the WithdarwRequestNFT contract
     *      - the transfer is not allowed if the from or to is blacklisted
     */
    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal view override {
        blacklister.nonBlacklisted(from);
        blacklister.nonBlacklisted(to);
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 tokenId = firstTokenId + i;
            if (!_requests[tokenId].isValid && msg.sender != owner()) revert InvalidRequest();
        }
    }

    /**
     * @notice Checks if the ETH amount locked for withdrawal is sufficient
     * @dev Reverts if the ETH amount locked for withdrawal is greater than the ETH balance of the contract
     */
    function _checkEthAmountLockedForWithdrawal() internal view {
        if (address(this).balance < ethAmountLockedForWithdrawal) revert InsufficientEscrow();
    }

    /**
     * @notice Checks if the contract is not paused
     * @dev Reverts if the contract is paused
     */
    function _requireNotPaused() internal view virtual {
        if (paused) revert ContractPaused();
    }

    /**
     * @notice Authorizes the upgrade of the contract
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Gets a withdrawal request
     * @param requestId The ID of the withdrawal request
     * @return request The withdrawal request
     */
    function getRequest(uint256 requestId) external view returns (IWithdrawRequestNFT.WithdrawRequest memory) {
        return _requests[requestId];
    }

    /**
     * @notice Gets the claimable amount for a withdrawal request
     * @param tokenId The ID of the withdrawal request
     * @return amountToTransfer The amount of eETH that can be claimed
     */
    function getClaimableAmount(uint256 tokenId) public view returns (uint256) {
        (uint256 amountToTransfer, ) = _getClaimableAmount(tokenId);
        return amountToTransfer;
    }

    /**
     * @notice Checks if a withdrawal request is finalized
     * @param requestId The ID of the withdrawal request
     * @return isFinalized True if the request is finalized, false otherwise
     */
    function isFinalized(uint256 requestId) public view returns (bool) {
        return requestId <= lastFinalizedRequestId;
    }

    /**
     * @notice Gets the frozen rate for a withdrawal request
     * @param tokenId The ID of the withdrawal request
     * @return frozenRate The frozen rate for the withdrawal request
     */
    function frozenRateFor(uint256 tokenId) external view returns (uint224) {
        return _finalizationRates.lowerLookup(uint32(tokenId));
    }

    /**
     * @notice Gets the number of finalization rates
     * @return finalizationRatesLength The number of finalization rates
     */
    function finalizationRatesLength() external view returns (uint256) {
        return _finalizationRates.length();
    }

    /**
     * @notice Checks if a withdrawal request is valid
     * @param requestId The ID of the withdrawal request
     * @return isValid True if the request is valid, false otherwise
     */
    function isValid(uint256 requestId) public view returns (bool) {
        if (!_exists(requestId)) revert RequestNotFound();
        return _requests[requestId].isValid;
    }

    /**
     * @notice Gets the remainder of the eEth amount
     * @return eEthRemainderAmount The remainder of the eEth amount
     */
    function getEEthRemainderAmount() public view returns (uint256) {
        return liquidityPool.amountForShare(totalRemainderEEthShares);
    }

    /**
     * @notice Gets the implementation address
     * @return implementation The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the caller is the liquidity pool
     * @dev Reverts if the caller is not the liquidity pool
     */
    modifier onlyLiquidityPool() {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        _;
    }

    /**
     * @notice Modifier to check if the contract is not paused
     * @dev Reverts if the contract is paused
     */
    modifier whenNotPaused() {
        _requireNotPaused();
        _requireNotPausedUntil();
        _;
    }

    /**
     * @notice Modifier to check if the caller is not blacklisted
     * @dev Reverts if the caller is blacklisted
     */
    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}

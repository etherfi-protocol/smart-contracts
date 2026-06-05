// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Checkpoints.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
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
contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardTransient, PausableUntil, IWithdrawRequestNFT {
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

    // deprecated storage slots
    uint96 private __gap_2;
    uint256[3] private __gap_3;

    uint128 public ethAmountLockedForWithdrawal;
    mapping(uint256 => uint256) public totalRequestedWithdrawalAmount;
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
    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error IncorrectCaller();
    error AddressZero();
    error InvalidRequest();
    error RequestValid();
    error RequestNotValid();
    error RequestNotFound();
    error CannotUndoFinalization();
    error CannotFinalizeFutureRequests();
    error CannotInvalidateFinalizedRequest();
    error RequestAmountGreaterThanAvailableLiquidity();
    error InsufficientEscrow();
    error EthTransferFailed();
    error AlreadyClaimed();
    error RequestNotFinalized();
    error AlreadyInitialized();
    error NotInitialized();

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _treasury The address of the treasury.
     * @param _eETH The address of the eETH token.
     * @param _liquidityPool The address of the liquidity pool.
     * @param _roleRegistry The address of the role registry.
     * @param _blacklister The address of the blacklister.
     * @param _etherFiAdmin The address of the etherFi admin.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _treasury, address _eETH, address _liquidityPool, address _roleRegistry, address _blacklister,  address _etherFiAdmin) RolesLibrary(_roleRegistry) {
        treasury = _treasury;
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
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
        uint256 _totalRequestedWithdrawalAmount = 0;
        uint256 _nextRequestId = nextRequestId;
        for (uint256 requestId = lastFinalizedRequestId + 1; requestId < _nextRequestId; requestId++) {
            if (_requests[requestId].isValid) {
                _totalRequestedWithdrawalAmount += _requests[requestId].amountOfEEth;
            }
        }
        totalRequestedWithdrawalAmount[_nextRequestId - 1] = _totalRequestedWithdrawalAmount;
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
        totalRequestedWithdrawalAmount[requestId] = totalRequestedWithdrawalAmount[requestId - 1] + amountOfEEth;

        _safeMint(recipient, requestId);

        emit WithdrawRequestCreated(uint32(requestId), amountOfEEth, shareOfEEth, recipient);
        return requestId;
    }

    /**
     * @notice called by the NFT owner to claim their ETH
     * @param tokenId The ID of the withdrawal request
     * @dev burns the NFT and transfers ETH from the liquidity pool to the owner, withdraw request must be valid and finalized
     */
    function claimWithdraw(uint256 tokenId) external nonReentrant nonBlacklisted {
        return _claimWithdraw(tokenId);
    }

    /**
     * @notice Claims multiple withdraw requests
     * @param tokenIds The IDs of the withdrawal requests
     * @dev burns the NFTs and transfers ETH from the liquidity pool to the owners, withdraw requests must be valid and finalized
     */
    function batchClaimWithdraw(uint256[] calldata tokenIds) external nonReentrant nonBlacklisted {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i]);
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
     * @notice Invalidates a withdrawal request
     * @param requestId The ID of the withdrawal request
     * @dev Admin can only invalidate requests that have NOT been finalized yet
     */
    function invalidateRequest(uint256 requestId) external onlyGuardian {
        if (requestId <= lastFinalizedRequestId) revert CannotInvalidateFinalizedRequest();
        if (!isValid(requestId)) revert RequestNotValid();
        _requests[requestId].isValid = false;
        totalRequestedWithdrawalAmount[nextRequestId - 1] -= _requests[requestId].amountOfEEth;

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
            totalRequestedWithdrawalAmount[nextRequestId - 1] += _requests[requestId].amountOfEEth;
        }
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(uint32(requestId));
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  INTERNAL FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Gets the claimable amount for a withdrawal request
     * @param tokenId The ID of the withdrawal request
     * @return amountToWithdraw The amount of eETH that can be claimed
     * @dev For pre-upgrade legacy requests (covered only by the sentinel checkpoint with value 0),
     *      the live rate from `LP.amountPerShareCeil()` is substituted locally — preserving legacy
     *      claim semantics (live-rate at claim). The claimable amount is the lesser of the originally
     *      requested eETH amount and the frozen-rate value of the request's shares.
     */
    function _getClaimableAmount(uint256 tokenId) internal view returns (uint256 amountToWithdraw) {
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
        amountToWithdraw = Math.min(request.amountOfEEth, amountForShares);
    }

    /**
     * @notice Pays the request owner from this contract's own ETH balance (segregated at finalize via
     *         `addEthAmountLockedForWithdrawal`) and burns the request's full share allocation in LP.
     * @param tokenId The ID of the withdrawal request
     * @dev Permissionless: any caller can settle a finalized, valid request; proceeds always go to the
     *      NFT owner. Burns the request's full `shareOfEEth` via `LP.withdraw(amount, share)`, leaving no
     *      share remainder. Any ETH left over after paying the owner (e.g. from a negative rebase shrinking
     *      the claimable amount below the segregated escrow) is swept back to the LP.
     */
    function _claimWithdraw(uint256 tokenId) internal {
        address recipient = ownerOf(tokenId);
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        if (!request.isValid) revert RequestNotValid();

        uint256 amountToWithdraw = _getClaimableAmount(tokenId);

        _burn(tokenId);
        delete _requests[tokenId];

        if (ethAmountLockedForWithdrawal < amountToWithdraw) revert InsufficientEscrow();
        ethAmountLockedForWithdrawal -= uint128(request.amountOfEEth);

        liquidityPool.withdraw(amountToWithdraw, request.shareOfEEth);

        (bool ok, ) = payable(recipient).call{value: amountToWithdraw}("");
        if (!ok) revert EthTransferFailed();

        // Return any stranded ETH (balance above what is still locked) to LP. Guarded so an
        // under-funded contract (balance < locked) reverts cleanly via the invariant check below
        // rather than underflowing here.
        if (address(this).balance > ethAmountLockedForWithdrawal) {
            uint256 strandedEth = address(this).balance - ethAmountLockedForWithdrawal;
            (bool okStranded, ) = payable(address(liquidityPool)).call{value: strandedEth}("");
            if (!okStranded) revert EthTransferFailed();
        }

        _checkEthAmountLockedForWithdrawal();

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, request.shareOfEEth, recipient);
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
        return _getClaimableAmount(tokenId);
    }

    function getFinalizedWithdrawalAmount(uint32 requestId) external view returns (uint128) {
        return uint128(totalRequestedWithdrawalAmount[requestId] - totalRequestedWithdrawalAmount[lastFinalizedRequestId]);
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
     * @notice Modifier to check if the caller is not blacklisted
     * @dev Reverts if the caller is blacklisted
     */
    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}

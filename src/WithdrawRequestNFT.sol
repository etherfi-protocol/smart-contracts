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
import "./RoleRegistry.sol";
import "./ReentrancyGuardNamespaced.sol";
import "./utils/PausableUntil.sol";



contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardNamespaced, PausableUntil, IWithdrawRequestNFT {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINT_SCALE = 1e4;
    // this treasury address is set to ethfi buyback wallet address
    address public immutable treasury;
    
    ILiquidityPool private DEPRECATED_liquidityPool;
    IeETH private DEPRECATED_eETH;
    IMembershipManager private DEPRECATED_membershipManager;

    mapping(uint256 => IWithdrawRequestNFT.WithdrawRequest) private _requests;
    mapping(address => bool) private DEPRECATED_admins;

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
    RoleRegistry private DEPRECATED_roleRegistry;

    uint128 public ethAmountLockedForWithdrawal;

    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IMembershipManager public immutable membershipManager;
    RoleRegistry public immutable roleRegistry;
    IBlacklister public immutable blacklister;
    address public immutable etherFiAdmin;

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event HandledRemainderOfClaimedWithdrawRequests(uint256 eEthAmountToTreasury, uint256 eEthAmountBurnt);

    event Paused();
    event Unpaused();

    error IncorrectRole();
    error IncorrectCaller();
    error AddressZero();
    error AlreadyPaused();
    error NotPaused();
    error EETHAmountCannotBeZero();
    error NotAllPrevRequestsHaveBeenScanned();
    error NotEnoughEEthRemainder();
    error FeeReturnFailed();
    error InvalidRequest();
    error ContractPaused();
    error ScanCompleted();
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _treasury, address _eETH, address _liquidityPool, address _membershipManager, address _roleRegistry, address _blacklister, address _etherFiAdmin) {
        treasury = _treasury;
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipManager = IMembershipManager(_membershipManager);
        roleRegistry = RoleRegistry(_roleRegistry);
        blacklister = IBlacklister(_blacklister);
        etherFiAdmin = _etherFiAdmin;
        _disableInitializers();
    }

    function initialize(address _liquidityPoolAddress, address _eEthAddress, address _membershipManagerAddress) initializer external {
        if (_liquidityPoolAddress == address(0) || _eEthAddress == address(0) || _membershipManagerAddress == address(0)) revert AddressZero();
        __ERC721_init("Withdraw Request NFT", "WithdrawRequestNFT");
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextRequestId = 1;
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
        (uint256 amountToTransfer, uint256 fee) = _getClaimableAmount(tokenId);
        return amountToTransfer - fee;
    }

    function _getClaimableAmount(uint256 tokenId) internal view returns (uint256, uint256) {
        if (tokenId > lastFinalizedRequestId) revert RequestNotFinalized();
        if (ownerOf(tokenId) == address(0)) revert AlreadyClaimed();

        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];

        // send the lesser value of the originally requested amount of eEth or the current eEth value of the shares
        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        uint256 amountToTransfer = (request.amountOfEEth < amountForShares) ? request.amountOfEEth : amountForShares;
        uint256 fee = uint256(request.feeGwei) * 1 gwei;
        return (amountToTransfer, fee);
    }

    /// @notice called by the NFT owner to claim their ETH
    /// @dev burns the NFT and transfers ETH from the liquidity pool to the owner minus any fee, withdraw request must be valid and finalized
    /// @param tokenId the id of the withdraw request and associated NFT
    function claimWithdraw(uint256 tokenId) external nonReentrant nonBlacklisted {
        return _claimWithdraw(tokenId, ownerOf(tokenId));
    }
    
    /// @dev Pays the recipient from this contract's own ETH balance (segregated at finalize via LP.addEthAmountLockedForWithdrawal). Assumes non-decreasing share rate.
    function _claimWithdraw(uint256 tokenId, address recipient) internal {
        if (ownerOf(tokenId) != msg.sender) revert NotTheOwner();
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        if (!request.isValid) revert RequestNotValid();

        (uint256 amountToTransfer, uint256 fee) = _getClaimableAmount(tokenId);
        uint256 amountToWithdraw = amountToTransfer - fee;
        uint256 shareAmountToBurnForWithdrawal = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

        // transfer eth to recipient
        _burn(tokenId);
        delete _requests[tokenId];

        // update accounting
        totalRemainderEEthShares += request.shareOfEEth - shareAmountToBurnForWithdrawal;

        if (ethAmountLockedForWithdrawal < amountToTransfer) revert InsufficientEscrow();
        ethAmountLockedForWithdrawal -= uint128(amountToTransfer);

        uint256 amountBurnedShare = liquidityPool.withdraw(recipient, amountToWithdraw);
        assert (amountBurnedShare == shareAmountToBurnForWithdrawal);

        (bool ok, ) = payable(recipient).call{value: amountToWithdraw}("");
        if (!ok) revert EthTransferFailed();

        _checkEthAmountLockedForWithdrawal();

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, amountBurnedShare, recipient, 0);
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds) external nonReentrant nonBlacklisted {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i], ownerOf(tokenIds[i]));
        }
    }

    // This function is used to aggregate the sum of the eEth shares of the requests that have not been claimed yet.
    // To be triggered during the upgrade to the new version of the contract.
    function aggregateSumEEthShareAmount(uint256 _numReqsToScan) external {
        if (isScanOfShareRemainderCompleted()) revert ScanCompleted();

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
    function seizeInvalidRequest(uint256 requestId, address recipient) external onlyAdmin {
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

    function isValid(uint256 requestId) public view returns (bool) {
        if (!_exists(requestId)) revert RequestNotFound();
        return _requests[requestId].isValid;
    }

    function finalizeRequests(uint256 requestId) external {
        if (msg.sender != address(etherFiAdmin)) revert IncorrectRole();
        if (requestId < lastFinalizedRequestId) revert CannotUndoFinalization();
        if (requestId >= nextRequestId) revert CannotFinalizeFutureRequests();
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
            if (amount > address(liquidityPool).balance) revert RequestAmountGreaterThanAvailableLiquidity();
            liquidityPool.addEthAmountLockedForWithdrawal(uint128(amount));
        }
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(uint32(requestId));
    }

    function updateShareRemainderSplitToTreasuryInBps(uint16 _shareRemainderSplitToTreasuryInBps) external onlyAdmin {
        if (_shareRemainderSplitToTreasuryInBps > BASIS_POINT_SCALE) revert InvalidShareRemainderSplit();
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
    }

    function pauseContract() external onlyOperations {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused();
    }

    function unPauseContract() external onlyOperations {
        if (!paused) revert NotPaused();


        paused = false;
        emit Unpaused();
    }

    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    function unpauseContractUntil() external onlyOperations {
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
    function handleRemainder(uint256 _eEthAmount) external {
        if(!roleRegistry.hasRole(roleRegistry.EOA_2(), msg.sender)) revert IncorrectRole();
        if (_eEthAmount == 0) revert EETHAmountCannotBeZero(); 
        if (!isScanOfShareRemainderCompleted()) revert NotAllPrevRequestsHaveBeenScanned();
        if (getEEthRemainderAmount() < _eEthAmount) revert NotEnoughEEthRemainder();

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
            if (!ok) revert FeeReturnFailed();
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
            if (!_requests[tokenId].isValid && msg.sender != owner()) revert InvalidRequest();
        }
    }

    function _checkEthAmountLockedForWithdrawal() internal view {
        if (address(this).balance < ethAmountLockedForWithdrawal) revert InsufficientEscrow();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

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

    modifier onlyAdmin() {
        roleRegistry.onlyOperatingTimelock(msg.sender);
        _;
    }

    modifier onlyOperations() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }

    modifier onlyGuardian() {
        roleRegistry.onlyGuardian(msg.sender);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/IMembershipManager.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./RoleRegistry.sol";



contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, IWithdrawRequestNFT {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINT_SCALE = 1e4;
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

    uint256 public maxWithdrawalAmount;


    bytes32 public constant WITHDRAW_REQUEST_NFT_ADMIN_ROLE = keccak256("WITHDRAW_REQUEST_NFT_ADMIN_ROLE");
    bytes32 public constant IMPLICIT_FEE_CLAIMER_ROLE = keccak256("IMPLICIT_FEE_CLAIMER_ROLE");

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event HandledRemainderOfClaimedWithdrawRequests(uint256 eEthAmountToTreasury, uint256 eEthAmountBurnt);

    event Paused(address account);
    event Unpaused(address account);

    error IncorrectRole();
    error TooLargeWithdrawalAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _treasury) {
        treasury = _treasury;
        
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

    function setMaxWithdrawalAmount(uint256 _maxWithdrawalAmount) external onlyAdmin {
        maxWithdrawalAmount = _maxWithdrawalAmount;
    }

    /// @notice creates a withdraw request and issues an associated NFT to the recipient
    /// @dev liquidity pool contract will call this function when a user requests withdraw
    /// @param amountOfEEth amount of eETH requested for withdrawal
    /// @param shareOfEEth share of eETH requested for withdrawal
    /// @param recipient address to recieve with WithdrawRequestNFT
    /// @param fee fee to be subtracted from amount when recipient calls claimWithdraw
    /// @return uint256 id of the withdraw request
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient, uint256 fee) external payable onlyLiquidityPool whenNotPaused returns (uint256) {
        uint256 requestId = nextRequestId++;
        uint32 feeGwei = uint32(fee / 1 gwei);

        if(amountOfEEth > maxWithdrawalAmount) revert TooLargeWithdrawalAmount();

        _requests[requestId] = IWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, true, feeGwei);

        _safeMint(recipient, requestId);

        emit WithdrawRequestCreated(uint32(requestId), amountOfEEth, shareOfEEth, recipient, fee);
        return requestId;
    }

    function getClaimableAmount(uint256 tokenId) public view returns (uint256) {
        require(tokenId <= lastFinalizedRequestId, "Request is not finalized");
        require(ownerOf(tokenId) != address(0), "Already Claimed");

        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];

        // send the lesser value of the originally requested amount of eEth or the current eEth value of the shares
        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        uint256 amountToTransfer = (request.amountOfEEth < amountForShares) ? request.amountOfEEth : amountForShares;
        uint256 fee = uint256(request.feeGwei) * 1 gwei;

        return amountToTransfer - fee;
    }

    /// @notice called by the NFT owner to claim their ETH
    /// @dev burns the NFT and transfers ETH from the liquidity pool to the owner minus any fee, withdraw request must be valid and finalized
    /// @param tokenId the id of the withdraw request and associated NFT
    function claimWithdraw(uint256 tokenId) external whenNotPaused {
        return _claimWithdraw(tokenId, ownerOf(tokenId));
    }
    
    function _claimWithdraw(uint256 tokenId, address recipient) internal {
        require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        require(request.isValid, "Request is not valid");

        uint256 amountToWithdraw = getClaimableAmount(tokenId);
        uint256 shareAmountToBurnForWithdrawal = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

        // transfer eth to recipient
        _burn(tokenId);
        delete _requests[tokenId];

        // update accounting 
        totalRemainderEEthShares += request.shareOfEEth - shareAmountToBurnForWithdrawal;

        uint256 amountBurnedShare = liquidityPool.withdraw(recipient, amountToWithdraw);
        assert (amountBurnedShare == shareAmountToBurnForWithdrawal);

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, amountBurnedShare, recipient, 0);
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds) external whenNotPaused {
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

    function isValid(uint256 requestId) public view returns (bool) {
        require(_exists(requestId), "Request does not exist");
        return _requests[requestId].isValid;
    }

    function finalizeRequests(uint256 requestId) external onlyAdmin {
        require(requestId >= lastFinalizedRequestId, "Cannot undo finalization");
        require(requestId < nextRequestId, "Cannot finalize future requests");
        lastFinalizedRequestId = uint32(requestId);
    }

    function invalidateRequest(uint256 requestId) external onlyAdmin {
        require(isValid(requestId), "Request is not valid");
        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(uint32(requestId));
    }

    function validateRequest(uint256 requestId) external onlyAdmin {
        require(_exists(requestId), "Request does not exist");
        require(!_requests[requestId].isValid, "Request is valid");
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
        require(isScanOfShareRemainderCompleted(), "scan is not completed");
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (!paused) revert("Pausable: not paused");


        paused = false;
        emit Unpaused(msg.sender);
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

        emit HandledRemainderOfClaimedWithdrawRequests(eEthAmountToTreasury, liquidityPool.amountForShare(eEthSharesToBurn));
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
    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal override {
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 tokenId = firstTokenId + i;
            require(_requests[tokenId].isValid || msg.sender == owner(), "INVALID_REQUEST");
        }
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
        _;
    }
}

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


contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, IWithdrawRequestNFT {
    using Math for uint256;

    uint256 private constant BASIS_POINT_SCALE = 1e4;
    address public immutable treasury;
    
    ILiquidityPool public liquidityPool;
    IeETH public eETH; 
    IMembershipManager public membershipManager;

    mapping(uint256 => IWithdrawRequestNFT.WithdrawRequest) private _requests;
    mapping(address => bool) public admins;

    uint32 public nextRequestId;
    uint32 public lastFinalizedRequestId;
    uint16 public shareRemainderSplitToTreasuryInBps;

    // inclusive
    uint32 private _currentRequestIdToScanFromForShareRemainder;
    uint32 private _lastRequestIdToScanUntilForShareRemainder;

    uint256 public totalLockedEEthShares;

    bool public paused;
    address public pauser;

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event HandledRemainderOfClaimedWithdrawRequests(uint256 eEthAmountToTreasury, uint256 eEthAmountBurnt);

    event Paused(address account);
    event Unpaused(address account);
    

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

    function initializeOnUpgrade(address _pauser) external onlyOwner {
        require(pauser == address(0), "Already initialized");

        paused = false;
        pauser = _pauser;

        _currentRequestIdToScanFromForShareRemainder = 1;
        _lastRequestIdToScanUntilForShareRemainder = nextRequestId - 1;
    }

    /// @notice creates a withdraw request and issues an associated NFT to the recipient
    /// @dev liquidity pool contract will call this function when a user requests withdraw
    /// @param amountOfEEth amount of eETH requested for withdrawal
    /// @param shareOfEEth share of eETH requested for withdrawal
    /// @param recipient address to recieve with WithdrawRequestNFT
    /// @param fee fee to be subtracted from amount when recipient calls claimWithdraw
    /// @return uint256 id of the withdraw request
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient, uint256 fee) external payable onlyLiquidtyPool whenNotPaused returns (uint256) {
        uint256 requestId = nextRequestId++;
        uint32 feeGwei = uint32(fee / 1 gwei);

        _requests[requestId] = IWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, true, feeGwei);
        totalLockedEEthShares += shareOfEEth;

        _safeMint(recipient, requestId);

        emit WithdrawRequestCreated(uint32(requestId), amountOfEEth, shareOfEEth, recipient, fee);
        return requestId;
    }

    function getClaimableAmount(uint256 tokenId) public view returns (uint256) {
        require(tokenId < nextRequestId, "Request does not exist");
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

        // transfer eth to recipient
        _burn(tokenId);
        delete _requests[tokenId];
        
        uint256 shareAmountToBurnForWithdrawal = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);
        totalLockedEEthShares -= shareAmountToBurnForWithdrawal;

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
        // [scanFrom, scanUntil]
        uint256 scanFrom = _currentRequestIdToScanFromForShareRemainder;
        uint256 scanUntil = Math.min(_lastRequestIdToScanUntilForShareRemainder, scanFrom + _numReqsToScan - 1);

        for (uint256 i = scanFrom; i <= scanUntil; i++) {
            if (!_exists(i)) continue;
            totalLockedEEthShares += _requests[i].shareOfEEth;
        }

        _currentRequestIdToScanFromForShareRemainder = uint32(scanUntil + 1);
    }

    // Seize the request simply by transferring it to another recipient
    function seizeRequest(uint256 requestId, address recipient) external onlyOwner {
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
        require(_exists(requestId), "Request does not exist11");
        return _requests[requestId].isValid;
    }

    function finalizeRequests(uint256 requestId) external onlyAdmin {
        lastFinalizedRequestId = uint32(requestId);
    }

    function invalidateRequest(uint256 requestId) external onlyAdmin {
        require(isValid(requestId), "Request is not valid");
        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(uint32(requestId));
    }

    function validateRequest(uint256 requestId) external onlyAdmin {
        require(_exists(requestId), "Request does not exist22");
        require(!_requests[requestId].isValid, "Request is valid");
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(uint32(requestId));
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        require(_address != address(0), "Cannot be address zero");
        admins[_address] = _isAdmin;
    }

    function updateShareRemainderSplitToTreasuryInBps(uint16 _shareRemainderSplitToTreasuryInBps) external onlyOwner {
        require(_shareRemainderSplitToTreasuryInBps <= BASIS_POINT_SCALE, "INVALID");
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
    }

    function pauseContract() external onlyPauser {
        paused = true;
        emit Paused(msg.sender);
    }

    function unPauseContract() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @dev Handles the remainder of the eEth shares after the claim of the withdraw request
    /// the remainder eETH share for a request = request.shareOfEEth - request.amountOfEEth / (eETH amount to eETH shares rate)
    /// - Splits the remainder into two parts:
    ///  - Treasury: treasury gets a split of the remainder
    ///   - Burn: the rest of the remainder is burned
    /// @param _eEthAmount: the remainder of the eEth amount
    function handleRemainder(uint256 _eEthAmount) external onlyAdmin {
        require(getEEthRemainderAmount() >= _eEthAmount, "Not enough eETH remainder");
        require(_currentRequestIdToScanFromForShareRemainder == nextRequestId, "Not all requests have been scanned");

        uint256 beforeEEthShares = eETH.shares(address(this));
        
        uint256 eEthShares = liquidityPool.sharesForWithdrawalAmount(_eEthAmount);
        uint256 eEthSharesToTreasury = eEthShares.mulDiv(shareRemainderSplitToTreasuryInBps, BASIS_POINT_SCALE);

        uint256 eEthAmountToTreasury = liquidityPool.amountForShare(eEthSharesToTreasury);
        eETH.transfer(treasury, eEthAmountToTreasury);

        uint256 eEthSharesToBurn = eEthShares - eEthSharesToTreasury;
        eETH.burnShares(address(this), eEthSharesToBurn);

        uint256 reducedEEthShares = beforeEEthShares - eETH.shares(address(this));
        totalLockedEEthShares -= reducedEEthShares;

        emit HandledRemainderOfClaimedWithdrawRequests(eEthAmountToTreasury, liquidityPool.amountForShare(eEthSharesToBurn));
    }

    function getEEthRemainderAmount() public view returns (uint256) {
        uint256 eEthRemainderShare = eETH.shares(address(this)) - totalLockedEEthShares;
        return liquidityPool.amountForShare(eEthRemainderShare);
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
        require(admins[msg.sender], "Caller is not the admin");
        _;
    }

    modifier onlyPauser() {
        require(msg.sender == pauser || admins[msg.sender] || msg.sender == owner(), "Caller is not the pauser");
        _;
    }

    modifier onlyLiquidtyPool() {
        require(msg.sender == address(liquidityPool), "Caller is not the liquidity pool");
        _;
    }

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }
}

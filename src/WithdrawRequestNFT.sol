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

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event HandledRemainderOfClaimedWithdrawRequests(uint256 eEthAmountToTreasury, uint256 eEthAmountBurnt);

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

    /// @notice creates a withdraw request and issues an associated NFT to the recipient
    /// @dev liquidity pool contract will call this function when a user requests withdraw
    /// @param amountOfEEth amount of eETH requested for withdrawal
    /// @param shareOfEEth share of eETH requested for withdrawal
    /// @param recipient address to recieve with WithdrawRequestNFT
    /// @param fee fee to be subtracted from amount when recipient calls claimWithdraw
    /// @return uint256 id of the withdraw request
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient, uint256 fee) external payable onlyLiquidtyPool returns (uint256) {
        uint256 requestId = nextRequestId++;
        uint32 feeGwei = uint32(fee / 1 gwei);

        _requests[requestId] = IWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, true, feeGwei);
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
    function claimWithdraw(uint256 tokenId) external {
        return _claimWithdraw(tokenId, ownerOf(tokenId));
    }
    
    function _claimWithdraw(uint256 tokenId, address recipient) internal {
        require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        require(request.isValid, "Request is not valid");

        uint256 fee = uint256(request.feeGwei) * 1 gwei;
        uint256 amountToWithdraw = getClaimableAmount(tokenId);

        // transfer eth to recipient
        _burn(tokenId);
        delete _requests[tokenId];

        uint256 amountBurnedShare = 0;
        if (fee > 0) {
            amountBurnedShare += liquidityPool.withdraw(address(membershipManager), fee);
        }
        amountBurnedShare += liquidityPool.withdraw(recipient, amountToWithdraw);
        uint256 amountUnBurnedShare = request.shareOfEEth - amountBurnedShare;
        handleRemainder(amountUnBurnedShare);

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw + fee, amountBurnedShare, recipient, fee);
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i], ownerOf(tokenIds[i]));
        }
    }

    // There have been errors tracking `accumulatedDustEEthShares` in the past.
    // - https://github.com/etherfi-protocol/smart-contracts/issues/24
    // This is a one-time function to handle the remainder of the eEth shares after the claim of the withdraw requests
    // It must be called only once with ALL the requests that have not been claimed yet.
    // there are <3000 such requests and the total gas spending is expected to be ~9.0 M gas.
    function handleAccumulatedShareRemainder(uint256[] memory _reqIds, uint256 _scanBegin) external onlyOwner {      
        assert (_scanBegin < nextRequestId);

        bytes32 slot = keccak256("handleAccumulatedShareRemainder");
        uint256 executed;
        assembly {
            executed := sload(slot)
        }
        require(executed == 0, "ALREADY_EXECUTED");

        uint256 eEthSharesUnclaimedYet = 0;
        for (uint256 i = 0; i < _reqIds.length; i++) {
            if (!_requests[_reqIds[i]].isValid) continue;
            eEthSharesUnclaimedYet += _requests[_reqIds[i]].shareOfEEth;
        }
        for (uint256 i = _scanBegin + 1; i < nextRequestId; i++) {
            if (!_requests[i].isValid) continue;
            eEthSharesUnclaimedYet += _requests[i].shareOfEEth;
        }
        uint256 eEthSharesRemainder = eETH.shares(address(this)) - eEthSharesUnclaimedYet;

        handleRemainder(eEthSharesRemainder);

        assembly {
            sstore(slot, 1)
            executed := sload(slot)
        }
        assert (executed == 1);
    }

    // Given an invalidated withdrawal request NFT of ID `requestId`:,
    // - burn the NFT
    // - withdraw its ETH to the `recipient`
    function seizeInvalidRequest(uint256 requestId, address recipient) external onlyOwner {
        require(!_requests[requestId].isValid, "Request is valid");
        require(ownerOf(requestId) != address(0), "Already Claimed");

        // Bring the NFT to the `msg.sender` == contract owner
        _transfer(ownerOf(requestId), owner(), requestId);

        // Undo its invalidation to claim
        _requests[requestId].isValid = true;

        // its ETH amount is not locked
        // - if it was finalized when being invalidated, we revoked it via `reduceEthAmountLockedForWithdrawal`
        // - if it was not finalized when being invalidated, it was not locked
        uint256 ethAmount = getClaimableAmount(requestId);
        liquidityPool.addEthAmountLockedForWithdrawal(uint128(ethAmount));

        // withdraw the ETH to the recipient
        _claimWithdraw(requestId, recipient);

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
        lastFinalizedRequestId = uint32(requestId);
    }

    function invalidateRequest(uint256 requestId) external onlyAdmin {
        require(isValid(requestId), "Request is not valid");

        if (isFinalized(requestId)) {
            uint256 ethAmount = getClaimableAmount(requestId);
            liquidityPool.reduceEthAmountLockedForWithdrawal(uint128(ethAmount));
        }

        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(uint32(requestId));
    }

    function validateRequest(uint256 requestId) external onlyAdmin {
        require(!_requests[requestId].isValid, "Request is valid");
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(uint32(requestId));
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        require(_address != address(0), "Cannot be address zero");
        admins[_address] = _isAdmin;
    }

    function updateShareRemainderSplitToTreasuryInBps(uint16 _shareRemainderSplitToTreasuryInBps) external onlyOwner {
        shareRemainderSplitToTreasuryInBps = _shareRemainderSplitToTreasuryInBps;
    }

    /// @dev Handles the remainder of the eEth shares after the claim of the withdraw request
    /// the remainder eETH share for a request = request.shareOfEEth - request.amountOfEEth / (eETH amount to eETH shares rate)
    /// - Splits the remainder into two parts:
    ///  - Treasury: treasury gets a split of the remainder
    ///   - Burn: the rest of the remainder is burned
    /// @param _eEthShares: the remainder of the eEth shares
    function handleRemainder(uint256 _eEthShares) internal {
        uint256 eEthSharesToTreasury = _eEthShares.mulDiv(shareRemainderSplitToTreasuryInBps, BASIS_POINT_SCALE);

        uint256 eEthAmountToTreasury = liquidityPool.amountForShare(eEthSharesToTreasury);
        eETH.transfer(treasury, eEthAmountToTreasury);

        uint256 eEthSharesToBurn = _eEthShares - eEthSharesToTreasury;
        eETH.burnShares(address(this), eEthSharesToBurn);

        emit HandledRemainderOfClaimedWithdrawRequests(eEthAmountToTreasury, liquidityPool.amountForShare(eEthSharesToBurn));
    }

    // invalid NFTs is non-transferable except for the case they are being burnt by the owner via `seizeInvalidRequest`
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

    modifier onlyAdmin() {
        require(admins[msg.sender], "Caller is not the admin");
        _;
    }

    modifier onlyLiquidtyPool() {
        require(msg.sender == address(liquidityPool), "Caller is not the liquidity pool");
        _;
    }
}

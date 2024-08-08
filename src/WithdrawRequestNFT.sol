// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/IMembershipManager.sol";
import "./RoleRegistry.sol";


contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, IWithdrawRequestNFT {

    ILiquidityPool public liquidityPool;
    IeETH public eETH; 
    IMembershipManager public membershipManager;

    mapping(uint256 => IWithdrawRequestNFT.WithdrawRequest) private _requests;
    mapping(address => bool) public DEPRECATED_admins;

    uint32 public nextRequestId;
    uint32 public lastFinalizedRequestId;
    uint96 public accumulatedDustEEthShares; // to be burned or used to cover the validator churn cost

    RoleRegistry public roleRegistry;

    bytes32 public constant WITHDRAW_NFT_ADMIN_ROLE = keccak256("WITHDRAW_NFT_ADMIN_ROLE");

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);

    error IncorrectRole();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
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

    function initializeV2dot5(address _roleRegistry) external onlyOwner {
        require(address(roleRegistry) == address(0x00), "already initialized");

        // TODO: compile list of values in DEPRECATED_admins to clear out
        roleRegistry = RoleRegistry(_roleRegistry);
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

        if (fee > 0) {
            // send fee to membership manager
            liquidityPool.withdraw(address(membershipManager), fee);
        }

        uint256 amountBurnedShare = liquidityPool.withdraw(recipient, amountToWithdraw);
        uint256 amountUnBurnedShare = request.shareOfEEth - amountBurnedShare;
        if (amountUnBurnedShare > 0) {
            accumulatedDustEEthShares += uint96(amountUnBurnedShare);
        }

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw + fee, amountBurnedShare, recipient, fee);
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i], ownerOf(tokenIds[i]));
        }
    }

    // a function to transfer accumulated shares to admin
    function burnAccumulatedDustEEthShares() external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        require(eETH.totalShares() > accumulatedDustEEthShares, "Inappropriate burn");
        uint256 amount = accumulatedDustEEthShares;
        accumulatedDustEEthShares = 0;

        eETH.burnShares(address(this), amount);
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

    function calculateTotalPendingAmount(uint256 lastRequestId) public view returns (uint256) {
        uint256 totalAmount = 0;
        for (uint256 i = lastFinalizedRequestId + 1; i <= lastRequestId; i++) {
            if (!isValid(i)) continue;

            IWithdrawRequestNFT.WithdrawRequest memory request = _requests[i];
            uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
            uint256 amount = (request.amountOfEEth < amountForShares) ? request.amountOfEEth : amountForShares;

            totalAmount += amount;
        }
        return totalAmount;
    }

    function finalizeRequests(uint256 lastRequestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        uint128 totalAmount = uint128(calculateTotalPendingAmount(lastRequestId));
        _finalizeRequests(lastRequestId, totalAmount);
    }

    // It can be used to correct the total amount of pending withdrawals. There are some accounting erros as of now
    function finalizeRequests(uint256 lastRequestId, uint128 totalAmount) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        _finalizeRequests(lastRequestId, totalAmount);
    }

    function invalidateRequest(uint256 requestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        require(isValid(requestId), "Request is not valid");

        if (isFinalized(requestId)) {
            uint256 ethAmount = getClaimableAmount(requestId);
            liquidityPool.reduceEthAmountLockedForWithdrawal(uint128(ethAmount));
        }

        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(uint32(requestId));
    }

    function validateRequest(uint256 requestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        require(!_requests[requestId].isValid, "Request is valid");
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(uint32(requestId));
    }

    // invalid NFTs is non-transferable except for the case they are being burnt by the owner via `seizeInvalidRequest`
    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal override {
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 tokenId = firstTokenId + i;
            require(_requests[tokenId].isValid || msg.sender == owner(), "INVALID_REQUEST");
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _finalizeRequests(uint256 lastRequestId, uint128 totalAmount) internal {
        lastFinalizedRequestId = uint32(lastRequestId);
        liquidityPool.addEthAmountLockedForWithdrawal(totalAmount);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    modifier onlyLiquidtyPool() {
        require(msg.sender == address(liquidityPool), "Caller is not the liquidity pool");
        _;
    }
}

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

    FinalizationCheckpoint[] public finalizationCheckpoints;

    RoleRegistry public roleRegistry;

    bytes32 public constant WITHDRAW_NFT_ADMIN_ROLE = keccak256("WITHDRAW_NFT_ADMIN_ROLE");

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 DEPRECATED_burntShareOfEEth, address owner, uint256 fee);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event UpdateFinalizedRequestId(uint32 indexed requestId, uint128 finalizedAmount);

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

        // to avoid having to deal with the finalizationCheckpoints[index - 1] edgecase where the index is 0, we add a dummy checkpoint
        finalizationCheckpoints.push(FinalizationCheckpoint(0, 0));
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

    function getClaimableAmount(uint256 tokenId, uint256 checkpointIndex) public view returns (uint256) {
        require(tokenId <= lastFinalizedRequestId, "Request is not finalized");
        require(tokenId < nextRequestId, "Request does not exist");
        require(ownerOf(tokenId) != address(0), "Already Claimed");

        require(
            checkpointIndex != 0 &&
            checkpointIndex < finalizationCheckpoints.length, 
            "Invalid checkpoint index"
        );
        FinalizationCheckpoint memory lowerBoundCheckpoint = finalizationCheckpoints[checkpointIndex - 1];
        FinalizationCheckpoint memory checkpoint = finalizationCheckpoints[checkpointIndex];
        require(
            lowerBoundCheckpoint.lastFinalizedRequestId < tokenId && 
            tokenId <= checkpoint.lastFinalizedRequestId, 
            "Invalid checkpoint"
        );
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];

        // send the lesser ether ETH value of the originally requested amount of eEth or the eEth value at the last `cachedSharePrice` update
        uint256 cachedSharePrice = checkpoint.cachedShareValue;
        uint256 amountForSharesCached = request.shareOfEEth * cachedSharePrice / 1 ether;
        uint256 amountToTransfer = _min(request.amountOfEEth, amountForSharesCached);
        
        uint256 fee = uint256(request.feeGwei) * 1 gwei;

        return amountToTransfer - fee;
    }

    /// @notice called by the NFT owner to claim their ETH
    /// @dev burns the NFT and transfers ETH from the liquidity pool to the owner minus any fee, withdraw request must be valid and finalized
    /// @param tokenId the id of the withdraw request and associated NFT
    function claimWithdraw(uint256 tokenId, uint256 checkpointIndex) external {
        return _claimWithdraw(tokenId, ownerOf(tokenId), checkpointIndex);
    }
    
    function _claimWithdraw(uint256 tokenId, address recipient, uint256 checkpointIndex) internal {

        require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        require(request.isValid, "Request is not valid");

        uint256 fee = uint256(request.feeGwei) * 1 gwei;
        uint256 amountToWithdraw = getClaimableAmount(tokenId, checkpointIndex);

        // transfer eth to recipient
        _burn(tokenId);
        delete _requests[tokenId];

        if (fee > 0) {
            // send fee to membership manager
            _sendFund(address(membershipManager), fee);
        }
        _sendFund(recipient, amountToWithdraw);

        emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw + fee, 0, recipient, fee);
    }

    function batchClaimWithdraw(uint256[] calldata tokenIds, uint256[] calldata checkpointIndices) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claimWithdraw(tokenIds[i], ownerOf(tokenIds[i]), checkpointIndices[i]);
        }
    }

    // Reduce the accumulated dust eEth shares by the given amount
    // This is to fix the accounting error that was over-accumulating dust eEth shares due to the fee
    function updateAccumulatedDustEEthShares(uint96 amount) external onlyOwner {
        accumulatedDustEEthShares -= amount;
    }

    // a function to transfer accumulated shares to admin
    function withdrawAccumulatedDustEEthShares(address _recipient) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        uint256 shares = accumulatedDustEEthShares;
        accumulatedDustEEthShares = 0;

        uint256 amountForShares = liquidityPool.amountForShare(shares);
        eETH.transfer(_recipient, amountForShares);
    }

    // Given an invalidated withdrawal request NFT of ID `requestId`:,
    // - burn the NFT
    // - withdraw its ETH to the `recipient`
    function seizeInvalidRequest(uint256 requestId, address recipient, uint256 checkpointIndex) external onlyOwner {
        require(!_requests[requestId].isValid, "Request is valid");
        require(ownerOf(requestId) != address(0), "Already Claimed");

        // Bring the NFT to the `msg.sender` == contract owner
        _transfer(ownerOf(requestId), owner(), requestId);

        // Undo its invalidation to claim
        _requests[requestId].isValid = true;

        // withdraw the ETH to the recipient
        // TODO: fix this
        _claimWithdraw(requestId, recipient, checkpointIndex);

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

            IWithdrawRequestNFT.WithdrawRequest memory request = _requests[i];
            uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);

            uint256 amount = _min(request.amountOfEEth, amountForShares);

            totalAmount += amount;
        }
        return totalAmount;
    }

    function finalizeRequests(uint256 lastRequestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        uint128 totalAmount = uint128(calculateTotalPendingAmount(lastRequestId));
        uint256 cachedSharePrice = liquidityPool.amountForShare(1 ether);

        finalizationCheckpoints.push(FinalizationCheckpoint(uint32(lastRequestId), cachedSharePrice));
        
        // TODO: We can probably deprecate this variable and use the last element of the finalizationCheckpoints array
        lastFinalizedRequestId = uint32(lastRequestId);

        liquidityPool.withdraw(address(this), totalAmount);
        emit UpdateFinalizedRequestId(uint32(lastRequestId), totalAmount);
    }

    // Maybe deprecated ? I should try to fix any accounting errors and delete this function
    // It can be used to correct the total amount of pending withdrawals. There are some accounting erros as of now
    function finalizeRequests(uint256 lastRequestId, uint128 totalAmount) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        return;
    }

    function invalidateRequest(uint256 requestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        require(isValid(requestId), "Request is not valid");

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

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _sendFund(address _recipient, uint256 _amount) internal {
        uint256 balanace = address(this).balance;
        (bool sent, ) = _recipient.call{value: _amount}("");
        require(sent && address(this).balance == balanace - _amount, "SendFail");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // This contract only accepts ETH sent from the liquidity pool
    receive() external payable onlyLiquidtyPool() { }

    modifier onlyLiquidtyPool() {
        require(msg.sender == address(liquidityPool), "Caller is not the liquidity pool");
        _;
    }


    function getFinalizationCheckpoint(uint256 checkpointId) external view returns (FinalizationCheckpoint memory) {
        return finalizationCheckpoints[checkpointId];
    }

    /// @dev View function to find a finalization checkpoint to use in `claimWithdraw()` 
    ///  Search will be performed in the range of `[_start, _end]` over the `finalizationCheckpoints` array
    ///
    /// @param _requestId request id to search the checkpoint for
    /// @param _start index of the left boundary of the search range
    /// @param _end index of the right boundary of the search range, should be less than or equal to `finalizationCheckpoints.length`
    ///
    /// @return index into `finalizationCheckpoints` that the `_requestId` belongs to. 
    function findCheckpointIndex(uint256 _requestId, uint256 _start, uint256 _end) public view returns (uint256) {
        require(_requestId <= lastFinalizedRequestId, "Request is not finalized");
        require(_start <= _end, "Invalid range");
        require(_end < finalizationCheckpoints.length, "End index out of bounds of finalizationCheckpoints");

        // Binary search
        uint256 min = _start;
        uint256 max = _end;

        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (finalizationCheckpoints[mid].lastFinalizedRequestId < _requestId) {

                // if mid index in the array is less than the request id, we need to move up the array, as the index we are looking for has 
                // a `finalizationCheckpoints[mid].lastFinalizedRequestId` greater than the request id


                min = mid;
            } else {
                // by getting here, we have a `finalizationCheckpoints[mid].lastFinalizedRequestId` greater than the request id
                // to know we have found the right index, finalizationCheckpoints[mid - 1].lastFinalizedRequestId` must be less than the request id

                if (finalizationCheckpoints[mid - 1].lastFinalizedRequestId < _requestId) {
                    return mid;
                }

                max = mid - 1; // there are values to the left of mid that are greater than the request id
            }
        }
    }

    // Add a getter function for the length of the array
    function getFinalizationCheckpointsLength() public view returns (uint256) {
        return finalizationCheckpoints.length;
    }

}

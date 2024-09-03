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
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    ILiquidityPool public liquidityPool;
    IeETH public eETH; 
    IMembershipManager public membershipManager;

    mapping(uint256 => IWithdrawRequestNFT.WithdrawRequest) private _requests;
    mapping(address => bool) public DEPRECATED_admins;

    uint32 public nextRequestId;
    uint32 public lastFinalizedRequestId;
    uint96 public DEPRECATED_accumulatedDustEEthShares; // to be burned or used to cover the validator churn cost

    FinalizationCheckpoint[] public finalizationCheckpoints;

    RoleRegistry public roleRegistry;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ----------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant WITHDRAW_NFT_ADMIN_ROLE = keccak256("WITHDRAW_NFT_ADMIN_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event WithdrawRequestCreated(uint32 indexed requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner);
    event WithdrawRequestClaimed(uint32 indexed requestId, uint256 amountOfEEth, uint256 DEPRECATED_burntShareOfEEth, address owner);
    event WithdrawRequestInvalidated(uint32 indexed requestId);
    event WithdrawRequestValidated(uint32 indexed requestId);
    event WithdrawRequestSeized(uint32 indexed requestId);
    event UpdateFinalizedRequestId(uint32 indexed requestId, uint256 finalizedAmount);

    error IncorrectRole();

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

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
        DEPRECATED_accumulatedDustEEthShares = 0;

        roleRegistry = RoleRegistry(_roleRegistry);
        finalizationCheckpoints.push(FinalizationCheckpoint(0, 0));
    }

    /// @notice creates a withdraw request and issues an associated NFT to the recipient
    /// @dev liquidity pool contract will call this function when a user requests withdraw
    /// @param amountOfEEth amount of eETH requested for withdrawal
    /// @param shareOfEEth share of eETH requested for withdrawal
    /// @param recipient address to recieve with WithdrawRequestNFT
    /// @return uint256 id of the withdraw request
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient) external payable onlyLiquidityPool returns (uint32) {
        uint32 requestId = nextRequestId++; 

        _requests[requestId] = IWithdrawRequestNFT.WithdrawRequest(amountOfEEth, shareOfEEth, true, 0);
        _safeMint(recipient, requestId);

        emit WithdrawRequestCreated(uint32(requestId), amountOfEEth, shareOfEEth, recipient);
        return requestId;
    }

    /// @notice called by the NFT owner of a finalized request to claim their ETH
    /// @dev `checkpointIndex` can be found using `findCheckpointIndex` function
    /// @param requestId the id of the withdraw request and associated NFT
    /// @param checkpointIndex the index of the `finalizationCheckpoints` that the request belongs to.
    function claimWithdraw(uint32 requestId, uint32 checkpointIndex) external {
        return _claimWithdraw(requestId, ownerOf(requestId), checkpointIndex);
    }

    /// @notice Batch version of `claimWithdraw`
    function batchClaimWithdraw(uint32[] calldata requestIds, uint32[] calldata checkpointIndices) external {
        for (uint32 i = 0; i < requestIds.length; i++) {
            _claimWithdraw(requestIds[i], ownerOf(requestIds[i]), checkpointIndices[i]);
        }
    }

    /// @notice allows the admin to withdraw the accumulated dust eETH
    function withdrawAccumulatedDustEEth(address _recipient) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        uint256 dust = getAccumulatedDustEEthAmount();

        // the dust amount is monotonically increasing, so we can just transfer the whole amount
        eETH.transfer(_recipient, dust);
    }

    function seizeInvalidRequest(uint32 requestId, address recipient, uint32 checkpointIndex) external onlyOwner {
        require(!_requests[requestId].isValid, "Request is valid");
        require(ownerOf(requestId) != address(0), "Already Claimed");

        // Bring the NFT to the `msg.sender` == contract owner
        _transfer(ownerOf(requestId), owner(), requestId);

        // Undo its invalidation to claim
        _requests[requestId].isValid = true;

        _claimWithdraw(requestId, recipient, checkpointIndex);

        emit WithdrawRequestSeized(requestId);
    }

    function finalizeRequests(uint32 lastRequestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        uint256 totalAmount = uint256(calculateTotalPendingAmount(lastRequestId));
        uint256 cachedSharePrice = liquidityPool.amountForShare(1 ether);

        finalizationCheckpoints.push(FinalizationCheckpoint(uint32(lastRequestId), cachedSharePrice));
        
        lastFinalizedRequestId = lastRequestId;

        if (totalAmount > 0) {
            liquidityPool.withdraw(address(this), totalAmount);
        }

        emit UpdateFinalizedRequestId(lastRequestId, totalAmount);
    }

    function invalidateRequest(uint32 requestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        require(isValid(requestId), "Request is not valid");

        _requests[requestId].isValid = false;

        emit WithdrawRequestInvalidated(requestId);
    }

    function validateRequest(uint32 requestId) external {
        if (!roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        require(!_requests[requestId].isValid, "Request is valid");
        
        _requests[requestId].isValid = true;

        emit WithdrawRequestValidated(requestId);
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  VIEW FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice returns the value of a request after finalization. The value of a request can be:
    ///  - nominal (when the amount of eth locked for this request are equal to the request's eETH)
    ///  - discounted (when the amount of eth will be lower, because the protocol share rate dropped
    ///   before request is finalized, so it will be equal to `request's shares` * `protocol share rate`)
    /// @param requestId the id of the withdraw request NFT
    /// @param checkpointIndex the index of the `finalizationCheckpoints` that the request belongs to.
    /// `checkpointIndex` can be found using `findCheckpointIndex` function
    /// @return uint256 the amount of ETH that can be claimed by the owner of the NFT
    function getClaimableAmount(uint32 requestId, uint32 checkpointIndex) public view returns (uint256) {
        require(requestId <= lastFinalizedRequestId, "Request is not finalized");
        require(requestId < nextRequestId, "Request does not exist");
        require(ownerOf(requestId) != address(0), "Already claimed");

        require(
            checkpointIndex != 0 &&
            checkpointIndex < finalizationCheckpoints.length, 
            "Invalid checkpoint index"
        );
        FinalizationCheckpoint memory lowerBoundCheckpoint = finalizationCheckpoints[checkpointIndex - 1];
        FinalizationCheckpoint memory checkpoint = finalizationCheckpoints[checkpointIndex];
        require(
            lowerBoundCheckpoint.lastFinalizedRequestId < requestId && 
            requestId <= checkpoint.lastFinalizedRequestId, 
            "Checkpoint does not contain the request"
        );

        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[requestId];
        uint256 amountForSharesCached = request.shareOfEEth * checkpoint.cachedShareValue / 1 ether;
        uint256 amountToTransfer = _min(request.amountOfEEth, amountForSharesCached);

        return amountToTransfer;
    }

    /// @dev View function to find a finalization checkpoint to use in `claimWithdraw()` 
    ///  Search will be performed in the range of `[_start, _end]` over the `finalizationCheckpoints` array
    ///
    /// @param _requestId request id to search the checkpoint for
    /// @param _start index of the left boundary of the search range
    /// @param _end index of the right boundary of the search range, should be less than or equal to `finalizationCheckpoints.length`
    ///
    /// @return index into `finalizationCheckpoints` that the `_requestId` belongs to. 
    function findCheckpointIndex(uint32 _requestId, uint32 _start, uint32 _end) public view returns (uint32) {
        require(_requestId <= lastFinalizedRequestId, "Request is not finalized");
        require(_start <= _end, "Invalid range");
        require(_end < finalizationCheckpoints.length, "End index out of bounds of finalizationCheckpoints");

        // Binary search
        uint32 min = _start;
        uint32 max = _end;

        while (max > min) {
            uint32 mid = (max + min + 1) / 2;
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

    /// @notice The excess eETH balance of this contract beyond what is needed to fulfill withdrawal requests.
    /// This excess accumulates due to:
    /// - eETH requested for withdrawal accruing staking rewards until the withdrawal is finalized. 
    ///   Any remaining positive rebase rewards stay in the contract after finalization
    /// - eETH balance calculation includes integer division, and there is a common case when the whole eETH 
    /// balance can't be transferred from the account while leaving the last 1-2 wei on the sender's account
    function getAccumulatedDustEEthAmount() public view returns (uint256) {
        uint256 amountRequestedWithdraw = calculateTotalPendingAmount(nextRequestId - 1);

        uint256 contractEEthBalance = eETH.balanceOf(address(this));

        return contractEEthBalance - amountRequestedWithdraw;
    }

    /// @notice The amount of eETH that needed to fulfill the pending withdrawal requests up to and including `lastRequestId`
    function calculateTotalPendingAmount(uint32 lastRequestId) public view returns (uint256) {
        uint256 totalAmount = 0;
        for (uint32 i = lastFinalizedRequestId + 1; i <= lastRequestId; i++) {

            IWithdrawRequestNFT.WithdrawRequest memory request = _requests[i];
            uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
            uint256 amount = _min(request.amountOfEEth, amountForShares);

            totalAmount += amount;
        }
        return totalAmount;
    }

    function getFinalizationCheckpoint(uint32 checkpointId) external view returns (FinalizationCheckpoint memory) {
        return finalizationCheckpoints[checkpointId];
    }

    function getFinalizationCheckpointsLength() public view returns (uint32) {
        return uint32(finalizationCheckpoints.length);
    }

    function getRequest(uint32 requestId) external view returns (IWithdrawRequestNFT.WithdrawRequest memory) {
        return _requests[requestId];
    }


    function isFinalized(uint32 requestId) public view returns (bool) {
        return requestId <= lastFinalizedRequestId;
    }

    function isValid(uint32 requestId) public view returns (bool) {
        require(_exists(requestId), "Request does not exist");
        return _requests[requestId].isValid;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    function _claimWithdraw(uint32 requestId, address recipient, uint32 checkpointIndex) internal {

        require(ownerOf(requestId) == msg.sender, "Not the owner of the NFT");
        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[requestId];
        require(request.isValid, "Request is not valid");

        uint256 amountToWithdraw = getClaimableAmount(requestId, checkpointIndex);

        // transfer eth to recipient
        _burn(requestId);
        delete _requests[requestId];

        _sendFund(recipient, amountToWithdraw);

        emit WithdrawRequestClaimed(requestId, amountToWithdraw, 0, recipient);
    }

    // invalid NFTs is non-transferable except for the case they are being burnt by the owner via `seizeInvalidRequest`
    function _beforeTokenTransfer(address /*from*/, address /*to*/, uint256 firstTokenId, uint256 batchSize) internal view override {
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 tokenId = firstTokenId + i;
            require(_requests[tokenId].isValid || msg.sender == owner(), "INVALID_REQUEST");
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _sendFund(address _recipient, uint256 _amount) internal {
        uint256 balanace = address(this).balance;
        (bool sent, ) = _recipient.call{value: _amount}("");
        require(sent && address(this).balance == balanace - _amount, "SendFail");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    // This contract only accepts ETH sent from the liquidity pool
    receive() external payable onlyLiquidityPool() { }

    modifier onlyLiquidityPool() {
        require(msg.sender == address(liquidityPool), "Caller is not the liquidity pool");
        _;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IWithdrawRequestNFT.sol";
import "./interfaces/IMembershipManager.sol";


contract WithdrawRequestNFT is ERC721Upgradeable, UUPSUpgradeable, OwnableUpgradeable, IWithdrawRequestNFT {

    ILiquidityPool public liquidityPool;
    IeETH public eETH; 
    IMembershipManager public membershipManager;

    mapping(uint256 => IWithdrawRequestNFT.WithdrawRequest) private _requests;
    mapping(address => bool) public admins;

    uint32 public nextRequestId;
    uint32 public lastFinalizedRequestId;

    event WithdrawRequestCreated(uint32 requestId, uint256 amountOfEEth, uint256 shareOfEEth, address owner, uint256 fee);
    event WithdrawRequestClaimed(uint32 requestId, uint256 amountOfEEth, uint256 burntShareOfEEth, address owner, uint256 fee);

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

    /// @notice called by the NFT owner to claim their ETH
    /// @dev burns the NFT and transfers ETH from the liquidity pool to the owner minus any fee, withdraw request must be valid and finalized
    /// @param tokenId the id of the withdraw request and associated NFT
    function claimWithdraw(uint256 tokenId) external {
        require(tokenId <= nextRequestId, "Request does not exist");
        require(tokenId <= lastFinalizedRequestId, "Request is not finalized");
        require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");

        IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
        require(request.isValid, "Request is not valid");

        // send the lesser value of the originally requested amount of eEth or the current eEth value of the shares
        uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
        uint256 amountToTransfer = (request.amountOfEEth < amountForShares) ? request.amountOfEEth : amountForShares;
        require(amountToTransfer > 0, "Amount to transfer is zero");

        // transfer eth to requester
        address recipient = ownerOf(tokenId);
        _burn(tokenId);
        delete _requests[tokenId];

        uint256 fee = request.feeGwei * 1 gwei;
        if (fee > 0) {
            // send fee to membership manager
            liquidityPool.withdraw(address(membershipManager), fee);
        }

        uint256 amountBurnedShare = liquidityPool.withdraw(recipient, amountToTransfer - fee);

        emit WithdrawRequestClaimed(uint32(tokenId), amountToTransfer, amountBurnedShare, recipient, fee);
    }
    
    // add function to transfer accumulated shares to admin

    function getRequest(uint256 requestId) external view returns (IWithdrawRequestNFT.WithdrawRequest memory) {
        return _requests[requestId];
    }

    function isFinalized(uint256 requestId) external view returns (bool) {
        return requestId <= lastFinalizedRequestId;
    }

    function finalizeRequests(uint256 requestId) external onlyAdmin {
        lastFinalizedRequestId = uint32(requestId);
    }

    function invalidateRequest(uint256 requestId) external onlyAdmin {
        _requests[requestId].isValid = false;
    }

    function updateLiquidityPool(address _newLiquidityPool) external onlyAdmin {
        require(_newLiquidityPool != address(0), "Cannot be address zero");
        liquidityPool = ILiquidityPool(_newLiquidityPool);
    }

    function updateEEth(address _newEEth) external onlyAdmin {
        require(_newEEth != address(0), "Cannot be address zero");
        eETH = IeETH(_newEEth);
    }

    function updateMembershipManager(address _newMembershipManager) external onlyAdmin {
        require(_newMembershipManager != address(0), "Cannot be address zero");
        membershipManager = IMembershipManager(_newMembershipManager);
    }

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        require(_address != address(0), "Cannot be address zero");
        admins[_address] = _isAdmin;
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
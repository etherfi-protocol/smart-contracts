// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./interfaces/IMembershipNFT.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IEtherFiNode.sol";

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";


/**
 * @title Escrow
 * @dev A contract for escrowing NFT trades between a multi-sig wallet and a staker.
 */
contract NFTExchange is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IERC721 public tNft;
    IMembershipNFT public membershipNft;
    IEtherFiNodesManager nodesMgr;

    mapping (uint256 => address) public reservedBuyers;
    mapping (uint256 => uint256) public targetTNftTokenIds;
    address public admin;

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Sets the addresses for the T-NFT and membership NFT contracts.
     * @param _tNft The address of the T-NFT contract.
     * @param _membershipNft The address of the membership NFT contract.
     */
    function initialize(address _tNft, address _membershipNft, address _nodesMgr) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        tNft = IERC721(_tNft);
        membershipNft = IMembershipNFT(_membershipNft);
        nodesMgr = IEtherFiNodesManager(_nodesMgr);
    }

    /**
     * @dev Allows the owner to list membership NFTs for sale.
     * @param _mNftTokenIds The token IDs of the membership NFTs to list for sale.
     * @param _targetTNftTokenIds The token IDs of the T-NFTs to be traded for.
     * @param _reservedBuyers The addresses of the reserved buyers for each NFT.
     */
    function listForSale(uint256[] calldata _mNftTokenIds, uint256[] calldata _targetTNftTokenIds, address[] calldata _reservedBuyers) external onlyAdmin {
        require(_mNftTokenIds.length == _reservedBuyers.length, "Input arrays must be the same length");
        for (uint256 i = 0; i < _mNftTokenIds.length; i++) {
            uint256 mNftTokenId = _mNftTokenIds[i];

            reservedBuyers[mNftTokenId] = _reservedBuyers[i];
            targetTNftTokenIds[mNftTokenId] = _targetTNftTokenIds[i];

            membershipNft.safeTransferFrom(msg.sender, address(this), mNftTokenId, 1, "");
        }
    }

    /**
     * @dev Allows a reserved buyer to purchase a membership NFT with a T-NFT.
     * @param _tnftTokenIds The token IDs of the T-NFTs to trade.
     * @param _mNftTokenIds The token IDs of the membership NFTs to purchase.
     */
    function buy(uint256[] calldata _tnftTokenIds, uint256[] calldata _mNftTokenIds) external nonReentrant {
        require(_tnftTokenIds.length == _mNftTokenIds.length, "Input arrays must be the same length");
        for (uint256 i = 0; i < _mNftTokenIds.length; i++) {
            uint256 tnftTokenId = _tnftTokenIds[i];
            uint256 mNftTokenId = _mNftTokenIds[i];

            require(reservedBuyers[mNftTokenId] != address(0), "Token is not currently listed for sale");
            require(msg.sender == reservedBuyers[mNftTokenId], "You are not the reserved buyer");
            require(tnftTokenId == targetTNftTokenIds[mNftTokenId], "The T-NFT is not the target");

            require(nodesMgr.phase(tnftTokenId) == IEtherFiNode.VALIDATOR_PHASE.LIVE, "The validator is not LIVE");

            reservedBuyers[mNftTokenId] = address(0);
            targetTNftTokenIds[mNftTokenId] = 0;

            tNft.transferFrom(msg.sender, owner(), tnftTokenId);
            membershipNft.safeTransferFrom(address(this), msg.sender, mNftTokenId, 1, "");
        }
    }

    /**
     * @dev Allows the owner to delist membership NFTs from sale.
     * @param _mNftTokenIds The token IDs of the membership NFTs to delist.
     */
    function delist(uint256[] calldata _mNftTokenIds) external onlyAdmin nonReentrant {
        for (uint256 i = 0; i < _mNftTokenIds.length; i++) {
            uint256 tokenId = _mNftTokenIds[i];
            require(reservedBuyers[tokenId] != address(0), "Token is not currently listed for sale");

            reservedBuyers[tokenId] = address(0);
            targetTNftTokenIds[tokenId] = 0;

            membershipNft.safeTransferFrom(address(this), owner(), tokenId, 1, "");
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns(bytes4) {
        return this.onERC1155Received.selector;
    }

    /// @notice Updates the address of the admin
    /// @param _newAdmin the new address to set as admin
    function updateAdmin(address _newAdmin) external onlyOwner {
        require(_newAdmin != address(0), "Cannot be address zero");
        admin = _newAdmin;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  MODIFIER  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        require(msg.sender == admin, "Caller is not the admin");
        _;
    }

}

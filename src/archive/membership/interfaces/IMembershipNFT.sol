// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC1155/IERC1155Upgradeable.sol";

interface IMembershipNFT is IERC1155Upgradeable {

    struct NftData {
        uint32 transferLockedUntil; // in terms of blocck number
        uint8[28] __gap;
    }

    function initialize(string calldata _metadataURI, address _membershipManagerAddress) external;

    function incrementLock(uint256 _tokenId, uint32 _blocks) external;
    function burn(address _from, uint256 _tokenId, uint256 _amount) external;

    function nextMintTokenId() external view returns (uint32);
    function valueOf(uint256 _tokenId) external view returns (uint256);
    function loyaltyPointsOf(uint256 _tokenId) external view returns (uint40);
    function tierPointsOf(uint256 _tokenId) external view returns (uint40);
    function tierOf(uint256 _tokenId) external view returns (uint8);
    function claimableTier(uint256 _tokenId) external view returns (uint8);
    function accruedLoyaltyPointsOf(uint256 _tokenId) external view returns (uint40);
    function accruedTierPointsOf(uint256 _tokenId) external view returns (uint40);
    function accruedStakingRewardsOf(uint256 _tokenId) external view returns (uint);
    function isWithdrawable(uint256 _tokenId, uint256 _withdrawalAmount) external view returns (bool);
    function allTimeHighDepositOf(uint256 _tokenId) external view returns (uint256);
    function transferLockedUntil(uint256 _tokenId) external view returns (uint32);
    function balanceOfUser(address _user, uint256 _id) external view returns (uint256);

    function contractURI() external view returns (string memory);
    function setContractMetadataURI(string calldata _newURI) external;
    function setMetadataURI(string calldata _newURI) external;

    function alertMetadataUpdate(uint256 id) external;
    function alertBatchMetadataUpdate(uint256 startID, uint256 endID) external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC1155/IERC1155Upgradeable.sol";

interface IMembershipNFT is IERC1155Upgradeable {

    struct NftData {
        uint32 transferLockedUntil; // in terms of blocck number
        uint8[28] __gap;
    }

    function initialize(string calldata _metadataURI) external;
    function setMembershipManager(address _address) external;
    function computeTierPointsForEap(uint32 _eapDepositBlockNumber) external view returns (uint40);
    function setUpForEap(bytes32 _newMerkleRoot, uint64[] calldata _requiredEapPointsPerEapDeposit) external;
    function processDepositFromEapUser(address _user, uint32  _eapDepositBlockNumber, uint256 _snapshotEthAmount, uint256 _points, bytes32[] calldata _merkleProof) external;
    
    function incrementLock(uint256 _tokenId, uint32 _blocks) external;
    function mint(address _to, uint256 _amount) external returns (uint256);
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
    function canTopUp(uint256 _tokenId, uint256 _totalAmount, uint128 _amount, uint128 _amountForPoints) external view returns (bool);
    function isWithdrawable(uint256 _tokenId, uint256 _withdrawalAmount) external view returns (bool);
    function allTimeHighDepositOf(uint256 _tokenId) external view returns (uint256);
    function transferLockedUntil(uint256 _tokenId) external view returns (uint32);
    function balanceOfUser(address _user, uint256 _id) external returns (uint256);

    function contractURI() external view returns (string memory);
    function setContractMetadataURI(string calldata _newURI) external;
    function setMetadataURI(string calldata _newURI) external;
    function setMaxTokenId(uint32 _maxTokenId) external;

    function alertMetadataUpdate(uint256 id) external;
    function alertBatchMetadataUpdate(uint256 startID, uint256 endID) external;
}

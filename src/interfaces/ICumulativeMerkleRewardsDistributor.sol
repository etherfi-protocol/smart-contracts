// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// Allows anyone to claim a token if they exist in a merkle root.
interface ICumulativeMerkleRewardsDistributor {

    event MerkleRootUpdated(bytes32 oldMerkleRoot, bytes32 newMerkleRoot);
    event Claimed(address indexed token, address indexed account, uint256 amount);
    event PendingMerkleRootUpdated(address indexed token, bytes32 merkleRoot);
    event ClaimableMerkleRootUpdated(address indexed token, bytes32 oldMerkleRoot, bytes32 newMerkleRoot, uint256 rewardsCalculatedToBlock);

    error IncorrectRole();
    error InsufficentDelay();
    error InvalidProof();
    error MerkleRootWasUpdated();
    error NothingToClaim();

    // Sets the merkle root of the merkle tree containing cumulative account balances available to claim.
    function setPendingMerkleRoot(address _token, bytes32 _merkleRoot) external;
    function finalizeMerkleRoot(address _token, uint256 _finalizedBlock) external;
    // Claim the given amount of the token to the given address. Reverts if the inputs are invalid.
    function claim(
        address token, 
        address account,
        uint256 cumulativeAmount,
        bytes32 expectedMerkleRoot,
        bytes32[] calldata merkleProof
    ) external;
}
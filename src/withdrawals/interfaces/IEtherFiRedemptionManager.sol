// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IEtherFiRedemptionManager {
    function redeem(uint256 amount, address receiver, address outputToken) external;
    function redeemWeEth(uint256 weEthAmount, address receiver, address outputToken) external;
    function setClaimDelay(uint256 _claimDelay) external;
    function setPendingMerkleRoot(address _token, bytes32 _merkleRoot) external;
    function finalizeMerkleRoot(address _token, uint256 _finalizedBlock) external;
    function claimableMerkleRoots(address _token) external view returns (bytes32);
    function lastRewardsCalculatedToBlock(address _token) external view returns (uint256);
    function lastPendingMerkleUpdatedToTimestamp(address _token) external view returns (uint256);
    function claimDelay() external view returns (uint256);
    function pendingMerkleRoots(address _token) external view returns (bytes32);
    function pauseContract() external;
    function unPauseContract() external;
    function pauseContractUntil() external;
    function unpauseContractUntil() external;
    function setPauseUntilDuration(uint256 _pauseUntilDuration) external;
}
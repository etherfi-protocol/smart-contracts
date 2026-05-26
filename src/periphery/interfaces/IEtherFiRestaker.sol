// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@etherfi/periphery/interfaces/ILiquifier.sol";

interface IEtherFiRestaker {
    function stEthRequestWithdrawal(uint256 _amount) external returns (uint256[] memory);
    function stEthClaimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external;
    function depositIntoStrategy(address token, uint256 amount) external returns (uint256);
    function queueWithdrawals(address token, uint256 amount) external returns (bytes32[] memory);
    function undelegate() external returns (bytes32[] memory);
    function transferStETH(address recipient, uint256 amount) external;
    function lido() external view returns (ILido);
    function pauseContract() external;
    function unPauseContract() external;
}
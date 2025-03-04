// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../../test/mocks/MockDelegationManagerBase.sol";
import "../../src/eigenlayer-interfaces/IDelegationManager.sol";
import "../../test/mocks/MockStrategy.sol";
import "forge-std/console2.sol";
import "forge-std/Test.sol";


contract MockDelegationManager is MockDelegationManagerBase, Test {

    constructor() {
        mock_beaconChainETHStrategy = new MockStrategy();
    }

    // OVERRIDES

    //************************************************************
    // beaconChainETHStrategy()
    //************************************************************
    IStrategy mock_beaconChainETHStrategy;
    function beaconChainETHStrategy() external view override returns (IStrategy) {
        return mock_beaconChainETHStrategy;
    }

    //************************************************************
    // withdrawableShares()
    //************************************************************
    mapping(address => mapping(IStrategy => uint256)) public mock_withdrawableShares;
    mapping(address => mapping(IStrategy => uint256)) public mock_depositShares;
    function mockSet_withdrawableShares(address staker, IStrategy strategy, uint256 withdrawableShares, uint256 depositShares) external {
        mock_withdrawableShares[staker][strategy] = withdrawableShares;
        mock_depositShares[staker][strategy] = depositShares;
    }
    function getWithdrawableShares(address staker, IStrategy[] memory strategies) external override view returns (uint256[] memory withdrawableShares, uint256[] memory depositShares) {
        withdrawableShares = new uint256[](strategies.length);
        depositShares = new uint256[](strategies.length);
        for (uint256 i; i < strategies.length; i++) {
            withdrawableShares[i] = mock_withdrawableShares[staker][strategies[i]];
            depositShares[i] = mock_depositShares[staker][strategies[i]];
        }
    }

    //************************************************************
    // queueWithdrawals()
    //************************************************************
    event mockEvent_queuedWithdrawalShares(uint256 shares);
    function queueWithdrawals(IDelegationManagerTypes.QueuedWithdrawalParams[] calldata params) external override returns (bytes32[] memory) {
        uint256 queuedShares;
        for (uint256 i = 0; i < params.length; i++) {
            for (uint256 s = 0; s < params[i].strategies.length; s++) {
                queuedShares += params[i].depositShares[s];
            }
        }

        // capture this value easier in tests
        emit mockEvent_queuedWithdrawalShares(queuedShares);

        bytes32[] memory withdrawalRoots = new bytes32[](params.length);
        return withdrawalRoots;
    }


    //************************************************************
    // completeQueuedWithdrawals()
    //************************************************************
    function completeQueuedWithdrawals(
        Withdrawal[] calldata withdrawals,
        IERC20[][] calldata tokens,
        bool[] calldata receiveAsTokens
    ) external override {

        // EtherfiNode currently doesn't support any tokens other than beacon ETH
        // so I just assume it here
        for (uint256 i = 0; i < withdrawals.length; i++) {
            uint256 ethClaimed = withdrawals[i].scaledShares[i];
            vm.deal(withdrawals[i].staker, ethClaimed);
        }
    }
}

/*
contract MockDelegationManager is MockDelegationManagerBase {


}
*/

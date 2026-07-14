// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IEtherFiAdmin {
    struct TaskStatus {
        bool completed;
        bool exists;
    }

    struct ConstructorAddresses {
        address etherFiOracle;
        address stakingManager;
        address auctionManager;
        address etherFiNodesManager;
        address liquidityPool;
        address withdrawRequestNft;
        address roleRegistry;
        address priorityWithdrawalQueue;
    }

    function lastHandledReportRefSlot() external view returns (uint32);
    function lastHandledReportRefBlock() external view returns (uint32);
    function lastAdminExecutionBlock() external view returns (uint32);
}

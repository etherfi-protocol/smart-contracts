// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IProtocolRevenueManager {
    struct AuctionRevenueSplit {
        uint64 treasurySplit;
        uint64 nodeOperatorSplit;
        uint64 tnftHolderSplit;
        uint64 bnftHolderSplit;
    }

    function setEtherFiNodesManagerAddress(address _etherFiNodesManager) external;
    function setAuctionManagerAddress(address _auctionManager) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@etherfi/governance/rate-limiting/libraries/BucketLimiter.sol";

interface IEtherFiRedemptionManager {
    struct RedemptionInfo {
        BucketLimiter.Limit limit;
        uint16 exitFeeSplitToTreasuryInBps;
        uint16 exitFeeInBps;
        uint16 lowWatermarkInBpsOfTvl;
    }

    function redeemEEth(uint256 eEthAmount, address receiver, address outputToken) external;
    function redeemWeEth(uint256 weEthAmount, address receiver, address outputToken) external;
}
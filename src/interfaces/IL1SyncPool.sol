// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts-upgradeable/oapp/interfaces/IOAppCore.sol";

interface IL1SyncPool is IOAppCore {
    function onMessageReceived(uint32 originEid, bytes32 guid, address tokenIn, uint256 amountIn, uint256 amountOut)
        external
        payable;
}
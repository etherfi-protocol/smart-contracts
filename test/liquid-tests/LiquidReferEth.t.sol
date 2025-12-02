// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LiquidReferBaseTest} from "./base/liquidReferBaseTest.t.sol";
import {ILayerZeroTellerWithRateLimiting} from "src/liquid-interfaces/ILayerZeroTellerWithRateLimiting.sol";

contract LiquidReferEthTest is LiquidReferBaseTest {
    function _assetConfig() internal pure override returns (AssetConfig memory) {
        return AssetConfig({
            teller: ILayerZeroTellerWithRateLimiting(LIQUID_ETH_TELLER),
            asset: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH mainnet
            depositAmount: 1 ether
        });
    }

    function _maxFuzzAmount() internal pure override returns (uint256) {
        return 10 ether;
    }
}

contract LiquidReferETHScrollTest is LiquidReferBaseTest {
    function _assetConfig() internal pure override returns (AssetConfig memory) {
        return AssetConfig({
            teller: ILayerZeroTellerWithRateLimiting(LIQUID_ETH_TELLER),
            asset: 0x5300000000000000000000000000000000000004, // WETH scroll
            depositAmount: 1 ether
        });
    }

    function _maxFuzzAmount() internal pure override returns (uint256) {
        return 10 ether;
    }
    function _envVar() internal pure override returns (string memory) {
        return "SCROLL_RPC_URL";
    }
}

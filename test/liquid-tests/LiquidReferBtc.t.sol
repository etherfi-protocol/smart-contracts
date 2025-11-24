// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ILayerZeroTellerWithRateLimiting} from "src/liquid-interfaces/ILayerZeroTellerWithRateLimiting.sol";
import {LiquidReferBaseTest} from "./base/liquidReferBaseTest.t.sol";

contract LiquidReferBtcTest is LiquidReferBaseTest {
    function _assetConfig() internal pure override returns (AssetConfig memory) {
        return AssetConfig({
            teller: ILayerZeroTellerWithRateLimiting(LIQUID_BTC_TELLER),
            asset: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // WBTC mainnet
            depositAmount: 1e8 // WBTC has 8 decimals
        });
    }

    function _maxFuzzAmount() internal pure override returns (uint256) {
        return 2e8; // cap fuzzed WBTC deposits to 2 BTC
    }
}

contract LiquidReferBtcScrollTest is LiquidReferBaseTest {
    function _assetConfig() internal pure override returns (AssetConfig memory) {
        return AssetConfig({
            teller: ILayerZeroTellerWithRateLimiting(LIQUID_BTC_TELLER),
            asset: 0x3C1BCa5a656e69edCD0D4E36BEbb3FcDAcA60Cf1, // WBTC scroll
            depositAmount: 1e8 // WBTC has 8 decimals
        });
    }

    function _maxFuzzAmount() internal pure override returns (uint256) {
        return 2e8; // cap fuzzed WBTC deposits to 2 BTC
    }
    function _envVar() internal pure override returns (string memory) {
        return "SCROLL_RPC_URL";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LiquidReferPermitFuzzBaseTest} from "./base/liquidReferPermitBase.t.sol";
import {ILayerZeroTellerWithRateLimiting} from "src/liquid-interfaces/ILayerZeroTellerWithRateLimiting.sol";

// Only USDC supports permit; WETH and WBTC lack EIP-2612.
contract LiquidReferUsdPermitTest is LiquidReferPermitFuzzBaseTest {
    function _assetConfig() internal pure override returns (AssetConfig memory) {
        return AssetConfig({
            teller: ILayerZeroTellerWithRateLimiting(LIQUID_USD_TELLER),
            asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, //usdc mainnet
            depositAmount: 1_000e6 // USDC has 6 decimals
        });
    }

    function _permitDetails() internal pure override returns (string memory name, string memory version) {
        return ("USD Coin", "2");
    }

    function _maxFuzzAmount() internal pure override returns (uint256) {
        return 10_000e6; // cap fuzzed USDC deposits to 10k
    }
}
contract LiquidReferUsdPermitOPTest is LiquidReferPermitFuzzBaseTest {
    function _assetConfig() internal pure override returns (AssetConfig memory) {
        return AssetConfig({
            teller: ILayerZeroTellerWithRateLimiting(LIQUID_USD_TELLER),
            asset: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, //usdc OP
            depositAmount: 1_000e6 // USDC has 6 decimals
        });
    }

    function _permitDetails() internal pure override returns (string memory name, string memory version) {
        return ("USD Coin", "2");
    }

    function _maxFuzzAmount() internal pure override returns (uint256) {
        return 10_000e6; // cap fuzzed USDC deposits to 10k
    }
    function _envVar() internal pure override returns (string memory) {
        return "OP_RPC_URL";
    }
}
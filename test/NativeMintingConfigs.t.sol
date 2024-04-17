
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract NativeMintingConfigs {
    struct ConfigPerL2 {
        string rpc_url;
        uint32 l2Eid;
        address l2Oft;
        address l2SyncPool;
        address l2SyncPoolRateLimiter;
        address l2ExchagneRateProvider;
        address l2PriceOracle;

        address l1dummyToken;
        address l1Receiver;
    }

    uint32 l1Eid = 30101;
    address l1Endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
    address ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address l1SyncPool = 0xD789870beA40D056A4d26055d0bEFcC8755DA146;
    address l1OftAdapter = 0xFE7fe01F8B9A76803aF3750144C2715D9bcf7D0D;

    ConfigPerL2 BLAST = ConfigPerL2({
        rpc_url: "https://rpc.blast.io",
        l2Eid: 30243,
        l2Oft: 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A,
        l2SyncPool: 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B,
        l2SyncPoolRateLimiter: 0x6f257089bF046a02751b60767871953F3899652e,
        l2ExchagneRateProvider: 0xc42853c0C6624F42fcB8219aCeb67Ad188087DCB,
        l2PriceOracle: 0xcD96262Df56127f298b452FA40759632868A472a,
        l1dummyToken: 0x83998e169026136760bE6AF93e776C2F352D4b28,
        l1Receiver: 0x27e120C518a339c3d8b665E56c4503DF785985c2
    });

    ConfigPerL2 LINEA = ConfigPerL2({
        rpc_url: "https://1rpc.io/linea",
        l2Eid: 30183,
        l2Oft: 0x1Bf74C010E6320bab11e2e5A532b5AC15e0b8aA6,
        l2SyncPool: 0x823106E745A62D0C2FC4d27644c62aDE946D9CCa,
        l2SyncPoolRateLimiter: 0x3A19866D5E0fAE0Ce19Adda617f9d2B9fD5a3975,
        l2ExchagneRateProvider: 0x241a91F095B2020890Bc8518bea168C195518344,
        l2PriceOracle: address(0),
        l1dummyToken: 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf,
        l1Receiver: 0x6F149F8bf1CB0245e70171c9972059C22294aa35
    });

    ConfigPerL2 MODE = ConfigPerL2({
        rpc_url: "https://mainnet.mode.network",
        l2Eid: 30260,
        l2Oft: 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A,
        l2SyncPool: 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B,
        l2SyncPoolRateLimiter: 0x95F1138837F1158726003251B32ecd8732c76781,
        l2ExchagneRateProvider: 0xc42853c0C6624F42fcB8219aCeb67Ad188087DCB,
        l2PriceOracle: address(0),
        l1dummyToken: 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46,
        l1Receiver: 0xC8Ad0949f33F02730cFf3b96E7F067E83De1696f
    });

}
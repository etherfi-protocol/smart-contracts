// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title Deployed_Hoodi
 * @notice Contains addresses of all deployed contracts on Hoodi testnet
 */
contract Deployed_Hoodi {
    // Core Protocol Contracts
    address public constant ADDRESS_PROVIDER = 0xd4bBb3Ba0827Ed7abC6977C572910d25a1488296;
    address public constant LIQUIDITY_POOL = 0x4a8081095549e63153a61D21F92ff079fe39858E;
    address public constant ETHFI = address(0);
    address public constant EETH = 0x5595b182162DB7ECfdFE5Ea948d7636b9e250C4D;
    address public constant WEETH = 0xd5A50FAE2736CA59Bd6Ac4AF59b1f0fFAB62c4A2;
    
    // Membership & NFTs
    address public constant MEMBERSHIP_MANAGER = 0x79eF7d2d9b68056912Eb020ac65b971017191DE0;
    address public constant MEMBERSHIP_NFT = 0x254eAD7aca562D50624b0556729Ca9843b7f6FbB;
    address public constant TNFT = 0xd31bC004Ba46A048e272A45A6b24Ed985c4DF5AC;
    address public constant BNFT = 0x2B736C58EE03C5d4930a32D3c8F6acd7FbbdA08C;
    address public constant WITHDRAW_REQUEST_NFT = 0xb17528f26b0F7ED107E4E17f48bcC2E169Dcb6c1;
    
    // Staking & Withdrawals
    address public constant NODE_OPERATOR_MANAGER = 0x3e17543CaE3366cc67a3CBeD5Aa42d9d09D59b39;
    address public constant AUCTION_MANAGER = 0x261315c176864cE29D582f38DdA4930ED17CD95A;
    address public constant STAKING_MANAGER = 0xDbE50E32Ed95f539F36bA315a75377FBc35aBc12;
    address public constant ETHERFI_NODE_BEACON = 0x7AbD4dF572a4Daaed21b1FdaDE897a5A634a1fd1;
    address public constant ETHERFI_NODES_MANAGER = 0x7579194b8265e3Aa7df451c6BD2aff5B1FC5F945;
    address public constant ETHERFI_REDEMPTION_MANAGER = 0x95AeCaa1B0C3A04C8aFf5D05f27363e9e3367D6F;
    
    // Oracle
    address public constant ETHERFI_ORACLE = 0x1888Fd1914af6980204AA0424f550d9bE35735e1;
    address public constant ETHERFI_ADMIN = 0x0CF5ddcF6861Efd8C498466d162F231E44eB85Dd;
    
    // Adapters & Liquifiers
    address public constant DEPOSIT_ADAPTER = address(0); // MISSING
    address public constant LIQUIFIER = 0x2e871581aAcc79EbcF75F9da364f5078FAd9bb4D;
    
    // AVS & Sync
    address public constant ETHERFI_RESTAKER = 0xc27F4dae10Ec60539619F7Deb0E2dBb413df6EAd;
    address public constant ETHERFI_AVS_OPERATORS_MANAGER = address(0); // MISSING
    address public constant ETHERFI_L1_SYNC_POOL_ETH = address(0);
    address public constant ETHERFI_OFT_ADAPTER = address(0);
    
    // Utilities
    address public constant ETHERFI_VIEWER = 0xA239C957951C2237eCd730596629b246E2c75857;
    address public constant ETHERFI_REWARDS_ROUTER = 0x703f2f1eC0B82EFe1C16927aEbc4D99536ECF5CE;
    address public constant ETHERFI_OPERATION_PARAMETERS = 0x01bc3a772307394E755a3519E6983fEA445B2722;
    address public constant ETHERFI_RATE_LIMITER = 0x1e6881572e7bB49B4737ac650bce5587085a4d48;

    address public constant EARLY_ADOPTER_POOL = address(0);

    // role registry & multi-sig
    address public constant ROLE_REGISTRY = 0x7279853cA1804d4F705d885FeA7f1662323B5Aab;
    address public constant UPGRADE_TIMELOCK = address(0);
    address public constant OPERATING_TIMELOCK = address(0);
    address public constant ETHERFI_OPERATING_ADMIN = address(0);
    address public constant ETHERFI_UPGRADE_ADMIN = address(0);

    // Additional Hoodi-specific contracts
    address public constant TREASURY = 0xa16E2fcf1331B2AA90b3a83EC0B54923d74b5E19;
    address public constant ETHERFI_TIMELOCK = 0x75AEB07F913a895F1eE2e0a8990B633D1dB00731;
    address public constant PROTOCOL_REVENUE_MANAGER = 0xA7C53aCCBB67D803e185E63730BB78C68db2966d;
    address public constant REGULATIONS_MANAGER = 0x91E4e2c24f8634f05a46dd88F8d79cA0767575f6;
    address public constant BUCKET_RATE_LIMITER = 0x52DbeF0e3E019aafbB654bc80c15ffa4Dcc17566;
    address public constant TVL_ORACLE = 0x9B9D42E2D3B3989567de5028A91d9492B8cF68c2;
    address public constant ETHERFI_NODE = 0xCb77c1EDf717b551C57c15332700b213c02f1b90;
    address public constant MAIN_ADMIN = 0x001000621b95AA950c1a27Bb2e1273e10d8dfF68;

    // External contracts (EigenLayer, Ethereum)
    address public constant ETH2_DEPOSIT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    address public constant EIGEN_POD_MANAGER = 0xcd1442415Fc5C29Aa848A49d2e232720BE07976c;
    address public constant DELEGATION_MANAGER = 0x867837a9722C512e0862d8c2E15b8bE220E8b87d;
    address public constant REWARDS_COORDINATOR = 0x29e8572678e0c272350aa0b4B8f304E47EBcd5e7;
    address public constant BEACON_ORACLE = 0x5e1577f8efB21b229cD5Eb4C5Aa3d6C4b228f650;
    address public constant STRATEGY_MANAGER = 0xeE45e76ddbEDdA2918b8C7E3035cd37Eab3b5D41;
    address public constant CREATE2_FACTORY_HOODI = 0x29bd9fc3E826f10288D58bEa41d1258FB3ecF4F0;

    mapping(address => address) public timelockToAdmin;

    constructor() {
    }
}

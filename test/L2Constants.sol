
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


contract L2Constants {
    struct ConfigPerL2 {
        string name;
        string rpc_url;

        // https://docs.layerzero.network/v2/developers/evm/technical-reference/endpoints
        uint32 l2Eid;
        address l2Endpoint;

        address l1Messenger;
        address l2Messenger;

        address l2Oft;
        address l2SyncPool;
        address l2SyncPoolRateLimiter;
        address l2ExchagneRateProvider;
        
        address l2PriceOracle;
        uint32 l2PriceOracleHeartBeat;

        address l2ContractControllerSafe;

        address l1dummyToken;
        address l1Receiver;

        // ProxyAdmin
        address l2Oft_ProxyAdmin;
        address l2SyncPool_ProxyAdmin;
        address l2ExchagneRateProvider_ProxyAdmin;
        address l1dummyToken_ProxyAdmin;
        address l1Receiver_ProxyAdmin;

        // DVN
        // - https://docs.layerzero.network/v2/developers/evm/technical-reference/executor-addresses
        // - https://docs.layerzero.network/v2/developers/evm/technical-reference/messagelibs
        // - https://docs.layerzero.network/v2/developers/evm/technical-reference/dvn-addresses
        address send302;
        address receive302;
        address lzExecutor;
        address[2] lzDvn;
    }

    function getL2Config() public returns (ConfigPerL2 memory) {
        if (block.chainid == 59144) return LINEA;
        else if (block.chainid == 81457) return BLAST;
        else if (block.chainid == 34443) return MODE;
        else if (block.chainid == 56) return BNB;
        else if (block.chainid == 8453) return BASE;
        else revert("Unsupported chain id");
    }


    string l1RpcUrl = "https://mainnet.gateway.tenderly.co";
    uint32 l1Eid = 30101;
    address l1Endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
    address ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address l1ContractController = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;

    address l1SyncPoolAddress = 0xD789870beA40D056A4d26055d0bEFcC8755DA146;
    address l1OftAdapter = 0xFE7fe01F8B9A76803aF3750144C2715D9bcf7D0D;
    address l1Send302 = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address l1Receive302 = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
    address[2] l1Dvn = [0x589dEDbD617e0CBcB916A9223F4d1300c294236b, 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5];

    address l1SyncPool_ProxyAdmin = 0xDBf6bE120D4dc72f01534673a1223182D9F6261D;


    ConfigPerL2 BLAST = ConfigPerL2({
        name: "BLAST",
        rpc_url: "https://rpc.blast.io",
        
        l2Eid: 30243,
        l2Endpoint: 0x1a44076050125825900e736c501f859c50fE728c,

        l1Messenger: 0x5D4472f31Bd9385709ec61305AFc749F0fA8e9d0,
        l2Messenger: 0x4200000000000000000000000000000000000007,

        l2Oft: 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A,
        l2SyncPool: 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B,
        l2SyncPoolRateLimiter: 0x6f257089bF046a02751b60767871953F3899652e,
        l2ExchagneRateProvider: 0xc42853c0C6624F42fcB8219aCeb67Ad188087DCB,
        l2PriceOracle: 0xcD96262Df56127f298b452FA40759632868A472a,
        l2PriceOracleHeartBeat: 24 hours,
        l2ContractControllerSafe: 0xa4822d7d24747e6A1BAA171944585bad4434f2D5,
        l1dummyToken: 0x83998e169026136760bE6AF93e776C2F352D4b28,
        l1Receiver: 0x27e120C518a339c3d8b665E56c4503DF785985c2,

        l2Oft_ProxyAdmin: 0x2F6f3cc4a275C7951FB79199F01eD82421eDFb68,
        l2SyncPool_ProxyAdmin: 0x8f732e00d6CF2302775Df16d4110f0f7ad3780f9,
        l2ExchagneRateProvider_ProxyAdmin: 0xb4224E552016ba5D35b44608Cd4578fF7FCB6e82,
        l1dummyToken_ProxyAdmin: 0x96a226ad7c14870502f9794fB481EE102E595fFa,
        l1Receiver_ProxyAdmin: 0x70F38913d95987829577788dF9a6A0741dA16543,

        send302: 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821,
        receive302: 0x377530cdA84DFb2673bF4d145DCF0C4D7fdcB5b6,
        lzExecutor: 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b,
        lzDvn: [0xc097ab8CD7b053326DFe9fB3E3a31a0CCe3B526f, 0xDd7B5E1dB4AaFd5C8EC3b764eFB8ed265Aa5445B]
    });

    ConfigPerL2 MODE = ConfigPerL2({
        name: "MODE",
        rpc_url: "https://mainnet.mode.network",

        l2Eid: 30260,
        l2Endpoint: 0x1a44076050125825900e736c501f859c50fE728c,

        l1Messenger: 0x95bDCA6c8EdEB69C98Bd5bd17660BaCef1298A6f,
        l2Messenger: 0xC0d3c0d3c0D3c0D3C0d3C0D3C0D3c0d3c0d30007,

        l2Oft: 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A,
        l2SyncPool: 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B,
        l2SyncPoolRateLimiter: 0x95F1138837F1158726003251B32ecd8732c76781,
        l2ExchagneRateProvider: 0xc42853c0C6624F42fcB8219aCeb67Ad188087DCB,
        l2ContractControllerSafe: 0xa4822d7d24747e6A1BAA171944585bad4434f2D5,
        l2PriceOracle: 0x7C1DAAE7BB0688C9bfE3A918A4224041c7177256,
        l2PriceOracleHeartBeat: 6 hours,
        l1dummyToken: 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3,
        l1Receiver: 0xC8Ad0949f33F02730cFf3b96E7F067E83De1696f,

        l2Oft_ProxyAdmin: 0x2F6f3cc4a275C7951FB79199F01eD82421eDFb68,
        l2SyncPool_ProxyAdmin: 0x8f732e00d6CF2302775Df16d4110f0f7ad3780f9,
        l2ExchagneRateProvider_ProxyAdmin: 0xb4224E552016ba5D35b44608Cd4578fF7FCB6e82,
        l1dummyToken_ProxyAdmin: 0x59a5518aCE8e3d60C740503639B94bD86F7CEDF0,
        l1Receiver_ProxyAdmin: 0xe85e493d78a4444bf5fC4A2E415AF530aEad6dd5,

        send302: 0x2367325334447C5E1E0f1b3a6fB947b262F58312,
        receive302: 0xc1B621b18187F74c8F6D52a6F709Dd2780C09821,
        lzExecutor: 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b,
        lzDvn: [0xcd37CA043f8479064e10635020c65FfC005d36f6, 0xce8358bc28dd8296Ce8cAF1CD2b44787abd65887]
    });

    ConfigPerL2 LINEA = ConfigPerL2({
        name: "LINEA",
        rpc_url: "https://1rpc.io/linea",

        l2Eid: 30183,
        l2Endpoint: 0x1a44076050125825900e736c501f859c50fE728c,

        l1Messenger: 0xd19d4B5d358258f05D7B411E21A1460D11B0876F,
        l2Messenger: 0x508Ca82Df566dCD1B0DE8296e70a96332cD644ec,

        l2Oft: 0x1Bf74C010E6320bab11e2e5A532b5AC15e0b8aA6,
        l2SyncPool: 0x823106E745A62D0C2FC4d27644c62aDE946D9CCa,
        l2SyncPoolRateLimiter: 0x3A19866D5E0fAE0Ce19Adda617f9d2B9fD5a3975,
        l2ExchagneRateProvider: 0x241a91F095B2020890Bc8518bea168C195518344,
        l2PriceOracle: 0x100c8e61aB3BeA812A42976199Fc3daFbcDD7272,
        l2PriceOracleHeartBeat: 6 hours,
        l2ContractControllerSafe: 0xe4ff196Cd755566845D3dEBB1e2bD34123807eBc,
        l1dummyToken: 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf,
        l1Receiver: 0x6F149F8bf1CB0245e70171c9972059C22294aa35,
        
        l2Oft_ProxyAdmin: 0xE21B7A5e4c15156180a76F4747313a3485fC4163,
        l2SyncPool_ProxyAdmin: 0x0F88DB75B9011B909b67c498cdcc1C0FD2308444,
        l2ExchagneRateProvider_ProxyAdmin: 0x40B6a79A93f9596Fe6155c9a56f79482d831178f,
        l1dummyToken_ProxyAdmin: 0xaa249a01a3D73611a27B735130Ab77fd6b0f5a3e,
        l1Receiver_ProxyAdmin: 0x7c6261c2eD0Bd5e532B45C4E553e633cBF34063f,

        send302: 0x32042142DD551b4EbE17B6FEd53131dd4b4eEa06,
        receive302: 0xE22ED54177CE1148C557de74E4873619e6c6b205,
        lzExecutor: 0x0408804C5dcD9796F22558464E6fE5bDdF16A7c7,
        lzDvn: [0x129Ee430Cb2Ff2708CCADDBDb408a88Fe4FFd480, 0xDd7B5E1dB4AaFd5C8EC3b764eFB8ed265Aa5445B]
    });

    ConfigPerL2 BNB = ConfigPerL2({
        name: "BNB",
        rpc_url: "https://bsc-dataseed1.binance.org/",

        l2Eid: 30102,
        l2Endpoint: 0x1a44076050125825900e736c501f859c50fE728c,

        l1Messenger: address(0),
        l2Messenger: address(0),

        l2Oft: 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A,
        l2SyncPool: address(0),
        l2SyncPoolRateLimiter: address(0),
        l2ExchagneRateProvider: address(0),
        l2ContractControllerSafe: 0xD568c4D42147224a701A14468bEC9E9bccF571F5,
        l2PriceOracle: address(0),
        l2PriceOracleHeartBeat: 0,
        l1dummyToken: address(0),
        l1Receiver: address(0),

        l2Oft_ProxyAdmin: 0x2F6f3cc4a275C7951FB79199F01eD82421eDFb68,
        l2SyncPool_ProxyAdmin: address(0),
        l2ExchagneRateProvider_ProxyAdmin: address(0),
        l1dummyToken_ProxyAdmin: address(0),
        l1Receiver_ProxyAdmin: address(0),

        send302: 0x9F8C645f2D0b2159767Bd6E0839DE4BE49e823DE,
        receive302: 0xB217266c3A98C8B2709Ee26836C98cf12f6cCEC1,
        lzExecutor: 0x3ebD570ed38B1b3b4BC886999fcF507e9D584859,
        lzDvn: [0x31F748a368a893Bdb5aBB67ec95F232507601A73, 0xfD6865c841c2d64565562fCc7e05e619A30615f0]
    });

    ConfigPerL2 BASE = ConfigPerL2({
        name: "Base",
        rpc_url: "https://base.drpc.org/",

        l2Eid: 30184,
        l2Endpoint: 0x1a44076050125825900e736c501f859c50fE728c,

        l1Messenger: 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa,
        l2Messenger: 0x4200000000000000000000000000000000000007,

        l2Oft: 0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A,
        l2SyncPool: 0xc38e046dFDAdf15f7F56853674242888301208a5,
        l2SyncPoolRateLimiter: 0xe6e0fe0C3Ac45d1FE71AF7853007467eE89e1e67,
        l2ExchagneRateProvider: 0xF2c5519c634796B73dE90c7Dc27B4fEd560fC3ca,
        l2ContractControllerSafe: 0x7a00657a45420044bc526B90Ad667aFfaee0A868,
        l2PriceOracle: 0x35e9D7001819Ea3B39Da906aE6b06A62cfe2c181, // CL
        l2PriceOracleHeartBeat: 24 hours,
        l1dummyToken: 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46,
        l1Receiver: 0x8963C96186bd05995AdaA9E1fda25B7181CCBc37,

        l2Oft_ProxyAdmin: 0x2F6f3cc4a275C7951FB79199F01eD82421eDFb68,
        l2SyncPool_ProxyAdmin: 0x9055c6EF7Cb895D550368fE7B38Be346E7eA9eE6,
        l2ExchagneRateProvider_ProxyAdmin: 0x7Ce9B21e86778Bb6D06CF107f1C154cB5635598f,
        l1dummyToken_ProxyAdmin: 0x915B16B555872A084B3512169b1F1dC089C3ca9A,
        l1Receiver_ProxyAdmin: 0x0df531532cf25156b1fe91232F41B4c9AA514125,

        send302: 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2,
        receive302: 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf,
        lzExecutor: 0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4,
        lzDvn: [0x9e059a54699a285714207b43B055483E78FAac25, 0xcd37CA043f8479064e10635020c65FfC005d36f6]
    });

    ConfigPerL2 TRON = ConfigPerL2({
        name: "TRON",
        rpc_url: "https://rpc.ankr.com/http/tron",

        l2Eid: 0,
        l2Endpoint: address(0),

        l1Messenger: address(0),
        l2Messenger: address(0),

        l2Oft: address(0),
        l2SyncPool: address(0),
        l2SyncPoolRateLimiter: address(0),
        l2ExchagneRateProvider: address(0),
        l2ContractControllerSafe: address(0),
        l2PriceOracle: address(0),
        l2PriceOracleHeartBeat: 0,
        l1dummyToken: address(0),
        l1Receiver: address(0),

        l2Oft_ProxyAdmin: 0x2F6f3cc4a275C7951FB79199F01eD82421eDFb68,
        l2SyncPool_ProxyAdmin: address(0),
        l2ExchagneRateProvider_ProxyAdmin: address(0),
        l1dummyToken_ProxyAdmin: address(0),
        l1Receiver_ProxyAdmin: address(0),

        send302: address(0),
        receive302: address(0),
        lzExecutor: address(0),
        lzDvn: [address(0), address(0)]
    });

    // ConfigPerL2 ExampleL2 = ConfigPerL2({
    //     name: "BNB",
    //     rpc_url: "https://bsc-dataseed1.binance.org/",

    //     l2Eid: 0,
    //     l2Endpoint: address(0),

    //     l2Oft: address(0),
    //     l2SyncPool: address(0),
    //     l2SyncPoolRateLimiter: address(0),
    //     l2ExchagneRateProvider: address(0),
    //     l2ContractControllerSafe: address(0),
    //     l2PriceOracle: address(0),
    //     l2PriceOracleHeartBeat: 0,
    //     l1dummyToken: address(0),
    //     l1Receiver: address(0),

    //     l2Oft_ProxyAdmin: 0x2F6f3cc4a275C7951FB79199F01eD82421eDFb68,
    //     l2SyncPool_ProxyAdmin: address(0),
    //     l2ExchagneRateProvider_ProxyAdmin: address(0),
    //     l1dummyToken_ProxyAdmin: address(0),
    //     l1Receiver_ProxyAdmin: address(0),

    //     send302: address(0),
    //     receive302: address(0),
    //     lzExecutor: address(0),
    //     lzDvn: [address(0), address(0)]
    // });
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title Deployed
 * @notice Contains addresses of all deployed contracts on Ethereum mainnet
 */
contract Deployed {
    // Core Protocol Contracts
    address public constant ADDRESS_PROVIDER = 0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848;
    address public constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address public constant ETHFI = 0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB;
    address public constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    
    // Membership & NFTs
    address public constant MEMBERSHIP_MANAGER = 0x3d320286E014C3e1ce99Af6d6B00f0C1D63E3000;
    address public constant MEMBERSHIP_NFT = 0xb49e4420eA6e35F98060Cd133842DbeA9c27e479;
    address public constant TNFT = 0x7B5ae07E2AF1C861BcC4736D23f5f66A61E0cA5e;
    address public constant BNFT = 0x6599861e55abd28b91dd9d86A826eC0cC8D72c2c;
    address public constant WITHDRAW_REQUEST_NFT = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    
    // Staking & Withdrawals
    address public constant NODE_OPERATOR_MANAGER = 0xd5edf7730ABAd812247F6F54D7bd31a52554e35E;
    address public constant AUCTION_MANAGER = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address public constant STAKING_MANAGER = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address public constant ETHERFI_NODE_BEACON = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
    address public constant ETHERFI_NODES_MANAGER = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address public constant ETHERFI_REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address public constant WEETH_WITHDRAW_ADAPTER = 0xFbfe6b9cEe0E555Bad7e2E7309EFFC75200cBE38;
    
    // Oracle
    address public constant ETHERFI_ORACLE = 0x57AaF0004C716388B21795431CD7D5f9D3Bb6a41;
    address public constant ETHERFI_ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    
    // Adapters & Liquifiers
    address public constant DEPOSIT_ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant LIQUIFIER = 0x9FFDF407cDe9a93c47611799DA23924Af3EF764F;
    
    // AVS & Sync
    address public constant ETHERFI_RESTAKER = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;
    address public constant ETHERFI_AVS_OPERATORS_MANAGER = 0x2093Bbb221f1d8C7c932c32ee28Be6dEe4a37A6a;
    address public constant ETHERFI_L1_SYNC_POOL_ETH = 0xD789870beA40D056A4d26055d0bEFcC8755DA146;
    address public constant ETHERFI_OFT_ADAPTER = 0xcd2eb13D6831d4602D80E5db9230A57596CDCA63;
    
    // Utilities
    address public constant ETHERFI_VIEWER = 0x2ecd155405cA52a5ca0e552981fF44A8252FAb81;
    address public constant ETHERFI_REWARDS_ROUTER = 0x73f7b1184B5cD361cC0f7654998953E2a251dd58;
    address public constant ETHERFI_OPERATION_PARAMETERS = 0xD0Ff8996DB4bDB46870b7E833b7532f484fEad1A;
    address public constant ETHERFI_RATE_LIMITER = 0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;

    address public constant EARLY_ADOPTER_POOL = 0x7623e9DC0DA6FF821ddb9EbABA794054E078f8c4;
    address public constant CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR = 0x9A8c5046a290664Bf42D065d33512fe403484534;
    address public constant TREASURY = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;

    // role registry & multi-sig
    address public constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address public constant UPGRADE_TIMELOCK = address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761); // upgrade timelock
    address public constant OPERATING_TIMELOCK = address(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a); // operating timelock
    address public constant ETHERFI_OPERATING_ADMIN = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC; // operating admin
    address public constant ETHERFI_UPGRADE_ADMIN = 0xcdd57D11476c22d265722F68390b036f3DA48c21; // upgrade admin
    address public constant ADMIN_EOA = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F; // admin eoa

    address public constant AVS_OPERATOR_1 = 0xDd777e5158Cb11DB71B4AF93C75A96eA11A2A615;
    address public constant AVS_OPERATOR_2 = 0x2c7cB7d5dC4aF9caEE654553a144C76F10D4b320;

    mapping(address => address) public timelockToAdmin;

    constructor() {
        timelockToAdmin[UPGRADE_TIMELOCK] = ETHERFI_UPGRADE_ADMIN;
        timelockToAdmin[OPERATING_TIMELOCK] = ETHERFI_OPERATING_ADMIN;
    }
}


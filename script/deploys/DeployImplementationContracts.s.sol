// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/Treasury.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/ProtocolRevenueManager.sol";
import "../../src/StakingManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EETH.sol";
import "../../src/WeETH.sol";
import "../../src/RegulationsManager.sol";
import "../../src/UUPSProxy.sol";
import "../../src/EtherFiOracle.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/MembershipManager.sol";
import "../../src/MembershipNFT.sol";
import "../../src/BNFT.sol";
import "../../src/TNFT.sol";



import "@openzeppelin/contracts/utils/Strings.sol";

import "../../test/TestERC20.sol";

contract DeployImplementationContractsScript is Script {
    using Strings for string;

    BNFT public bNFT;
    TNFT public tNFT;
    WeETH public weEth;
    AuctionManager public auctionManager;
    StakingManager public stakingManager;
    ProtocolRevenueManager public protocolRevenueManager;
    EtherFiNodesManager public etherFiNodesManager;
    LiquidityPool public liquidityPool;
    EETH public eETH;
    RegulationsManager public regulationsManager;
    EtherFiNode public etherFiNode;
    MembershipManager public membershipManager;
    MembershipNFT public membershipNft;

    struct suiteAddresses {
        // address treasury;
        // address nodeOperatorManager;
        address auctionManager;
        address stakingManager;
        address tNFT;
        address bNFT;
        address etherFiNodesManager;
        // address protocolRevenueManager;
        address etherFiNode;
        // address regulationsManager;
        address liquidityPool;
        address eETH;
        address weEth;
        address membershipManager;
        address membershipNft;
        // address etherFiOracle;
        // address etherFiAdmin;
        // address withdrawRequestNFT;
    }

    suiteAddresses suiteAddressesStruct;

    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Deploy contracts
        // Treasury treasury = new Treasury();
        // NodeOperatorManager nodeOperatorManager = new NodeOperatorManager();
        auctionManager = new AuctionManager();
        stakingManager = new StakingManager();
        bNFT = new BNFT();
        tNFT = new TNFT();
        // protocolRevenueManager = new ProtocolRevenueManager();
        etherFiNodesManager = new EtherFiNodesManager();
        etherFiNode = new EtherFiNode();
        // regulationsManager = new RegulationsManager();
        liquidityPool = new LiquidityPool();
        eETH = new EETH();
        weEth = new WeETH();
        membershipManager = new MembershipManager();
        membershipNft = new MembershipNFT();
        // EtherFiOracle etherFiOracle = new EtherFiOracle();
        // EtherFiAdmin etherFiAdmin = new EtherFiAdmin();
        // WithdrawRequestNFT withdrawRequestNFT = new WithdrawRequestNFT();

        vm.stopBroadcast();

        suiteAddressesStruct = suiteAddresses({
            // treasury: address(treasury),
            // nodeOperatorManager: address(nodeOperatorManager),
            auctionManager: address(auctionManager),
            stakingManager: address(stakingManager),
            tNFT: address(tNFT),
            bNFT: address(bNFT),
            // protocolRevenueManager: address(protocolRevenueManager),
            etherFiNodesManager: address(etherFiNodesManager),
            etherFiNode: address(etherFiNode),
            // regulationsManager: address(regulationsManager),
            liquidityPool: address(liquidityPool),
            eETH: address(eETH),
            weEth: address(weEth),
            membershipManager: address(membershipManager),
            membershipNft: address(membershipNft)
            // etherFiOracle: address(etherFiOracle),
            // etherFiAdmin: address(etherFiAdmin),
            // withdrawRequestNFT: address(withdrawRequestNFT)
        });

        writeSuiteVersionFile();
    }

    function _stringToUint(
        string memory numString
    ) internal pure returns (uint256) {
        uint256 val = 0;
        bytes memory stringBytes = bytes(numString);
        for (uint256 i = 0; i < stringBytes.length; i++) {
            uint256 exp = stringBytes.length - i;
            bytes1 ival = stringBytes[i];
            uint8 uval = uint8(ival);
            uint256 jval = uval - uint256(0x30);

            val += (uint256(jval) * (10 ** (exp - 1)));
        }
        return val;
    }

    function writeSuiteVersionFile() internal {
        // Read Current version
        string memory versionString = vm.readLine("release/logs/implementation/version.txt");

        // Cast string to uint256
        uint256 version = _stringToUint(versionString);

        version++;

        // Overwrites the version.txt file with incremented version
        vm.writeFile(
            "release/logs/EtherFiSuite/version.txt",
            string(abi.encodePacked(Strings.toString(version)))
        );

        string memory one = string(
                abi.encodePacked(
                    // "\nTreasury ",
                    // Strings.toHexString(suiteAddressesStruct.treasury),
                    // "\nNodeOperatorManager ",
                    // Strings.toHexString(suiteAddressesStruct.nodeOperatorManager),
                    // "\nProtocolRevenueManager ",
                    // Strings.toHexString(suiteAddressesStruct.protocolRevenueManager),
                    "\nAuctionManager ",
                    Strings.toHexString(suiteAddressesStruct.auctionManager),
                    "\nStakingManager ",
                    Strings.toHexString(suiteAddressesStruct.stakingManager),
                    "\nEtherFiNodesManager ",
                    Strings.toHexString(suiteAddressesStruct.etherFiNodesManager),
                    "\nEtherFiNode ",
                    Strings.toHexString(suiteAddressesStruct.etherFiNode),
                    "\nTNFT ",
                    Strings.toHexString(suiteAddressesStruct.tNFT),
                    "\nBNFT ",
                    Strings.toHexString(suiteAddressesStruct.bNFT)
                )
            );
        string memory two = string(
                abi.encodePacked(
                    // "\nRegulationsManager ",
                    // Strings.toHexString(suiteAddressesStruct.regulationsManager),
                    "\nLiquidityPool ",
                    Strings.toHexString(suiteAddressesStruct.liquidityPool),
                    "\nEETH ",
                    Strings.toHexString(suiteAddressesStruct.eETH),
                    "\nWeETH ",
                    Strings.toHexString(suiteAddressesStruct.weEth),
                    "\nMembershipManager ",
                    Strings.toHexString(suiteAddressesStruct.membershipManager),
                    "\nMembershipNFT ",
                    Strings.toHexString(suiteAddressesStruct.membershipNft)
                    // "\nEtherFiOracle ",
                    // Strings.toHexString(suiteAddressesStruct.etherFiOracle),
                    // "\nEtherFiAdmin ",
                    // Strings.toHexString(suiteAddressesStruct.etherFiAdmin),
                    // "\nWithdrawRequestNFT ",
                    // Strings.toHexString(suiteAddressesStruct.withdrawRequestNFT)
                )
            );

        // str = one + two;
        string memory str = string(abi.encodePacked(one, two));

        // Writes the data to .release file
        vm.writeFile(
            string(
                abi.encodePacked(
                    "release/logs/implementation/",
                    Strings.toString(version),
                    ".release"
                )
            ),
            str
        );
    }
}

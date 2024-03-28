// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../src/helpers/AddressProvider.sol";

import "../src/UUPSProxy.sol";

import "../src/AuctionManager.sol";
import "../src/StakingManager.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiNode.sol";
import "../src/Treasury.sol";
import "../src/NodeOperatorManager.sol";
import "../src/TNFT.sol";
import "../src/BNFT.sol";
import "../src/MembershipManager.sol";
import "../src/MembershipNFT.sol";
import "../src/EETH.sol";
import "../src/WeETH.sol";
import "../src/LiquidityPool.sol";
import "../src/WithdrawRequestNFT.sol";
import "../src/EtherFiOracle.sol";
import "../src/EtherFiAdmin.sol";


contract Deploy is Script {

    mapping(string => UUPSProxy) public proxies;
    mapping(string => address) public implementations;

    AddressProvider public addressProvider;
    string[] public contracts;

    address owner;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        owner = vm.envAddress("DEPLOYER");

        uint256 step = 2;
        vm.startBroadcast(deployerPrivateKey);
        
        if (step == 1) {
            addressProvider = new AddressProvider(msg.sender);

            list_all_contracts();
            deploy_all_contracts();
            initialize_all_contracts();
        } else if (step == 2) {
            addressProvider = AddressProvider(vm.envAddress("CONTRACT_REGISTRY"));

            upgrade_contracts();
        }
        vm.stopBroadcast();

        sanity_checks();
    }

    function generateAddress(uint256 privateKey) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(privateKey)))));
    }

    function list_all_contracts() internal {
        contracts.push("Treasury");
        contracts.push("NodeOperatorManager");
        contracts.push("EtherFiNodesManager");
        contracts.push("BNFT");
        contracts.push("TNFT");
        contracts.push("StakingManager");
        contracts.push("AuctionManager");
        contracts.push("MembershipManager");
        contracts.push("MembershipNFT");
        contracts.push("WeETH");
        contracts.push("EETH");
        contracts.push("LiquidityPool");
        contracts.push("WithdrawRequestNFT");
        contracts.push("EtherFiOracle");
        contracts.push("EtherFiAdmin");

        implementations["Treasury"] = address(new Treasury());
        implementations["NodeOperatorManager"] = address(new NodeOperatorManager());
        implementations["EtherFiNodesManager"] = address(new EtherFiNodesManager());
        implementations["EtherFiNode"] = address(new EtherFiNode());
        implementations["BNFT"] = address(new BNFT());
        implementations["TNFT"] = address(new TNFT());
        implementations["StakingManager"] = address(new StakingManager());
        implementations["AuctionManager"] = address(new AuctionManager());
        implementations["MembershipManager"] = address(new MembershipManager());
        implementations["MembershipNFT"] = address(new MembershipNFT());
        implementations["WeETH"] = address(new WeETH());
        implementations["EETH"] = address(new EETH());
        implementations["LiquidityPool"] = address(new LiquidityPool());
        implementations["WithdrawRequestNFT"] = address(new WithdrawRequestNFT());
        implementations["EtherFiOracle"] = address(new EtherFiOracle());
        implementations["EtherFiAdmin"] = address(new EtherFiAdmin());
    }

    function deploy_all_contracts() internal {
        for (uint i = 0; i < contracts.length; i++) {
            string memory contractName = contracts[i];
            address implementation = implementations[contractName];
            proxies[contractName] = new UUPSProxy(payable(implementation), "");
            addressProvider.addContract(address(proxies[contractName]), contractName);
        }

        // holesky
        if (block.chainid == 17000) {
            addressProvider.addContract(0x4242424242424242424242424242424242424242, "DepositContract");
            addressProvider.addContract(0x30770d7E3e71112d7A6b7259542D1f680a70e315, "EigenPodManager");
            addressProvider.addContract(0xA44151489861Fe9e3055d95adC98FbD462B948e7, "DelegationManager");
            addressProvider.addContract(0x642c646053eaf2254f088e9019ACD73d9AE0FA32, "DelayedWithdrawalRouter");
        } else {
            require(false, "fail");
        }
    }

    function initialize_all_contracts() internal {
        AuctionManager(addressProvider.getContractAddress("AuctionManager")).initialize(address(addressProvider));
        StakingManager(addressProvider.getContractAddress("StakingManager")).initialize(address(addressProvider));
        EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager"))).initialize(address(addressProvider));
        NodeOperatorManager(addressProvider.getContractAddress("NodeOperatorManager")).initialize(address(addressProvider));
        TNFT(addressProvider.getContractAddress("TNFT")).initialize(address(addressProvider));
        BNFT(addressProvider.getContractAddress("BNFT")).initialize(address(addressProvider));
        MembershipManager(payable(addressProvider.getContractAddress("MembershipManager"))).initialize(address(addressProvider));
        MembershipNFT(addressProvider.getContractAddress("MembershipNFT")).initialize(vm.envString("BASE_URI"), address(addressProvider));
        EETH(addressProvider.getContractAddress("EETH")).initialize(address(addressProvider));
        WeETH(addressProvider.getContractAddress("WeETH")).initialize(address(addressProvider));
        LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool"))).initialize(address(addressProvider));
        WithdrawRequestNFT(addressProvider.getContractAddress("WithdrawRequestNFT")).initialize(address(addressProvider));
        EtherFiAdmin(addressProvider.getContractAddress("EtherFiAdmin")).initialize(address(addressProvider));
        EtherFiOracle(addressProvider.getContractAddress("EtherFiOracle")).initialize(address(addressProvider), 1, 96, 0, 32, 12, 1695902400);


        StakingManager(addressProvider.getContractAddress("StakingManager")).initializeOnUpgrade(
            addressProvider.getContractAddress("NodeOperatorManager"),
            addressProvider.getContractAddress("EtherFiAdmin")
        );
        EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager"))).initializeOnUpgrade(
            addressProvider.getContractAddress("EtherFiAdmin"),
            addressProvider.getContractAddress("EigenPodManager"),
            addressProvider.getContractAddress("DelayedWithdrawalRouter"),
            5
        );
        MembershipManager(payable(addressProvider.getContractAddress("MembershipManager"))).initializeOnUpgrade(
            addressProvider.getContractAddress("EtherFiAdmin"),
            0.1 ether,
            30
        );
    
        StakingManager(addressProvider.getContractAddress("StakingManager")).registerEtherFiNodeImplementationContract(implementations["EtherFiNode"]);

        {
            NodeOperatorManager nodeOperatorManager = NodeOperatorManager(addressProvider.getContractAddress("NodeOperatorManager"));

            nodeOperatorManager.addToWhitelist(owner);
            address[] memory _users = new address[](2);
            _users[0] = owner;
            _users[1] = owner;
            ILiquidityPool.SourceOfFunds[] memory _approvedTags = new ILiquidityPool.SourceOfFunds[](2);
            _approvedTags[0] = ILiquidityPool.SourceOfFunds.EETH;
            _approvedTags[1] = ILiquidityPool.SourceOfFunds.ETHER_FAN;

            bool[] memory _approvals = new bool[](2);
            _approvals[0] = true;
            _approvals[1] = true;
            nodeOperatorManager.batchUpdateOperatorsApprovedTags(_users, _approvedTags, _approvals);
        }

        {
            LiquidityPool liquidityPool = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));
            
            liquidityPool.deposit{value: 1 ether}();
            assert(liquidityPool.getTotalPooledEther() == 1 ether);
        }

        {
            EtherFiOracle etherFiOracle = EtherFiOracle(addressProvider.getContractAddress("EtherFiOracle"));
            etherFiOracle.addCommitteeMember(owner);
        }
    }

    function sanity_checks() internal {

    }

    function upgrade_contracts() internal {
        StakingManager(addressProvider.getContractAddress("StakingManager")).upgradeTo(address(new StakingManager()));
        EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager"))).upgradeTo(address(new EtherFiNodesManager()));
        MembershipManager(payable(addressProvider.getContractAddress("MembershipManager"))).upgradeTo(address(new MembershipManager()));
    }

}
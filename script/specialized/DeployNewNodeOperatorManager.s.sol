// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeployNewNodeOperatorManagerScript is Script {
    using Strings for string;
        
    UUPSProxy public nodeOperatorManagerProxy;

    NodeOperatorManager public nodeOperatorManagerImplementation;
    NodeOperatorManager public nodeOperatorManagerInstance;

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address AuctionManagerProxyAddress = addressProvider.getContractAddress("AuctionManager");
        address phaseOneNodeOperator = addressProvider.getContractAddress("NodeOperatorManager");

        address[] memory operators;
        bytes[] memory hashes;
        uint64[] memory totalKeys;
        uint64[] memory keysUsed;

        if(block.chainid == 1) {
            // MAINNET
            operators = new address[](8);
            operators[0] = 0x83B55dF61cD1181F019DF8e93D46bAFd31806d50;
            operators[1] = 0x78cA32Ac90D7F99225a3B9288D561E0cB3744899;
            operators[2] = 0x7C0576343975A1360CEb91238e7B7985B8d71BF4;
            operators[3] = 0x6916487F0c4553B9EE2f401847B6C58341B76991;
            operators[4] = 0xd624FEfF4b4E77486B544c93A30794CA4B3f10A2;
            operators[5] = 0x00a16D2572573DC9E26e2d267f2270cddAC9218B;
            operators[6] = 0xB8db44e12eacc48F7C2224a248c8990289556fAe;
            operators[7] = 0x3f95F8f6222F6D97b47122372D60117ab386C48F;

            hashes = new bytes[](8);
            totalKeys = new uint64[](8);
            keysUsed = new uint64[](8); 
        }else if(block.chainid == 5) {
            // GOERLI
            operators = new address[](2);
            operators[0] = 0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA;
            operators[1] = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;

            hashes = new bytes[](2);
            totalKeys = new uint64[](2);
            keysUsed = new uint64[](2);
        }

        vm.startBroadcast(deployerPrivateKey);

        for(uint256 i = 0; i < operators.length; i++) {
            (uint64 totalKeysLocal, uint64 keysUsedLocal, bytes memory ipfsHash) = NodeOperatorManager(phaseOneNodeOperator).addressToOperatorData(operators[i]);
            hashes[i] = ipfsHash;
            totalKeys[i] = totalKeysLocal;
            keysUsed[i] = keysUsedLocal;
        }

        nodeOperatorManagerImplementation = new NodeOperatorManager();
        nodeOperatorManagerProxy = new UUPSProxy(address(nodeOperatorManagerImplementation), "");
        nodeOperatorManagerInstance = NodeOperatorManager(address(nodeOperatorManagerProxy));
        nodeOperatorManagerInstance.initialize();

        NodeOperatorManager(nodeOperatorManagerInstance).updateAdmin(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39, true);
        NodeOperatorManager(nodeOperatorManagerInstance).batchMigrateNodeOperator(operators, hashes, totalKeys, keysUsed);

        AuctionManager(AuctionManagerProxyAddress).updateNodeOperatorManager(address(nodeOperatorManagerInstance));
        
        if (addressProvider.getContractAddress("NodeOperatorManager") != address(nodeOperatorManagerInstance)) {
            addressProvider.removeContract("NodeOperatorManager");
        }
        addressProvider.addContract(address(nodeOperatorManagerInstance), "NodeOperatorManager");

        vm.stopBroadcast();
    }
}

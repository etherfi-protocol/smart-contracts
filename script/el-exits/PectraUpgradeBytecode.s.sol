// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../ContractCodeChecker.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/StakingManager.sol";
import "../../src/EtherFiRateLimiter.sol";


contract PectraUpgradeBytecode is Script {
    ContractCodeChecker public contractCodeChecker;
    address public stakingManagerProxy; 
    address public etherFiNodesManagerProxy;
    address public roleRegistryProxy;
    address public rateLimiterProxy;
    address public liquidityPoolProxy;
    address public auctionManager;
    address public etherFiNodeBeacon;
    address public delegationManager;
    address public eigenPodManager;
    address public  stakingDepositContract;

    address public deployedRateLimiter;

    function setUp() public {
        contractCodeChecker = new ContractCodeChecker();
        stakingManagerProxy = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
        etherFiNodesManagerProxy = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
        roleRegistryProxy = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
        rateLimiterProxy = 0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;
        liquidityPoolProxy = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
        auctionManager = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
        etherFiNodeBeacon = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
        delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
        eigenPodManager = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
        stakingDepositContract = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
        deployedRateLimiter = 0x1dd43C32f03f8A74b8160926D559d34358880A89;

    }

    function run() external {
        vm.startBroadcast();
        console2.log("========================================");
        console2.log("PECTRA UPGRADE BYTECODE");
        console2.log("========================================");
        console2.log("");

        address deployedEtherFiNode = address(0x6268728c52aAa4EC670F5fcdf152B50c4B463472);
        address deployedEtherFiNodesManager = address(0x0f366dF7af5003fC7C6524665ca58bDeAdDC3745);
        address deployedStakingManager = address(0xa38d03ea42F8bc31892336E1F42523e94FB91a7A);

        EtherFiNode etherFiNodeImplementation = new EtherFiNode(address(liquidityPoolProxy), address(etherFiNodesManagerProxy), address(eigenPodManager), address(delegationManager), address(roleRegistryProxy));
        EtherFiNodesManager etherFiNodesManagerImplementation = new EtherFiNodesManager(address(stakingManagerProxy), address(roleRegistryProxy), address(rateLimiterProxy));
        StakingManager stakingManagerImplementation = new StakingManager(address(liquidityPoolProxy), address(etherFiNodesManagerProxy), address(stakingDepositContract), address(auctionManager), address(etherFiNodeBeacon), address(roleRegistryProxy));
        EtherFiRateLimiter rateLimiterImplementation = new EtherFiRateLimiter(address(roleRegistryProxy));

        console.log("Rate limiter implementation:", address(rateLimiterImplementation));
        console.log("Etherfi node implementation:", address(etherFiNodeImplementation));
        console.log("Etherfi nodes manager implementation:", address(etherFiNodesManagerImplementation));
        console.log("Staking manager implementation:", address(stakingManagerImplementation));

        console2.log("Verifying rate limiter bytecode...");
        contractCodeChecker.verifyContractByteCodeMatch(deployedRateLimiter, address(rateLimiterImplementation));
        // console2.log("Verifying etherfi node bytecode...");
        // contractCodeChecker.verifyContractByteCodeMatch(deployedEtherFiNode, address(etherFiNodeImplementation));
        // console2.log("Verifying etherfi nodes manager bytecode...");
        // contractCodeChecker.verifyContractByteCodeMatch(deployedEtherFiNodesManager, address(etherFiNodesManagerImplementation));
        // console2.log("Verifying staking manager bytecode...");
        // contractCodeChecker.verifyContractByteCodeMatch(deployedStakingManager, address(stakingManagerImplementation));
        vm.stopBroadcast();
    }
}

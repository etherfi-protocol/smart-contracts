// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {Utils} from "../utils/utils.sol";
// import {EtherFiRedemptionManagerTemp} from "../../src/EtherFiRedemptionManagerTemp.sol";
import {EtherFiRestaker} from "../../src/EtherFiRestaker.sol";
import {EtherFiRedemptionManager} from "../../src/EtherFiRedemptionManager.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import {ICreate2Factory} from "../utils/utils.sol";

contract DeployInstanstStETHWithdrawals is Script, Utils {
    // ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);
    // //--------------------------------------------------------------------------------------
    // //---------------------------- New Deployments -----------------------------------------
    // //--------------------------------------------------------------------------------------
    // address liquidityPoolImpl;
    // address etherFiRedemptionManagerTempImpl;
    // address etherFiRestakerImpl;
    // address etherFiRedemptionManagerImpl;

    // //--------------------------------------------------------------------------------------
    // //------------------------- Existing Users/Proxies -------------------------------------
    // //--------------------------------------------------------------------------------------
    // address constant rewardsCoordinator = 0x7750d328b314EfFa365A0402CcfD489B80B0adda; // Eigen Layer Rewards Coordinator - https://etherscan.io/address/0x7750d328b314effa365a0402ccfd489b80b0adda
    // address constant etherFiRedemptionManager = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    // address constant eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    // address constant weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    // address constant liquidityPool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    // address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    // address constant treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    // address constant etherFiRestaker = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;

    // // TODO: update with final commit
    // bytes32 commitHashSalt = bytes32(bytes20(hex"037da63f453b943e7bd96c155e0798003094e4a0"));

    // function run() external {
    //     vm.startBroadcast();

    //     {
    //         string memory contractName = "EtherFiRedemptionManagerTemp";
    //         bytes memory constructorArgs = abi.encode(
    //             address(liquidityPool),
    //             address(eETH),
    //             address(weETH),
    //             address(treasury),
    //             address(roleRegistry)
    //         );
    //         bytes memory bytecode = abi.encodePacked(
    //             type(EtherFiRedemptionManagerTemp).creationCode,
    //             constructorArgs
    //         );
    //         etherFiRedemptionManagerTempImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
    //         verify(etherFiRedemptionManagerTempImpl, bytecode, commitHashSalt, factory);
    //     }

    //     {
    //         string memory contractName = "EtherFiRestaker";
    //         bytes memory constructorArgs = abi.encode(
    //             address(rewardsCoordinator),
    //             address(etherFiRedemptionManager)
    //         );
    //         bytes memory bytecode = abi.encodePacked(
    //             type(EtherFiRestaker).creationCode,
    //             constructorArgs
    //         );
    //         etherFiRestakerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
    //         verify(etherFiRestakerImpl, bytecode, commitHashSalt, factory);
    //     }

    //     {
    //         string memory contractName = "EtherFiRedemptionManager";
    //         bytes memory constructorArgs = abi.encode(
    //             address(liquidityPool),
    //             address(eETH),
    //             address(weETH),
    //             address(treasury),
    //             address(roleRegistry),
    //             address(etherFiRestaker)
    //         );
    //         bytes memory bytecode = abi.encodePacked(
    //             type(EtherFiRedemptionManager).creationCode,
    //             constructorArgs
    //         );
    //         etherFiRedemptionManagerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
    //         verify(etherFiRedemptionManagerImpl, bytecode, commitHashSalt, factory);
    //     }

    //     {
    //         string memory contractName = "LiquidityPool";
    //         bytes memory constructorArgs = abi.encode(
    //         );
    //         bytes memory bytecode = abi.encodePacked(
    //             type(LiquidityPool).creationCode,
    //             constructorArgs
    //         );
    //         liquidityPoolImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
    //         verify(liquidityPoolImpl, bytecode, commitHashSalt, factory);
    //     }
    //     vm.stopBroadcast();
    // }
}
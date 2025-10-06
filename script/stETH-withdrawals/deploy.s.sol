// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {Utils} from "../utils/utils.sol";
import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";
import {EtherFiRedemptionManagerTemp} from "../../src/EtherFiRedemptionManagerTemp.sol";
import {EtherFiRestaker} from "../../src/EtherFiRestaker.sol";
import {EtherFiRedemptionManager} from "../../src/EtherFiRedemptionManager.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import {ICreate2Factory} from "../utils/utils.sol";

contract DeployInstanstStETHWithdrawals is Script, Utils {
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));

    //--------------------------------------------------------------------------------------
    //--------------------- Previous Implementations ---------------------------------------
    //--------------------------------------------------------------------------------------
    address constant oldLiquidityPoolImpl = 0xA6099d83A67a2c653feB5e4e48ec24C5aeE1C515;

    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    address liquidityPoolImpl;
    address etherFiRedemptionManagerTempImpl;
    address etherFiRestakerImpl;
    address etherFiRedemptionManagerImpl;

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    address constant rewardsCoordinator = 0x7750d328b314EfFa365A0402CcfD489B80B0adda; // Eigen Layer Rewards Coordinator - https://etherscan.io/address/0x7750d328b314effa365a0402ccfd489b80b0adda
    address constant etherFiRedemptionManager = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address constant eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant liquidityPool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant operatingTimelock = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    address constant etherFiRestaker = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;
    // address constant etherFiNodesManager = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    // address constant stakingManager = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    // address constant proofSubmitter = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;
    // address constant etherFiOracle = 0x57AaF0004C716388B21795431CD7D5f9D3Bb6a41;
    // address constant etherFiAdminExecuter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    // address constant etherFiAdmin = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;

    // TODO: update with final commit
    bytes32 commitHashSalt = bytes32(bytes20(hex"7972bd777a339ca98eff1677484aacc816b24d87"));

    function run() external {
        vm.startBroadcast();

        {
            string memory contractName = "EtherFiRedemptionManagerTemp";
            bytes memory constructorArgs = abi.encode(
                address(liquidityPool),
                address(eETH),
                address(weETH),
                address(treasury),
                address(roleRegistry)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRedemptionManagerTemp).creationCode,
                constructorArgs
            );
            etherFiRedemptionManagerTempImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
            verify(etherFiRedemptionManagerTempImpl, bytecode, commitHashSalt, factory);
        }

        {
            string memory contractName = "EtherFiRestaker";
            bytes memory constructorArgs = abi.encode(
                address(rewardsCoordinator),
                address(etherFiRedemptionManager)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRestaker).creationCode,
                constructorArgs
            );
            etherFiRestakerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
            verify(etherFiRestakerImpl, bytecode, commitHashSalt, factory);
        }

        {
            string memory contractName = "EtherFiRedemptionManager";
            bytes memory constructorArgs = abi.encode(
                address(liquidityPool),
                address(eETH),
                address(weETH),
                address(treasury),
                address(roleRegistry),
                address(etherFiRestaker)
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRedemptionManager).creationCode,
                constructorArgs
            );
            etherFiRedemptionManagerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
            verify(etherFiRedemptionManagerImpl, bytecode, commitHashSalt, factory);
        }

        {
            string memory contractName = "LiquidityPool";
            bytes memory constructorArgs = abi.encode(
                address(treasury)
            );
            bytes memory bytecode = abi.encodePacked(
                type(LiquidityPool).creationCode,
                constructorArgs
            );
            liquidityPoolImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
            verify(liquidityPoolImpl, bytecode, commitHashSalt, factory);
        }
        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/WeETH.sol";
import "../../src/UUPSProxy.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/EtherFiRewardsRouter.sol";
import "forge-std/console.sol";


contract DeployV2Dot49Script is Script {

    LiquidityPool public newLiquidtyPoolImplementation = LiquidityPool(payable(address(0x58e97Ce26b29F3B490A137bE6ABB81b08790B107)));
    RoleRegistry public newRoleRegistryImplementation = RoleRegistry(address(0xecd1E25928665Fce0154424F1CD3D9cfd4e03C16));
    EtherFiAdmin public newEtherFiAdminImplementation = EtherFiAdmin(address(0x208DE797E018cfd0DD5989119cb2B2F46Bc4FE79));
    EtherFiRewardsRouter public newEtherFiRewardsRouterImplementation = EtherFiRewardsRouter(payable(address(0x78e660c053271Fb779C83c6D07aE727Debc016c3)));
    WeETH public newWeETHImplementation = WeETH(address(0x3325bC167433785481bBd9Ba0D1e0dCf95290798));

    LiquidityPool public liquidityPoolInstance;
    RoleRegistry public roleRegistryInstance = RoleRegistry(address(0xC1dD9Fd7DD43Bbde426A74AAca1Ed208aAD9d9e1));
    EtherFiAdmin public etherFiAdminInstance;
    EtherFiRewardsRouter public etherFiRewardsRouterInstance;
    WeETH public weETHInstance;
    bool public isProd = false;

    AddressProvider public addressProvider;
    TimelockController public timelockInstance;
    address public deployerKey = address(0x123); //get correct deployer key
    address public treasuryGnosisSafeAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);

    function init() internal {
        addressProvider = AddressProvider(vm.envAddress("CONTRACT_REGISTRY"));
        timelockInstance = TimelockController(payable(address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761)));
        //liquidityPoolInstance = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));
        etherFiAdminInstance = EtherFiAdmin(addressProvider.getContractAddress("EtherFiAdmin"));
        weETHInstance = WeETH(addressProvider.getContractAddress("WeETH"));
        etherFiRewardsRouterInstance = EtherFiRewardsRouter(payable(address(0x73f7b1184B5cD361cC0f7654998953E2a251dd58)));
    }

    function deployImplementationContracts() internal {
        // deploy key
        vm.startBroadcast(address(timelockInstance));

        //deploy new role registry
        newRoleRegistryImplementation = new RoleRegistry();
        UUPSProxy roleRegistryProxy = new UUPSProxy(address(newRoleRegistryImplementation), "");
        roleRegistryInstance = RoleRegistry(address(roleRegistryProxy));
        roleRegistryInstance.initialize(address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39));

        // deploy new implementation contracts
        //newLiquidtyPoolImplementation = new LiquidityPool();
        newEtherFiAdminImplementation = new EtherFiAdmin();
        //newWeETHImplementation = new WeETH();
        //newEtherFiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), treasuryGnosisSafeAddress, address(roleRegistryInstance));
        vm.stopBroadcast();
    }

    function grantRoles() internal { 
        // tenderly address
        address etherfiMultisig = address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39);
        address etherfiOracleAdmin = address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39);
        address liquidityPoolAdmin = address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39);
        address hypernativeEoa = address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39); 
        if(isProd) {
        // prod address
        etherfiMultisig = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        etherfiOracleAdmin = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);
        liquidityPoolAdmin = address(0xFa238cB37E58556b23ea45643FFe4Da382162a53);
        hypernativeEoa = address(0x9AF1298993DC1f397973C62A5D47a284CF76844D); 
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        roleRegistryInstance.grantRole(liquidityPoolInstance.LIQUIDITY_POOL_ADMIN_ROLE(), liquidityPoolAdmin);
        roleRegistryInstance.grantRole(etherFiAdminInstance.ETHERFI_ADMIN_ADMIN_ROLE(), etherfiOracleAdmin);
        roleRegistryInstance.grantRole(etherFiAdminInstance.ETHERFI_ADMIN_TASK_EXECUTOR_ROLE(), etherfiOracleAdmin);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), etherfiMultisig); 
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(etherFiAdminInstance));
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(hypernativeEoa)); 
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(etherfiMultisig));
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), address(etherFiAdminInstance));
        roleRegistryInstance.grantRole(etherFiRewardsRouterInstance.ETHERFI_ROUTER_ADMIN(), address(etherfiMultisig));
        roleRegistryInstance.transferOwnership(address(timelockInstance));
        vm.stopBroadcast();
    }

    function updateAddressProvider() internal {
        address etherfiMultisig = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        vm.startBroadcast(address(timelockInstance));
        addressProvider.addContract(address(roleRegistryInstance), "RoleRegistry");
        addressProvider.addContract(address(etherFiRewardsRouterInstance), "EtherFiRewardsRouter");
        addressProvider.setOwner(etherfiMultisig);
        vm.stopBroadcast();
    }

    function upgradeContracts() internal {
        //behind timelock
        vm.startBroadcast(address(timelockInstance));
        liquidityPoolInstance.upgradeTo(address(newLiquidtyPoolImplementation));
        etherFiAdminInstance.upgradeTo(address(newEtherFiAdminImplementation));
        weETHInstance.upgradeTo(address(newWeETHImplementation));
        etherFiRewardsRouterInstance.upgradeTo(address(newEtherFiRewardsRouterImplementation));
        vm.stopBroadcast();
    }

    //transfer ownership and initalize role registry
    function completeRoleRegistrySetup() internal {
        vm.startBroadcast(address(timelockInstance));
        roleRegistryInstance.acceptOwnership();
        //liquidityPoolInstance.initializeRoleRegistry(address(roleRegistryInstance));
        etherFiAdminInstance.initializeRoleRegistry(address(roleRegistryInstance));
        vm.stopBroadcast();

    }

    function run() external {
        init();
        deployImplementationContracts();
        //only for tenderly test will be done through timelock in prod
        upgradeContracts();

        //grantRoles();           
        //completeRoleRegistrySetup();
        //updateAddressProvider();

    } 

}
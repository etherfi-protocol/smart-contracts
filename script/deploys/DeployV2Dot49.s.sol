
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
import "../../src/EtherFiRedemptionManager.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/WithdrawRequestNFT.sol";
import "forge-std/console.sol";
import "forge-std/console2.sol";

import "../../src/eETH.sol";

contract DeployV2Dot49Script is Script {

    LiquidityPool liquidityPoolImplementation;
    RoleRegistry roleRegistryImplementation;
    EtherFiAdmin etherFiAdminImplementation;
    EtherFiRewardsRouter etherFiRewardsRouterImplementation;
    WeETH weEthImplementation;
    EtherFiNodesManager managerImplementation;
    WithdrawRequestNFT withdrawRequestNFTImplementation;
    EtherFiRedemptionManager etherFiRedemptionManagerImplementation;
    EtherFiTimelock operatingTimelockImplementation;

    LiquidityPool public liquidityPoolInstance;
    RoleRegistry public roleRegistryInstance;
    EtherFiAdmin public etherFiAdminInstance;
    EtherFiRewardsRouter public etherFiRewardsRouterInstance;
    WeETH public weETHInstance;
    EtherFiNodesManager public managerInstance;
    WithdrawRequestNFT public withdrawRequestNFTInstance;
    EtherFiRedemptionManager public etherFiRedemptionManagerInstance;
    EtherFiTimelock public operatingTimelockInstance;
    EtherFiTimelock public oldOperatingTimelockInstance;
    EtherFiTimelock public timelockInstance;
    EETH public eETHInstance;

    bool public isProd = true;

    AddressProvider public addressProvider;
    EtherFiTimelock public etherFiTimelock;
    address public deployerKey = address(0x123); //get correct deployer key
    address public treasuryGnosisSafeAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);

    address public treasuryAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);

    address public etherfiMultisig = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
    address public etherfiOracleAdmin = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);
    address public liquidityPoolAdmin = address(0xFa238cB37E58556b23ea45643FFe4Da382162a53);
    address public hypernativeEoa = address(0x9AF1298993DC1f397973C62A5D47a284CF76844D); 
    address public timelockAddress = address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761);
    address public oldTreasury = address(0x6329004E903B7F420245E7aF3f355186f2432466);
    address public etherOracleMember1 = address(0xDd777e5158Cb11DB71B4AF93C75A96eA11A2A615);
    address public etherOracleMember2 = address(0x2c7cB7d5dC4aF9caEE654553a144C76F10D4b320);

    function init() internal {
        addressProvider = AddressProvider(vm.envAddress("CONTRACT_REGISTRY"));
        roleRegistryInstance = RoleRegistry(address(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9));
        operatingTimelockInstance = EtherFiTimelock(payable(address(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a)));
        timelockInstance = EtherFiTimelock(payable(address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761)));

        etherFiAdminInstance = EtherFiAdmin(addressProvider.getContractAddress("EtherFiAdmin"));
        managerInstance = EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager")));
        etherFiRewardsRouterInstance = EtherFiRewardsRouter(payable(address(0x73f7b1184B5cD361cC0f7654998953E2a251dd58)));
        liquidityPoolInstance = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));
        weETHInstance = WeETH(addressProvider.getContractAddress("WeETH"));
        withdrawRequestNFTInstance = WithdrawRequestNFT(addressProvider.getContractAddress("WithdrawRequestNFT"));
        //etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(addressProvider.getContractAddress("EtherFiRedemptionManager")));
        eETHInstance = EETH(addressProvider.getContractAddress("EETH"));
        

        //print all addresses of contracts in same order
        console2.log('AddressProvider: ', address(addressProvider));
        console2.log('RoleRegistry: ', address(roleRegistryInstance));
        console2.log('OperatingTimelock: ', address(operatingTimelockInstance));
        console2.log('Timelock: ', address(timelockInstance));

        console2.log('EtherFiAdmin: ', address(etherFiAdminInstance));
        console2.log('EtherFiNodesManager: ', address(managerInstance));
        console2.log('EtherFiRewardsRouter: ', address(etherFiRewardsRouterInstance));
        console2.log('LiquidityPool: ', address(liquidityPoolInstance));
        console2.log('WeETH: ', address(weETHInstance));
        console2.log('WithdrawRequestNFT: ', address(withdrawRequestNFTInstance));
        //console2.log('EtherFiRedemptionManager: ', address(etherFiRedemptionManagerInstance));
        console2.log('EETH: ', address(eETHInstance));
        console2.log('Treasury: ', address(treasuryAddress));
        
    }

function writeDeployedContractsToFile() internal {
    // Split the JSON generation to reduce stack variables
    string memory jsonPart1 = string(abi.encodePacked(
        "{\n",
        '  "EtherFiRedemptionManagerImplementation": "', vm.toString(address(etherFiRedemptionManagerImplementation)), '",\n',
        '  "EtherFiRedemptionManagerInstance": "', vm.toString(address(etherFiRedemptionManagerInstance)), '",\n',
        '  "EtherFiAdminImplementation": "', vm.toString(address(etherFiAdminImplementation)), '",\n'
        //'  "EtherFiNodesManagerImplementation": "', vm.toString(address(managerImplementation)), '",\n'
    ));
    
    string memory jsonPart2 = string(abi.encodePacked(
        '  "EtherFiRewardsRouterImplementation": "', vm.toString(address(etherFiRewardsRouterImplementation)), '",\n',
        '  "LiquidityPoolImplementation": "', vm.toString(address(liquidityPoolImplementation)), '",\n',
        '  "WeETHImplementation": "', vm.toString(address(weEthImplementation)), '",\n',
        '  "WithdrawRequestNFTImplementation": "', vm.toString(address(withdrawRequestNFTImplementation)), '",\n',
        "}"
    ));

    string memory jsonContent = string(abi.encodePacked(jsonPart1, jsonPart2));
    vm.writeFile("deployment/deployed-contracts.json", jsonContent);
}

    /////////////////////////// DEPLOYMENT ////////////////////////////
    function deployImplementationContracts() internal {
        // deploy key
        vm.startBroadcast();
        etherFiRedemptionManagerImplementation = new EtherFiRedemptionManager(address(liquidityPoolInstance), address(eETHInstance), address(weETHInstance), address(treasuryAddress), address(roleRegistryInstance));
        UUPSProxy etherFiRedemptionManagerProxy = new UUPSProxy(address(etherFiRedemptionManagerImplementation), "");
        etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(etherFiRedemptionManagerProxy));
        
        etherFiAdminImplementation = new EtherFiAdmin();
        //managerImplementation = new EtherFiNodesManager();
        etherFiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), treasuryAddress, address(roleRegistryInstance));
        liquidityPoolImplementation = new LiquidityPool();
        weEthImplementation = new WeETH();
        withdrawRequestNFTImplementation = new WithdrawRequestNFT(treasuryAddress);
        vm.stopBroadcast();
    }

    function deployNodesManager() internal {
        vm.startBroadcast();
        managerImplementation = new EtherFiNodesManager();
        console2.log('EtherFiNodesManager: ', address(managerImplementation));
        vm.stopBroadcast();
    }



    //////////////////////////// ROLE REGISTRY SETUP ////////////////////////////

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
        roleRegistryInstance.grantRole(etherFiAdminInstance.ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE(), etherfiOracleAdmin);
        roleRegistryInstance.grantRole(etherFiAdminInstance.ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE(), etherfiOracleAdmin);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), etherfiMultisig); 
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(etherFiAdminInstance));
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(hypernativeEoa)); 
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(etherfiMultisig));
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), address(etherFiAdminInstance));
        roleRegistryInstance.grantRole(etherFiRewardsRouterInstance.ETHERFI_REWARDS_ROUTER_ADMIN_ROLE(), address(etherfiMultisig));
        roleRegistryInstance.transferOwnership(address(timelockInstance));
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

    function renamingEtherAdminRoles() internal {
        vm.startBroadcast();
        address etherfiMultisig = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        address oracleEOA = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);
        bytes32 taskManagerRole = keccak256("ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE");
        bytes32 adminRole = keccak256("ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE");
        bytes32 validatorManagerRole = keccak256("ETHERFI_ORACLE_EXECUTOR_VALIDATOR_MANAGER_ROLE");
        RoleRegistry roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

        roleRegistry.revokeRole(adminRole, oracleEOA);
        roleRegistry.revokeRole(validatorManagerRole, oracleEOA);

        roleRegistry.grantRole(taskManagerRole, oracleEOA);
        roleRegistry.grantRole(taskManagerRole, etherfiMultisig);
        roleRegistry.grantRole(adminRole, etherfiMultisig);
        vm.stopBroadcast();
    }

    function updateRoleRegistry() internal {
        vm.startBroadcast();
        bytes32 taskManagerRole = keccak256("ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE");

        bytes32 adminRole = keccak256("ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE");
        bytes32 liquidityPoolAdminRole = keccak256("LIQUIDITY_POOL_ADMIN_ROLE");
        bytes32 redemptionManagerAdminRole = keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE");
        bytes32 withdrawRequestNFTAdminRole = keccak256("WITHDRAW_REQUEST_NFT_ADMIN_ROLE");


        roleRegistryInstance.revokeRole(liquidityPoolAdminRole, address(oldOperatingTimelockInstance));
        roleRegistryInstance.revokeRole(redemptionManagerAdminRole, address(oldOperatingTimelockInstance));
        roleRegistryInstance.revokeRole(withdrawRequestNFTAdminRole, address(oldOperatingTimelockInstance));
        roleRegistryInstance.revokeRole(adminRole, address(oldOperatingTimelockInstance));

        roleRegistryInstance.grantRole(liquidityPoolAdminRole, address(operatingTimelockInstance));
        roleRegistryInstance.grantRole(redemptionManagerAdminRole, address(operatingTimelockInstance));
        roleRegistryInstance.grantRole(withdrawRequestNFTAdminRole, address(operatingTimelockInstance));
        roleRegistryInstance.grantRole(adminRole, address(operatingTimelockInstance));
        vm.stopBroadcast();
    }

    //////////////////////////// ADDRESS PROVIDER SETUP ////////////////////////////

    function updateAddressProvider() internal {
        address etherfiMultisig = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        vm.startBroadcast(address(timelockInstance));
        addressProvider.addContract(address(roleRegistryInstance), "RoleRegistry");
        addressProvider.addContract(address(etherFiRewardsRouterInstance), "EtherFiRewardsRouter");
        addressProvider.setOwner(etherfiMultisig);
        vm.stopBroadcast();
    }

    //////////////////////////// CONTRACT UPGRADES ////////////////////////////

    function upgradeContracts() internal {
        //behind timelock
        vm.startBroadcast(address(timelockInstance));
        liquidityPoolInstance.upgradeTo(address(liquidityPoolImplementation));
        etherFiAdminInstance.upgradeTo(address(etherFiAdminImplementation));
        weETHInstance.upgradeTo(address(weEthImplementation));
        etherFiRewardsRouterInstance.upgradeTo(address(etherFiRewardsRouterImplementation));
        vm.stopBroadcast();
    }

    function initContracts() internal {
        etherFiRedemptionManagerInstance.initialize(10_00, 30, 1_00, 1000 ether, 0.01157407407 ether);
    }

    //////////////////////////// OPERATING TIMELOCK SETUP ////////////////////////////

    function deployOperatingTimelock() internal {
        vm.startBroadcast();
        uint256 minDelay = 60 * 60 * 8; // 8 hours
        address[] memory proposers = new address[](1);
        proposers[0] = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        address admin = address(0);
        EtherFiTimelock operatingTimelock = new EtherFiTimelock(minDelay, proposers, proposers, admin);
        vm.stopBroadcast();
    }


    function run() public {
        init();
        //completeRoleRegistrySetup();
        //grantRoles();
        //renamingEtherAdminRoles();


        //deployOperatingTimelock();
        //uncomment after operating timelock is deployed
        //oldOperatingTimelockInstance = EtherFiTimelock(payable(address(0x82215f1274356E94543a4D6baC6F7170D8A59F2A)));
        //updateRoleRegistry();

        //uncomment after deploy is done
        //EtherFiRedemptionManager etherFiRedemptionManagerInstance = EtherFiRedemptionManager(address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));
        //Timelock operatingTimelock = EtherFiTimelock();

        //deployImplementationContracts();
        //writeDeployedContractsToFile();
        //initContracts();
        deployNodesManager();
    }

}
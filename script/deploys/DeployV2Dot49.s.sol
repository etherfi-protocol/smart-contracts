// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EtherFiOracleExecutor.sol";
import "../../src/WeETH.sol";
import "../../src/UUPSProxy.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/EtherFiRewardsRouter.sol";
import "../../src/EtherFiRedemptionManager.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/eETH.sol";
import "forge-std/console.sol";

//source .env && forge script ./script/deploys/DeployV2Dot49.s.sol --rpc-url $TENDERLY_RPC_URL --etherscan-api-key $TENDERLY_ACCESS_TOKEN --slow --verifier-url $TENDERLY_VERIFIER_URL --verify -vvvv --sender 0x983cACB4d5AfbAA99B35F81d435b956bf4E628F8 

contract DeployV2Dot49Script is Script {

    // Define the role directly as a constant with the same keccak256 hash as in the LiquidityPool contract
    bytes32 public constant LIQUIDITY_POOL_ADMIN_ROLE = keccak256("LIQUIDITY_POOL_ADMIN_ROLE");
    bytes32 public constant WITHDRAW_REQUEST_NFT_ADMIN_ROLE = keccak256("WITHDRAW_REQUEST_NFT_ADMIN_ROLE");
    bytes32 public constant ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE");
    bytes32 public constant ETHERFI_ORACLE_EXECUTOR_VALIDATOR_MANAGER_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_VALIDATOR_MANAGER_ROLE");
    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN");


    LiquidityPool public newLiquidtyPoolImplementation;
    RoleRegistry public newRoleRegistryImplementation;
    EtherFiOracleExecutor public newEtherFiAdminImplementation;
    WithdrawRequestNFT public newWithdrawRequestNFTImplementation;
    EtherFiRewardsRouter public newEtherFiRewardsRouterImplementation;
    EtherFiRedemptionManager public newEtherFiRedemptionManagerImplementation;
    WeETH public newWeETHImplementation;

    EETH public eETHInstance;
    LiquidityPool public liquidityPoolInstance;
    RoleRegistry public roleRegistryInstance = RoleRegistry(address(0xC1dD9Fd7DD43Bbde426A74AAca1Ed208aAD9d9e1));
    EtherFiOracleExecutor public etherFiAdminInstance;
    EtherFiRewardsRouter public etherFiRewardsRouterInstance;
    WeETH public weETHInstance;
    WithdrawRequestNFT public withdrawRequestNFTInstance;
    EtherFiRedemptionManager public etherFiRedemptionManagerInstance;

    bool public isProd = false;

    AddressProvider public addressProvider;
    TimelockController public timelockInstance;
    address public deployerKey = address(0x123); //get correct deployer key
    address public treasuryGnosisSafeAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);

    function init() internal {
        addressProvider = AddressProvider(vm.envAddress("CONTRACT_REGISTRY"));
        timelockInstance = TimelockController(payable(address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761)));
        liquidityPoolInstance = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));
        withdrawRequestNFTInstance = WithdrawRequestNFT(payable(addressProvider.getContractAddress("WithdrawRequestNFT")));
        etherFiAdminInstance = EtherFiOracleExecutor(addressProvider.getContractAddress("EtherFiOracleExecutor"));
        weETHInstance = WeETH(addressProvider.getContractAddress("WeETH"));
        eETHInstance = EETH(addressProvider.getContractAddress("EETH"));

        etherFiRewardsRouterInstance = EtherFiRewardsRouter(payable(address(0x73f7b1184B5cD361cC0f7654998953E2a251dd58)));
    }

    function deployImplementationContracts() internal {
        // deploy key
        vm.startBroadcast();
        address deployer = address(0x8D5AAc5d3d5cda4c404fA7ee31B0822B648Bb150);
        //deploy new role registry
        newRoleRegistryImplementation = new RoleRegistry();
        UUPSProxy roleRegistryProxy = new UUPSProxy(address(newRoleRegistryImplementation), "");
        roleRegistryInstance = RoleRegistry(address(roleRegistryProxy));
        roleRegistryInstance.initialize(address(deployer));

        // // deploy new implementation contracts
        // newLiquidtyPoolImplementation = new LiquidityPool();
        // newEtherFiAdminImplementation = new EtherFiOracleExecutor();
        // newWeETHImplementation = new WeETH();
        // newEtherFiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), treasuryGnosisSafeAddress, address(roleRegistryInstance));
        // newWithdrawRequestNFTImplementation = new WithdrawRequestNFT(treasuryGnosisSafeAddress);

        //newEtherFiRedemptionManagerImplementation = new EtherFiRedemptionManager(address(liquidityPoolInstance), address(eETHInstance), address(weETHInstance), treasuryGnosisSafeAddress, address(roleRegistryInstance));
        //etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(address(new UUPSProxy(address(newEtherFiRedemptionManagerImplementation), ""))));
        vm.stopBroadcast();
    }

    function grantRoles() internal { 
        // tenderly address
        address etherfiMultisig = address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39);
        address etherfiOracleAdmin = address(0xc13C06899a9BbEbB3E2b38dBe86e4Ea8852AFC9b);
        address liquidityPoolAdmin = address(0xc351788DDb96cD98d99E62C97f57952A8b3Fc1B5);
        address hypernativeEoa = address(0x983cACB4d5AfbAA99B35F81d435b956bf4E628F8); 
        if(isProd) {
        // prod address
        etherfiMultisig = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        etherfiOracleAdmin = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);
        liquidityPoolAdmin = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        hypernativeEoa = address(0x9AF1298993DC1f397973C62A5D47a284CF76844D); 
        }

        vm.startBroadcast();
        //liquidity pool
        
        roleRegistryInstance.grantRole(LIQUIDITY_POOL_ADMIN_ROLE, liquidityPoolAdmin);
        roleRegistryInstance.grantRole(LIQUIDITY_POOL_ADMIN_ROLE, address(etherFiAdminInstance));

        //etherFiAdmin
        roleRegistryInstance.grantRole(ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE, etherfiOracleAdmin);
        roleRegistryInstance.grantRole(ETHERFI_ORACLE_EXECUTOR_VALIDATOR_MANAGER_ROLE, etherfiOracleAdmin);

        //rewardsRouter
        roleRegistryInstance.grantRole(ETHERFI_REWARDS_ROUTER_ADMIN, address(etherfiMultisig));

        //withdrawRequestNFT
        roleRegistryInstance.grantRole(WITHDRAW_REQUEST_NFT_ADMIN_ROLE, address(etherfiMultisig));
        roleRegistryInstance.grantRole(WITHDRAW_REQUEST_NFT_ADMIN_ROLE, address(etherFiAdminInstance));

        //RedemptionManager
        roleRegistryInstance.grantRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE, address(etherfiMultisig));

        //protocol
        //unpauser
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), etherfiMultisig); 
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), address(etherFiAdminInstance));
        //pauser
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(etherFiAdminInstance));
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(hypernativeEoa)); 
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(etherfiMultisig));

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
        withdrawRequestNFTInstance.upgradeTo(address(newWithdrawRequestNFTImplementation));
        vm.stopBroadcast();
    }

    //transfer ownership and initalize role registry
    function completeRoleRegistrySetup() internal {
        vm.startBroadcast(address(timelockInstance));
        etherFiRedemptionManagerInstance.initialize(1000, 100, 230, 500 ether, 0.005787037037 ether);
        liquidityPoolInstance.initializeVTwoDotFourNine(address(roleRegistryInstance), address(etherFiRedemptionManagerInstance));
        etherFiAdminInstance.initializeRoleRegistry(address(roleRegistryInstance));
        withdrawRequestNFTInstance.initializeOnUpgrade(address(roleRegistryInstance), 1000);
        vm.stopBroadcast();
    }

    function run() external {

        init();

        // step 0
        isProd = true; //set to true for prod

        //step 1
        roleRegistryInstance = RoleRegistry(address(0x98Fe79a199624c4a2280001303C8356fA3e4B0B9));
        deployImplementationContracts();
        grantRoles();           

        //step 2
        //roleRegistryInstance = RoleRegistry(address(0x98Fe79a199624c4a2280001303C8356fA3e4B0B9));
        //etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(address(0x69e03a920FE2e2FcD970fC20095B5cC664DC0C8b)));

        //step 3
        //upgradeContracts();
        
        //step 4: initialize contracts
        //completeRoleRegistrySetup();

        // step 5: update address provider
        //updateAddressProvider();

    } 

}
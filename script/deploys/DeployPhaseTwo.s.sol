// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/UUPSProxy.sol";
import "../../src/EtherFiOracle.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/helpers/AddressProvider.sol";

import "../../src/interfaces/IAuctionManager.sol";
import "../../src/interfaces/IStakingManager.sol";
import "../../src/interfaces/ILiquidityPool.sol";
import "../../src/interfaces/IMembershipManager.sol";
import "../../src/interfaces/IMembershipNFT.sol";
import "../../src/interfaces/IEtherFiNodesManager.sol";
import "../../src/interfaces/IEtherFiOracle.sol";
import "../../src/interfaces/IWithdrawRequestNFT.sol";

import "../../src/UUPSProxy.sol";

contract DeployPhaseTwoScript is Script {
    UUPSProxy public etherFiOracleProxy;
    EtherFiOracle public etherFiOracleInstance;
    EtherFiOracle public etherFiOracleImplementation;

    UUPSProxy public etherFiAdminProxy;
    EtherFiAdmin public etherFiAdminInstance;
    EtherFiAdmin public etherFiAdminImplementation;

    UUPSProxy public withdrawRequestNftProxy;
    WithdrawRequestNFT public withdrawRequestNftInstance;
    WithdrawRequestNFT public withdrawRequestNftImplementation;

    AddressProvider public addressProvider;

    address addressProviderAddress;
    address etherFiOracleAddress;
    address stakingManagerAddress;
    address auctionAddress;
    address managerAddress;
    address liquidityPoolAddress;
    address eEthAddress;
    address membershipManagerAddress;
    address withdrawRequestNFTAddress;

    address oracleAdminAddress;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");    
        addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        oracleAdminAddress = vm.envAddress("ORACLE_ADMIN_ADDRESS");
        addressProvider = AddressProvider(addressProviderAddress);
        
        vm.startBroadcast(deployerPrivateKey);

        deploy_WithdrawRequestNFT();

        deploy_EtherFiOracle();

        deploy_EtherFiAdmin();

        vm.stopBroadcast();
    }

    function retrieve_contract_addresses() internal {
        // Retrieve the addresses of the contracts that have already deployed
        etherFiOracleAddress = addressProvider.getContractAddress("EtherFiOracle");
        stakingManagerAddress = addressProvider.getContractAddress("StakingManager");
        auctionAddress = addressProvider.getContractAddress("AuctionManager");
        managerAddress = addressProvider.getContractAddress("EtherFiNodesManager");
        liquidityPoolAddress = addressProvider.getContractAddress("LiquidityPool");
        eEthAddress = addressProvider.getContractAddress("EETH");
        membershipManagerAddress = addressProvider.getContractAddress("MembershipManager");
        withdrawRequestNFTAddress = addressProvider.getContractAddress("WithdrawRequestNFT");
    }

    function deploy_WithdrawRequestNFT() internal {
        if (addressProvider.getContractAddress("WithdrawRequestNFT") != address(0)) {
            addressProvider.removeContract("WithdrawRequestNFT");
        }
        retrieve_contract_addresses();

        withdrawRequestNftImplementation = new WithdrawRequestNFT();
        withdrawRequestNftProxy = new UUPSProxy(address(withdrawRequestNftImplementation), "");
        withdrawRequestNftInstance = WithdrawRequestNFT(payable(withdrawRequestNftProxy));

        withdrawRequestNftInstance.initialize(liquidityPoolAddress, eEthAddress, membershipManagerAddress);

        addressProvider.addContract(address(withdrawRequestNftProxy), "WithdrawRequestNFT");
    }

    function deploy_EtherFiOracle() internal {
        if (addressProvider.getContractAddress("EtherFiOracle") != address(0)) {
            addressProvider.removeContract("EtherFiOracle");
        }
        retrieve_contract_addresses();

        etherFiOracleImplementation = new EtherFiOracle();
        etherFiOracleProxy = new UUPSProxy(address(etherFiOracleImplementation), "");
        etherFiOracleInstance = EtherFiOracle(payable(etherFiOracleProxy));

        if (block.chainid == 0) {
            // Mainnet's slot 0 happened at 1606824023; https://beaconcha.in/slot/0
            etherFiOracleInstance.initialize(1, 7200, 0, 32, 12, 1606824023);

            // TODO
            // address oracleNodeAddress = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39
            // etherFiOracleInstance.addCommitteeMember(oracleNodeAddress);

        } else if (block.chainid == 5) {
            // Goerli's slot 0 happened at 1616508000; https://goerli.beaconcha.in/slot/0
            etherFiOracleInstance.initialize(1, 96, 0, 32, 12, 1616508000);
            // 96 slots = 19.2 mins, 7200 slots = 225 epochs = 1day

            etherFiOracleInstance.addCommitteeMember(address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39));
            etherFiOracleInstance.addCommitteeMember(address(0x601B37004f2A6B535a6cfBace0f88D2d534aCcD8));
        } else {
            require(false, "chain is wrong");
        }

        addressProvider.addContract(address(etherFiOracleProxy), "EtherFiOracle");
    }

    function deploy_EtherFiAdmin() internal {
        if (addressProvider.getContractAddress("EtherFiAdmin") != address(0)) {
            addressProvider.removeContract("EtherFiAdmin");
        }
        retrieve_contract_addresses();

        etherFiAdminImplementation = new EtherFiAdmin();
        etherFiAdminProxy = new UUPSProxy(address(etherFiAdminImplementation), "");
        etherFiAdminInstance = EtherFiAdmin(payable(etherFiAdminProxy));

        int32 acceptableRebaseAprInBps;
        uint16 postReportWaitTimeInSlots;

        if (block.chainid == 0) {
            acceptableRebaseAprInBps = 500; // 5%
            postReportWaitTimeInSlots = 7200 / 2; // 7200 slots = 225 epochs = 1 day
        } else if (block.chainid == 5) {
            acceptableRebaseAprInBps = 600; // 6%
            postReportWaitTimeInSlots = 15 minutes / 12 seconds; // 15 minutes
        } else {
            require(false, "chain is wrong");
        }

        etherFiAdminInstance.initialize(
            etherFiOracleAddress,
            stakingManagerAddress,
            auctionAddress,
            managerAddress,
            liquidityPoolAddress,
            membershipManagerAddress,
            withdrawRequestNFTAddress,
            acceptableRebaseAprInBps,
            postReportWaitTimeInSlots
        );

        etherFiAdminInstance.updateAdmin(oracleAdminAddress, true);

        IEtherFiOracle(address(etherFiOracleAddress)).setEtherFiAdmin(address(etherFiAdminInstance));
        IWithdrawRequestNFT(address(withdrawRequestNFTAddress)).updateAdmin(address(etherFiAdminInstance), true);

        // Used only for development
        if (false) {
            address admin = address(etherFiAdminInstance);
            IAuctionManager(address(auctionAddress)).updateAdmin(admin, true);
            IStakingManager(address(stakingManagerAddress)).updateAdmin(admin, true);
            ILiquidityPool(address(liquidityPoolAddress)).updateAdmin(admin, true);
            IMembershipManager(address(membershipManagerAddress)).updateAdmin(admin, true);
            IEtherFiNodesManager(address(managerAddress)).updateAdmin(admin, true);
        }

        addressProvider.addContract(address(etherFiAdminProxy), "EtherFiAdmin");
    }
}
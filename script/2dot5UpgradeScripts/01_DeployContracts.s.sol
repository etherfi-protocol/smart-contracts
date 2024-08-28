// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/Pauser.sol";
import "../../src/RoleRegistry.sol";
import "../../src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/interfaces/IPausable.sol";
import "../../src/AuctionManager.sol";
import "../../src/BucketRateLimiter.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiOracle.sol";
import "../../src/EtherFiRewardsRouter.sol";
import "../../src/LiquidityPool.sol";
import "../../src/Liquifier.sol";
import "../../src/StakingManager.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/NodeOperatorManager.sol";

contract Deploy2Dot5Contracts is Script {

    IPausable[] initialPausables;
    RoleRegistry roleRegistry;
    AddressProvider addressProvider;
    address bucketRateLimiterAddress;

    string scheduleUpgradeGnosisTx;
    string executeUpgradeGnosisTx;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Configuring Mainnet Addresses...");

        addressProvider = AddressProvider(address(0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848));
        address superAdmin = address(0x0);

        console.log("Deploying RoleRegistry...");
        RoleRegistry roleRegistryImplementation = new RoleRegistry();
        bytes memory initializerData = abi.encodeWithSelector(RoleRegistry.initialize.selector, superAdmin);
        roleRegistry = RoleRegistry(address(new UUPSProxy(address(roleRegistryImplementation), initializerData)));

        console.log("Deploying BucketRateLimiter...");
        BucketRateLimiter bucketRateLimiterImplementation = new BucketRateLimiter();
        initializerData = abi.encodeWithSelector(BucketRateLimiter.initialize.selector, address(roleRegistry));
        bucketRateLimiterAddress = address(new UUPSProxy(address(roleRegistryImplementation), initializerData));

        console.log("Deploying Protocol Pauser...");
        Pauser pauserImplementation = new Pauser();
        initialPausables.push(IPausable(addressProvider.getContractAddress("AuctionManager")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("EtherFiNodesManager"))); 
        initialPausables.push(IPausable(addressProvider.getContractAddress("EtherFiOracle")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("LiquidityPool")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("Liquifier"))); 
        initialPausables.push(IPausable(addressProvider.getContractAddress("StakingManager")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("NodeOperatorManager")));

        initializerData = abi.encodeWithSelector(Pauser.initialize.selector, initialPausables, address(roleRegistry));
        Pauser pauser = Pauser(address(new UUPSProxy(address(pauserImplementation), initializerData)));

        console.log("Deploying new impls and generating timelock transactions to upgrade...");

        scheduleUpgradeGnosisTx = _getGnosisHeader("1");
        executeUpgradeGnosisTx = _getGnosisHeader("1");

        address newAuctionManagerImpl = address(new AuctionManager());
        _generateTimelockUpgradeTransactions(newAuctionManagerImpl);
        address newEtherFiAdminImpl = address(new EtherFiAdmin());
        _generateTimelockUpgradeTransactions(newEtherFiAdminImpl);
        address newEtherFiNodesManagerImpl = address(new EtherFiNodesManager());
        _generateTimelockUpgradeTransactions(newEtherFiNodesManagerImpl);
        address newEtherFiOracleImpl = address(new EtherFiOracle());
        _generateTimelockUpgradeTransactions(newEtherFiOracleImpl);
        address newLiquidityPoolImpl = address(new LiquidityPool());
        _generateTimelockUpgradeTransactions(newLiquidityPoolImpl);
        address newLiquifierImpl = address(new Liquifier());
        _generateTimelockUpgradeTransactions(newLiquifierImpl);
        address newNodeOperatorManagerImpl = address(new NodeOperatorManager());
        _generateTimelockUpgradeTransactions(newNodeOperatorManagerImpl);
        address newStakingManagerImpl = address(new StakingManager());
        _generateTimelockUpgradeTransactions(newStakingManagerImpl);
        address newWithdrawRequestNFTImpl = address(new WithdrawRequestNFT());
        _generateTimelockUpgradeTransactions(newWithdrawRequestNFTImpl, true);

        vm.writeJson(scheduleUpgradeGnosisTx, "./release/scheduleUpgrade.json");
        vm.writeJson(executeUpgradeGnosisTx, "./release/executeUpgrade.json");
    }

    function _generateTimelockUpgradeTransactions(address contractToUpgrade, bool isLastTransaction) internal {
        // constant values for all timelock transcations
        string memory timelockAddress = iToHex(abi.encodePacked((addressProvider.getContractAddress("EtherFiTimelock"))));
        uint256 value = 0;
        bytes32 predecessor = 0x0000000000000000000000000000000000000000000000000000000000000000;
        bytes32 salt = 0x0000000000000000000000000000000000000000000000000000000000000000;
        uint256 delay = 259200;

        // data objects for the upgrade and `initializeV2dot5` calls
        bytes memory upgradeContractData = abi.encodeWithSignature("upgradeTo(address)", contractToUpgrade);
        bytes memory initializeV2dot5Data;
        if (contractToUpgrade == addressProvider.getContractAddress("Liquifier")) {
            // Liquifier has an additional initialization param
            initializeV2dot5Data = abi.encodeWithSignature("initializeV2dot5(address,address)", roleRegistry, bucketRateLimiterAddress);
        } else {
            initializeV2dot5Data = abi.encodeWithSignature("initializeV2dot5(address)", roleRegistry);
        }

        // Generate the gnosis transactions to schedule the calls
        string memory scheduleUpgradeData = iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", contractToUpgrade, value, upgradeContractData, predecessor, salt, delay));
        string memory scheduleInitializeV2dot5Data = iToHex(abi.encodeWithSignature("schedule(address,uint256,bytes,bytes32,bytes32,uint256)", contractToUpgrade, value, initializeV2dot5Data, predecessor, salt, delay));

        scheduleUpgradeGnosisTx = string.concat(scheduleUpgradeGnosisTx, _getGnosisTransaction(timelockAddress, scheduleUpgradeData, false));
        scheduleUpgradeGnosisTx = string.concat(scheduleUpgradeGnosisTx, _getGnosisTransaction(timelockAddress, scheduleInitializeV2dot5Data, isLastTransaction));

        // Generate the gnosis transactions to execute the calls 
        string memory executeUpgradeData = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", contractToUpgrade, value, upgradeContractData, predecessor, salt));
        string memory executeInitializeV2dot5Data = iToHex(abi.encodeWithSignature("execute(address,uint256,bytes,bytes32,bytes32)", contractToUpgrade, value, initializeV2dot5Data, predecessor, salt));

        executeUpgradeGnosisTx = string.concat(executeUpgradeGnosisTx, _getGnosisTransaction(timelockAddress, executeUpgradeData, false));
        executeUpgradeGnosisTx = string.concat(executeUpgradeGnosisTx, _getGnosisTransaction(timelockAddress, executeInitializeV2dot5Data, isLastTransaction));
    }

    function _generateTimelockUpgradeTransactions(address contractToUpgrade) internal {
        _generateTimelockUpgradeTransactions(contractToUpgrade, false);
    }

    // functions that can be used together to create a gnosis transaction
    function _getGnosisHeader(string memory chainId) internal pure returns (string memory) {
        return string.concat('{"chainId":"', chainId, '","meta": { "txBuilderVersion": "1.16.5" }, "transactions": [');
    }
    function _getGnosisTransaction(string memory to, string memory data, bool isLast) internal pure returns (string memory) {
        string memory suffix = isLast ? ']}' : ',';
        // value is always 0 for these transactions
        return string.concat('{"to":"', to, '","value":"0","data":"', data, '"}', suffix);
    }
    // takes raw bytes and converts it to the hex string expected by the gnosis safe
    function iToHex(bytes memory buffer) public pure returns (string memory) {
        // Fixed buffer size for hexadecimal convertion
        bytes memory converted = new bytes(buffer.length * 2);

        bytes memory _base = "0123456789abcdef";

        for (uint256 i = 0; i < buffer.length; i++) {
            converted[i * 2] = _base[uint8(buffer[i]) / _base.length];
            converted[i * 2 + 1] = _base[uint8(buffer[i]) % _base.length];
        }

        return string(abi.encodePacked("0x", converted));
    }
}

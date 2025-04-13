// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "test/TestSetup.sol";

import "../src/EtherFiNode.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiRestaker.sol";
import "../src/StakingManager.sol";
import "../src/helpers/AddressProvider.sol";
import "../script/GnosisHelpers.sol";

contract Upgrade is Script, GnosisHelpers {

    address public etherFiTimelock = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
    address public addressProviderAddress = 0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848;
    AddressProvider public addressProvider = AddressProvider(addressProviderAddress);
    address public roleRegistry = 0x1d3Af47C1607A2EF33033693A9989D1d1013BB50;
    address public treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    address public pauser = 0x9AF1298993DC1f397973C62A5D47a284CF76844D;

    address public etherFiNodeImplementation;
    address public etherFiNodesManagerImplementation;
    address public etherFiRestakerImplementation;

    EtherFiNodesManager public etherFiNodesManagerInstance;
    EtherFiRestaker public etherFiRestakerInstance;
    StakingManager public stakingManagerInstance;

    function run() external {

        /*
        // Tenderly values
        etherFiNodeImplementation = address(0xC1dD9Fd7DD43Bbde426A74AAca1Ed208aAD9d9e1);
        etherFiNodesManagerImplementation = address(0x98Fe79a199624c4a2280001303C8356fA3e4B0B9);
        etherFiRestakerImplementation = address(0x58e97Ce26b29F3B490A137bE6ABB81b08790B107);
        */

        // new implementation addresses
        etherFiNodeImplementation = address(0xc5F2764383f93259Fba1D820b894B1DE0d47937e); 
        etherFiNodesManagerImplementation = address(0xE9EE6923D41Cf5F964F11065436BD90D4577B5e4);
        etherFiRestakerImplementation = address(0x0052F731a6BEA541843385ffBA408F52B74Cb624);
        require(etherFiNodeImplementation != address(0x0), "invalid node implementation");
        require(etherFiNodesManagerImplementation != address(0x0), "invalid node implementation");
        require(etherFiRestakerImplementation != address(0x0), "invalid node implementation");

        // proxy addresses
        stakingManagerInstance = StakingManager(payable(addressProvider.getContractAddress("StakingManager")));
        etherFiNodesManagerInstance = EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager")));
        etherFiRestakerInstance = EtherFiRestaker(payable(address(0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf))); // EtherFiRestaker is missing from addressProvideEtherfaddressr
        require(address(stakingManagerInstance) != address(0x0), "failed to lookup stakingManagerInstance");
        require(address(etherFiNodesManagerInstance) != address(0x0), "failed to lookup etherFiNodeInstance");
        require(address(etherFiRestakerInstance) != address(0x0), "failed to lookup etherFiRestakerInstance");

        vm.startBroadcast();

        deploy_upgrade();

         vm.stopBroadcast();
     }

    function deploy_upgrade() internal {
        predecessor = 0x0000000000000000000000000000000000000000000000000000000000000000;
        salt = keccak256("EigenlayerSlashingUpgrade-4_13");
        delay = 3 days;

        // entry point for each timelock subcall
        address[] memory targets = new address[](3);
        targets[0] = address(stakingManagerInstance); // staking manager is the beacon proxy owner for etherfiNode
        targets[1] = address(etherFiNodesManagerInstance);
        targets[2] = address(etherFiRestakerInstance);

        // eth to send (tx.value) in each timelock subcall
        uint256[] memory values = new uint256[](3);

        // calldata for each timelock subcall
        bytes[] memory payloads = new bytes[](3);
        bytes memory upgradeEtherFiNodeCalldata = abi.encodeWithSignature(
            "upgradeEtherFiNode(address)",
            etherFiNodeImplementation
        );
        bytes memory upgradeEtherFiNodesManagerCalldata = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            etherFiNodesManagerImplementation,
            ""
        );
        bytes memory upgradeEtherFiRestakerCalldata = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            etherFiRestakerImplementation,
            ""
        );

        payloads[0] = upgradeEtherFiNodeCalldata;
        payloads[1] = upgradeEtherFiNodesManagerCalldata;
        payloads[2] = upgradeEtherFiRestakerCalldata;

        string memory scheduleGnosisTx = _getGnosisHeader("1");
        string memory scheduleUpgrade = iToHex(abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, values, payloads, predecessor, salt, delay));
        scheduleGnosisTx = string(abi.encodePacked(scheduleGnosisTx, _getGnosisTransaction(addressToHex(timelock), scheduleUpgrade, true)));

        string memory path = "./operations/20250413_upgrade_eigenlayer_slashing_schedule.json";
        vm.writeFile(path, scheduleGnosisTx);

        string memory executeGnosisTx = _getGnosisHeader("1");
        string memory executeUpgrade = iToHex(abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, values, payloads, predecessor, salt));
        executeGnosisTx = string(abi.encodePacked(executeGnosisTx, _getGnosisTransaction(addressToHex(timelock), executeUpgrade, true)));

        path = "./operations/20250413_upgrade_eigenlayer_slashing_execute.json";
        vm.writeFile(path, executeGnosisTx);

        console2.log("timestamp: ", block.timestamp);
    }


}

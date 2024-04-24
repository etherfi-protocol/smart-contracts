// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiTimelock.sol";
import "forge-std/console2.sol";

contract TimelockTest is TestSetup {
    event TimelockTransaction(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt, uint256 delay);

    function test_timelock() public {
        initializeRealisticFork(MAINNET_FORK);

        address owner = managerInstance.owner();
        address admin = vm.addr(0x1234);
        console2.log("adminAddr:", admin);
        console2.log("ownerAddr:", owner);

        // who can propose transactions for the timelock
        address[] memory proposers = new address[](2);
        proposers[0] = owner;
        proposers[1] = admin;

        // who can execute transactions for the timelock
        address[] memory executors = new address[](1);
        executors[0] = owner;

        EtherFiTimelock tl = new EtherFiTimelock(2 days, proposers, executors, address(0x0));

        // transfer ownership to new timelock
        vm.prank(owner);
        managerInstance.transferOwnership(address(tl));
        assertEq(managerInstance.owner(), address(tl));

        // attempt to call an onlyOwner function with the previous owner
        vm.prank(owner);
        vm.expectRevert("Ownable: caller is not the owner");
        managerInstance.updateAdmin(admin, true);

        // encoded data for EtherFiNodesManager.UpdateAdmin(admin, true)
        bytes memory data = hex"670a6fd9000000000000000000000000cf03dd0a894ef79cb5b601a43c4b25e3ae4c67ed0000000000000000000000000000000000000000000000000000000000000001";

        // attempt to directly execute with timelock. Not allowed to do tx before queuing it
        vm.prank(owner);
        vm.expectRevert("TimelockController: operation is not ready");
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // not allowed to schedule a tx below the minimum delay
        vm.prank(owner);
        vm.expectRevert("TimelockController: insufficient delay");
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            1 days                    // time before operation can be run
        );

        // schedule updateAdmin tx
        vm.prank(owner);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );

        // find operation id by hashing relevant data
        bytes32 operationId = tl.hashOperation(address(managerInstance), 0, data, 0, 0);

        // cancel the scheduled tx
        vm.prank(owner);
        tl.cancel(operationId);

        // wait 2 days
        vm.warp(block.timestamp + 2 days);

        // should be unable to execute cancelled tx
        vm.prank(owner);
        vm.expectRevert("TimelockController: operation is not ready");
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // schedule again and wait
        vm.prank(owner);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );
        vm.warp(block.timestamp + 2 days);

        // account with admin but not exec should not be able to execute
        vm.prank(admin);
        vm.expectRevert("AccessControl: account 0xcf03dd0a894ef79cb5b601a43c4b25e3ae4c67ed is missing role 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63");
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // exec account should be able to execute tx
        vm.prank(owner);
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            data,                     // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );

        // admin account should now have admin permissions on EtherfiNodesManager
        assertEq(managerInstance.admins(admin), true);

        // queue and execute a tx to undo that change
        bytes memory undoData = hex"670a6fd9000000000000000000000000cf03dd0a894ef79cb5b601a43c4b25e3ae4c67ed0000000000000000000000000000000000000000000000000000000000000000";
        vm.prank(admin);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );
        assertEq(managerInstance.admins(admin), false);

        // non-proposer should not be able to schedule tx
        address rando = vm.addr(0x987654321);
        vm.prank(rando);
        vm.expectRevert("AccessControl: account 0xda5b629bd4e25a31b51a5bb22c55a39ec7efd68c is missing role 0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1");
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );


        console2.log("roleadmin:");
        console2.logBytes32( tl.getRoleAdmin(keccak256("PROPOSER_ROLE")));

        // should be able to give proposer role to new address. Now previous tx should work
        // I use different salt because we already previously scheduled a tx with this data and salt 0
        vm.prank(address(tl));
        tl.grantRole(keccak256("PROPOSER_ROLE"), rando);

        vm.prank(rando);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            undoData,                 // encoded call data
            0,                        // optional predecessor
            bytes32(uint256(1)),       // optional salt
            2 days                    // time before operation can be run
        );

        // Timelock should be able to give control back to a normal account
        address newOwner = 0xF155a2632Ef263a6A382028B3B33feb29175b8A5;
        bytes memory transferOwershipData = hex"f2fde38b000000000000000000000000f155a2632ef263a6a382028b3b33feb29175b8a5";
        vm.prank(admin);
        tl.schedule(
            address(managerInstance), // target
            0,                        // value
            transferOwershipData,     // encoded call data
            0,                        // optional predecessor
            0,                        // optional salt
            2 days                    // time before operation can be run
        );
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        tl.execute(
            address(managerInstance), // target
            0,                        // value
            transferOwershipData,                 // encoded call data
            0,                        // optional predecessor
            0                         // optional salt
        );
        assertEq(managerInstance.owner(), newOwner);
    }

    function test_generate_EtherFiOracle_updateAdmin() public {
        emit TimelockTransaction(address(etherFiOracleInstance), 0, abi.encodeWithSelector(bytes4(keccak256("updateAdmin(address,bool)")), 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC, true), bytes32(0), bytes32(0), 259200);
    }

    function test_updateDepositCap() public {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(liquifierInstance);
        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x83998e169026136760bE6AF93e776C2F352D4b28, 2_000, 5_000);
            _execute(target, data, true);
        }
        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 2_000, 5_000);
            _execute(target, data, true);
        }
        {
            // LINEA
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf, 2_000, 5_000);
            _execute(target, data, false);
        }
        {
            // BASE
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46, 2_000, 5_000);
            _execute(target, data, false);
        }

        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x83998e169026136760bE6AF93e776C2F352D4b28, 2_000, 10_000);
            _execute(target, data, false);
        }
        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 2_000, 10_000);
            _execute(target, data, false);
        }
        {
            // LINEA
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf, 2_000, 10_000);
            _execute(target, data, false);
        }
        {
            // BASE
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46, 2_000, 10_000);
            _execute(target, data, false);
        }
    }

    function _selector(bytes memory signature) internal pure returns (bytes4) {
        return bytes4(keccak256(signature));
    }

    function _execute(address target, bytes memory data, bool _alreadyScheduled) internal {
        vm.startPrank(0xcdd57D11476c22d265722F68390b036f3DA48c21);
        if (!_alreadyScheduled) {
            etherFiTimelockInstance.schedule(target, 0, data, bytes32(0), bytes32(0), etherFiTimelockInstance.getMinDelay());

            // _build_gnosis_schedule_txn(target, data, bytes32(0), bytes32(0), etherFiTimelockInstance.getMinDelay());
        }

        vm.warp(block.timestamp + etherFiTimelockInstance.getMinDelay());

        etherFiTimelockInstance.execute(target, 0, data, bytes32(0), bytes32(0));
        vm.stopPrank();
    }

    function _build_gnosis_schedule_txn(address target, bytes memory data, bytes32 predecessor, bytes32 salt, uint256 delay) internal {
        // {"to":"0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761","value":"0","data":null,"contractMethod":{"inputs":[{"internalType":"address","name":"target","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"},{"internalType":"bytes","name":"data","type":"bytes"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"},{"internalType":"uint256","name":"delay","type":"uint256"}],"name":"schedule","payable":false},"contractInputsValues":{"target":"0x9FFDF407cDe9a93c47611799DA23924Af3EF764F","value":"0","data":"0x3beb551700000000000000000000000061ff310ac15a517a846da08ac9f9abf2a0f9a2bf00000000000000000000000000000000000000000000000000000000000007d00000000000000000000000000000000000000000000000000000000000001388","predecessor":"0x0","salt":"0x0","delay":"259200"}}
        string memory operation = "";
        string memory obj = "";
        // string memory txn = "{"to":"0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761","value":"0","data":null,
        // "contractMethod":{"inputs":[{"internalType":"address","name":"target","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"},{"internalType":"bytes","name":"data","type":"bytes"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"},{"internalType":"uint256","name":"delay","type":"uint256"}],"name":"schedule","payable":false},
        // "contractInputsValues":{"target":"0x9FFDF407cDe9a93c47611799DA23924Af3EF764F","value":"0","data":"0x3beb551700000000000000000000000061ff310ac15a517a846da08ac9f9abf2a0f9a2bf00000000000000000000000000000000000000000000000000000000000007d00000000000000000000000000000000000000000000000000000000000001388","predecessor":"0x0","salt":"0x0","delay":"259200"}";
        
        operation = stdJson.serialize(operation, "target", target);
        operation = stdJson.serialize(operation, "value", uint256(0));
        operation = stdJson.serialize(operation, "data", data);
        operation = stdJson.serialize(operation, "predecessor", predecessor);
        operation = stdJson.serialize(operation, "salt", salt);
        operation = stdJson.serialize(operation, "delay", delay);
        
        obj = stdJson.serialize(obj, "to", address(etherFiTimelockInstance));
        obj = stdJson.serialize(obj, "value", uint256(0));
        obj = stdJson.serialize(obj, "data", abi.encode());
        obj = stdJson.serialize(obj, "contractMethod", string(' {"inputs":[{"internalType":"address","name":"target","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"},{"internalType":"bytes","name":"data","type":"bytes"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"},{"internalType":"uint256","name":"delay","type":"uint256"}],"name":"schedule","payable":false} '));
        obj = stdJson.serialize(obj, "contractInputsValues", operation);
        // emit TimelockTransaction(target, 0, data, predecessor, salt, delay);

        stdJson.write(obj, string("./out/example.json"));
    }
}

// {"version":"1.0","chainId":"1","createdAt":1713949623894,"meta":{"name":"Transactions Batch","description":"","txBuilderVersion":"1.16.5","createdFromSafeAddress":"0xcdd57D11476c22d265722F68390b036f3DA48c21","createdFromOwnerAddress":"","checksum":"0x37b66d67757452f835ebc6540e283e27544d1414409577963593e7e535ce3ad9"},
// "transactions":[
// {"to":"0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761","value":"0","data":null,"contractMethod":{"inputs":[{"internalType":"address","name":"target","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"},{"internalType":"bytes","name":"data","type":"bytes"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"},{"internalType":"uint256","name":"delay","type":"uint256"}],"name":"schedule","payable":false},"contractInputsValues":{"target":"0x9FFDF407cDe9a93c47611799DA23924Af3EF764F","value":"0","data":"0x3beb551700000000000000000000000061ff310ac15a517a846da08ac9f9abf2a0f9a2bf00000000000000000000000000000000000000000000000000000000000007d00000000000000000000000000000000000000000000000000000000000001388","predecessor":"0x0","salt":"0x0","delay":"259200"}}
// ]
// }
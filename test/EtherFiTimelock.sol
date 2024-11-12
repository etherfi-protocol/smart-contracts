// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiTimelock.sol";
import "forge-std/console2.sol";

contract TimelockTest is TestSetup {


    function test_generate_EtherFiOracle_updateAdmin() public {
        emit Schedule(address(etherFiOracleInstance), 0, abi.encodeWithSelector(bytes4(keccak256("updateAdmin(address,bool)")), 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC, true), bytes32(0), bytes32(0), 259200);
    }

    function test_registerToken() internal {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(liquifierInstance);

        {
            // MODE
            bytes memory data = abi.encodeWithSelector(Liquifier.registerToken.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, address(0), true, 0, 2_000, 10_000, true);
            _execute_timelock(target, data, false, false, true, true);
        }
        {
            // LINEA
            bytes memory data = abi.encodeWithSelector(Liquifier.registerToken.selector, 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf, address(0), true, 0, 2_000, 10_000, true);
            _execute_timelock(target, data, false, false, true, true);
        }
    }

    function test_updateDepositCap() internal {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(liquifierInstance);
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x83998e169026136760bE6AF93e776C2F352D4b28, 4_000, 20_000);
        //     _execute_timelock(target, data, false, false, true, true);
        // }
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 4_000, 20_000);
        //     _execute_timelock(target, data, false, false, true, true);
        // }
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46, 1_000, 100_000);
        //     _execute_timelock(target, data, true, true, true, false);
        // }
        // {
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 1_000, 100_000);
        //     _execute_timelock(target, data, true, true, true, false);
        // }

        // {
        //     // LINEA
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf, 2_000, 10_000);
        //     _execute_timelock(target, data, false);
        // }
        // {
        //     // BASE
        //     bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46, 2_000, 10_000);
        //     _execute_timelock(target, data, false);
        // }
    }
}

// {"version":"1.0","chainId":"1

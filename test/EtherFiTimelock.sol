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

    function test_upgrade_for_pepe() internal {
        initializeRealisticFork(MAINNET_FORK);
        {
            address target = address(managerInstance);
            bytes memory data = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x20f2A7a3C941e13083b36f2b765213dec9EE9073);
            _execute_timelock(target, data, true, true, true, true);
        }

        {
            address target = address(stakingManagerInstance);
            bytes memory data = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, 0x942CEddafE32395608F99DEa7b6ea8801A8F4748);
            _execute_timelock(target, data, true, true, true, true);
        }
    }

    function test_EIGEN_transfer() internal {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(managerInstance);
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));

        bytes memory data = abi.encodeWithSelector(EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector, selector, 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83, true);
        _execute_timelock(target, data, true, true, true, true);
        
        address[] memory nodes = new address[](1);
        bytes[] memory datas = new bytes[](1);
        nodes[0] = 0xe8e39aA7E08F13f1Ccd5F38706F9e1D60C661825;
        datas[0] = abi.encodeWithSelector(selector, 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC, 1 ether);
        
        vm.prank(0x7835fB36A8143a014A2c381363cD1A4DeE586d2A);
        managerInstance.forwardExternalCall(nodes, datas, 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83);
    }
    
    function test_efip4() public {
        initializeRealisticFork(MAINNET_FORK);
        {
            address target = address(liquidityPoolInstance);
            bytes memory data = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0xa8A8Be862BA6301E5949ABDE93b1D892C14FfB1F);
            _execute_timelock(target, data, true, true, true, true);
        }
        {
            address target = address(liquidityPoolInstance);
            bytes memory data = abi.encodeWithSelector(LiquidityPool.setTreasury.selector, 0xf40bcc0845528873784F36e5C105E62a93ff7021);
            _execute_timelock(target, data, true, true, true, true);
        }

        {
            address target = address(etherFiOracleInstance);
            bytes memory data = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x99BE559FAdf311D2CEdeA6265F4d36dfa4377B70);
            _execute_timelock(target, data, true, true, true, true);
        }

        {
            address target = address(etherFiAdminInstance);
            bytes memory data = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x92c27bA54A62fcd41d3df9Fd2dC5C8dfacbd3C4C);
            _execute_timelock(target, data, true, true, true, true);
        }
    }

    function test_whitelist_RewardsCoordinator_processClaim() public {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(managerInstance);
        bytes4 selector = 0x3ccc861d;
        bytes memory data = abi.encodeWithSelector(EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector, selector, 0x7750d328b314EfFa365A0402CcfD489B80B0adda, true);
        _execute_timelock(target, data, true, true, true, true);
    }
    
    function test_update_treasury() public {
        initializeRealisticFork(MAINNET_FORK);
        {
            address target = address(liquidityPoolInstance);
            bytes memory data = abi.encodeWithSelector(LiquidityPool.setTreasury.selector, 0x0c83EAe1FE72c390A02E426572854931EefF93BA);
            _execute_timelock(target, data, true, true, true, true);
        }
    }

    function test_whitelist_DelegationManager() public {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(managerInstance);
        bytes4[] memory selectors = new bytes4[](4);

        // https://etherscan.io/address/0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A#writeProxyContract
        selectors[0] = 0xeea9064b; // delegateTo
        selectors[1] = 0x7f548071; // delegateToBySignature
        selectors[2] = 0xda8be864; // undelegate
        selectors[3] = 0x0dd8dd02; // queueWithdrawals

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes memory data = abi.encodeWithSelector(EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector, selectors[i], 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);
            _execute_timelock(target, data, true, true, true, true);
        }
    }

    function test_unpause_liquifier() public {
        initializeRealisticFork(MAINNET_FORK);
        if (liquifierInstance.paused()) {
            address target = address(liquifierInstance);
            bytes memory data = abi.encodeWithSelector(Liquifier.unPauseContract.selector);
            _execute_timelock(target, data, true, true, true, true);
        }
    }
}

// {"version":"1.0","chainId":"1

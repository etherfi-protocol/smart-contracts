// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiTimelock.sol";
import "forge-std/console2.sol";

contract TimelockTest is TestSetup {

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
        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x83998e169026136760bE6AF93e776C2F352D4b28, 4_000, 20_000);
            _execute_timelock(target, data, false, false, true, true);
        }
        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 4_000, 20_000);
            _execute_timelock(target, data, false, false, true, true);
        }
        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46, 1_000, 100_000);
            _execute_timelock(target, data, true, true, true, false);
        }
        {
            bytes memory data = abi.encodeWithSelector(Liquifier.updateDepositCap.selector, 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3, 1_000, 100_000);
            _execute_timelock(target, data, true, true, true, false);
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

    function test_add_updateEigenLayerOperatingAdmin() internal {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(managerInstance);
        bytes memory data = abi.encodeWithSelector(EtherFiNodesManager.updateEigenLayerOperatingAdmin.selector, 0x44358b1cc2C296fFc7419835438D1BD97Ec1FB78, true);
        _execute_timelock(target, data, true, true, true, true);
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
            bytes memory data = abi.encodeWithSelector(LiquidityPool.setFeeRecipient.selector, 0xf40bcc0845528873784F36e5C105E62a93ff7021);
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
            bytes memory data = abi.encodeWithSelector(LiquidityPool.setFeeRecipient.selector, 0x0c83EAe1FE72c390A02E426572854931EefF93BA);
            _execute_timelock(target, data, true, true, true, true);
        }
    }

    function test_upgrade_liquifier() public {
        initializeRealisticFork(MAINNET_FORK);
        address new_impl = 0xA1A15FB15cbda9E6c480C5bca6E9ABA9C5E2ff95;
        {   
            assertEq(new_impl, computeAddressByCreate2(address(create2factory), type(Liquifier).creationCode, keccak256("ETHER_FI")));
            address target = address(liquifierInstance);
            bytes memory data = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, new_impl);
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

        vm.startPrank(owner);
        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
        address delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
        uint256[] memory validatorIds = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        validatorIds[0] = 65536;
        data[0] = abi.encodeWithSelector(selectors[0], 0x67943aE8e07bFC9f5C9A90d608F7923D9C21e051, signatureWithExpiry, bytes32(0));
        managerInstance.forwardExternalCall(validatorIds, data, delegationManager);

        data[0] = abi.encodeWithSelector(selectors[2],  managerInstance.etherfiNodeAddress(validatorIds[0]));
        managerInstance.forwardExternalCall(validatorIds, data, delegationManager);

        vm.stopPrank();
    }

    function test_unpause_liquifier() public {
        initializeRealisticFork(MAINNET_FORK);
        address target = address(liquifierInstance);
        bytes memory data = abi.encodeWithSelector(Liquifier.unPauseContract.selector);
        _execute_timelock(target, data, true, true, true, true);
    }

        function test_update_committee_members() public {
        initializeRealisticFork(MAINNET_FORK);
        address etherfi_oracle1 = address(0x6d850af8e7AB3361CfF28b31C701647414b9C92b);
        address etherfi_oracle2 = address(0x1a9AC2a6fC85A7234f9E21697C75D06B2b350864);
        address avs_etherfi_oracle1 = address(0xDd777e5158Cb11DB71B4AF93C75A96eA11A2A615);
        address avs_etherfi_oracle2 = address(0x2c7cB7d5dC4aF9caEE654553a144C76F10D4b320);
        address target = address(etherFiOracleInstance);
        bytes memory data = abi.encodeWithSelector(EtherFiOracle.removeCommitteeMember.selector, etherfi_oracle1);
        _execute_timelock(target, data, true, true, true, true);
       data = abi.encodeWithSelector(EtherFiOracle.removeCommitteeMember.selector, etherfi_oracle2);
        _execute_timelock(target, data, true, true, true, true);
        data = abi.encodeWithSelector(EtherFiOracle.addCommitteeMember.selector, avs_etherfi_oracle1);
        _execute_timelock(target, data, true, true, true, true);
        data = abi.encodeWithSelector(EtherFiOracle.addCommitteeMember.selector, avs_etherfi_oracle2);
        _execute_timelock(target, data, true, true, true, true);

    }

    function test_accept_ownership_role_registry() public {
        initializeRealisticFork(MAINNET_FORK);
        roleRegistryInstance = RoleRegistry(address(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9));
        address target = address(roleRegistryInstance);
        bytes memory data = abi.encodeWithSelector(Ownable2StepUpgradeable.acceptOwnership.selector);
        _execute_timelock(target, data, true, true, true, true);
    }

    function test_v2_dot_49() public {
        shouldSetupRoleRegistry = false;
        //upgrade contracts
        initializeRealisticFork(MAINNET_FORK);
        address[] memory _targets = new address[](15);
        bytes[] memory _data = new bytes[](15);
        uint256[] memory _values = new uint256[](15);
        address timelockAddress = address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761);
        address operatingTimelockAddress = address(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a);
        address treasuryAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);
        address etherFiRedemptionManagerAddress = address(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0);
        vm.startPrank(timelockAddress);
        roleRegistryInstance = RoleRegistry(address(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9));
        roleRegistryInstance.acceptOwnership();
        roleRegistryInstance.onlyProtocolUpgrader(timelockAddress);
        vm.stopPrank();
        uint256 balOldTreasury = weEthInstance.balanceOf(address(treasuryInstance));
        

        _targets[0] = address(managerInstance);
        _targets[1] = address(etherFiAdminInstance);
        _targets[2] = address(etherFiRewardsRouterInstance);
        _targets[3] = address(liquidityPoolInstance);
        _targets[4] = address(weEthInstance);
        _targets[5] = address(withdrawRequestNFTInstance);
        _targets[6] = address(etherFiAdminInstance);
        _targets[7] = address(liquidityPoolInstance);
        _targets[8] = address(withdrawRequestNFTInstance);
        _targets[9] = address(weEthInstance);
        _targets[10] = address(weEthInstance);
        _targets[11] = address(addressProviderInstance);
        _targets[12] = address(addressProviderInstance);
        _targets[13] = address(addressProviderInstance);
        _targets[14] = address(addressProviderInstance);

        //upgrade contracts
        _data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x572E25fD70b6eB9a3CaD1CE1D48E3CfB938767F1);
        _data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x683583979C8be7Bcfa41E788Ab38857dfF792f49);
        _data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0xe94bF0DF71002ff0165CF4daB461dEBC3978B0fa);
        _data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0xA6099d83A67a2c653feB5e4e48ec24C5aeE1C515);
        _data[4] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x353E98F34b6E5a8D9d1876Bf6dF01284d05837cB);
        _data[5] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x685870a508b56c7f1002EEF5eFCFa01304474F61);

        //initialize contracts
        _data[6] = abi.encodeWithSelector(EtherFiAdmin.initializeRoleRegistry.selector, address(roleRegistryInstance));
        _data[7] = abi.encodeWithSelector(LiquidityPool.initializeVTwoDotFourNine.selector, address(roleRegistryInstance), etherFiRedemptionManagerAddress);
        _data[8] = abi.encodeWithSelector(WithdrawRequestNFT.initializeOnUpgrade.selector, address(roleRegistryInstance), 10000);
        _data[9] = abi.encodeWithSelector(weEthInstance.rescueTreasuryWeeth.selector);
        _data[10] = abi.encodeWithSelector(weEthInstance.transfer.selector, treasuryAddress, balOldTreasury);

        //add to addressProvider
        _data[11] = abi.encodeWithSelector(AddressProvider.addContract.selector, etherFiRedemptionManagerAddress, "EtherFiRedemptionManager");
        _data[12] = abi.encodeWithSelector(AddressProvider.addContract.selector, address(etherFiRewardsRouterInstance), "EtherFiRewardsRouter");
        _data[13] = abi.encodeWithSelector(AddressProvider.addContract.selector, operatingTimelockAddress, "OperatingTimelock");
        _data[14] = abi.encodeWithSelector(AddressProvider.addContract.selector, address(roleRegistryInstance), "RoleRegistry");


        _batch_execute_timelock(_targets, _data, _values, true, true, true, true);
    }

    function test_handle_remainder() public {
        initializeRealisticFork(MAINNET_FORK);
        etherFiTimelockInstance = EtherFiTimelock(payable(address(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a)));
        address target = address(withdrawRequestNFTInstance);
        uint256 remainder = withdrawRequestNFTInstance.getEEthRemainderAmount();

            // Write remainder to a file
        string memory remainderStr = vm.toString(remainder);
        vm.writeFile("./release/logs/txns/remainder.txt", remainderStr);

        bytes memory data = abi.encodeWithSelector(WithdrawRequestNFT.handleRemainder.selector, remainder);
        _execute_timelock(target, data, true, true, true, true);
    }
}

// {"version":"1.0","chainId":"1

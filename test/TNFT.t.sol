// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract TnftTest is TestSetup {

    function setUp() public {
        setUpTests();

        assertEq(TNFTInstance.stakingManagerAddress(), address(stakingManagerInstance));
    }

    function test_DisableInitializer() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        BNFTImplementation.initialize(address(stakingManagerInstance));
    }

    function test_TNFTMintsFailsIfNotCorrectCaller() public {
        vm.startPrank(alice);
        vm.expectRevert("Only staking manager contract");
        TNFTInstance.mint(address(alice), 1);
    }
}

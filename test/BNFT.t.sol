// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract BNFTTest is TestSetup {
   function setUp() public {
        setUpTests();
    }

    function test_DisableInitializer() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        BNFTImplementation.initialize(address(stakingManagerInstance));
    }

    function test_Mint() public {
        depositAndRegisterValidator(false);

        assertEq(BNFTInstance.ownerOf(1), alice);
        assertEq(BNFTInstance.balanceOf(alice), 1);
    }

    function test_BNFTMintsFailsIfNotCorrectCaller() public {
        vm.startPrank(alice);
        vm.expectRevert("Only staking manager contract");
        BNFTInstance.mint(address(alice), 1);
    }

    function test_BNFTCannotBeTransferred() public {
        test_Mint();
        
        address tokenOwner = BNFTInstance.ownerOf(1);
        vm.prank(tokenOwner);
        vm.expectRevert("Err: token is SOUL BOUND");
        BNFTInstance.transferFrom(
            tokenOwner,
            address(alice),
            1
        );
    }
}

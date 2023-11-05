// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract RegulationsManagerTest is TestSetup {

    function setUp() public {
        setUpTests();
    }

    function test_ConfirmEligibilityWorks() public {
        vm.startPrank(alice);
        regulationsManagerInstance.pauseContract();
        vm.expectRevert("Pausable: paused");
        regulationsManagerInstance.confirmEligibility(termsAndConditionsHash);
        regulationsManagerInstance.unPauseContract();
        vm.stopPrank();

        assertEq(regulationsManagerInstance.isEligible(1, alice), false);
        
        vm.prank(alice);
        regulationsManagerInstance.confirmEligibility(termsAndConditionsHash);

        assertEq(regulationsManagerInstance.isEligible(1, alice), true);
    }

    function test_RemoveFromWhitelistWorks() public {
        vm.prank(alice);
        vm.expectRevert("Incorrect Caller");
        regulationsManagerInstance.removeFromWhitelist(bob);

        vm.prank(alice);
        vm.expectRevert("User may be in a regulated country");
        regulationsManagerInstance.removeFromWhitelist(alice);

        vm.startPrank(alice);
        regulationsManagerInstance.pauseContract();
        vm.expectRevert("Pausable: paused");
        regulationsManagerInstance.removeFromWhitelist(alice);
        regulationsManagerInstance.unPauseContract();
        vm.stopPrank();

        vm.prank(alice);
        regulationsManagerInstance.confirmEligibility(termsAndConditionsHash);


        assertEq(regulationsManagerInstance.isEligible(1, alice), true);

        vm.prank(alice);
        regulationsManagerInstance.removeFromWhitelist(alice);

        assertEq(regulationsManagerInstance.isEligible(1, alice), false);

        vm.prank(bob);
        regulationsManagerInstance.confirmEligibility(termsAndConditionsHash);

        assertEq(regulationsManagerInstance.isEligible(1, bob), true);

        vm.prank(bob);
        regulationsManagerInstance.removeFromWhitelist(bob);

        assertEq(regulationsManagerInstance.isEligible(1, bob), false);
    }

    function test_initializeNewWhitelistWorks() public {
        vm.startPrank(owner);
        vm.expectRevert("Caller is not the admin");
        regulationsManagerInstance.initializeNewWhitelist(termsAndConditionsHash);

        assertEq(regulationsManagerInstance.whitelistVersion(), 1);
        vm.stopPrank();

        vm.prank(alice);
        regulationsManagerInstance.confirmEligibility(termsAndConditionsHash);

        assertEq(regulationsManagerInstance.isEligible(regulationsManagerInstance.whitelistVersion(), alice), true);

        vm.prank(alice);
        regulationsManagerInstance.initializeNewWhitelist("USA, CANADA, FRANCE");

        assertEq(regulationsManagerInstance.whitelistVersion(), 2);
        assertEq(regulationsManagerInstance.isEligible(regulationsManagerInstance.whitelistVersion(), alice), false);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract TreasuryTest is TestSetup {

    function setUp() public {
        setUpTests();
    }

    function test_TreasuryCanReceiveFunds() public {
        assertEq(address(treasuryInstance).balance, 0);
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        (bool sent, ) = address(treasuryInstance).call{value: 0.5 ether}("");
        require(sent, "Failed to send Ether");

        assertEq(address(treasuryInstance).balance, 0.5 ether);
    }

    function test_WithdrawFailsIfNotOwner() public {
        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        (bool sent, ) = address(treasuryInstance).call{value: 0.5 ether}("");
        require(sent, "Failed to send Ether");

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        treasuryInstance.withdraw(0, alice);
    }

    function test_WithdrawWorks() public {
        assertEq(address(treasuryInstance).balance, 0);
        uint256 ownerBalanceBeforeWithdrawal = address(owner).balance;

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        (bool sent, ) = address(treasuryInstance).call{value: 0.5 ether}("");
        require(sent, "Failed to send Ether");
        assertEq(address(treasuryInstance).balance, 0.5 ether);
        vm.prank(owner);
        vm.expectRevert("the balance is lower than the requested amount");
        treasuryInstance.withdraw(0.5 ether + 1, owner);

        vm.prank(owner);
        treasuryInstance.withdraw(0.5 ether, owner);

        assertEq(address(owner).balance, ownerBalanceBeforeWithdrawal + 0.5 ether);

        assertEq(address(treasuryInstance).balance, 0);
    }

    function test_WithdrawPartialWorks() public {
        assertEq(address(treasuryInstance).balance, 0);
        uint256 ownerBalanceBeforeWithdrawal = address(owner).balance;

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        (bool sent, ) = address(treasuryInstance).call{value: 5 ether}("");
        require(sent, "Failed to send Ether");

        assertEq(address(treasuryInstance).balance, 5 ether);

        vm.prank(owner);
        treasuryInstance.withdraw(0.5 ether, owner);

        assertEq(address(owner).balance, ownerBalanceBeforeWithdrawal + 0.5 ether);
        assertEq(address(treasuryInstance).balance, 4.5 ether);
    }
}

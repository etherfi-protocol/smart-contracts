// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract WeETHTest is TestSetup {
    function setUp() public {
        setUpTests();
    }

    function test_UpdatedName() public {
        assertEq(weEthInstance.name(), "Wrapped eETH");
    }

    function test_WrapEETHFailsIfZeroAmount() public {
        vm.expectRevert("weETH: can't wrap zero eETH");
        weEthInstance.wrap(0);
    }

    function test_WrapWorksCorrectly() public {
        // Total pooled ether = 10
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(alice), 0 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);

        // Total pooled ether = 20
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 20 ether);
        assertEq(eETHInstance.balanceOf(alice), 10 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);

        startHoax(alice);

        //Approve the wrapped eth contract to spend 100 eEth
        eETHInstance.approve(address(weEthInstance), 100 ether);
        weEthInstance.wrap(5 ether);
        vm.stopPrank();

        assertEq(weEthInstance.balanceOf(alice), 5 ether);
        assertEq(eETHInstance.balanceOf(alice), 5 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);
    }

    function test_WrapWithPermitFailsWhenExceedingAllowance() public {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(alice), 10 ether);

        startHoax(alice);

        uint256 aliceNonce = eETHInstance.nonces(alice);
        // alice priv key = 2
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(weEthInstance), 2 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());

        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");
        weEthInstance.wrapWithPermit(5 ether, permitInput);

    }

    function test_WrapWithPermitFailsWithInvalidSignature() public {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(alice), 10 ether);

        startHoax(alice);

        uint256 aliceNonce = eETHInstance.nonces(alice);
        // 69 is an invalid private key for alice
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(69, address(weEthInstance), 5 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());

        vm.expectRevert("ERC20Permit: invalid signature");
        weEthInstance.wrapWithPermit(5 ether, permitInput);
    }

    function test_WrapWithPermitWorksCorrectly() public {
        // Total pooled ether = 10
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(alice), 0 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);

        // Total pooled ether = 20
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 20 ether);
        assertEq(eETHInstance.balanceOf(alice), 10 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);

        startHoax(alice);

        uint256 aliceNonce = eETHInstance.nonces(alice);
        // alice priv key = 2
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(weEthInstance), 5 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
        weEthInstance.wrapWithPermit(5 ether, permitInput);

        assertEq(weEthInstance.balanceOf(alice), 5 ether);
        assertEq(eETHInstance.balanceOf(alice), 5 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);
    }

    function test_UnWrapEETHFailsIfZeroAmount() public {
        vm.expectRevert("Cannot unwrap a zero amount");
        weEthInstance.unwrap(0);
    }

    function test_UnWrapWorksCorrectly() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        // Total pooled ether = 10
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.totalSupply(), 10 ether);

        // Total pooled ether = 20
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 20 ether);
        assertEq(eETHInstance.totalSupply(), 20 ether);

        assertEq(weEthInstance.balanceOf(alice), 0 ether);
        assertEq(eETHInstance.balanceOf(alice), 10 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);

        vm.startPrank(alice);

        //Approve the wrapped eth contract to spend 100 eEth
        eETHInstance.approve(address(weEthInstance), 100 ether);
        weEthInstance.wrap(2.5 ether);

        assertEq(weEthInstance.balanceOf(alice), 2.5 ether);
        assertEq(eETHInstance.balanceOf(alice), 7.5 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);

        weEthInstance.unwrap(2.5 ether);

        assertEq(weEthInstance.balanceOf(alice), 0 ether);
        assertEq(eETHInstance.balanceOf(alice), 10 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);

        vm.stopPrank();
    }

    function test_MultipleDepositsAndFunctionalityWorksCorrectly() public {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.totalSupply(), 10 ether);

        assertEq(eETHInstance.shares(alice), 10 ether);
        assertEq(eETHInstance.totalShares(), 10 ether);

        //----------------------------------------------------------------------------------------------------------

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 5 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 15 ether);
        assertEq(eETHInstance.totalSupply(), 15 ether);

        assertEq(eETHInstance.shares(bob), 5 ether);
        assertEq(eETHInstance.shares(alice), 10 ether);
        assertEq(eETHInstance.totalShares(), 15 ether);

        //----------------------------------------------------------------------------------------------------------

        startHoax(greg);
        liquidityPoolInstance.deposit{value: 35 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 50 ether);
        assertEq(eETHInstance.totalSupply(), 50 ether);

        assertEq(eETHInstance.shares(greg), 35 ether);
        assertEq(eETHInstance.shares(bob), 5 ether);
        assertEq(eETHInstance.shares(alice), 10 ether);
        assertEq(eETHInstance.totalShares(), 50 ether);

        //----------------------------------------------------------------------------------------------------------

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether);

        _transferTo(address(liquidityPoolInstance), 10 ether);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);
        assertEq(eETHInstance.balanceOf(greg), 42 ether);

        //----------------------------------------------------------------------------------------------------------

        startHoax(alice);
        eETHInstance.approve(address(weEthInstance), 500 ether);
        weEthInstance.wrap(10 ether);
        assertEq(eETHInstance.shares(alice), 1.666666666666666667 ether);
        assertEq(eETHInstance.shares(address(weEthInstance)), 8.333333333333333333 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);

        //Not sure what happens to the 0.000000000000000001 ether
        assertEq(eETHInstance.balanceOf(address(weEthInstance)), 9.999999999999999999 ether);
        assertEq(weEthInstance.balanceOf(alice), 8.333333333333333333 ether);
        vm.stopPrank();

        //----------------------------------------------------------------------------------------------------------

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(50 ether);

        _transferTo(address(liquidityPoolInstance), 50 ether);   
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 110 ether);
        assertEq(eETHInstance.balanceOf(alice), 3.666666666666666667 ether);

        //----------------------------------------------------------------------------------------------------------

        startHoax(alice);
        weEthInstance.unwrap(6 ether);
        assertEq(eETHInstance.balanceOf(alice), 16.866666666666666667 ether);
        assertEq(eETHInstance.shares(alice), 7.666666666666666667 ether);
        assertEq(eETHInstance.balanceOf(address(weEthInstance)), 5.133333333333333332 ether);
        assertEq(eETHInstance.shares(address(weEthInstance)), 2.333333333333333333 ether);
        assertEq(weEthInstance.balanceOf(alice), 2.333333333333333333 ether);
    }

    function test_UnwrappingWithRewards() public {
        // Alice deposits into LP
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        vm.stopPrank();

        assertEq(weEthInstance.getRate(), 1 ether);

        // Bob deposits into LP
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 1 ether}();
        assertEq(eETHInstance.balanceOf(bob), 1 ether);
        vm.stopPrank();

        //Bob chooses to wrap his eETH into weETH
        vm.startPrank(bob);
        eETHInstance.approve(address(weEthInstance), 1 ether);
        weEthInstance.wrap(1 ether);
        assertEq(eETHInstance.balanceOf(bob), 0 ether);
        assertEq(weEthInstance.balanceOf(bob), 1 ether);
        vm.stopPrank();

        // Rewards enter LP
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(1 ether);
        _transferTo(address(liquidityPoolInstance), 1 ether);
        assertEq(address(liquidityPoolInstance).balance, 4 ether);

        assertEq(weEthInstance.getRate(), 1.333333333333333333 ether);

        // Alice now has 2.666666666666666666 ether
        // Bob should still have 1 ether weETH because it doesn't rebase
        assertEq(eETHInstance.balanceOf(alice), 2.666666666666666666 ether);
        assertEq(weEthInstance.balanceOf(bob), 1 ether);

        // Bob unwraps his weETH and should get his principal + rewards
        // Bob should get 1.333333333333333333 ether
        vm.startPrank(bob);
        weEthInstance.unwrap(1 ether);
        assertEq(eETHInstance.balanceOf(bob), 1.333333333333333332 ether);
    }
    function test_rescueTreasuryWeeth() public {
        uint256 treasuryBal = 31859761318927469119;
        address treasuryInstance = 0x6329004E903B7F420245E7aF3f355186f2432466;
        vm.deal(treasuryInstance, treasuryBal);
        vm.startPrank(treasuryInstance);
        liquidityPoolInstance.deposit{value: treasuryBal}();
        eETHInstance.approve(address(weEthInstance), treasuryBal);
        weEthInstance.wrap(treasuryBal);
        vm.stopPrank();
        uint256 preTreasuryBal = weEthInstance.balanceOf(treasuryInstance);
        uint256 preOwnerBal = weEthInstance.balanceOf(owner);
        vm.startPrank(alice);
        vm.expectRevert();
        weEthInstance.rescueTreasuryWeeth();
        vm.stopPrank();
        vm.startPrank(owner);
        weEthInstance.rescueTreasuryWeeth();
        vm.stopPrank();
        assertEq(weEthInstance.balanceOf(address(treasuryInstance)), 0);
        assertEq(weEthInstance.balanceOf(owner), preTreasuryBal + preOwnerBal);
        vm.stopPrank(); 
    }

    function test_PermitWhitelistWeETH() public {
        // allocationg weETH to alice
        test_WrapWorksCorrectly();

        // alice approves bob to spend 1 ether of weETH
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                weEthInstance.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    alice,
                    address(bob),
                    1 ether,
                    weEthInstance.nonces(alice),
                    block.timestamp
                ))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(2, permitHash);

        vm.expectRevert("weETH: spender not whitelisted");
        weEthInstance.permit(alice, bob, 1 ether, block.timestamp, v, r, s);

        address[] memory whitelist = new address[](1);
        whitelist[0] = bob;
        vm.prank(owner);
        weEthInstance.setWhitelistedSpender(whitelist, true);

        weEthInstance.permit(alice, bob, 1 ether, block.timestamp, v, r, s);
        vm.prank(bob);
        weEthInstance.transferFrom(alice, bob, 1 ether);
    }

    function test_TransferBlacklistWeETH() public {
        // allocationg weETH to alice
        test_WrapWorksCorrectly();
        
        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);

        vm.prank(owner);
        address[] memory blacklist = new address[](1);
        blacklist[0] = bob;
        weEthInstance.setBlacklistedRecipient(blacklist, true);

        vm.prank(alice);
        vm.expectRevert("weETH: blacklisted address");
        weEthInstance.transfer(bob, 1 ether);

        vm.prank(bob);
        vm.expectRevert("weETH: blacklisted address");
        weEthInstance.transfer(alice, 1 ether);
    }
}

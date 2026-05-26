// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@tests/TestERC20.sol";
import "@tests/TestERC721.sol";
import {ForceETHSender} from "@tests/EETH.t.sol";
import "@etherfi/governance/Blacklister.sol";
import "@etherfi/governance/utils/PausableUntil.sol";

contract WeETHTest is TestSetup {
    function setUp() public {
        setUpTests();
    }

    function test_UpdatedName() public {
        assertEq(weEthInstance.name(), "Wrapped eETH");
    }

    function test_WrapEETHFailsIfZeroAmount() public {
        vm.expectRevert(WeETH.ZeroAmount.selector);
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

        vm.expectRevert(EETH.TransferAmountExceedsAllowance.selector);
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

        vm.expectRevert(EETH.TransferAmountExceedsAllowance.selector);
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
        vm.expectRevert(WeETH.ZeroAmount.selector);
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
    
    function test_WrapWithPermitGriefingAttack() public {
        // alice sends a `wrapWithPermit` transaction to mempool with the following inputs
        uint256 aliceNonce = eETHInstance.nonces(alice);
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(weEthInstance), 5 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());

        // bob sees alice's `wrapWithPermit` in the mempool and frontruns her transaction with copied inputs 
        vm.prank(bob);
        eETHInstance.permit(alice, address(weEthInstance), 5 ether, 2**256 - 1, permitInput.v, permitInput.r, permitInput.s);

        startHoax(alice);
        // alices transaction still succeeds as the try catch swallows the error
        weEthInstance.wrapWithPermit(5 ether, permitInput);
    }
    
    function test_RecoverETH() public {
        uint256 amountToSend = 2 ether;
        // We cannot send ETH directly to eETH contract because it has no fallback/retrieve method
        ForceETHSender sender = new ForceETHSender();
        vm.deal(address(sender), amountToSend);
        sender.forceSend(payable(address(weEthInstance)));
        
        // Check that eETH contract now has ETH
        assertEq(address(weEthInstance).balance, amountToSend);
        
        // Try to recover ETH without proper role - should fail
        vm.expectRevert();
        vm.prank(bob);
        weEthInstance.recoverETH(payable(bob), amountToSend);
        
        // Check alice's balance before recovery
        uint256 aliceBalanceBefore = alice.balance;
        
        // Recover ETH as admin
        vm.prank(admin);
        weEthInstance.recoverETH(payable(alice), amountToSend);
        
        // Verify ETH was recovered
        assertEq(address(weEthInstance).balance, 0);
        assertEq(alice.balance, aliceBalanceBefore + amountToSend);
    }
    
    function test_RecoverERC20() public {
        // Create a mock ERC20 token
        TestERC20 mockToken = new TestERC20("Test Token", "TEST");
        uint256 amountToSend = 1000e18;
        
        // Mint tokens to alice and send to eETH contract
        mockToken.mint(alice, amountToSend);
        vm.prank(alice);
        mockToken.transfer(address(weEthInstance), amountToSend);
        
        assertEq(mockToken.balanceOf(address(weEthInstance)), amountToSend);
            
        // Try to recover tokens without proper role - should fail
        vm.expectRevert();
        vm.prank(bob);
        weEthInstance.recoverERC20(address(mockToken), alice, amountToSend);
        
        // Recover tokens as admin (who has the role)
        vm.prank(admin);
        weEthInstance.recoverERC20(address(mockToken), alice, amountToSend);
        
        // Verify tokens were recovered
        assertEq(mockToken.balanceOf(address(weEthInstance)), 0);
        assertEq(mockToken.balanceOf(alice), amountToSend);
    }

    function test_RecoverERC721() public {
        // Create a mock ERC721 token
        TestERC721 mockNFT = new TestERC721("Test NFT", "TNFT");
        
        // Mint NFT to alice and send to eETH contract
        uint256 tokenId = mockNFT.mint(alice);
        vm.prank(alice);
        mockNFT.transferFrom(alice, address(weEthInstance), tokenId);
        
        assertEq(mockNFT.ownerOf(tokenId), address(weEthInstance));
        
        // Try to recover NFT without proper role - should fail
        vm.expectRevert();
        vm.prank(bob);
        weEthInstance.recoverERC721(address(mockNFT), alice, tokenId);
        
        // Recover NFT as admin
        vm.prank(admin);
        weEthInstance.recoverERC721(address(mockNFT), alice, tokenId);
        
        // Verify NFT was recovered
        assertEq(mockNFT.ownerOf(tokenId), alice);
    }

    function test_RecoverETH_ErrorConditions() public {
        uint256 amountToSend = 2 ether;
        // Force ETH into the contract
        ForceETHSender sender = new ForceETHSender();
        vm.deal(address(sender), amountToSend);
        sender.forceSend(payable(address(weEthInstance)));
        
        // Test 1: Try to recover 0 ETH - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        weEthInstance.recoverETH(payable(alice), 0);
        
        // Test 2: Try to recover more ETH than exists - should revert with InsufficientBalance
        vm.expectRevert(AssetRecovery.InsufficientBalance.selector);
        vm.prank(admin);
        weEthInstance.recoverETH(payable(alice), amountToSend + 1);
        
        // Test 3: Try to send to zero address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        weEthInstance.recoverETH(payable(address(0)), amountToSend);
    }

    function test_RecoverERC20_ErrorConditions() public {
        TestERC20 mockToken = new TestERC20("Test Token", "TEST");
        uint256 amountToSend = 1000e18;
        
        // Send tokens to eETH contract
        mockToken.mint(alice, amountToSend);
        vm.prank(alice);
        mockToken.transfer(address(weEthInstance), amountToSend);
        
        // Test 1: Try to recover 0 tokens - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        weEthInstance.recoverERC20(address(mockToken), alice, 0);
        
        // Test 2: Try to recover more tokens than exists - should revert with InsufficientBalance
        vm.expectRevert(AssetRecovery.InsufficientBalance.selector);
        vm.prank(admin);
        weEthInstance.recoverERC20(address(mockToken), alice, amountToSend + 1);
        
        // Test 3: Try to send to zero address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        weEthInstance.recoverERC20(address(mockToken), address(0), amountToSend);
        
        // Test 4: Try to recover from zero token address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        weEthInstance.recoverERC20(address(0), alice, amountToSend);
    }

    function test_RecoverERC721_ErrorConditions() public {
        TestERC721 mockNFT = new TestERC721("Test NFT", "TNFT");
        uint256 tokenId = mockNFT.mint(alice);
        
        // Send NFT to eETH contract
        vm.prank(alice);
        mockNFT.transferFrom(alice, address(weEthInstance), tokenId);
        
        // Test 1: Try to recover NFT that doesn't exist - should revert
        uint256 nonExistentTokenId = 9999;
        vm.expectRevert(); // ERC721: invalid token ID or similar
        vm.prank(admin);
        weEthInstance.recoverERC721(address(mockNFT), alice, nonExistentTokenId);
        
        // Test 2: Try to recover NFT that contract doesn't own - should revert with ContractIsNotOwnerOfERC721Token
        uint256 bobsTokenId = mockNFT.mint(bob);
        vm.expectRevert(AssetRecovery.ContractIsNotOwnerOfERC721Token.selector);
        vm.prank(admin);
        weEthInstance.recoverERC721(address(mockNFT), alice, bobsTokenId);
        
        // Test 3: Try to send to zero address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        weEthInstance.recoverERC721(address(mockNFT), address(0), tokenId);
        
        // Test 4: Try to recover from zero token address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        weEthInstance.recoverERC721(address(0), alice, tokenId);
    }

    // -------------------------------------------------------------------------
    // Pause + blacklist
    //
    // WeETH gates all token movement through `_beforeTokenTransfer`, which
    // (a) reverts with "PAUSED" when `paused` is set, and (b) calls
    // `blacklister.nonBlacklisted(from)` / `(to)`. This hook runs on mint
    // (wrap), burn (unwrap), and transfer, so each path must respect the gate.
    // Pause is gated by PROTOCOL_PAUSER / PROTOCOL_UNPAUSER on RoleRegistry.
    // -------------------------------------------------------------------------

    function _expectBlacklistedRevert(address user) internal {
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, user));
    }

    function _aliceWithEEth(uint256 amount) internal {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: amount}();
        eETHInstance.approve(address(weEthInstance), amount);
        vm.stopPrank();
    }

    function _aliceWithWeEth(uint256 amount) internal {
        _aliceWithEEth(amount);
        vm.prank(alice);
        weEthInstance.wrap(amount);
    }

    // ---- pause role gating --------------------------------------------------

    function test_WeETH_pause_requiresPauserRole() public {
        // pause() / unpause() are gated by onlyAdmin (OPERATION_MULTISIG_ROLE).
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        weEthInstance.pause();

        vm.prank(admin);
        weEthInstance.pause();
        assertTrue(weEthInstance.paused());
    }

    function test_WeETH_unpause_requiresUnpauserRole() public {
        vm.prank(admin);
        weEthInstance.pause();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        weEthInstance.unpause();

        vm.prank(admin);
        weEthInstance.unpause();
        assertFalse(weEthInstance.paused());
    }

    // ---- paused blocks mint/burn/transfer via _beforeTokenTransfer ----------

    function test_WeETH_wrap_revertsWhenPaused() public {
        _aliceWithEEth(1 ether);
        vm.prank(admin);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert(WeETH.ContractPaused.selector);
        weEthInstance.wrap(1 ether);
    }

    function test_WeETH_unwrap_revertsWhenPaused() public {
        _aliceWithWeEth(1 ether);

        vm.prank(admin);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert(WeETH.ContractPaused.selector);
        weEthInstance.unwrap(0.5 ether);
    }

    function test_WeETH_transfer_revertsWhenPaused() public {
        _aliceWithWeEth(1 ether);

        vm.prank(admin);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert(WeETH.ContractPaused.selector);
        weEthInstance.transfer(bob, 0.5 ether);
    }

    function test_WeETH_transfer_succeedsAfterUnpause() public {
        _aliceWithWeEth(1 ether);

        vm.prank(admin);
        weEthInstance.pause();
        vm.prank(admin);
        weEthInstance.unpause();

        vm.prank(alice);
        weEthInstance.transfer(bob, 0.5 ether);
        assertEq(weEthInstance.balanceOf(bob), 0.5 ether);
    }

    // ---- blacklist gates mint (wrap) / burn (unwrap) / transfer -------------

    function test_WeETH_wrap_revertsForBlacklistedRecipient() public {
        // wrap mints to msg.sender — gate trips on `to` (msg.sender).
        _aliceWithEEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        weEthInstance.wrap(1 ether);
    }

    function test_WeETH_unwrap_revertsForBlacklistedUser() public {
        _aliceWithWeEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        // unwrap burns from msg.sender — gate trips on `from`. Note this also
        // exercises the EETH `_transferShares` path on the way back, which has
        // its own gate; alice is blacklisted there too, so either revert
        // could surface — both are `BlacklistedUser(alice)`.
        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        weEthInstance.unwrap(0.5 ether);
    }

    function test_WeETH_transfer_revertsWhenSenderBlacklisted() public {
        _aliceWithWeEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        weEthInstance.transfer(bob, 0.5 ether);
    }

    function test_WeETH_transfer_revertsWhenRecipientBlacklisted() public {
        _aliceWithWeEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(bob);

        vm.prank(alice);
        _expectBlacklistedRevert(bob);
        weEthInstance.transfer(bob, 0.5 ether);
    }

    function test_WeETH_transferFrom_revertsForBlacklistedParticipants() public {
        _aliceWithWeEth(1 ether);
        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(bob);
        _expectBlacklistedRevert(alice);
        weEthInstance.transferFrom(alice, bob, 0.5 ether);
    }

    function test_WeETH_transfer_succeedsAfterBlacklistExpires() public {
        _aliceWithWeEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(alice, 1 days);

        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        weEthInstance.transfer(bob, 0.5 ether);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        weEthInstance.transfer(bob, 0.5 ether);
        assertEq(weEthInstance.balanceOf(bob), 0.5 ether);
    }

    function test_WeETH_transfer_succeedsAfterUnblacklist() public {
        _aliceWithWeEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);
        vm.prank(owner);
        blacklisterInstance.unblacklistUser(alice);

        vm.prank(alice);
        weEthInstance.transfer(bob, 0.5 ether);
        assertEq(weEthInstance.balanceOf(bob), 0.5 ether);
    }

    // -------------------------------------------------------------------------
    // pauseContractUntil / unpauseContractUntil
    //
    // WeETH inherits PausableUntil. The `_beforeTokenTransfer` hook calls
    // `_requireNotPausedUntil`, so every token movement — wrap (mint), unwrap
    // (burn), transfer, transferFrom — is gated. Entry points are gated by
    // PAUSE_UNTIL_ROLE / UNPAUSE_UNTIL_ROLE on RoleRegistry. The state lives in
    // the same fixed namespaced storage slot as EETH (slot is per-contract; the
    // path inside each contract is identical).
    // -------------------------------------------------------------------------

    bytes32 constant PAUSABLE_UNTIL_SLOT =
        0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    address pauseUntilPauser = makeAddr("pauseUntilPauser");
    address unpauseUntilUnpauser = makeAddr("unpauseUntilUnpauser");
    address pauseUntilDurationSetter = makeAddr("pauseUntilDurationSetter");

    function _grantPauseUntilRoles() internal {
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.SUPER_GUARDIAN_ROLE(), pauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), unpauseUntilUnpauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), pauseUntilDurationSetter);
        vm.stopPrank();
        // Foundry's default block.timestamp is too small to clear the cooldown
        // check on the very first pause (lastPauseTimestamp[0] = 0 ⇒ trips
        // 0 + MAX_PAUSE_DURATION + PAUSER_UNTIL_COOLDOWN > block.timestamp).
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

        // Resolve before prank — nested staticcall otherwise consumes the prank.
        uint256 maxDuration = weEthInstance.MAX_PAUSE_DURATION();
        vm.prank(pauseUntilDurationSetter);
        weEthInstance.setPauseUntilDuration(maxDuration);
    }

    function _weETHPausedUntil() internal view returns (uint256) {
        return uint256(vm.load(address(weEthInstance), PAUSABLE_UNTIL_SLOT));
    }

    // ---- pauseContractUntil role gating -------------------------------------

    function test_WeETH_pauseContractUntil_requiresRole() public {
        _grantPauseUntilRoles();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlySuperGuardian.selector);
        weEthInstance.pauseContractUntil();

        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();
        assertEq(_weETHPausedUntil(), block.timestamp + weEthInstance.MAX_PAUSE_DURATION());
    }

    function test_WeETH_unpauseContractUntil_requiresRole() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        weEthInstance.unpauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        weEthInstance.unpauseContractUntil();
        assertEq(_weETHPausedUntil(), 0);
    }

    function test_WeETH_unpauseContractUntil_revertsIfNotPaused() public {
        _grantPauseUntilRoles();
        vm.prank(unpauseUntilUnpauser);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        weEthInstance.unpauseContractUntil();
    }

    function test_WeETH_pauseContractUntil_revertsIfAlreadyPaused() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();

        vm.prank(pauseUntilPauser);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _weETHPausedUntil())
        );
        weEthInstance.pauseContractUntil();
    }

    function test_WeETH_pauseContractUntil_cooldownEnforced() public {
        _grantPauseUntilRoles();

        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        weEthInstance.unpauseContractUntil();

        // Past MAX_PAUSE_DURATION but inside cooldown window — should still revert.
        vm.warp(block.timestamp + weEthInstance.MAX_PAUSE_DURATION() + 1);
        vm.prank(pauseUntilPauser);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        weEthInstance.pauseContractUntil();

        vm.warp(block.timestamp + weEthInstance.PAUSER_UNTIL_COOLDOWN());
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();
    }

    // ---- pause-until blocks every token movement ----------------------------

    function test_WeETH_wrap_revertsWhenPausedUntil() public {
        _aliceWithEEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();
        uint256 pausedUntilTs = _weETHPausedUntil();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        weEthInstance.wrap(1 ether);
    }

    function test_WeETH_unwrap_revertsWhenPausedUntil() public {
        _aliceWithWeEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();
        uint256 pausedUntilTs = _weETHPausedUntil();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        weEthInstance.unwrap(0.5 ether);
    }

    function test_WeETH_transfer_revertsWhenPausedUntil() public {
        _aliceWithWeEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();
        uint256 pausedUntilTs = _weETHPausedUntil();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        weEthInstance.transfer(bob, 0.5 ether);
    }

    function test_WeETH_transferFrom_revertsWhenPausedUntil() public {
        _aliceWithWeEth(1 ether);
        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();
        uint256 pausedUntilTs = _weETHPausedUntil();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        weEthInstance.transferFrom(alice, bob, 0.5 ether);
    }

    // ---- recovery paths -----------------------------------------------------

    function test_WeETH_transfer_unblockedAfterPauseExpires() public {
        _aliceWithWeEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();

        vm.warp(block.timestamp + weEthInstance.MAX_PAUSE_DURATION() + 1);

        vm.prank(alice);
        weEthInstance.transfer(bob, 0.5 ether);
        assertEq(weEthInstance.balanceOf(bob), 0.5 ether);
    }

    function test_WeETH_transfer_unblockedAfterManualUnpause() public {
        _aliceWithWeEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        weEthInstance.unpauseContractUntil();

        vm.prank(alice);
        weEthInstance.transfer(bob, 0.5 ether);
        assertEq(weEthInstance.balanceOf(bob), 0.5 ether);
    }

    function test_WeETH_wrap_unblockedAfterPauseExpires() public {
        _aliceWithEEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();

        vm.warp(block.timestamp + weEthInstance.MAX_PAUSE_DURATION() + 1);

        vm.prank(alice);
        weEthInstance.wrap(1 ether);
        assertGt(weEthInstance.balanceOf(alice), 0);
    }

    // ---- setPauseUntilDuration role gating ----------------------------------

    function test_WeETH_setPauseUntilDuration_requiresRole() public {
        _grantPauseUntilRoles();
        uint256 maxDur = weEthInstance.MAX_PAUSE_DURATION();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        weEthInstance.setPauseUntilDuration(maxDur);

        // PAUSE_UNTIL_ROLE alone is insufficient.
        vm.prank(pauseUntilPauser);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        weEthInstance.setPauseUntilDuration(maxDur);
    }

    function test_WeETH_setPauseUntilDuration_setsValue() public {
        _grantPauseUntilRoles();
        uint256 d = weEthInstance.MIN_PAUSE_DURATION() + 1 hours;

        vm.prank(pauseUntilDurationSetter);
        weEthInstance.setPauseUntilDuration(d);

        vm.prank(pauseUntilPauser);
        weEthInstance.pauseContractUntil();
        assertEq(weEthInstance.pausedUntil(), block.timestamp + d);
    }

    function test_WeETH_setPauseUntilDuration_revertsOnInvalidValue() public {
        _grantPauseUntilRoles();
        uint256 belowMin = weEthInstance.MIN_PAUSE_DURATION() - 1;
        uint256 aboveMax = weEthInstance.MAX_PAUSE_DURATION() + 1;

        vm.prank(pauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        weEthInstance.setPauseUntilDuration(belowMin);

        vm.prank(pauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        weEthInstance.setPauseUntilDuration(aboveMax);
    }

    // ---- spender (msg.sender) blacklist on transferFrom ---------------------
    // `_beforeTokenTransfer` now blacklist-checks msg.sender in addition to
    // from/to, so a blacklisted spender cannot move tokens even between clean
    // parties.

    function test_WeETH_transferFrom_revertsWhenSpenderBlacklisted() public {
        address spender = vm.addr(0xCAFE);

        _aliceWithWeEth(1 ether);
        vm.prank(alice);
        weEthInstance.approve(spender, 1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(spender);

        vm.prank(spender);
        _expectBlacklistedRevert(spender);
        weEthInstance.transferFrom(alice, bob, 0.5 ether);
    }
}

pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "./TestERC20.sol";
import "./TestERC721.sol";
import "../src/helpers/Blacklister.sol";
import "../src/utils/PausableUntil.sol";

// Helper contract to force ETH into a contract using selfdestruct
contract ForceETHSender {
    function forceSend(address payable target) external payable {
        selfdestruct(target);
    }
}

contract EETHTest is TestSetup {

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
       
        setUpTests();
    }

    function test_EETHInitializedCorrectly() public {
        assertEq(eETHInstance.totalShares(), 0);
        assertEq(eETHInstance.name(), "ether.fi ETH");
        assertEq(eETHInstance.symbol(), "eETH");
        assertEq(eETHInstance.decimals(), 18);
        assertEq(eETHInstance.totalSupply(), 0);
        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(eETHInstance.balanceOf(bob), 0);
        assertEq(eETHInstance.allowance(alice, bob), 0);
        assertEq(eETHInstance.allowance(alice, address(liquidityPoolInstance)), 0);
        assertEq(eETHInstance.shares(alice), 0);
        assertEq(eETHInstance.shares(bob), 0);
        assertEq(eETHInstance.getImplementation(), address(eETHImplementation));
    }

    function test_MintShares() public {
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 100);

        assertEq(eETHInstance.shares(alice), 100);
        assertEq(eETHInstance.totalShares(), 100);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(eETHInstance.totalSupply(), 0);

        vm.expectRevert("Only pool contract function");
        vm.prank(alice);
        eETHInstance.mintShares(alice, 100);
    }

    function test_BurnShares() public {
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 100);

        assertEq(eETHInstance.shares(alice), 100);
        assertEq(eETHInstance.totalShares(), 100);

        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, 25);

        assertEq(eETHInstance.shares(alice), 75);
        assertEq(eETHInstance.totalShares(), 75);

        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, 25);

        assertEq(eETHInstance.shares(alice), 50);
        assertEq(eETHInstance.totalShares(), 50);

        vm.expectRevert("BURN_AMOUNT_EXCEEDS_BALANCE");
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, 100);

        vm.expectRevert("Incorrect Caller");
        vm.prank(bob);
        eETHInstance.burnShares(alice, 50);
    }

    function test_EEthRebase() public {
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 0 ether);

        // Total pooled ether = 10
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.totalSupply(), 10 ether);
        assertEq(eETHInstance.totalShares(), 10 ether);
        assertEq(eETHInstance.shares(alice), 10 ether);

        // Total pooled ether = 20
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether);
        _transferTo(address(liquidityPoolInstance), 10 ether);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 20 ether);
        assertEq(eETHInstance.totalSupply(), 20 ether);
        assertEq(eETHInstance.totalShares(), 10 ether);
        assertEq(eETHInstance.shares(alice), 10 ether);

        // ALice total claimable Ether
        /// (20 * 10) / 10
        assertEq(liquidityPoolInstance.getTotalEtherClaimOf(alice), 20 ether);

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 5 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 25 ether);
        assertEq(eETHInstance.totalSupply(), 25 ether);

        // Bob Shares = (5 * 10) / (25 - 5) = 2,5
        assertEq(eETHInstance.shares(bob), 2.5 ether);
        assertEq(eETHInstance.totalShares(), 12.5 ether);

        // Bob claimable Ether
        /// (25 * 2,5) / 12,5 = 5 ether

        //ALice Claimable Ether
        /// (25 * 10) / 12,5 = 20 ether
        assertEq(liquidityPoolInstance.getTotalEtherClaimOf(alice), 20 ether);
        assertEq(liquidityPoolInstance.getTotalEtherClaimOf(bob), 5 ether);

        assertEq(eETHInstance.balanceOf(alice), 20 ether);
        assertEq(eETHInstance.balanceOf(bob), 5 ether);

        // Staking Rewards sent to liquidity pool
        /// vm.deal sets the balance of whoever its called on
        /// In this case 10 ether is added as reward 
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether);
        _transferTo(address(liquidityPoolInstance), 10 ether);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 35 ether);
        assertEq(eETHInstance.totalSupply(), 35 ether);

        // Bob claimable Ether
        /// (35 * 2,5) / 12,5 = 7 ether
        assertEq(liquidityPoolInstance.getTotalEtherClaimOf(bob), 7 ether);

        // Alice Claimable Ether
        /// (35 * 10) / 12,5 = 20 ether
        assertEq(liquidityPoolInstance.getTotalEtherClaimOf(alice), 28 ether);

        assertEq(eETHInstance.balanceOf(alice), 28 ether);
        assertEq(eETHInstance.balanceOf(bob), 7 ether);
    }

    function test_TransferWithAmount() public {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        vm.stopPrank();

        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        assertEq(eETHInstance.balanceOf(bob), 0 ether);
        assertEq(eETHInstance.shares(alice), 1 ether);
        assertEq(eETHInstance.shares(bob), 0);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0.5 ether);
        vm.prank(alice);
        eETHInstance.transfer(bob, 0.5 ether);

        assertEq(eETHInstance.balanceOf(alice), 0.5 ether);
        assertEq(eETHInstance.balanceOf(bob), 0.5 ether);
        assertEq(eETHInstance.shares(alice), 0.5 ether);
        assertEq(eETHInstance.shares(bob), 0.5 ether);

        vm.expectRevert("TRANSFER_FROM_THE_ZERO_ADDRESS");
        vm.prank(address(0));
        eETHInstance.transfer(bob, 0.5 ether);

        vm.expectRevert("TRANSFER_TO_THE_ZERO_ADDRESS");
        vm.prank(alice);
        eETHInstance.transfer(address(0), 0.5 ether);

        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_BALANCE");
        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_TransferWithZero() public {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        vm.stopPrank();

        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        assertEq(eETHInstance.balanceOf(bob), 0 ether);
        assertEq(eETHInstance.shares(alice), 1 ether);
        assertEq(eETHInstance.shares(bob), 0);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        eETHInstance.transfer(bob, 0);

        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        assertEq(eETHInstance.balanceOf(bob), 0 ether);
        assertEq(eETHInstance.shares(alice), 1 ether);
        assertEq(eETHInstance.shares(bob), 0);
    }

    function test_ApproveWithAmount() public {
        assertEq(eETHInstance.allowance(alice, bob), 0);

        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 5 ether);
        vm.prank(alice);
        eETHInstance.approve(bob, 5 ether);

        assertEq(eETHInstance.allowance(alice, bob), 5 ether);

        vm.expectRevert("APPROVE_FROM_ZERO_ADDRESS");
        vm.prank(address(0));
        eETHInstance.approve(bob, 5 ether);

        vm.expectRevert("APPROVE_TO_ZERO_ADDRESS");
        vm.prank(alice);
        eETHInstance.approve(address(0), 5 ether);
    }

    function test_ApproveWithZero() public {
        assertEq(eETHInstance.allowance(alice, bob), 0);

        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 0 ether);
        vm.prank(alice);
        eETHInstance.approve(bob, 0 ether);

        assertEq(eETHInstance.allowance(alice, bob), 0 ether);
    }

    function test_UpdateApprovalAmounts() public {
        assertEq(eETHInstance.allowance(alice, bob), 0);

        vm.startPrank(alice);
        eETHInstance.approve(bob, 5 ether);

        assertEq(eETHInstance.allowance(alice, bob), 5 ether);
        eETHInstance.increaseAllowance(bob, 2 ether);
        assertEq(eETHInstance.allowance(alice, bob), 7 ether);

        eETHInstance.decreaseAllowance(bob, 4 ether);
        assertEq(eETHInstance.allowance(alice, bob), 3 ether);

        vm.expectRevert("ERC20: decreased allowance below zero");
        eETHInstance.decreaseAllowance(bob, 4 ether);
    }

    function test_TransferFromWithAmount() public {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        vm.stopPrank();

        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        assertEq(eETHInstance.balanceOf(bob), 0 ether);
        assertEq(eETHInstance.shares(alice), 1 ether);
        assertEq(eETHInstance.shares(bob), 0);

        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");
        vm.prank(bob);
        eETHInstance.transferFrom(alice, bob, 0.5 ether);

        vm.prank(alice);
        eETHInstance.approve(bob, 0.5 ether);
        assertEq(eETHInstance.allowance(alice, bob), 0.5 ether);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0.5 ether);
        vm.prank(bob);
        eETHInstance.transferFrom(alice, bob, 0.5 ether);

        assertEq(eETHInstance.balanceOf(alice), 0.5 ether);
        assertEq(eETHInstance.balanceOf(bob), 0.5 ether);
        assertEq(eETHInstance.shares(alice), 0.5 ether);
        assertEq(eETHInstance.shares(bob), 0.5 ether);

        assertEq(eETHInstance.allowance(alice, bob), 0 ether);
    }

    function test_TransferFromWithZero() public {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        vm.stopPrank();

        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        assertEq(eETHInstance.balanceOf(bob), 0 ether);
        assertEq(eETHInstance.shares(alice), 1 ether);
        assertEq(eETHInstance.shares(bob), 0);

        vm.prank(alice);
        eETHInstance.approve(bob, 0.5 ether);
        assertEq(eETHInstance.allowance(alice, bob), 0.5 ether);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0 ether);
        vm.prank(bob);
        eETHInstance.transferFrom(alice, bob, 0 ether);

        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        assertEq(eETHInstance.balanceOf(bob), 0 ether);
        assertEq(eETHInstance.shares(alice), 1 ether);
        assertEq(eETHInstance.shares(bob), 0 ether);

        assertEq(eETHInstance.allowance(alice, bob), 0.5 ether);
    }
    function test_RecoverETH() public {
        uint256 amountToSend = 2 ether;
        // We cannot send ETH directly to eETH contract because it has no fallback/retrieve method
        ForceETHSender sender = new ForceETHSender();
        vm.deal(address(sender), amountToSend);
        sender.forceSend(payable(address(eETHInstance)));
        
        // Check that eETH contract now has ETH
        assertEq(address(eETHInstance).balance, amountToSend);
        
        // Try to recover ETH without proper role - should fail
        vm.expectRevert();
        vm.prank(bob);
        eETHInstance.recoverETH(payable(bob), amountToSend);
        
        // Check alice's balance before recovery
        uint256 aliceBalanceBefore = alice.balance;
        
        // Recover ETH as admin
        vm.prank(admin);
        eETHInstance.recoverETH(payable(alice), amountToSend);
        
        // Verify ETH was recovered
        assertEq(address(eETHInstance).balance, 0);
        assertEq(alice.balance, aliceBalanceBefore + amountToSend);
    }
    function test_RecoverERC20() public {
        // Create a mock ERC20 token
        TestERC20 mockToken = new TestERC20("Test Token", "TEST");
        uint256 amountToSend = 1000e18;
        
        // Mint tokens to alice and send to eETH contract
        mockToken.mint(alice, amountToSend);
        vm.prank(alice);
        mockToken.transfer(address(eETHInstance), amountToSend);
        
        assertEq(mockToken.balanceOf(address(eETHInstance)), amountToSend);
            
        // Try to recover tokens without proper role - should fail
        vm.expectRevert();
        vm.prank(bob);
        eETHInstance.recoverERC20(address(mockToken), alice, amountToSend);
        
        // Recover tokens as admin (who has the role)
        vm.prank(admin);
        eETHInstance.recoverERC20(address(mockToken), alice, amountToSend);
        
        // Verify tokens were recovered
        assertEq(mockToken.balanceOf(address(eETHInstance)), 0);
        assertEq(mockToken.balanceOf(alice), amountToSend);
    }

    function test_RecoverERC721() public {
        // Create a mock ERC721 token
        TestERC721 mockNFT = new TestERC721("Test NFT", "TNFT");
        
        // Mint NFT to alice and send to eETH contract
        uint256 tokenId = mockNFT.mint(alice);
        vm.prank(alice);
        mockNFT.transferFrom(alice, address(eETHInstance), tokenId);
        
        assertEq(mockNFT.ownerOf(tokenId), address(eETHInstance));
        
        // Try to recover NFT without proper role - should fail
        vm.expectRevert();
        vm.prank(bob);
        eETHInstance.recoverERC721(address(mockNFT), alice, tokenId);
        
        // Recover NFT as admin
        vm.prank(admin);
        eETHInstance.recoverERC721(address(mockNFT), alice, tokenId);
        
        // Verify NFT was recovered
        assertEq(mockNFT.ownerOf(tokenId), alice);
    }

    function test_RecoverETH_ErrorConditions() public {
        uint256 amountToSend = 2 ether;
        // Force ETH into the contract
        ForceETHSender sender = new ForceETHSender();
        vm.deal(address(sender), amountToSend);
        sender.forceSend(payable(address(eETHInstance)));
        
        // Test 1: Try to recover 0 ETH - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        eETHInstance.recoverETH(payable(alice), 0);
        
        // Test 2: Try to recover more ETH than exists - should revert with InsufficientBalance
        vm.expectRevert(AssetRecovery.InsufficientBalance.selector);
        vm.prank(admin);
        eETHInstance.recoverETH(payable(alice), amountToSend + 1);
        
        // Test 3: Try to send to zero address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        eETHInstance.recoverETH(payable(address(0)), amountToSend);
    }

    function test_RecoverERC20_ErrorConditions() public {
        TestERC20 mockToken = new TestERC20("Test Token", "TEST");
        uint256 amountToSend = 1000e18;
        
        // Send tokens to eETH contract
        mockToken.mint(alice, amountToSend);
        vm.prank(alice);
        mockToken.transfer(address(eETHInstance), amountToSend);
        
        // Test 1: Try to recover 0 tokens - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        eETHInstance.recoverERC20(address(mockToken), alice, 0);
        
        // Test 2: Try to recover more tokens than exists - should revert with InsufficientBalance
        vm.expectRevert(AssetRecovery.InsufficientBalance.selector);
        vm.prank(admin);
        eETHInstance.recoverERC20(address(mockToken), alice, amountToSend + 1);
        
        // Test 3: Try to send to zero address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        eETHInstance.recoverERC20(address(mockToken), address(0), amountToSend);
        
        // Test 4: Try to recover from zero token address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        eETHInstance.recoverERC20(address(0), alice, amountToSend);
    }

    function test_RecoverERC721_ErrorConditions() public {
        TestERC721 mockNFT = new TestERC721("Test NFT", "TNFT");
        uint256 tokenId = mockNFT.mint(alice);
        
        // Send NFT to eETH contract
        vm.prank(alice);
        mockNFT.transferFrom(alice, address(eETHInstance), tokenId);
        
        // Test 1: Try to recover NFT that doesn't exist - should revert
        uint256 nonExistentTokenId = 9999;
        vm.expectRevert(); // ERC721: invalid token ID or similar
        vm.prank(admin);
        eETHInstance.recoverERC721(address(mockNFT), alice, nonExistentTokenId);
        
        // Test 2: Try to recover NFT that contract doesn't own - should revert with ContractIsNotOwnerOfERC721Token
        uint256 bobsTokenId = mockNFT.mint(bob);
        vm.expectRevert(AssetRecovery.ContractIsNotOwnerOfERC721Token.selector);
        vm.prank(admin);
        eETHInstance.recoverERC721(address(mockNFT), alice, bobsTokenId);
        
        // Test 3: Try to send to zero address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        eETHInstance.recoverERC721(address(mockNFT), address(0), tokenId);
        
        // Test 4: Try to recover from zero token address - should revert with InvalidInput
        vm.expectRevert(AssetRecovery.InvalidInput.selector);
        vm.prank(admin);
        eETHInstance.recoverERC721(address(0), alice, tokenId);
    }

    // -------------------------------------------------------------------------
    // Pause + blacklist
    //
    // The eETH share-mutating paths (`mintShares`, `burnShares`,
    // `_transferShares`) all carry the new `whenNotPaused` modifier and call
    // `blacklister.nonBlacklisted` on the affected addresses. Pause is gated
    // by RoleRegistry's PROTOCOL_PAUSER / PROTOCOL_UNPAUSER. The blacklist
    // check is `blacklistedUntil[user] > block.timestamp`, so a time-bounded
    // entry auto-opens at expiry.
    // -------------------------------------------------------------------------

    function _expectBlacklistedRevert(address user) internal {
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, user));
    }

    function _aliceWithEEth(uint256 amount) internal {
        startHoax(alice);
        liquidityPoolInstance.deposit{value: amount}();
        vm.stopPrank();
    }

    // ---- pause role gating --------------------------------------------------

    function test_EETH_pause_requiresPauserRole() public {
        // pause() is now onlyAdmin -> OPERATION_MULTISIG_ROLE.
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        eETHInstance.pause();

        // `admin` holds OPERATION_MULTISIG_ROLE from setUpTests.
        vm.prank(admin);
        eETHInstance.pause();
        assertTrue(eETHInstance.paused());
    }

    function test_EETH_unpause_requiresUnpauserRole() public {
        vm.prank(admin);
        eETHInstance.pause();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        eETHInstance.unpause();

        vm.prank(admin);
        eETHInstance.unpause();
        assertFalse(eETHInstance.paused());
    }

    // ---- paused blocks all share-mutating paths -----------------------------

    function test_EETH_mintShares_revertsWhenPaused() public {
        vm.prank(admin);
        eETHInstance.pause();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("PAUSED");
        eETHInstance.mintShares(alice, 100);
    }

    function test_EETH_burnShares_revertsWhenPaused() public {
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 100);

        vm.prank(admin);
        eETHInstance.pause();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("PAUSED");
        eETHInstance.burnShares(alice, 50);
    }

    function test_EETH_transfer_revertsWhenPaused() public {
        _aliceWithEEth(1 ether);

        vm.prank(admin);
        eETHInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, 0.5 ether);
    }

    function test_EETH_transfer_succeedsAfterUnpause() public {
        _aliceWithEEth(1 ether);

        vm.prank(admin);
        eETHInstance.pause();
        vm.prank(admin);
        eETHInstance.unpause();

        vm.prank(alice);
        eETHInstance.transfer(bob, 0.5 ether);

        assertEq(eETHInstance.balanceOf(bob), 0.5 ether);
    }

    // ---- blacklist gates mint/burn/transfer ---------------------------------

    function test_EETH_mintShares_revertsForBlacklistedRecipient() public {
        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(address(liquidityPoolInstance));
        _expectBlacklistedRevert(alice);
        eETHInstance.mintShares(alice, 100);
    }

    function test_EETH_burnShares_revertsForBlacklistedUser() public {
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 100);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(address(liquidityPoolInstance));
        _expectBlacklistedRevert(alice);
        eETHInstance.burnShares(alice, 50);
    }

    function test_EETH_transfer_revertsWhenSenderBlacklisted() public {
        _aliceWithEEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        eETHInstance.transfer(bob, 0.5 ether);
    }

    function test_EETH_transfer_revertsWhenRecipientBlacklisted() public {
        _aliceWithEEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(bob);

        vm.prank(alice);
        _expectBlacklistedRevert(bob);
        eETHInstance.transfer(bob, 0.5 ether);
    }

    function test_EETH_transferFrom_revertsForBlacklistedParticipants() public {
        // transferFrom path also routes through `_transferShares`, so both
        // sender and recipient checks apply here too. Spender (msg.sender) is
        // not in the gate, only the share-side `from`/`to`.
        _aliceWithEEth(1 ether);
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);

        vm.prank(bob);
        _expectBlacklistedRevert(alice);
        eETHInstance.transferFrom(alice, bob, 0.5 ether);
    }

    function test_EETH_transfer_succeedsAfterBlacklistExpires() public {
        _aliceWithEEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(alice, 1 days);

        vm.prank(alice);
        _expectBlacklistedRevert(alice);
        eETHInstance.transfer(bob, 0.5 ether);

        // Strict `>` comparison in Blacklister.nonBlacklisted ⇒ opens at exactly `until`.
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        eETHInstance.transfer(bob, 0.5 ether);
        assertEq(eETHInstance.balanceOf(bob), 0.5 ether);
    }

    function test_EETH_transfer_succeedsAfterUnblacklist() public {
        _aliceWithEEth(1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(alice);
        vm.prank(owner);
        blacklisterInstance.unblacklistUser(alice);

        vm.prank(alice);
        eETHInstance.transfer(bob, 0.5 ether);
        assertEq(eETHInstance.balanceOf(bob), 0.5 ether);
    }

    // -------------------------------------------------------------------------
    // pauseContractUntil / unpauseContractUntil
    //
    // EETH inherits PausableUntil. The pause-until check now lives inside the
    // `whenNotPaused` modifier (`_requireNotPausedUntil`), so every share-mutating
    // path — `mintShares`, `burnShares`, and `_transferShares` (i.e. `transfer` /
    // `transferFrom`) — is gated. Entry points are gated by PAUSE_UNTIL_ROLE /
    // UNPAUSE_UNTIL_ROLE on RoleRegistry. The state lives in a fixed namespaced
    // storage slot — read via vm.load when we need to assert it.
    // -------------------------------------------------------------------------

    bytes32 constant PAUSABLE_UNTIL_SLOT =
        0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    address pauseUntilPauser = makeAddr("pauseUntilPauser");
    address unpauseUntilUnpauser = makeAddr("unpauseUntilUnpauser");
    address pauseUntilDurationSetter = makeAddr("pauseUntilDurationSetter");

    function _grantPauseUntilRoles() internal {
        vm.startPrank(roleRegistryInstance.owner());
        // pauseContractUntil → GUARDIAN_ROLE; unpauseContractUntil + setPauseUntilDuration → OPERATION_MULTISIG_ROLE
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), pauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), unpauseUntilUnpauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), pauseUntilDurationSetter);
        vm.stopPrank();
        // Foundry's default block.timestamp is too small — the cooldown check is
        // `lastPauseTimestamp + MAX_PAUSE_DURATION + COOLDOWN > block.timestamp`,
        // which fires on the very first call unless we warp forward past that sum.
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

        // Resolve MAX_PAUSE_DURATION before the prank — otherwise the nested
        // staticcall consumes the prank and setPauseUntilDuration is called by
        // the test contract instead of pauseUntilDurationSetter.
        uint256 maxDuration = eETHInstance.MAX_PAUSE_DURATION();
        vm.prank(pauseUntilDurationSetter);
        eETHInstance.setPauseUntilDuration(maxDuration);
    }

    function _eETHPausedUntil() internal view returns (uint256) {
        return uint256(vm.load(address(eETHInstance), PAUSABLE_UNTIL_SLOT));
    }

    // ---- pauseContractUntil role gating -------------------------------------

    function test_EETH_pauseContractUntil_requiresRole() public {
        _grantPauseUntilRoles();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
        eETHInstance.pauseContractUntil();

        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();
        assertEq(_eETHPausedUntil(), block.timestamp + eETHInstance.MAX_PAUSE_DURATION());
    }

    function test_EETH_unpauseContractUntil_requiresRole() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        eETHInstance.unpauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        eETHInstance.unpauseContractUntil();
        assertEq(_eETHPausedUntil(), 0);
    }

    function test_EETH_unpauseContractUntil_revertsIfNotPaused() public {
        _grantPauseUntilRoles();
        vm.prank(unpauseUntilUnpauser);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        eETHInstance.unpauseContractUntil();
    }

    function test_EETH_pauseContractUntil_revertsIfAlreadyPaused() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        // Re-pausing while already paused-until hits _requireNotPausedUntil inside _pauseUntil.
        vm.prank(pauseUntilPauser);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _eETHPausedUntil())
        );
        eETHInstance.pauseContractUntil();
    }

    function test_EETH_pauseContractUntil_cooldownEnforced() public {
        _grantPauseUntilRoles();

        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        // Unpause and re-attempt before cooldown ends. Cooldown = MAX_PAUSE_DURATION + PAUSER_UNTIL_COOLDOWN.
        vm.prank(unpauseUntilUnpauser);
        eETHInstance.unpauseContractUntil();

        // Warp past MAX_PAUSE_DURATION (so we are no longer pausedUntil) but not past the cooldown.
        vm.warp(block.timestamp + eETHInstance.MAX_PAUSE_DURATION() + 1);

        vm.prank(pauseUntilPauser);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        eETHInstance.pauseContractUntil();

        // After the cooldown window also passes, same pauser can re-pause.
        vm.warp(block.timestamp + eETHInstance.PAUSER_UNTIL_COOLDOWN());
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();
    }

    // ---- pause-until blocks mint/burn ---------------------------------------

    function test_EETH_mintShares_revertsWhenPausedUntil() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        uint256 pausedUntilTs = _eETHPausedUntil();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        eETHInstance.mintShares(alice, 100);
    }

    function test_EETH_burnShares_revertsWhenPausedUntil() public {
        // Mint before pausing — mint path is also gated, so we can't do it after.
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 100);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        uint256 pausedUntilTs = _eETHPausedUntil();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        eETHInstance.burnShares(alice, 50);
    }

    // ---- pause-until blocks transfer / transferFrom -------------------------

    function test_EETH_transfer_revertsWhenPausedUntil() public {
        _aliceWithEEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();
        uint256 pausedUntilTs = _eETHPausedUntil();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        eETHInstance.transfer(bob, 0.5 ether);
    }

    function test_EETH_transferFrom_revertsWhenPausedUntil() public {
        _aliceWithEEth(1 ether);
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();
        uint256 pausedUntilTs = _eETHPausedUntil();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilTs)
        );
        eETHInstance.transferFrom(alice, bob, 0.5 ether);
    }

    // ---- recovery paths -----------------------------------------------------

    function test_EETH_mintShares_unblockedAfterPauseExpires() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        // Strict `>=` comparison in _requireNotPausedUntil ⇒ opens at exactly `pausedUntil + 1`.
        vm.warp(block.timestamp + eETHInstance.MAX_PAUSE_DURATION() + 1);

        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 100);
        assertEq(eETHInstance.shares(alice), 100);
    }

    function test_EETH_mintShares_unblockedAfterManualUnpause() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        eETHInstance.unpauseContractUntil();

        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 100);
        assertEq(eETHInstance.shares(alice), 100);
    }

    function test_EETH_transfer_unblockedAfterPauseExpires() public {
        _aliceWithEEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        vm.warp(block.timestamp + eETHInstance.MAX_PAUSE_DURATION() + 1);

        vm.prank(alice);
        eETHInstance.transfer(bob, 0.5 ether);
        assertEq(eETHInstance.balanceOf(bob), 0.5 ether);
    }

    function test_EETH_transfer_unblockedAfterManualUnpause() public {
        _aliceWithEEth(1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        eETHInstance.unpauseContractUntil();

        vm.prank(alice);
        eETHInstance.transfer(bob, 0.5 ether);
        assertEq(eETHInstance.balanceOf(bob), 0.5 ether);
    }

    // ---- spender (msg.sender) blacklist on transferFrom ---------------------
    // `_transferShares` now blacklist-checks msg.sender in addition to from/to,
    // so a blacklisted spender cannot move tokens even between clean parties.

    function test_EETH_transferFrom_revertsWhenSpenderBlacklisted() public {
        // Use a distinct spender so we can blacklist them without also tripping
        // the from/to checks.
        address spender = vm.addr(0xCAFE);

        _aliceWithEEth(1 ether);
        vm.prank(alice);
        eETHInstance.approve(spender, 1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(spender);

        vm.prank(spender);
        _expectBlacklistedRevert(spender);
        eETHInstance.transferFrom(alice, bob, 0.5 ether);
    }

    // --- setPauseUntilDuration ---

    function test_setPauseUntilDuration_requiresRole() public {
        _grantPauseUntilRoles();
        uint256 maxDur = eETHInstance.MAX_PAUSE_DURATION();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        eETHInstance.setPauseUntilDuration(maxDur);

        // Guardian-only role (pauseUntilPauser) cannot set the duration; needs admin role.
        vm.prank(pauseUntilPauser);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        eETHInstance.setPauseUntilDuration(maxDur);
    }

    function test_setPauseUntilDuration_setsValue() public {
        _grantPauseUntilRoles();
        uint256 d = eETHInstance.MIN_PAUSE_DURATION() + 1 hours;

        vm.prank(pauseUntilDurationSetter);
        eETHInstance.setPauseUntilDuration(d);

        vm.prank(pauseUntilPauser);
        eETHInstance.pauseContractUntil();
        assertEq(eETHInstance.pausedUntil(), block.timestamp + d);
    }

    function test_setPauseUntilDuration_revertsOnInvalidValue() public {
        _grantPauseUntilRoles();
        uint256 belowMin = eETHInstance.MIN_PAUSE_DURATION() - 1;
        uint256 aboveMax = eETHInstance.MAX_PAUSE_DURATION() + 1;

        vm.prank(pauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        eETHInstance.setPauseUntilDuration(belowMin);

        vm.prank(pauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        eETHInstance.setPauseUntilDuration(aboveMax);
    }
}

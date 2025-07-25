pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "./TestERC20.sol";
import "./TestERC721.sol";

// Helper contract to force ETH into a contract using selfdestruct
contract ForceETHSender {
    function forceSend(address payable target) external payable {
        selfdestruct(target);
    }
}

contract EETHTest is TestSetup {

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ETHRecovered(address indexed to, uint256 amount);

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
    

}

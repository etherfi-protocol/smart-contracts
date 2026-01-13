// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RestakingRewardsRouter.sol";
import "../src/RoleRegistry.sol";
import "../src/UUPSProxy.sol";
import "./TestERC20.sol";

contract RestakingRewardsRouterTest is Test {
    RestakingRewardsRouter public router;
    RestakingRewardsRouter public routerImpl;
    UUPSProxy public proxy;
    RoleRegistry public roleRegistry;
    RoleRegistry public roleRegistryImpl;
    UUPSProxy public roleRegistryProxy;
    
    TestERC20 public rewardToken;
    TestERC20 public otherToken;
    
    address public owner = vm.addr(1);
    address public admin = vm.addr(2);
    address public transferRoleUser = vm.addr(7);
    address public unauthorizedUser = vm.addr(3);
    address public liquidityPool = vm.addr(4);
    address public recipient = vm.addr(5);
    address public user = vm.addr(6);
    
    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE");
    
    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);
    event RecipientAddressSet(address indexed recipient);
    event RewardTokenAddressSet(address indexed rewardTokenAddress);
    event Erc20Transferred(address indexed token, address indexed recipient, uint256 amount);
    
    function setUp() public {
        // Deploy RoleRegistry
        vm.startPrank(owner);
        roleRegistryImpl = new RoleRegistry();
        roleRegistryProxy = new UUPSProxy(
            address(roleRegistryImpl),
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        );
        roleRegistry = RoleRegistry(address(roleRegistryProxy));
        
        // Deploy tokens
        rewardToken = new TestERC20("Reward Token", "RWD");
        otherToken = new TestERC20("Other Token", "OTH");
        
        // Deploy RestakingRewardsRouter implementation
        routerImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            liquidityPool
        );
        
        // Grant admin role
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, admin);
        // Grant transfer role
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE, admin);
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE, transferRoleUser);
        vm.stopPrank();
        
        // Deploy proxy and initialize (outside prank so owner is address(this))
        proxy = new UUPSProxy(
            address(routerImpl),
            abi.encodeWithSelector(RestakingRewardsRouter.initialize.selector)
        );
        router = RestakingRewardsRouter(payable(address(proxy)));
        
        // Transfer ownership to owner address
        router.transferOwnership(owner);
        
        // Set reward token address (since it's no longer immutable, needs to be set after proxy deployment)
        vm.prank(admin);
        router.setRewardTokenAddress(address(rewardToken));
    }
    
    // ============ Constructor Tests ============
    
    function test_constructor_setsValues() public {
        assertEq(router.rewardTokenAddress(), address(rewardToken));
        assertEq(router.liquidityPool(), liquidityPool);
        assertEq(address(router.roleRegistry()), address(roleRegistry));
    }
    
    function test_constructor_revertsWithZeroRewardToken() public {
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        new RestakingRewardsRouter(
            address(roleRegistry),
            address(0),
            liquidityPool
        );
    }
    
    function test_constructor_revertsWithZeroLiquidityPool() public {
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            address(0)
        );
    }
    
    function test_constructor_revertsWithZeroRoleRegistry() public {
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        new RestakingRewardsRouter(
            address(0),
            address(rewardToken),
            liquidityPool
        );
    }
    
    function test_constructor_disablesInitializers() public {
        vm.expectRevert();
        routerImpl.initialize();
    }
    
    // ============ Initialization Tests ============
    
    function test_initialize_setsOwner() public {
        assertEq(router.owner(), owner);
    }
    
    function test_initialize_canOnlyBeCalledOnce() public {
        vm.expectRevert("Initializable: contract is already initialized");
        router.initialize();
    }
    
    // ============ Receive ETH Tests ============
    
    function test_receive_emitsEthReceivedEvent() public {
        vm.deal(user, 10 ether);
        
        vm.expectEmit(true, false, false, true);
        emit EthReceived(user, 10 ether);
        
        vm.prank(user);
        (bool success, ) = address(router).call{value: 10 ether}("");
        assertTrue(success);
    }
    
    function test_receive_forwardsEthToLiquidityPool() public {
        uint256 amount = 10 ether;
        vm.deal(user, amount);
        uint256 initialLiquidityPoolBalance = liquidityPool.balance;
        
        vm.expectEmit(true, true, false, true);
        emit EthSent(address(router), liquidityPool, amount);
        
        vm.prank(user);
        (bool success, ) = address(router).call{value: amount}("");
        assertTrue(success);
        
        assertEq(address(router).balance, 0);
        assertEq(liquidityPool.balance, initialLiquidityPoolBalance + amount);
    }
    
    function test_receive_handlesMultipleDeposits() public {
        vm.deal(user, 20 ether);
        uint256 initialLiquidityPoolBalance = liquidityPool.balance;
        
        vm.prank(user);
        (bool success1, ) = address(router).call{value: 5 ether}("");
        assertTrue(success1);
        
        vm.prank(user);
        (bool success2, ) = address(router).call{value: 10 ether}("");
        assertTrue(success2);
        
        assertEq(address(router).balance, 0);
        assertEq(liquidityPool.balance, initialLiquidityPoolBalance + 15 ether);
    }
    
    function test_receive_revertsIfLiquidityPoolTransferFails() public {
        // Create a contract that will revert on receive
        RevertingReceiver revertingPool = new RevertingReceiver();
        
        // Deploy new router with reverting pool
        RestakingRewardsRouter newRouterImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            address(revertingPool)
        );
        
        UUPSProxy newProxy = new UUPSProxy(
            address(newRouterImpl),
            abi.encodeWithSelector(RestakingRewardsRouter.initialize.selector)
        );
        RestakingRewardsRouter newRouter = RestakingRewardsRouter(payable(address(newProxy)));
        
        vm.deal(user, 10 ether);
        vm.prank(user);
        vm.expectRevert(RestakingRewardsRouter.TransferFailed.selector);
        address(newRouter).call{value: 10 ether}("");
    }
    
    // ============ Set Recipient Address Tests ============
    
    function test_setRecipientAddress_success() public {
        vm.prank(admin);
        router.setRecipientAddress(recipient);
        
        assertEq(router.recipientAddress(), recipient);
    }
    
    function test_setRecipientAddress_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit RecipientAddressSet(recipient);
        
        vm.prank(admin);
        router.setRecipientAddress(recipient);
    }
    
    function test_setRecipientAddress_revertsWithoutRole() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(RestakingRewardsRouter.IncorrectRole.selector);
        router.setRecipientAddress(recipient);
    }
    
    function test_setRecipientAddress_revertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        router.setRecipientAddress(address(0));
    }
    
    function test_setRecipientAddress_canUpdateRecipient() public {
        address newRecipient = vm.addr(100);
        
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        assertEq(router.recipientAddress(), recipient);
        
        router.setRecipientAddress(newRecipient);
        assertEq(router.recipientAddress(), newRecipient);
        vm.stopPrank();
    }
    
    // ============ Set Reward Token Address Tests ============
    
    function test_setRewardTokenAddress_success() public {
        TestERC20 newRewardToken = new TestERC20("New Reward Token", "NRWD");
        
        vm.prank(admin);
        router.setRewardTokenAddress(address(newRewardToken));
        
        assertEq(router.rewardTokenAddress(), address(newRewardToken));
    }
    
    function test_setRewardTokenAddress_emitsEvent() public {
        TestERC20 newRewardToken = new TestERC20("New Reward Token", "NRWD");
        
        vm.expectEmit(true, false, false, false);
        emit RewardTokenAddressSet(address(newRewardToken));
        
        vm.prank(admin);
        router.setRewardTokenAddress(address(newRewardToken));
    }
    
    function test_setRewardTokenAddress_revertsWithoutRole() public {
        TestERC20 newRewardToken = new TestERC20("New Reward Token", "NRWD");
        
        vm.prank(unauthorizedUser);
        vm.expectRevert(RestakingRewardsRouter.IncorrectRole.selector);
        router.setRewardTokenAddress(address(newRewardToken));
    }
    
    function test_setRewardTokenAddress_revertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        router.setRewardTokenAddress(address(0));
    }
    
    function test_setRewardTokenAddress_canUpdateToken() public {
        TestERC20 newRewardToken1 = new TestERC20("New Reward Token 1", "NRWD1");
        TestERC20 newRewardToken2 = new TestERC20("New Reward Token 2", "NRWD2");
        
        vm.startPrank(admin);
        router.setRewardTokenAddress(address(newRewardToken1));
        assertEq(router.rewardTokenAddress(), address(newRewardToken1));
        
        router.setRewardTokenAddress(address(newRewardToken2));
        assertEq(router.rewardTokenAddress(), address(newRewardToken2));
        vm.stopPrank();
    }
    
    // ============ transferERC20 Tests ============
    
    function test_transferERC20_forwardsBalance() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        rewardToken.mint(address(router), amount);
        
        uint256 initialRecipientBalance = rewardToken.balanceOf(recipient);
        
        vm.expectEmit(true, true, false, true);
        emit Erc20Transferred(address(rewardToken), recipient, amount);
        
        vm.prank(admin);
        router.transferERC20(address(rewardToken));
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(rewardToken.balanceOf(recipient), initialRecipientBalance + amount);
    }
    
    function test_transferERC20_revertsWhenNoRecipientSet() public {
        uint256 amount = 1000 ether;
        rewardToken.mint(address(router), amount);
        
        // Ensure reward token is set (it's set in setUp, but let's be explicit)
        vm.startPrank(admin);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        vm.prank(admin);
        vm.expectRevert(RestakingRewardsRouter.NoRecipientSet.selector);
        router.transferERC20(address(rewardToken));
    }
    
    function test_transferERC20_handlesZeroBalance() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        // Should not revert with zero balance
        vm.prank(admin);
        router.transferERC20(address(rewardToken));
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
    }
    
    function test_transferERC20_requiresRole() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        uint256 amount = 500 ether;
        rewardToken.mint(address(router), amount);
        
        vm.prank(unauthorizedUser);
        vm.expectRevert(RestakingRewardsRouter.IncorrectRole.selector);
        router.transferERC20(address(rewardToken));
        
        // Should still have tokens since transfer failed
        assertEq(rewardToken.balanceOf(address(router)), amount);
    }
    
    function test_transferERC20_withTransferRole() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        uint256 amount = 500 ether;
        rewardToken.mint(address(router), amount);
        
        vm.prank(transferRoleUser);
        router.transferERC20(address(rewardToken));
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(rewardToken.balanceOf(recipient), amount);
    }
    
    function test_transferERC20_handlesPartialTransfers() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        uint256 amount1 = 500 ether;
        uint256 amount2 = 300 ether;
        rewardToken.mint(address(router), amount1);
        
        vm.prank(admin);
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), amount1);
        
        rewardToken.mint(address(router), amount2);
        vm.prank(admin);
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), amount1 + amount2);
    }
    
    function test_transferERC20_revertsWithOtherToken() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        otherToken.mint(address(router), amount);
        
        vm.prank(admin);
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        router.transferERC20(address(otherToken));
        
        // Token should still be in router since transfer failed
        assertEq(otherToken.balanceOf(address(router)), amount);
    }
    
    function test_transferERC20_worksAfterTokenUpdate() public {
        TestERC20 newRewardToken = new TestERC20("New Reward Token", "NRWD");
        
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(newRewardToken));
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        newRewardToken.mint(address(router), amount);
        
        uint256 initialRecipientBalance = newRewardToken.balanceOf(recipient);
        
        vm.expectEmit(true, true, false, true);
        emit Erc20Transferred(address(newRewardToken), recipient, amount);
        
        vm.prank(admin);
        router.transferERC20(address(newRewardToken));
        
        assertEq(newRewardToken.balanceOf(address(router)), 0);
        assertEq(newRewardToken.balanceOf(recipient), initialRecipientBalance + amount);
    }
    
    function test_transferERC20_revertsWithZeroAddress() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        vm.prank(admin);
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        router.transferERC20(address(0));
    }
    
    // ============ Role Management Tests ============
    
    function test_roleManagement_grantAndRevoke() public {
        address newAdmin = vm.addr(100);
        
        // Grant role
        vm.prank(owner);
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, newAdmin);
        
        vm.prank(newAdmin);
        router.setRecipientAddress(recipient);
        assertEq(router.recipientAddress(), recipient);
        
        // Revoke role
        vm.prank(owner);
        roleRegistry.revokeRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, newAdmin);
        
        vm.prank(newAdmin);
        vm.expectRevert(RestakingRewardsRouter.IncorrectRole.selector);
        router.setRecipientAddress(vm.addr(101));
    }
    
    // ============ Upgrade Tests ============
    
    function test_upgrade_onlyProtocolUpgrader() public {
        RestakingRewardsRouter newImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            liquidityPool
        );
        
        // Unauthorized user cannot upgrade
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        router.upgradeTo(address(newImpl));
        
        // Owner of RoleRegistry (protocol upgrader) can upgrade
        vm.prank(owner);
        router.upgradeTo(address(newImpl));
        
        assertEq(router.getImplementation(), address(newImpl));
    }
    
    function test_getImplementation_returnsCurrentImplementation() public {
        address impl = router.getImplementation();
        assertEq(impl, address(routerImpl));
    }
    
    function test_upgrade_preservesState() public {
        // Set up some state
        uint256 ethAmount = 5 ether;
        uint256 tokenAmount = 100 ether;
        vm.deal(address(router), ethAmount);
        rewardToken.mint(address(router), tokenAmount);
        
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        RestakingRewardsRouter newImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            liquidityPool
        );
        
        // Owner of RoleRegistry (protocol upgrader) can upgrade
        vm.prank(owner);
        router.upgradeTo(address(newImpl));
        
        // State should be preserved
        assertEq(address(router).balance, ethAmount);
        assertEq(rewardToken.balanceOf(address(router)), tokenAmount);
        assertEq(router.rewardTokenAddress(), address(rewardToken));
        assertEq(router.liquidityPool(), liquidityPool);
        assertEq(router.recipientAddress(), recipient);
    }
    
    // ============ Edge Cases ============
    
    function test_multipleOperations_sequence() public {
        // Set recipient and reward token
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        // Send ETH
        vm.deal(user, 10 ether);
        vm.prank(user);
        (bool success, ) = address(router).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(liquidityPool.balance, 10 ether);
        
        // Transfer tokens (they will accumulate since there's no hook)
        uint256 tokenAmount = 500 ether;
        rewardToken.mint(user, tokenAmount);
        vm.prank(user);
        rewardToken.transfer(address(router), tokenAmount);
        assertEq(rewardToken.balanceOf(address(router)), tokenAmount);
        
        // Manual transfer to recover accumulated tokens
        vm.prank(admin);
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), tokenAmount);
        
        // Manual transfer for additional tokens
        uint256 manualAmount = 200 ether;
        rewardToken.mint(address(router), manualAmount);
        vm.prank(admin);
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), tokenAmount + manualAmount);
    }
    
    function test_receiveAndTransfer_combined() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        router.setRewardTokenAddress(address(rewardToken));
        vm.stopPrank();
        
        // Send ETH and tokens simultaneously
        vm.deal(user, 10 ether);
        uint256 tokenAmount = 1000 ether;
        rewardToken.mint(user, tokenAmount);
        
        vm.startPrank(user);
        (bool success, ) = address(router).call{value: 10 ether}("");
        assertTrue(success);
        rewardToken.transfer(address(router), tokenAmount);
        vm.stopPrank();
        
        assertEq(liquidityPool.balance, 10 ether);
        // Tokens accumulate since there's no hook
        assertEq(rewardToken.balanceOf(address(router)), tokenAmount);
        
        // Manual transfer to recover tokens
        vm.prank(admin);
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), tokenAmount);
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("Reverting receiver");
    }
}


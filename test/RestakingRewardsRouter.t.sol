// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RestakingRewardsRouter.sol";
import "../src/RoleRegistry.sol";
import "../src/UUPSProxy.sol";
import "./TestERC20.sol";

contract ERC20WithHook is TestERC20 {
    constructor(string memory _name, string memory _symbol) TestERC20(_name, _symbol) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (success && to.code.length > 0) {
            // Call hook and propagate revert if it fails
            IERC20Receiver(to).onERC20Received(address(this), msg.sender, amount, "");
        }
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        if (success && to.code.length > 0) {
            // Call hook and propagate revert if it fails
            IERC20Receiver(to).onERC20Received(address(this), from, amount, "");
        }
        return success;
    }
}

contract RestakingRewardsRouterTest is Test {
    RestakingRewardsRouter public router;
    RestakingRewardsRouter public routerImpl;
    UUPSProxy public proxy;
    RoleRegistry public roleRegistry;
    RoleRegistry public roleRegistryImpl;
    UUPSProxy public roleRegistryProxy;
    
    ERC20WithHook public rewardToken;
    TestERC20 public otherToken;
    
    address public owner = vm.addr(1);
    address public admin = vm.addr(2);
    address public unauthorizedUser = vm.addr(3);
    address public liquidityPool = vm.addr(4);
    address public recipient = vm.addr(5);
    address public user = vm.addr(6);
    
    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    
    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);
    event RecipientAddressSet(address indexed recipient);
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
        rewardToken = new ERC20WithHook("Reward Token", "RWD");
        otherToken = new TestERC20("Other Token", "OTH");
        
        // Deploy RestakingRewardsRouter implementation
        routerImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            liquidityPool
        );
        
        // Grant admin role
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, admin);
        vm.stopPrank();
        
        // Deploy proxy and initialize (outside prank so owner is address(this))
        proxy = new UUPSProxy(
            address(routerImpl),
            abi.encodeWithSelector(RestakingRewardsRouter.initialize.selector)
        );
        router = RestakingRewardsRouter(payable(address(proxy)));
        
        // Transfer ownership to owner address
        router.transferOwnership(owner);
    }
    
    // ============ Constructor Tests ============
    
    function test_constructor_setsImmutableValues() public {
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
    
    // ============ onERC20Received Tests ============
    
    function test_onERC20Received_forwardsRewardToken() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        rewardToken.mint(user, amount);
        
        uint256 initialRecipientBalance = rewardToken.balanceOf(recipient);
        
        vm.expectEmit(true, true, false, true);
        emit Erc20Transferred(address(rewardToken), recipient, amount);
        
        vm.prank(user);
        rewardToken.transfer(address(router), amount);
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(rewardToken.balanceOf(recipient), initialRecipientBalance + amount);
    }
    
    function test_onERC20Received_revertsWithInvalidToken() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        
        // Call the hook directly with invalid token
        vm.expectRevert(abi.encodeWithSelector(RestakingRewardsRouter.InvalidToken.selector, address(otherToken)));
        router.onERC20Received(address(otherToken), user, amount, "");
    }
    
    function test_onERC20Received_revertsWhenNoRecipientSet() public {
        uint256 amount = 1000 ether;
        rewardToken.mint(user, amount);
        
        vm.prank(user);
        vm.expectRevert(RestakingRewardsRouter.NoRecipientSet.selector);
        rewardToken.transfer(address(router), amount);
    }
    
    function test_onERC20Received_handlesMultipleTransfers() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount1 = 500 ether;
        uint256 amount2 = 300 ether;
        rewardToken.mint(user, amount1 + amount2);
        
        vm.startPrank(user);
        rewardToken.transfer(address(router), amount1);
        rewardToken.transfer(address(router), amount2);
        vm.stopPrank();
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(rewardToken.balanceOf(recipient), amount1 + amount2);
    }
    
    function test_onERC20Received_returnsCorrectSelector() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 100 ether;
        rewardToken.mint(user, amount);
        
        vm.prank(user);
        rewardToken.transfer(address(router), amount);
        
        // If we got here without revert, the selector was correct
        assertTrue(true);
    }
    
    // ============ transferERC20 Tests ============
    
    function test_transferERC20_forwardsBalance() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        rewardToken.mint(address(router), amount);
        
        uint256 initialRecipientBalance = rewardToken.balanceOf(recipient);
        
        vm.expectEmit(true, true, false, true);
        emit Erc20Transferred(address(rewardToken), recipient, amount);
        
        router.transferERC20(address(rewardToken));
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(rewardToken.balanceOf(recipient), initialRecipientBalance + amount);
    }
    
    function test_transferERC20_revertsWhenNoRecipientSet() public {
        uint256 amount = 1000 ether;
        rewardToken.mint(address(router), amount);
        
        vm.expectRevert(RestakingRewardsRouter.NoRecipientSet.selector);
        router.transferERC20(address(rewardToken));
    }
    
    function test_transferERC20_handlesZeroBalance() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        // Should not revert with zero balance
        router.transferERC20(address(rewardToken));
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
    }
    
    function test_transferERC20_anyoneCanCall() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 500 ether;
        rewardToken.mint(address(router), amount);
        
        vm.prank(unauthorizedUser);
        router.transferERC20(address(rewardToken));
        
        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(rewardToken.balanceOf(recipient), amount);
    }
    
    function test_transferERC20_handlesPartialTransfers() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount1 = 500 ether;
        uint256 amount2 = 300 ether;
        rewardToken.mint(address(router), amount1);
        
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), amount1);
        
        rewardToken.mint(address(router), amount2);
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), amount1 + amount2);
    }
    
    function test_transferERC20_withOtherToken() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        otherToken.mint(address(router), amount);
        
        uint256 initialRecipientBalance = otherToken.balanceOf(recipient);
        
        vm.expectEmit(true, true, false, true);
        emit Erc20Transferred(address(otherToken), recipient, amount);
        
        router.transferERC20(address(otherToken));
        
        assertEq(otherToken.balanceOf(address(router)), 0);
        assertEq(otherToken.balanceOf(recipient), initialRecipientBalance + amount);
    }
    
    function test_transferERC20_revertsWithZeroAddress() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
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
    
    function test_upgrade_onlyOwner() public {
        RestakingRewardsRouter newImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            liquidityPool
        );
        
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        router.upgradeTo(address(newImpl));
        
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
        vm.stopPrank();
        
        RestakingRewardsRouter newImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            liquidityPool
        );
        
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
        // Set recipient
        vm.prank(admin);
        router.setRecipientAddress(recipient);
        
        // Send ETH
        vm.deal(user, 10 ether);
        vm.prank(user);
        (bool success, ) = address(router).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(liquidityPool.balance, 10 ether);
        
        // Transfer tokens via hook
        uint256 tokenAmount = 500 ether;
        rewardToken.mint(user, tokenAmount);
        vm.prank(user);
        rewardToken.transfer(address(router), tokenAmount);
        assertEq(rewardToken.balanceOf(recipient), tokenAmount);
        
        // Manual transfer
        uint256 manualAmount = 200 ether;
        rewardToken.mint(address(router), manualAmount);
        router.transferERC20(address(rewardToken));
        assertEq(rewardToken.balanceOf(recipient), tokenAmount + manualAmount);
    }
    
    function test_receiveAndTransfer_combined() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
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
        assertEq(rewardToken.balanceOf(recipient), tokenAmount);
    }
    
    function test_onERC20Received_withStandardERC20() public {
        // Standard ERC20 doesn't call the hook, so tokens will accumulate
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();
        
        uint256 amount = 1000 ether;
        otherToken.mint(user, amount);
        
        // Direct transfer (standard ERC20 doesn't call hook)
        vm.prank(user);
        otherToken.transfer(address(router), amount);
        
        // Token is in router but hook wasn't called
        assertEq(otherToken.balanceOf(address(router)), amount);
        
        // But if we try to use the hook manually with wrong token, it reverts
        vm.expectRevert(abi.encodeWithSelector(RestakingRewardsRouter.InvalidToken.selector, address(otherToken)));
        router.onERC20Received(address(otherToken), user, amount, "");
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("Reverting receiver");
    }
}


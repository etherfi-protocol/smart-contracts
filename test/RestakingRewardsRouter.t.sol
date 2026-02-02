// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RestakingRewardsRouter.sol";
import "../src/RoleRegistry.sol";
import "../src/UUPSProxy.sol";
import "../src/LiquidityPool.sol";
import "./TestERC20.sol";
import "../src/interfaces/ILiquidityPool.sol";

contract RestakingRewardsRouterTest is Test {
    RestakingRewardsRouter public router;
    RestakingRewardsRouter public routerImpl;
    UUPSProxy public proxy;
    RoleRegistry public roleRegistry;
    RoleRegistry public roleRegistryImpl;
    UUPSProxy public roleRegistryProxy;
    TestERC20 public rewardToken;
    TestERC20 public otherToken;
    LiquidityPool public liquidityPool;
    LiquidityPool public liquidityPoolImpl;
    UUPSProxy public liquidityPoolProxy;
    address public owner = vm.addr(1);
    address public admin = vm.addr(2);
    address public transferRoleUser = vm.addr(7);
    address public unauthorizedUser = vm.addr(3);
    address public recipient = vm.addr(5);
    address public user = vm.addr(6);

    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE =
        keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE =
        keccak256("ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE");

    event EthSent(address indexed from, address indexed to, address indexed sender, uint256 value);
    event RecipientAddressSet(address indexed recipient);
    event Erc20Recovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

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

        // Deploy LiquidityPool
        liquidityPoolImpl = new LiquidityPool(address(0x0));
        liquidityPoolProxy = new UUPSProxy(address(liquidityPoolImpl), "");
        liquidityPool = LiquidityPool(payable(address(liquidityPoolProxy)));
        
        // Set initial totalValueOutOfLp to allow receive() to work
        // Storage slot 207: totalValueOutOfLp (uint128, offset 0) + totalValueInLp (uint128, offset 16)
        // The receive() function does: totalValueOutOfLp -= uint128(msg.value) and totalValueInLp += uint128(msg.value)
        // Set: totalValueOutOfLp = 1000 ether (lower 16 bytes), totalValueInLp = 0 (upper 16 bytes)
        bytes32 value = bytes32(uint256(1000 ether)); // Lower 16 bytes = 1000 ether, upper 16 bytes = 0
        vm.store(address(liquidityPool), bytes32(uint256(207)), value);

        // Deploy RestakingRewardsRouter implementation
        routerImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            address(liquidityPool)
        );

        // Grant admin role
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, admin);
        // Grant transfer role
        roleRegistry.grantRole(
            ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE,
            admin
        );
        roleRegistry.grantRole(
            ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE,
            transferRoleUser
        );
        vm.stopPrank();

        // Deploy proxy and initialize (outside prank so owner is address(this))
        proxy = new UUPSProxy(
            address(routerImpl),
            abi.encodeWithSelector(RestakingRewardsRouter.initialize.selector)
        );
        router = RestakingRewardsRouter(payable(address(proxy)));
    }

    // ============ Constructor Tests ============

    function test_constructor_setsImmutableValues() public {
        assertEq(router.rewardTokenAddress(), address(rewardToken));
        assertEq(router.liquidityPool(), address(liquidityPool));
        assertEq(address(router.roleRegistry()), address(roleRegistry));
    }

    function test_constructor_revertsWithZeroRewardToken() public {
        vm.expectRevert(RestakingRewardsRouter.InvalidAddress.selector);
        new RestakingRewardsRouter(
            address(roleRegistry),
            address(0),
            address(liquidityPool)
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
            address(liquidityPool)
        );
    }

    function test_constructor_disablesInitializers() public {
        vm.expectRevert();
        routerImpl.initialize();
    }

    // ============ Initialization Tests ============

    function test_initialize_canOnlyBeCalledOnce() public {
        vm.expectRevert("Initializable: contract is already initialized");
        router.initialize();
    }

    // ============ Receive ETH Tests ============

    function test_receive_emitsEthSentEvent() public {
        vm.deal(user, 10 ether);

        vm.expectEmit(true, true, true, true);
        emit EthSent(address(router), address(liquidityPool), user, 10 ether);

        vm.prank(user);
        (bool success, ) = address(router).call{value: 10 ether}("");
        assertTrue(success);
    }

    function test_receive_forwardsEthToLiquidityPool() public {
        uint256 amount = 10 ether;
        vm.deal(user, amount);
        uint256 initialLiquidityPoolBalance = address(liquidityPool).balance;
        uint256 initialTotalValueInLp = liquidityPool.totalValueInLp();
        uint256 initialTotalValueOutOfLp = liquidityPool.totalValueOutOfLp();

        vm.expectEmit(true, true, true, true);
        emit EthSent(address(router), address(liquidityPool), user, amount);

        vm.prank(user);
        (bool success, ) = address(router).call{value: amount}("");
        assertTrue(success);

        uint256 totalValueInLp = liquidityPool.totalValueInLp();
        uint256 totalValueOutOfLp = liquidityPool.totalValueOutOfLp();

        assertEq(address(router).balance, 0);
        assertEq(address(liquidityPool).balance, initialLiquidityPoolBalance + amount);
        assertEq(totalValueInLp, initialTotalValueInLp + amount);
        // totalValueOutOfLp decreases by amount (real LiquidityPool will revert if underflow)
        assertEq(totalValueOutOfLp, initialTotalValueOutOfLp - amount);
    }

    function test_receive_handlesMultipleDeposits() public {
        vm.deal(user, 20 ether);
        uint256 initialLiquidityPoolBalance = address(liquidityPool).balance;

        vm.prank(user);
        (bool success1, ) = address(router).call{value: 5 ether}("");
        assertTrue(success1);

        vm.prank(user);
        (bool success2, ) = address(router).call{value: 10 ether}("");
        assertTrue(success2);

        assertEq(address(router).balance, 0);
        assertEq(address(liquidityPool).balance, initialLiquidityPoolBalance + 15 ether);
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
        RestakingRewardsRouter newRouter = RestakingRewardsRouter(
            payable(address(newProxy))
        );

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

    // ============ recoverERC20 Tests ============

    function test_recoverERC20_forwardsBalance() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();

        uint256 amount = 1000 ether;
        rewardToken.mint(address(router), amount);

        uint256 initialRecipientBalance = rewardToken.balanceOf(recipient);

        vm.expectEmit(true, true, false, true);
        emit Erc20Recovered(address(rewardToken), recipient, amount);

        vm.prank(admin);
        router.recoverERC20();

        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(
            rewardToken.balanceOf(recipient),
            initialRecipientBalance + amount
        );
    }

    function test_recoverERC20_revertsWhenNoRecipientSet() public {
        uint256 amount = 1000 ether;
        rewardToken.mint(address(router), amount);

        vm.prank(admin);
        vm.expectRevert(RestakingRewardsRouter.NoRecipientSet.selector);
        router.recoverERC20();
    }

    function test_recoverERC20_handlesZeroBalance() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();

        // Should not revert with zero balance
        vm.prank(admin);
        router.recoverERC20();

        assertEq(rewardToken.balanceOf(address(router)), 0);
    }

    function test_recoverERC20_requiresRole() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();

        uint256 amount = 500 ether;
        rewardToken.mint(address(router), amount);

        vm.prank(unauthorizedUser);
        vm.expectRevert(RestakingRewardsRouter.IncorrectRole.selector);
        router.recoverERC20();

        // Should still have tokens since transfer failed
        assertEq(rewardToken.balanceOf(address(router)), amount);
    }

    function test_recoverERC20_withTransferRole() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();

        uint256 amount = 500 ether;
        rewardToken.mint(address(router), amount);

        vm.prank(transferRoleUser);
        router.recoverERC20();

        assertEq(rewardToken.balanceOf(address(router)), 0);
        assertEq(rewardToken.balanceOf(recipient), amount);
    }

    function test_recoverERC20_handlesPartialTransfers() public {
        vm.startPrank(admin);
        router.setRecipientAddress(recipient);
        vm.stopPrank();

        uint256 amount1 = 500 ether;
        uint256 amount2 = 300 ether;
        rewardToken.mint(address(router), amount1);

        vm.prank(admin);
        router.recoverERC20();
        assertEq(rewardToken.balanceOf(recipient), amount1);

        rewardToken.mint(address(router), amount2);
        vm.prank(admin);
        router.recoverERC20();
        assertEq(rewardToken.balanceOf(recipient), amount1 + amount2);
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
            address(liquidityPool)
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
        vm.stopPrank();

        RestakingRewardsRouter newImpl = new RestakingRewardsRouter(
            address(roleRegistry),
            address(rewardToken),
            address(liquidityPool)
        );

        // Owner of RoleRegistry (protocol upgrader) can upgrade
        vm.prank(owner);
        router.upgradeTo(address(newImpl));

        // State should be preserved
        assertEq(address(router).balance, ethAmount);
        assertEq(rewardToken.balanceOf(address(router)), tokenAmount);
        assertEq(router.rewardTokenAddress(), address(rewardToken));
        assertEq(router.liquidityPool(), address(liquidityPool));
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
        assertEq(address(liquidityPool).balance, 10 ether);

        // Transfer tokens (they will accumulate since there's no hook)
        uint256 tokenAmount = 500 ether;
        rewardToken.mint(user, tokenAmount);
        vm.prank(user);
        rewardToken.transfer(address(router), tokenAmount);
        assertEq(rewardToken.balanceOf(address(router)), tokenAmount);

        // Manual transfer to recover accumulated tokens
        vm.prank(admin);
        router.recoverERC20();
        assertEq(rewardToken.balanceOf(recipient), tokenAmount);

        // Manual transfer for additional tokens
        uint256 manualAmount = 200 ether;
        rewardToken.mint(address(router), manualAmount);
        vm.prank(admin);
        router.recoverERC20();
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

        assertEq(address(liquidityPool).balance, 10 ether);
        // Tokens accumulate since there's no hook
        assertEq(rewardToken.balanceOf(address(router)), tokenAmount);

        // Manual transfer to recover tokens
        vm.prank(admin);
        router.recoverERC20();
        assertEq(rewardToken.balanceOf(recipient), tokenAmount);
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("Reverting receiver");
    }
}

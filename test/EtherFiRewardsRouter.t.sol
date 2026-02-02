// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EtherFiRewardsRouter.sol";
import "../src/RoleRegistry.sol";
import "../src/UUPSProxy.sol";
import "./TestERC20.sol";
import "./TestERC721.sol";

contract MockLiquidityPool {
    uint128 public totalValueOutOfLp;

    function setTotalValueOutOfLp(uint128 _value) external {
        totalValueOutOfLp = _value;
    }

    receive() external payable {}
}

contract EtherFiRewardsRouterTest is Test {
    EtherFiRewardsRouter public rewardsRouter;
    EtherFiRewardsRouter public rewardsRouterImpl;
    UUPSProxy public proxy;
    RoleRegistry public roleRegistry;
    RoleRegistry public roleRegistryImpl;
    UUPSProxy public roleRegistryProxy;

    MockLiquidityPool public mockLiquidityPool;
    
    TestERC20 public testToken;
    TestERC721 public testNFT;
    
    address public owner = vm.addr(1);
    address public admin = vm.addr(2);
    address public unauthorizedUser = vm.addr(3);
    address public liquidityPool;
    address public treasury = vm.addr(5);
    address public user = vm.addr(6);
    
    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    
    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);
    event Erc20Sent(address indexed caller, address indexed token, uint256 amount);
    event Erc721Sent(address indexed caller, address indexed token, uint256 tokenId);
    
    function setUp() public {
        // Deploy RoleRegistry
        vm.startPrank(owner);
        roleRegistryImpl = new RoleRegistry();
        roleRegistryProxy = new UUPSProxy(
            address(roleRegistryImpl),
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        );
        roleRegistry = RoleRegistry(address(roleRegistryProxy));

        mockLiquidityPool = new MockLiquidityPool();
        liquidityPool = address(mockLiquidityPool);
        
        // Deploy EtherFiRewardsRouter implementation
        rewardsRouterImpl = new EtherFiRewardsRouter(
            liquidityPool,
            treasury,
            address(roleRegistry)
        );
        
        // Grant admin role
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, admin);
        vm.stopPrank();
        
        // Deploy proxy and initialize (outside prank so owner is address(this))
        proxy = new UUPSProxy(
            address(rewardsRouterImpl),
            abi.encodeWithSelector(EtherFiRewardsRouter.initialize.selector)
        );
        rewardsRouter = EtherFiRewardsRouter(payable(address(proxy)));
        
        // Transfer ownership to owner address
        rewardsRouter.transferOwnership(owner);
        
        // Deploy test tokens
        testToken = new TestERC20("Test Token", "TEST");
        testNFT = new TestERC721("Test NFT", "TNFT");
        
        // Mint tokens to router for recovery tests
        testToken.mint(address(rewardsRouter), 1000 ether);
        testNFT.mint(address(rewardsRouter));
    }
    
    // ============ Constructor Tests ============
    
    function test_constructor_setsImmutableValues() public {
        assertEq(rewardsRouter.liquidityPool(), liquidityPool);
        assertEq(rewardsRouter.treasury(), treasury);
        assertEq(address(rewardsRouter.roleRegistry()), address(roleRegistry));
    }
    
    function test_constructor_disablesInitializers() public {
        vm.expectRevert();
        rewardsRouterImpl.initialize();
    }
    
    // ============ Initialization Tests ============
    
    function test_initialize_setsOwner() public {
        // Owner is transferred to owner address in setUp
        assertEq(rewardsRouter.owner(), owner);
    }
    
    function test_initialize_canOnlyBeCalledOnce() public {
        vm.expectRevert();
        rewardsRouter.initialize();
    }
    
    // ============ Receive ETH Tests ============
    
    function test_receive_emitsEthReceivedEvent() public {
        vm.deal(user, 10 ether);
        
        vm.expectEmit(true, false, false, true);
        emit EthReceived(user, 10 ether);
        
        vm.prank(user);
        (bool success, ) = address(rewardsRouter).call{value: 10 ether}("");
        assertTrue(success);
    }
    
    function test_receive_increasesContractBalance() public {
        uint256 initialBalance = address(rewardsRouter).balance;
        
        vm.deal(user, 10 ether);
        vm.prank(user);
        (bool success, ) = address(rewardsRouter).call{value: 10 ether}("");
        assertTrue(success);
        
        assertEq(address(rewardsRouter).balance, initialBalance + 10 ether);
    }
    
    function test_receive_handlesMultipleDeposits() public {
        vm.deal(user, 20 ether);
        
        vm.prank(user);
        (bool success1, ) = address(rewardsRouter).call{value: 5 ether}("");
        assertTrue(success1);
        
        vm.prank(user);
        (bool success2, ) = address(rewardsRouter).call{value: 10 ether}("");
        assertTrue(success2);
        
        assertEq(address(rewardsRouter).balance, 15 ether);
    }
    
    // ============ Withdraw to Liquidity Pool Tests ============
    
    function test_withdrawToLiquidityPool_success() public {
        uint256 amount = 10 ether;
        vm.deal(address(rewardsRouter), amount);
        
        // Set totalValueOutOfLp to allow full withdrawal
        mockLiquidityPool.setTotalValueOutOfLp(uint128(amount));
        
        uint256 initialLiquidityPoolBalance = liquidityPool.balance;
        
        vm.expectEmit(true, true, false, true);
        emit EthSent(address(rewardsRouter), liquidityPool, amount);
        
        rewardsRouter.withdrawToLiquidityPool();
        
        assertEq(address(rewardsRouter).balance, 0);
        assertEq(liquidityPool.balance, initialLiquidityPoolBalance + amount);
    }

    function test_withdrawToLiquidityPool_cappedByTotalValueOutOfLp() public {
        uint256 contractBalance = 10 ether;
        uint128 totalValueOutOfLpAmount = 3 ether;
        vm.deal(address(rewardsRouter), contractBalance);
        
        mockLiquidityPool.setTotalValueOutOfLp(totalValueOutOfLpAmount);
        
        uint256 initialLiquidityPoolBalance = liquidityPool.balance;
        
        vm.expectEmit(true, true, false, true);
        emit EthSent(address(rewardsRouter), liquidityPool, totalValueOutOfLpAmount);
        
        rewardsRouter.withdrawToLiquidityPool();
        
        // Only totalValueOutOfLp amount should be withdrawn
        assertEq(address(rewardsRouter).balance, contractBalance - totalValueOutOfLpAmount);
        assertEq(liquidityPool.balance, initialLiquidityPoolBalance + totalValueOutOfLpAmount);
    }
    
    function test_withdrawToLiquidityPool_revertsWhenBalanceIsZero() public {
        assertEq(address(rewardsRouter).balance, 0);
        
        // Even with high totalValueOutOfLp, should revert if contract balance is 0
        mockLiquidityPool.setTotalValueOutOfLp(type(uint128).max);
        
        vm.expectRevert("Contract balance is zero");
        rewardsRouter.withdrawToLiquidityPool();
    }

    function test_withdrawToLiquidityPool_revertsWhenTotalValueOutOfLpIsZero() public {
        uint256 amount = 5 ether;
        vm.deal(address(rewardsRouter), amount);
        
        // totalValueOutOfLp is 0, so min(balance, 0) = 0
        mockLiquidityPool.setTotalValueOutOfLp(0);
        
        vm.expectRevert("Contract balance is zero");
        rewardsRouter.withdrawToLiquidityPool();
    }
    
    function test_withdrawToLiquidityPool_anyoneCanCall() public {
        uint256 amount = 5 ether;
        vm.deal(address(rewardsRouter), amount);
        
        mockLiquidityPool.setTotalValueOutOfLp(uint128(amount));
        
        vm.prank(unauthorizedUser);
        rewardsRouter.withdrawToLiquidityPool();
        
        assertEq(address(rewardsRouter).balance, 0);
        assertEq(liquidityPool.balance, amount);
    }
    
    function test_withdrawToLiquidityPool_withdrawsFullBalance() public {
        uint256 amount1 = 5 ether;
        uint256 amount2 = 3 ether;
        vm.deal(address(rewardsRouter), amount1 + amount2);
        
        mockLiquidityPool.setTotalValueOutOfLp(uint128(amount1 + amount2));
        
        uint256 balanceBefore = address(rewardsRouter).balance;
        rewardsRouter.withdrawToLiquidityPool();
        
        assertEq(address(rewardsRouter).balance, 0);
        assertEq(liquidityPool.balance, balanceBefore);
    }
        
    // ============ Recover ERC20 Tests ============
    
    function test_recoverERC20_success() public {
        uint256 amount = 500 ether;
        // Clear existing balance first
        uint256 existingBalance = testToken.balanceOf(address(rewardsRouter));
        if (existingBalance > 0) {
            vm.prank(admin);
            rewardsRouter.recoverERC20(address(testToken), existingBalance);
        }
        
        testToken.mint(address(rewardsRouter), amount);
        
        uint256 initialTreasuryBalance = testToken.balanceOf(treasury);
        
        vm.expectEmit(true, true, false, true);
        emit Erc20Sent(admin, address(testToken), amount);
        
        vm.prank(admin);
        rewardsRouter.recoverERC20(address(testToken), amount);
        
        assertEq(testToken.balanceOf(address(rewardsRouter)), 0);
        assertEq(testToken.balanceOf(treasury), initialTreasuryBalance + amount);
    }
    
    function test_recoverERC20_revertsWithoutRole() public {
        uint256 amount = 100 ether;
        
        vm.prank(unauthorizedUser);
        vm.expectRevert(EtherFiRewardsRouter.IncorrectRole.selector);
        rewardsRouter.recoverERC20(address(testToken), amount);
    }
    
    function test_recoverERC20_partialRecovery() public {
        // Clear existing balance first
        uint256 existingBalance = testToken.balanceOf(address(rewardsRouter));
        if (existingBalance > 0) {
            vm.prank(admin);
            rewardsRouter.recoverERC20(address(testToken), existingBalance);
        }
        
        uint256 totalAmount = 1000 ether;
        uint256 recoverAmount = 300 ether;
        
        testToken.mint(address(rewardsRouter), totalAmount);
        
        uint256 initialTreasuryBalance = testToken.balanceOf(treasury);
        
        vm.prank(admin);
        rewardsRouter.recoverERC20(address(testToken), recoverAmount);
        
        assertEq(testToken.balanceOf(address(rewardsRouter)), totalAmount - recoverAmount);
        assertEq(testToken.balanceOf(treasury), initialTreasuryBalance + recoverAmount);
    }
    
    function test_recoverERC20_multipleTokens() public {
        TestERC20 token2 = new TestERC20("Token 2", "T2");
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;
        
        testToken.mint(address(rewardsRouter), amount1);
        token2.mint(address(rewardsRouter), amount2);
        
        vm.startPrank(admin);
        rewardsRouter.recoverERC20(address(testToken), amount1);
        rewardsRouter.recoverERC20(address(token2), amount2);
        vm.stopPrank();
        
        assertEq(testToken.balanceOf(treasury), amount1);
        assertEq(token2.balanceOf(treasury), amount2);
    }
    
    function test_recoverERC20_zeroAmount() public {
        vm.prank(admin);
        // Should not revert, just transfer 0
        rewardsRouter.recoverERC20(address(testToken), 0);
        
        assertEq(testToken.balanceOf(treasury), 0);
    }
    
    // ============ Recover ERC721 Tests ============
    
    function test_recoverERC721_success() public {
        uint256 tokenId = testNFT.mint(address(rewardsRouter));
        
        vm.expectEmit(true, true, false, true);
        emit Erc721Sent(admin, address(testNFT), tokenId);
        
        vm.prank(admin);
        rewardsRouter.recoverERC721(address(testNFT), tokenId);
        
        assertEq(testNFT.ownerOf(tokenId), treasury);
    }
    
    function test_recoverERC721_revertsWithoutRole() public {
        uint256 tokenId = testNFT.mint(address(rewardsRouter));
        
        vm.prank(unauthorizedUser);
        vm.expectRevert(EtherFiRewardsRouter.IncorrectRole.selector);
        rewardsRouter.recoverERC721(address(testNFT), tokenId);
    }
    
    function test_recoverERC721_multipleTokens() public {
        uint256 tokenId1 = testNFT.mint(address(rewardsRouter));
        uint256 tokenId2 = testNFT.mint(address(rewardsRouter));
        
        vm.startPrank(admin);
        rewardsRouter.recoverERC721(address(testNFT), tokenId1);
        rewardsRouter.recoverERC721(address(testNFT), tokenId2);
        vm.stopPrank();
        
        assertEq(testNFT.ownerOf(tokenId1), treasury);
        assertEq(testNFT.ownerOf(tokenId2), treasury);
    }
    
    function test_recoverERC721_differentNFTs() public {
        TestERC721 nft2 = new TestERC721("NFT 2", "N2");
        uint256 tokenId1 = testNFT.mint(address(rewardsRouter));
        uint256 tokenId2 = nft2.mint(address(rewardsRouter));
        
        vm.startPrank(admin);
        rewardsRouter.recoverERC721(address(testNFT), tokenId1);
        rewardsRouter.recoverERC721(address(nft2), tokenId2);
        vm.stopPrank();
        
        assertEq(testNFT.ownerOf(tokenId1), treasury);
        assertEq(nft2.ownerOf(tokenId2), treasury);
    }
    
    // ============ Role Management Tests ============
    
    function test_roleManagement_grantAndRevoke() public {
        address newAdmin = vm.addr(100);
        
        // Grant role
        vm.prank(owner);
        roleRegistry.grantRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, newAdmin);
        
        uint256 amount = 100 ether;
        testToken.mint(address(rewardsRouter), amount);
        
        vm.prank(newAdmin);
        rewardsRouter.recoverERC20(address(testToken), amount);
        
        assertEq(testToken.balanceOf(treasury), amount);
        
        // Revoke role
        vm.prank(owner);
        roleRegistry.revokeRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, newAdmin);
        
        testToken.mint(address(rewardsRouter), amount);
        vm.prank(newAdmin);
        vm.expectRevert(EtherFiRewardsRouter.IncorrectRole.selector);
        rewardsRouter.recoverERC20(address(testToken), amount);
    }
    
    // ============ Upgrade Tests ============
    
    function test_upgrade_onlyOwner() public {
        EtherFiRewardsRouter newImpl = new EtherFiRewardsRouter(
            liquidityPool,
            treasury,
            address(roleRegistry)
        );
        
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        rewardsRouter.upgradeTo(address(newImpl));
        
        vm.prank(owner);
        rewardsRouter.upgradeTo(address(newImpl));
        
        assertEq(rewardsRouter.getImplementation(), address(newImpl));
    }
    
    function test_getImplementation_returnsCurrentImplementation() public {
        address impl = rewardsRouter.getImplementation();
        assertEq(impl, address(rewardsRouterImpl));
    }
    
    function test_upgrade_preservesState() public {
        // Set up some state
        uint256 ethAmount = 5 ether;
        uint256 tokenAmount = 100 ether;
        vm.deal(address(rewardsRouter), ethAmount);
        
        // Clear existing token balance first
        uint256 existingBalance = testToken.balanceOf(address(rewardsRouter));
        if (existingBalance > 0) {
            vm.prank(admin);
            rewardsRouter.recoverERC20(address(testToken), existingBalance);
        }
        
        testToken.mint(address(rewardsRouter), tokenAmount);
        
        EtherFiRewardsRouter newImpl = new EtherFiRewardsRouter(
            liquidityPool,
            treasury,
            address(roleRegistry)
        );
        
        vm.prank(owner);
        rewardsRouter.upgradeTo(address(newImpl));
        
        // State should be preserved
        assertEq(address(rewardsRouter).balance, ethAmount);
        assertEq(testToken.balanceOf(address(rewardsRouter)), tokenAmount);
        assertEq(rewardsRouter.liquidityPool(), liquidityPool);
        assertEq(rewardsRouter.treasury(), treasury);
    }
    
    // ============ Edge Cases ============
    
    function test_recoverERC20_moreThanBalance() public {
        uint256 balance = testToken.balanceOf(address(rewardsRouter));
        uint256 excessAmount = balance + 1 ether;
        
        vm.prank(admin);
        // Should revert due to SafeERC20
        vm.expectRevert();
        rewardsRouter.recoverERC20(address(testToken), excessAmount);
    }
    
    function test_recoverERC721_tokenNotOwned() public {
        uint256 tokenId = 9999; // Token that doesn't exist
        
        vm.prank(admin);
        vm.expectRevert();
        rewardsRouter.recoverERC721(address(testNFT), tokenId);
    }
    
    function test_withdrawToLiquidityPool_afterERC20Recovery() public {
        uint256 ethAmount = 10 ether;
        uint256 tokenAmount = 100 ether;
        
        vm.deal(address(rewardsRouter), ethAmount);
        testToken.mint(address(rewardsRouter), tokenAmount);
        
        mockLiquidityPool.setTotalValueOutOfLp(uint128(ethAmount));
        
        // Recover ERC20 first
        vm.prank(admin);
        rewardsRouter.recoverERC20(address(testToken), tokenAmount);
        
        // Then withdraw ETH
        rewardsRouter.withdrawToLiquidityPool();
        
        assertEq(address(rewardsRouter).balance, 0);
        assertEq(liquidityPool.balance, ethAmount);
    }
    
    function test_multipleOperations_sequence() public {
        // Clear existing token balance first
        uint256 existingBalance = testToken.balanceOf(address(rewardsRouter));
        if (existingBalance > 0) {
            vm.prank(admin);
            rewardsRouter.recoverERC20(address(testToken), existingBalance);
        }
        
        // Clear existing NFT
        try testNFT.ownerOf(0) returns (address ownerOfToken) {
            if (ownerOfToken == address(rewardsRouter)) {
                vm.prank(admin);
                rewardsRouter.recoverERC721(address(testNFT), 0);
            }
        } catch {}
        
        // Send ETH
        vm.deal(user, 10 ether);
        vm.prank(user);
        (bool success, ) = address(rewardsRouter).call{value: 10 ether}("");
        assertTrue(success);
        
        // Mint tokens
        testToken.mint(address(rewardsRouter), 500 ether);
        uint256 tokenId = testNFT.mint(address(rewardsRouter));
        
        // Set totalValueOutOfLp to allow full withdrawal
        mockLiquidityPool.setTotalValueOutOfLp(uint128(10 ether));
        
        // Withdraw ETH
        rewardsRouter.withdrawToLiquidityPool();
        assertEq(address(rewardsRouter).balance, 0);
        
        // Recover tokens
        uint256 initialTreasuryBalance = testToken.balanceOf(treasury);
        vm.startPrank(admin);
        rewardsRouter.recoverERC20(address(testToken), 500 ether);
        rewardsRouter.recoverERC721(address(testNFT), tokenId);
        vm.stopPrank();
        
        assertEq(testToken.balanceOf(address(rewardsRouter)), 0);
        assertEq(testToken.balanceOf(treasury), initialTreasuryBalance + 500 ether);
        assertEq(testNFT.ownerOf(tokenId), treasury);
    }
}
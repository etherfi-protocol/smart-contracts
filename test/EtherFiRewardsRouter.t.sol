import "./TestSetup.sol";
import "../src/EtherFiRewardsRouter.sol";
import "../src/LiquidityPool.sol";
import "forge-std/console2.sol";

contract EtherFiRewardsRouterTest is TestSetup {

    address liquidityPoolAddress;
    EtherFiRewardsRouter etherfiRewardsRouterImplementation;
    UUPSProxy etherfiRewardsRouterProxy;
    EtherFiRewardsRouter etherfiRewardsRouterInstance;

    function get_eeth() public {
        vm.startPrank(address(etherfiRewardsRouterInstance));
        vm.deal(address(etherfiRewardsRouterInstance), 10 ether);
        liquidityPoolInstance.deposit{value: 2 ether}();
        vm.stopPrank();
    } 

    function setUp() public {
        setUpTests();
        initializeRealisticFork(MAINNET_FORK);
        vm.startPrank(superAdmin);
        etherfiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), address(roleRegistry));
        etherfiRewardsRouterProxy = new UUPSProxy(address(etherfiRewardsRouterImplementation), "");
        etherfiRewardsRouterInstance = EtherFiRewardsRouter(payable(address(etherfiRewardsRouterProxy)));
        etherfiRewardsRouterInstance.initialize();
        vm.startPrank(superAdmin);
        roleRegistry.grantRole(etherfiRewardsRouterInstance.ETHERFI_ROUTER_ADMIN(), admin);
        etherfiRewardsRouterInstance.transferOwnership(owner);
        vm.stopPrank();
        vm.startPrank(owner);
        etherfiRewardsRouterInstance.setTreasury(address(treasuryInstance));
        vm.stopPrank();

        liquidityPoolAddress = address(liquidityPoolInstance);
        vm.deal(address(etherfiRewardsRouterInstance), 10 ether);
        vm.stopPrank(); 
    }

    function test_withdrawToLiquidityPool() public {
        vm.startPrank(admin);
        uint256 lpBalanceBefore = address(liquidityPoolAddress).balance;
        etherfiRewardsRouterInstance.withdrawToLiquidityPool();
        uint256 lpBalanceAfter = address(liquidityPoolAddress).balance;
        assertEq(lpBalanceAfter, lpBalanceBefore + 10 ether);
        vm.stopPrank();
    }

    function test_elRouterUpgrade() public {
        vm.startPrank(owner);
        EtherFiRewardsRouter newEtherfiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), address(roleRegistry));
        address oldImplementation = etherfiRewardsRouterInstance.getImplementation();
        etherfiRewardsRouterInstance.upgradeTo(address(newEtherfiRewardsRouterImplementation));
        address newImplementation = etherfiRewardsRouterInstance.getImplementation();
        assert(newImplementation != oldImplementation);
        assert(newImplementation == address(newEtherfiRewardsRouterImplementation));
        test_withdrawToLiquidityPool();
        vm.stopPrank();
    } 

    function test_checkEventEmitted() public {
        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit EtherFiRewardsRouter.EthSent(address(etherfiRewardsRouterInstance), liquidityPoolAddress, 10 ether);
        etherfiRewardsRouterInstance.withdrawToLiquidityPool();
        vm.stopPrank();
    }

    function test_recoverERC20() public {
        get_eeth();
        vm.startPrank(admin);
        uint256 balanceBefore = eETHInstance.balanceOf(address(treasuryInstance));
        etherfiRewardsRouterInstance.recoverERC20(address(eETHInstance), 1 ether);
        uint256 balanceAfter = eETHInstance.balanceOf(address(treasuryInstance));
        console.log("balanceBefore: ", balanceBefore);
        console.log("balanceAfter: ", balanceAfter);
        assertApproxEqAbs(balanceAfter, balanceBefore + 1 ether, 1);
    }

    function test_setTreasury() public {
        vm.startPrank(owner);
        etherfiRewardsRouterInstance.setTreasury(alice);
        assertEq(etherfiRewardsRouterInstance.treasury(), alice);
    } 

    function test_setTreasuryFailure() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        etherfiRewardsRouterInstance.setTreasury(alice);
    } 
}
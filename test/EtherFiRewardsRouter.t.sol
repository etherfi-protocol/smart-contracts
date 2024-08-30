import "./TestSetup.sol";
import "../src/EtherFiRewardsRouter.sol";
import "../src/LiquidityPool.sol";

contract EtherFiRewardsRouterTest is TestSetup {

    address liquidityPoolAddress;
    EtherFiRewardsRouter etherfiRewardsRouterImplementation;
    UUPSProxy etherfiRewardsRouterProxy;
    EtherFiRewardsRouter etherfiRewardsRouterInstance;


    function setUp() public {
        setUpTests();
        initializeRealisticFork(MAINNET_FORK);
        vm.startPrank(owner);
        etherfiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), admin);
        etherfiRewardsRouterProxy = new UUPSProxy(address(etherfiRewardsRouterImplementation), "");
        etherfiRewardsRouterInstance = EtherFiRewardsRouter(payable(address(etherfiRewardsRouterProxy)));
        etherfiRewardsRouterInstance.initialize();
        vm.startPrank(superAdmin);
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
        EtherFiRewardsRouter newEtherfiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), admin);
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
}
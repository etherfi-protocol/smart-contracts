import "./TestSetup.sol";
import "../src/ExecutionRewardRouter.sol";
import "../src/LiquidityPool.sol";

contract ExecutionRewardRouterTest is TestSetup {

    address liquidityPoolAddress;
    EtherFiExecutionLayerRewardsRouter elRewardRouterImplementation;
    UUPSProxy elRewardRouterProxy;
    EtherFiExecutionLayerRewardsRouter elRewardRouterInstance;


    function setUp() public {
        setUpTests();
        initializeRealisticFork(MAINNET_FORK);
        vm.startPrank(owner);
        elRewardRouterImplementation = new EtherFiExecutionLayerRewardsRouter();
        elRewardRouterProxy = new UUPSProxy(address(elRewardRouterImplementation), "");
        elRewardRouterInstance = EtherFiExecutionLayerRewardsRouter(address(elRewardRouterProxy));
        elRewardRouterInstance.initialize(address(liquidityPoolInstance));
        liquidityPoolAddress = address(liquidityPoolInstance);
        vm.deal(address(elRewardRouterInstance), 10 ether);
        vm.stopPrank(); 
    }

    function test_transferToLiquidityPool() public {
        uint256 lpBalanceBefore = address(liquidityPoolAddress).balance;
        elRewardRouterInstance.transferToLiquidityPool();
        uint256 lpBalanceAfter = address(liquidityPoolAddress).balance;
        assertEq(lpBalanceAfter, lpBalanceBefore + 10 ether);
    }

    function test_setLiquidityPoolAddress() public {
        liquidityPoolAddress = address(0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848);
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        elRewardRouterInstance.setLiquidityPoolAddress(liquidityPoolAddress);
        vm.startPrank(owner);
        elRewardRouterInstance.transferToLiquidityPool();
        vm.stopPrank(); 
    }

    function test_elRouterUpgrade() public {
        vm.startPrank(owner);
        EtherFiExecutionLayerRewardsRouter newELRewardRouterImplementation = new EtherFiExecutionLayerRewardsRouter();
        address oldImplementation = elRewardRouterInstance.getImplementation();
        elRewardRouterInstance.upgradeTo(address(newELRewardRouterImplementation));
        address newImplementation = elRewardRouterInstance.getImplementation();
        assert(newImplementation != oldImplementation);
        assert(newImplementation == address(newELRewardRouterImplementation));
        test_transferToLiquidityPool();
        vm.stopPrank();
    } 

    function test_checkEventEmitted() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit EtherFiExecutionLayerRewardsRouter.TransferToLiquidityPool(address(elRewardRouterInstance), liquidityPoolAddress, 10 ether);
        elRewardRouterInstance.transferToLiquidityPool();
        vm.stopPrank();
    }  
}
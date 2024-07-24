import "./TestSetup.sol";
import "forge-std/console2.sol";
import "../src/LiquidityPool.sol";  

contract eethPayoutUpgradeTest is TestSetup {
    address treasury;
    address lpAdmin;

    function setUp() public {
        setUpTests();
        initializeRealisticFork(MAINNET_FORK);
        treasury = address(alice);
        LiquidityPool newLiquidityImplementation = new LiquidityPool(); 
        lpAdmin = address(bob);
        vm.startPrank(liquidityPoolInstance.owner());
        liquidityPoolInstance.upgradeTo(address(newLiquidityImplementation));
        liquidityPoolInstance.setTreasury(alice);    
        vm.stopPrank();
    }

    function test_sanity() public {
        uint256[] memory validatorIds = new uint256[](5);
        uint256[] memory beaconBalances = new uint256[](5);
        uint256 rewards = 1 ether / 10;
        for(uint256 i = 0; i < 5; i++) {
            validatorIds[i] = i + 200;
            beaconBalances[i] = 32 ether + rewards;
        }
        vm.startPrank(address(liquidityPoolInstance.owner()));
        liquidityPoolInstance.mintShareOnChangeSplit(validatorIds, beaconBalances);
        vm.stopPrank();
    }
    
    function test_migration() public {
        assert(1 == 1);

    }
}
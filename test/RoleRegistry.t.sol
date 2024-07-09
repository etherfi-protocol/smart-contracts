import "./TestSetup.sol";
import "forge-std/console2.sol";

contract RoleRegistryTest is TestSetup {
   function setUp() public {
        setUpTests();
    }

    function test_DisableInitializer() public {
        vm.expectRevert("Initalizable: contract is already initialized");
        vm.prank(owner);
        BNFTImplementation.initialize(address(stakingManagerInstance));
    }

    function test_initializeSuperAdmin() public {

        RoleRegistry roleRegistryImplementation = new RoleRegistry();
        RoleRegistry roleRegistry;

        bytes memory initializerData =  abi.encodeWithSelector(RoleRegistry.initialize.selector, admin);
        roleRegistry = RoleRegistry(address(new UUPSProxy(address(roleRegistryImplementation), initializerData)));

        // admin should have DEFAULT_ADMIN_ROLE
        assert(roleRegistry.hasRole(roleRegistry.DEFAULT_ADMIN_ROLE(), admin));

        // random user should not
        assert(!roleRegistry.hasRole(roleRegistry.DEFAULT_ADMIN_ROLE(), bob));

        console2.log("admin", admin);
        //console2.logBytes32(roleRegistry.getRoleAdmin(keccak256("PROPOSER_ROLE")));
        console2.logBytes32(roleRegistry.getRoleAdmin(roleRegistry.DEFAULT_ADMIN_ROLE()));
        //console2.log(roleRegistry.getRoleAdmin(roleRegistry.DEFAULT_ADMIN_ROLE()));

        /*
                    abi.encodeWithSelector(
                        DummyTokenUpgradeable.initialize.selector, name, symbol, deployer
                    )
                    */

    }

}

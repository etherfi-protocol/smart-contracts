import "./TestSetup.sol";
import "forge-std/console2.sol";

contract RoleRegistryTest is TestSetup {
   function setUp() public {
        setUpTests();
    }

    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    function test_DisableInitializer() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        BNFTImplementation.initialize(address(stakingManagerInstance));
    }

    function test_initializeSuperAdmin() public {

        roleRegistryImplementation = new RoleRegistry();

        // foundry doesn't detect the emit for some reason, maybe because its part of a constructor,
        // but I see the expected values in the trace if I crank logging up
        /*
            vm.expectEmit(true, true, false, false);
            emit RoleGranted(0x00, admin, admin);
        */

        bytes memory initializerData =  abi.encodeWithSelector(RoleRegistry.initialize.selector, admin);
        roleRegistry = RoleRegistry(address(new UUPSProxy(address(roleRegistryImplementation), initializerData)));

        // admin should have DEFAULT_ADMIN_ROLE
        assert(roleRegistry.hasRole(roleRegistry.DEFAULT_ADMIN_ROLE(), admin));

        // random user should not
        assert(!roleRegistry.hasRole(roleRegistry.DEFAULT_ADMIN_ROLE(), bob));

        // can't re-initialize
        vm.expectRevert("Initializable: contract is already initialized");
        roleRegistry.initialize(bob);
    }

    function test_renounceRole() public {
        bytes32 SANDWICH_MAKER_ROLE = keccak256("SANDWICH_MAKER_ROLE");

        vm.prank(admin);
        roleRegistry.grantRole(SANDWICH_MAKER_ROLE, bob);
        assert(roleRegistry.hasRole(SANDWICH_MAKER_ROLE, bob));

        // can't renounce on behalf of someone else
        vm.expectRevert();
        roleRegistry.renounceRole(SANDWICH_MAKER_ROLE, bob);

        vm.prank(bob);
        roleRegistry.renounceRole(SANDWICH_MAKER_ROLE, bob);
        assert(!roleRegistry.hasRole(SANDWICH_MAKER_ROLE, bob));
    }

    function test_setupNewRole() public {
        bytes32 TOKEN_PAMPER_ROLE = keccak256("TOKEN_PAMPER");
        bytes32 TOKEN_PAMPER_ADMIN_ROLE = keccak256("TOKEN_PAMPER_ADMIN");

        // bob can't give role to self because not default admin
        vm.prank(bob);
        vm.expectRevert("AccessControl: account 0x6813eb9362372eef6200f3b1dbc3f819671cba69 is missing role 0x0000000000000000000000000000000000000000000000000000000000000000");
        roleRegistry.grantRole(TOKEN_PAMPER_ROLE, bob);

        // admin grants bob the role
        vm.prank(admin);
        roleRegistry.grantRole(TOKEN_PAMPER_ROLE, bob);
        assert(roleRegistry.hasRole(TOKEN_PAMPER_ROLE, bob));

        // admin gives control over the role to a new role
        vm.prank(admin);
        roleRegistry.setRoleAdmin(TOKEN_PAMPER_ROLE, TOKEN_PAMPER_ADMIN_ROLE);

        // admin no longer has permission to manage this role
        vm.expectRevert();
        vm.prank(admin);
        roleRegistry.grantRole(TOKEN_PAMPER_ROLE, bob);

        // give chad the new admin role
        vm.prank(admin);
        roleRegistry.grantRole(TOKEN_PAMPER_ADMIN_ROLE, chad);

        // chad should be able to grant child role to dan
        vm.prank(chad);
        roleRegistry.grantRole(TOKEN_PAMPER_ROLE, dan);

        // but shouldn't be able to grant others the admin role
        vm.expectRevert();
        vm.prank(chad);
        roleRegistry.grantRole(TOKEN_PAMPER_ADMIN_ROLE, dan);

        // chad should be able to revoke the role
        assert(roleRegistry.hasRole(TOKEN_PAMPER_ROLE, dan));
        vm.prank(chad);
        roleRegistry.revokeRole(TOKEN_PAMPER_ROLE, dan);
        assert(!roleRegistry.hasRole(TOKEN_PAMPER_ROLE, dan));

    }



}

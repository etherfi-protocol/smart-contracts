// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/Pauser.sol";

contract PauserTest is TestSetup {
    uint256 public constant INITIAL_DELAY = 1200; // 20 minutes
    Pauser pauser;
    IPausable[] initialPausables;

    function setUp() public {
        setUpTests();
        
        // deploy+initialize the pauser
        Pauser pauserImplementation = new Pauser();
        initialPausables.push(IPausable(address(liquifierInstance)));
        initialPausables.push(IPausable(address(etherFiOracleInstance)));
        
        bytes memory initializerData = abi.encodeWithSelector(Pauser.initialize.selector, initialPausables, INITIAL_DELAY,  address(roleRegistry));
        pauser = Pauser(address(new UUPSProxy(address(pauserImplementation), initializerData)));

        // giving the pauser contract the permissions it needs to pause and unpause the contracts
        // TODO: refactor to integrate with `RoleRegistry` tests once the configuration plan is planned
        vm.startPrank(owner);
        etherFiOracleInstance.updateAdmin(address(pauser), true);
        auctionInstance.updateAdmin(address(pauser), true);

        // setting contract roles
        vm.startPrank(admin);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER(), address(pauser));
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER(), address(pauser));
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER(), alice);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER(), alice);
        roleRegistry.grantRole(pauser.PAUSER_ADMIN(), alice);
        vm.startPrank(alice);
    }

    function test_singlePause() public {
        // pausing the `liquifier` and `etherFiOracle`
        pauser.pauseSingle(IPausable(address(liquifierInstance)));
        pauser.pauseSingle(IPausable(address(etherFiOracleInstance)));
        assertTrue(liquifierInstance.paused());
        assertTrue(etherFiOracleInstance.paused());

        // testing single unpause execution
        pauser.unpauseSingle(IPausable(address(liquifierInstance)));
        assertFalse(liquifierInstance.paused());
        assertTrue(etherFiOracleInstance.paused());

        vm.expectRevert("Pausable: not paused");
        pauser.unpauseSingle(IPausable(address(liquifierInstance)));
    }

    function test_pauseAll() public {
        // testing the removal and addition of pausables
        uint256 liquifierIndex = pauser.getPausableIndex(address(liquifierInstance));
        pauser.removePausable(liquifierIndex); // removing the `liquifier`
        pauser.addPausable(IPausable(address(auctionInstance)));

        vm.expectRevert("Contract not found");
        pauser.getPausableIndex(address(liquifierInstance));

        uint256 auctionIndex = pauser.getPausableIndex(address(auctionInstance));
        assertTrue(auctionIndex == 1);

        // pausing updated pausables array
        pauser.pauseAll();
        assertFalse(liquifierInstance.paused());
        assertTrue(etherFiOracleInstance.paused());
        assertTrue(auctionInstance.paused());
    }

    function test_pauseMulti() public {
        pauser.addPausable(IPausable(address(auctionInstance)));

        // pausing the `liquifier` and `etherFiOracle` from initialPausables
        pauser.pauseMultiple(initialPausables);
        assertTrue(liquifierInstance.paused());
        assertTrue(etherFiOracleInstance.paused());
        assertFalse(auctionInstance.paused());

        // unpausing the `liquifier` and `etherFiOracle` from initialPausables
        pauser.unpauseMultiple(initialPausables);
        assertFalse(liquifierInstance.paused());
        assertFalse(etherFiOracleInstance.paused());
    }

    function test_reverts() public {
        roleRegistry.revokeRole(pauser.PAUSER_ADMIN(), alice);

        vm.expectRevert("Sender requires permission");
        pauser.removePausable(0);

        roleRegistry.grantRole(pauser.PAUSER_ADMIN(), alice);
        pauser.removePausable(0);

        vm.expectRevert(Pauser.Pauser__IndexOutOfBounds.selector);
        pauser.removePausable(1);

        vm.startPrank(bob);
        vm.expectRevert("Sender requires permission");
        pauser.pauseSingle(IPausable(address(liquifierInstance)));
    }
}

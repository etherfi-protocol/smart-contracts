// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/Pauser.sol";

contract PauserTest is TestSetup {

    uint256 public constant INITIAL_DELAY = 1200; // 20 minutes
    Pauser pauser;

    function setUp() public {
        setUpTests();
        
        // deploy+initialize the pauser
        Pauser pauserImplementation = new Pauser();
        IPausable[] memory pausables = new IPausable[](2);
        pausables[0] = IPausable(address(liquifierInstance));
        pausables[1] = IPausable(address(etherFiOracleInstance));
        bytes memory initializerData = abi.encodeWithSelector(Pauser.initialize.selector, pausables, INITIAL_DELAY,  address(roleRegistry));
        pauser = Pauser(address(new UUPSProxy(address(pauserImplementation), initializerData)));

        // giving the pauser contract the permissions it needs to pause and unpause the contracts
        vm.startPrank(owner);
        liquifierInstance.updatePauser(address(pauser), true);
        liquifierInstance.transferOwnership(address(pauser));
        etherFiOracleInstance.updateAdmin(address(pauser), true);
        auctionInstance.updateAdmin(address(pauser), true);

        // setting contract roles
        vm.startPrank(admin);
        roleRegistry.grantRole(pauser.PROTOCOL_PAUSER(), alice);
        roleRegistry.grantRole(pauser.PROTOCOL_UNPAUSER(), alice);
        roleRegistry.grantRole(pauser.PAUSER_ADMIN(), alice);
        vm.startPrank(alice);
    }

    function test_singlePause() public {
        // pausing the `liquifier` and `etherFiOracle`
        pauser.pauseSingle(IPausable(address(liquifierInstance)));
        pauser.pauseSingle(IPausable(address(etherFiOracleInstance)));
        assertTrue(liquifierInstance.paused());

        // scheduling the unpause of `liquifier` and warping past the delay
        pauser.scheduleUnpauseSingle(IPausable(address(liquifierInstance)));
        assertTrue(liquifierInstance.paused());
        vm.warp(block.timestamp + INITIAL_DELAY);

        // testing single unpause execution
        vm.expectRevert("Unpause operation is not scheduled");
        pauser.executeUnpauseSingle(IPausable(address(etherFiOracleInstance)), 1);
        pauser.executeUnpauseSingle(IPausable(address(liquifierInstance)), 1);
        assertFalse(liquifierInstance.paused());

        // testing re-use of executed unpause
        pauser.pauseSingle(IPausable(address(liquifierInstance)));
        vm.expectRevert("Unpause operation already executed");
        pauser.executeUnpauseSingle(IPausable(address(liquifierInstance)), 1);
    }

    function test_pauseAll() public {
        // testing the removal and addition of pausables
        pauser.removePausable(0); // removing the `liquifier`
        pauser.addPausable(IPausable(address(auctionInstance)));

        // pausing updated pausables array
        pauser.pauseAll();
        assertFalse(liquifierInstance.paused());
        assertTrue(etherFiOracleInstance.paused());
        assertTrue(auctionInstance.paused());

        vm.warp(531531);
        bytes32 id = pauser.scheduleUnpauseAll();

        vm.warp(block.timestamp + INITIAL_DELAY - 1);
        assertFalse(pauser.isExecutable(id));
        vm.expectRevert("Unpause operation not past delay");
        pauser.executeUnpauseAll(531531);

        vm.warp(block.timestamp + 1);
        assertTrue(pauser.isExecutable(id));
        pauser.executeUnpauseAll(531531);

        assertFalse(etherFiOracleInstance.paused());
        assertFalse(auctionInstance.paused());
    }

    function test_pauseMulti() public {
        pauser.addPausable(IPausable(address(auctionInstance)));

        // pausing the `liquifier` and `etherFiOracle`
        IPausable[] memory pausables = new IPausable[](2);
        pausables[0] = IPausable(address(liquifierInstance));
        pausables[1] = IPausable(address(etherFiOracleInstance));
        pauser.pauseMultiple(pausables);

        assertTrue(liquifierInstance.paused());
        assertTrue(etherFiOracleInstance.paused());
        assertFalse(auctionInstance.paused());

        bytes32 id = pauser.scheduleUnpauseMultiple(pausables);
        vm.warp(block.timestamp + INITIAL_DELAY);

        assertTrue(pauser.isExecutable(id));
        pauser.deleteUnpause(id);

        assertFalse(pauser.isExecutable(id));
        vm.expectRevert("Unpause operation is not scheduled");
        pauser.executeUnpauseMultiple(pausables, 1);

        uint256 currentTimestamp = block.timestamp;
        pauser.scheduleUnpauseMultiple(pausables);
        vm.warp(block.timestamp + INITIAL_DELAY);

        pauser.executeUnpauseMultiple(pausables, currentTimestamp);
        assertFalse(liquifierInstance.paused());
        assertFalse(etherFiOracleInstance.paused());
    }
}
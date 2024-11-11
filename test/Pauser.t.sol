// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/Pauser.sol";

contract PauserTest is TestSetup {
    IPausable[] pausables;

    function setUp() public {
        setUpTests();

        pausables.push(liquidityPoolInstance);
        pausables.push(etherFiOracleInstance);

        vm.startPrank(admin);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER(), alice);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER(), alice);
        roleRegistry.grantRole(pauserInstance.PAUSER_ADMIN(), alice);
        vm.startPrank(alice);
    }

    function test_singlePause() public {
        // pausing the `liquifier` and `etherFiOracle`
        pauserInstance.pauseSingle(IPausable(address(liquidityPoolInstance)));
        pauserInstance.pauseSingle(IPausable(address(etherFiOracleInstance)));
        assertTrue(liquidityPoolInstance.paused());
        assertTrue(etherFiOracleInstance.paused());

        // testing single unpause execution
        pauserInstance.unpauseSingle(IPausable(address(liquidityPoolInstance)));
        assertFalse(liquidityPoolInstance.paused());
        assertTrue(etherFiOracleInstance.paused());

        vm.expectRevert("Pausable: not paused");
        pauserInstance.unpauseSingle(IPausable(address(liquidityPoolInstance)));
    }

    function test_pauseAll() public {
        // testing the removal and addition of pausables
        uint256 liquidityPoolIndex = pauserInstance.getPausableIndex(address(liquidityPoolInstance));
        pauserInstance.removePausable(liquidityPoolIndex); // removing the `liquidityPool`
        pauserInstance.addPausable(IPausable(address(auctionInstance)));

        vm.expectRevert("Contract not found");
        pauserInstance.getPausableIndex(address(liquidityPoolInstance));

        uint256 auctionIndex = pauserInstance.getPausableIndex(address(auctionInstance));
        assertTrue(auctionIndex == 1);

        // pausing updated pausables array
        pauserInstance.pauseAll();
        assertFalse(liquidityPoolInstance.paused());
        assertTrue(etherFiOracleInstance.paused());
        assertTrue(auctionInstance.paused());
    }

    function test_pauseMulti() public {
        pauserInstance.addPausable(IPausable(address(auctionInstance)));

        // pausing the `liquifier` and `etherFiOracle` from pausables
        pauserInstance.pauseMultiple(pausables);
        assertTrue(liquidityPoolInstance.paused());
        assertTrue(etherFiOracleInstance.paused());
        assertFalse(auctionInstance.paused());

        // unpausing the `liquifier` and `etherFiOracle` from pausables
        pauserInstance.unpauseMultiple(pausables);
        assertFalse(liquidityPoolInstance.paused());
        assertFalse(etherFiOracleInstance.paused());
    }

    function test_reverts() public {
        roleRegistry.revokeRole(pauserInstance.PAUSER_ADMIN(), alice);

        vm.expectRevert("Sender requires permission");
        pauserInstance.removePausable(0);

        roleRegistry.grantRole(pauserInstance.PAUSER_ADMIN(), alice);
        pauserInstance.removePausable(0);

        vm.expectRevert(Pauser.Pauser__IndexOutOfBounds.selector);
        pauserInstance.removePausable(1);

        vm.startPrank(bob);
        vm.expectRevert("Sender requires permission");
        pauserInstance.pauseSingle(IPausable(address(liquidityPoolInstance)));
    }

    function test_pushDuplicate() public {
        vm.expectRevert("Contract already in pausables");
        pauserInstance.addPausable(IPausable(address(liquidityPoolInstance)));

        pauserInstance.removePausable(0);

        pauserInstance.addPausable(IPausable(address(liquidityPoolInstance)));
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract TVLOracleTest is TestSetup {

    function setUp() public {
        setUpTests();
    }

    function test_SetTvlCorrectly() public {

        vm.prank(alice);
        uint256 newTvl = 1000;
        tvlOracle.setTvl(newTvl);

        uint256 currentTvl = tvlOracle.getTvl();
        assertEq(currentTvl, newTvl);
    }

    function test_GetTvl() public {
        uint256 currentTvl = tvlOracle.getTvl();
        assertEq(currentTvl, 0);

        vm.prank(alice);
        uint256 newTvl = 1000;
        tvlOracle.setTvl(newTvl);

        currentTvl = tvlOracle.getTvl();
        assertEq(currentTvl, newTvl);
    }

    function test_SetTVLAggregator() public {
    
        address newAggregator = bob;
        vm.prank(owner);
        tvlOracle.setTVLAggregator(newAggregator);

        address currentAggregator = tvlOracle.tvlAggregator();
        assertEq(currentAggregator, newAggregator);
    }

    function test_SetTVLAggregatorShouldRequireNonZeroAddress() public {
        address newAggregator = address(0);
        vm.prank(owner);

        vm.expectRevert("No zero addresses");
        tvlOracle.setTVLAggregator(newAggregator);
    }

    function test_OnlyAggregatorCanSetTvl() public {
        uint256 newTvl = 1000;

        vm.prank(bob);
        vm.expectRevert("Only TVL Aggregator can call this message");
        tvlOracle.setTvl(newTvl);

        vm.prank(owner);
        vm.expectRevert("Only TVL Aggregator can call this message");
        tvlOracle.setTvl(newTvl);

        vm.prank(alice);
        tvlOracle.setTvl(newTvl);
        uint256 currentTvl = tvlOracle.getTvl();
        assertEq(currentTvl, 1000);
    }

    function test_OnlyAggregatorCanSetTvlAggregator() public {

        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        tvlOracle.setTVLAggregator(bob);

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tvlOracle.setTVLAggregator(bob);

        vm.prank(owner);
        tvlOracle.setTVLAggregator(bob);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/RateOracle.sol";

contract RateOracleTest is Test {

    RateOracle oracle;
    address owner;
    
    function setUp() public {

        owner = vm.addr(0x1);

        // (token, baseToken)
        vm.prank(owner);
        oracle = new RateOracle("weETH", "ETH");
    }

    function test_setRate() public {


        vm.startPrank(owner);

        // fail because not set
        vm.expectRevert(RateOracle.InvalidRate.selector);
        oracle.getRate();

        // can't set if not admin
        vm.expectRevert("Caller is not the admin");
        oracle.setRate(1e18);

        oracle.updateAdmin(owner, true);

        uint256 setTimestamp = block.timestamp;
        oracle.setRate(1e18);

        assertEq(oracle.getRate(), 1e18);
        assertEq(oracle.lastUpdated(), setTimestamp);

        // can't set to crazy value
        vm.expectRevert(RateOracle.InvalidRate.selector);
        oracle.setRate(1e20);
        vm.expectRevert(RateOracle.InvalidRate.selector);
        oracle.setRate(1e16);


        oracle.setRate(1e18 + 5e16);
        assertEq(oracle.getRate(), 1e18 + 5e16);
    }

}

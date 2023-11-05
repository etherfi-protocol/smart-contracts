// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract AuctionManagerV2Test is AuctionManager {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract AddressProviderTest is TestSetup {

    AuctionManagerV2Test public auctionManagerV2Instance;

    function setUp() public {
        setUpTests();
    }

    function test_ContractInstantiatedCorrectly() public {
        assertEq(addressProviderInstance.owner(), address(owner));
        assertEq(addressProviderInstance.numberOfContracts(), 0);
    }

    function test_AddNewContract() public {
        vm.expectRevert("Only owner function");
        vm.prank(alice);
        addressProviderInstance.addContract(
            address(auctionManagerProxy),
            "AuctionManager"
        );

        vm.startPrank(owner);
        vm.warp(20000);
        addressProviderInstance.addContract(
            address(auctionManagerProxy),
            "AuctionManager"
        );

        (
            address contractAddress,
            string memory name
        ) = addressProviderInstance.contracts("AuctionManager");
        
        assertEq(contractAddress, address(auctionManagerProxy));
        assertEq(name, "AuctionManager");
        assertEq(addressProviderInstance.numberOfContracts(), 1);
    }

    function test_RemoveContract() public {
        vm.startPrank(owner);
        vm.warp(20000);
        addressProviderInstance.addContract(
            address(auctionManagerProxy),
            "AuctionManager"
        );

        addressProviderInstance.addContract(
            address(liquidityPoolProxy),
            "LiquidityPool"
        );
        vm.stopPrank();

        vm.expectRevert("Only owner function");
        vm.prank(alice);
        addressProviderInstance.removeContract(
            "AuctionManager"
        );

        vm.startPrank(owner);
        vm.expectRevert("Contract does not exist");
        addressProviderInstance.removeContract(
            "AuctionManage"
        );

        (
            address contractAddress,
            string memory name
        ) = addressProviderInstance.contracts("AuctionManager");
        
        assertEq(contractAddress, address(auctionManagerProxy));
        assertEq(name, "AuctionManager");
        assertEq(addressProviderInstance.numberOfContracts(), 2);

        addressProviderInstance.removeContract(
            "AuctionManager"
        );

        (
            contractAddress,
            name
        ) = addressProviderInstance.contracts("AuctionManager");

        assertEq(contractAddress, address(0));
        assertEq(addressProviderInstance.numberOfContracts(), 1);

    }

    function test_SetOwner() public {
        vm.expectRevert("Only owner function");
        vm.prank(alice);
        addressProviderInstance.setOwner(address(alice));

        vm.startPrank(owner);
        vm.expectRevert("Cannot be zero addr");
        addressProviderInstance.setOwner(address(0));

        assertEq(addressProviderInstance.owner(), address(owner));

        addressProviderInstance.setOwner(address(alice));
        assertEq(addressProviderInstance.owner(), address(alice));
    }

    function test_GetImplementationAddress() public {
        vm.startPrank(owner);
        addressProviderInstance.addContract(
            address(auctionManagerProxy),
            "AuctionManager"
        );
        addressProviderInstance.addContract(
            address(liquidityPoolProxy),
            "LiquidityPool"
        );
        addressProviderInstance.addContract(
            address(regulationsManagerProxy),
            "RegulationsManager"
        );

        assertEq(addressProviderInstance.getImplementationAddress("LiquidityPool"), address(liquidityPoolImplementation));
        assertEq(addressProviderInstance.getImplementationAddress("RegulationsManager"), address(regulationsManagerImplementation));
        assertEq(addressProviderInstance.getImplementationAddress("AuctionManager"), address(auctionImplementation));

        AuctionManagerV2Test auctionManagerV2Implementation = new AuctionManagerV2Test();
        auctionInstance.upgradeTo(address(auctionManagerV2Implementation));

        assertEq(addressProviderInstance.getImplementationAddress("AuctionManager"), address(auctionManagerV2Implementation));

    }
}

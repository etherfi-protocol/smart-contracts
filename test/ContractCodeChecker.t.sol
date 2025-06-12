// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiRestaker.sol";

/**
 * @title TestByteCodeMatch
 * @dev Test contract to verify bytecode matches between deployed contracts and their implementations
 */
contract ContractCodeCheckerTest is TestSetup {

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

    function test_deployment_bytecode() public {
        // Create new implementations
        EtherFiNodesManager etherFiNodesManagerImplementation = new EtherFiNodesManager();
        address etherFiNodesManagerImplAddress = address(0xE9EE6923D41Cf5F964F11065436BD90D4577B5e4);

        EtherFiNode etherFiNodeImplementation = new EtherFiNode();
        address etherFiNodeImplAddress = address(0xc5F2764383f93259Fba1D820b894B1DE0d47937e);

        EtherFiRestaker etherFiRestakerImplementation = new EtherFiRestaker(address(0x7750d328b314EfFa365A0402CcfD489B80B0adda), address(0x2093Bbb221f1d8C7c932c32ee28Be6dEe4a37A6a));
        address etherFiRestakerImplAddress = address(0x0052F731a6BEA541843385ffBA408F52B74Cb624);

        // Verify bytecode matches between deployed contracts and their implementations
        verifyContractByteCodeMatch(etherFiNodesManagerImplAddress, address(etherFiNodesManagerImplementation));
        verifyContractByteCodeMatch(etherFiNodeImplAddress, address(etherFiNodeImplementation));
        verifyContractByteCodeMatch(etherFiRestakerImplAddress, address(etherFiRestakerImplementation));
    }

    function test_bytecode_match_for_new_deployments() public {
        // This test can be used for future deployments
        // It follows the same pattern as the test_deployment_bytecode function
        // but with different contract addresses
        
        // Example (replace with actual addresses when needed):
        // address newNodesManagerImplAddress = address(0x...);
        // EtherFiNodesManager newNodesManagerImplementation = new EtherFiNodesManager();
        // verifyContractByteCodeMatch(newNodesManagerImplAddress, address(newNodesManagerImplementation));
    }
}


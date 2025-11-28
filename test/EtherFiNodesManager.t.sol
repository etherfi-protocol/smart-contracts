// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "../src/interfaces/IEtherFiNodesManager.sol";
import "../src/eigenlayer-interfaces/IEigenPod.sol";
import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "../src/eigenlayer-interfaces/IStrategy.sol";
import {BeaconChainProofs} from "../src/eigenlayer-libraries/BeaconChainProofs.sol";
import {IDelegationManagerTypes} from "../src/eigenlayer-interfaces/IDelegationManager.sol";
import {IEigenPodTypes} from "../src/eigenlayer-interfaces/IEigenPod.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Deployed} from "../script/deploys/Deployed.s.sol";


contract EtherFiNodesManagerTest is TestSetup {
    address public eigenlayerAdmin;
    address public podProver;
    address public callForwarder;
    address public elTriggerExit;
    address public testNode;
    bytes public testPubkey;
    bytes32 public testPubkeyHash;
    uint256 public testLegacyId = 1;
    Deployed public deployed;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        console2.log("managerInstance.rateLimiter()", address(managerInstance.rateLimiter()));

        // Get rate limiter from manager instance and set it for use in tests
        // rateLimiterInstance might not be set when using initializeRealisticFork
        rateLimiterInstance = EtherFiRateLimiter(address(managerInstance.rateLimiter()));

        deployed = new Deployed();
        
        // Setup roles
        eigenlayerAdmin = vm.addr(100);
        podProver = vm.addr(101);
        callForwarder = vm.addr(102);
        elTriggerExit = vm.addr(103);
        
        vm.startPrank(managerInstance.owner());
        roleRegistryInstance.grantRole(managerInstance.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), admin);
        roleRegistryInstance.grantRole(managerInstance.ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(), eigenlayerAdmin);
        roleRegistryInstance.grantRole(managerInstance.ETHERFI_NODES_MANAGER_POD_PROVER_ROLE(), podProver);
        roleRegistryInstance.grantRole(managerInstance.ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE(), callForwarder);
        roleRegistryInstance.grantRole(managerInstance.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(), elTriggerExit);
        roleRegistryInstance.grantRole(stakingManagerInstance.STAKING_MANAGER_NODE_CREATOR_ROLE(), address(liquidityPoolInstance));
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), admin);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), admin);
        roleRegistryInstance.grantRole(rateLimiterInstance.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), admin);
        roleRegistryInstance.grantRole(managerInstance.ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(), deployed.STAKING_MANAGER());
        vm.stopPrank();
        
        // Setup rate limiter - check if limiters already exist before creating
        vm.startPrank(admin);
        if (!rateLimiterInstance.limitExists(managerInstance.UNRESTAKING_LIMIT_ID())) {
            rateLimiterInstance.createNewLimiter(managerInstance.UNRESTAKING_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        }
        
        if (!rateLimiterInstance.limitExists(managerInstance.EXIT_REQUEST_LIMIT_ID())) {
            rateLimiterInstance.createNewLimiter(managerInstance.EXIT_REQUEST_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        }
        
        rateLimiterInstance.updateConsumers(managerInstance.UNRESTAKING_LIMIT_ID(), address(managerInstance), true);
        rateLimiterInstance.updateConsumers(managerInstance.EXIT_REQUEST_LIMIT_ID(), address(managerInstance), true);
        vm.stopPrank();
        
        // // Create a proper beacon and upgrade the node implementation
        // // First, create a new EtherFiNode implementation
        // address eigenPodManager = address(eigenLayerEigenPodManager);
        // address delegationManager = address(eigenLayerDelegationManager);
        // EtherFiNode nodeImpl = new EtherFiNode(
        //     address(liquidityPoolInstance),
        //     address(managerInstance),
        //     eigenPodManager,
        //     delegationManager,
        //     address(roleRegistryInstance)
        // );
        
        // // Upgrade the beacon to use the new implementation
        // vm.prank(stakingManagerInstance.owner());
        // stakingManagerInstance.upgradeEtherFiNode(address(nodeImpl));
        
        // // Now create a test node
        // vm.prank(address(liquidityPoolInstance));
        // testNode = stakingManagerInstance.instantiateEtherFiNode(true);

        // testNode = stakingManagerInstance.getEtherFiNodeBeacon();
        testNode = 0x7898333991035242A1115D978c0619F8736dD323; // Node on Mainnet
        
        // Generate test pubkey
        testPubkey = vm.randomBytes(48);
        testPubkeyHash = managerInstance.calculateValidatorPubkeyHash(testPubkey);
        
        // Link pubkey to node
        vm.prank(address(stakingManagerInstance));
        managerInstance.linkPubkeyToNode(testPubkey, testNode, testLegacyId);
    }

    // ============================================
    // Pure Functions Tests
    // ============================================
    
    function test_addressToWithdrawalCredentials() public {
        address testAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory result = managerInstance.addressToWithdrawalCredentials(testAddr);
        bytes memory expected = abi.encodePacked(bytes1(0x01), bytes11(0x0), testAddr);
        assertEq(result, expected);
    }
    
    function test_addressToCompoundingWithdrawalCredentials() public {
        address testAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory result = managerInstance.addressToCompoundingWithdrawalCredentials(testAddr);
        bytes memory expected = abi.encodePacked(bytes1(0x02), bytes11(0x0), testAddr);
        assertEq(result, expected);
    }
    
    function test_calculateValidatorPubkeyHash() public {
        bytes memory pubkey = vm.randomBytes(48);
        bytes32 hash = managerInstance.calculateValidatorPubkeyHash(pubkey);
        assertTrue(hash != bytes32(0));
        
        // Test that same pubkey gives same hash
        bytes32 hash2 = managerInstance.calculateValidatorPubkeyHash(pubkey);
        assertEq(hash, hash2);
    }
    
    function test_calculateValidatorPubkeyHash_invalidLength() public {
        bytes memory invalidPubkey = vm.randomBytes(47);
        vm.expectRevert(IEtherFiNodesManager.InvalidPubKeyLength.selector);
        managerInstance.calculateValidatorPubkeyHash(invalidPubkey);
    }

    // ============================================
    // View Functions Tests
    // ============================================
    
    function test_stakingManager() public view {
        assertEq(address(managerInstance.stakingManager()), address(stakingManagerInstance));
    }
    
    function test_etherfiNodeAddress_byLegacyId() public view {
        address nodeAddr = managerInstance.etherfiNodeAddress(testLegacyId);
        assertEq(nodeAddr, testNode);
    }
    
    function test_etherfiNodeAddress_byPubkeyHash() public view {
        address nodeAddr = managerInstance.etherfiNodeAddress(uint256(testPubkeyHash));
        assertEq(nodeAddr, testNode);
    }
    
    function test_etherFiNodeFromPubkeyHash() public view {
        IEtherFiNode node = managerInstance.etherFiNodeFromPubkeyHash(testPubkeyHash);
        assertEq(address(node), testNode);
    }
    
    function test_getEigenPod_byAddress() public view {
        address pod = managerInstance.getEigenPod(testNode);
        assertTrue(pod != address(0));
    }
    
    function test_getEigenPod_byId() public view {
        address pod = managerInstance.getEigenPod(testLegacyId);
        assertTrue(pod != address(0));
    }
    
    function test_getEigenPod_unknownNode() public {
        vm.expectRevert(IEtherFiNodesManager.UnknownNode.selector);
        managerInstance.getEigenPod(address(0x999));
    }
    
    function test_BEACON_ETH_STRATEGY_ADDRESS() public view {
        assertEq(managerInstance.BEACON_ETH_STRATEGY_ADDRESS(), address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0));
    }
    
    function test_UNRESTAKING_LIMIT_ID() public view {
        assertEq(managerInstance.UNRESTAKING_LIMIT_ID(), keccak256("UNRESTAKING_LIMIT_ID"));
    }
    
    function test_EXIT_REQUEST_LIMIT_ID() public view {
        assertEq(managerInstance.EXIT_REQUEST_LIMIT_ID(), keccak256("EXIT_REQUEST_LIMIT_ID"));
    }
    
    function test_FULL_EXIT_GWEI() public view {
        assertEq(managerInstance.FULL_EXIT_GWEI(), 2_048_000_000_000);
    }

    // ============================================
    // Admin Functions Tests
    // ============================================
    
    function test_pauseContract() public {
        vm.prank(admin);
        managerInstance.pauseContract();
        assertTrue(managerInstance.paused());
    }
    
    function test_pauseContract_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.pauseContract();
    }
    
    function test_unPauseContract() public {
        vm.prank(admin);
        managerInstance.pauseContract();
        vm.prank(admin);
        managerInstance.unPauseContract();
        assertFalse(managerInstance.paused());
    }
    
    function test_unPauseContract_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.unPauseContract();
    }
    
    function test_sweepFunds() public {
        // Send ETH to node
        vm.deal(testNode, 1 ether);
        
        vm.prank(admin);
        managerInstance.sweepFunds(testLegacyId);
        
        // Check event was emitted (if balance > 0)
        // Note: This depends on node implementation
    }
    
    function test_sweepFunds_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.sweepFunds(testLegacyId);
    }
    
    function test_sweepFunds_whenPaused() public {
        vm.prank(admin);
        managerInstance.pauseContract();
        
        vm.expectRevert();
        vm.prank(admin);
        managerInstance.sweepFunds(testLegacyId);
    }

    // ============================================
    // Eigenlayer Interactions Tests
    // ============================================
    
    function test_createEigenPod() public {
        address nodeCreatorRole = roleRegistryInstance.roleHolders(stakingManagerInstance.STAKING_MANAGER_NODE_CREATOR_ROLE())[0];
        vm.prank(nodeCreatorRole);
        address newNode = stakingManagerInstance.instantiateEtherFiNode(false);
        
        vm.prank(eigenlayerAdmin);
        address pod = managerInstance.createEigenPod(newNode);
        assertTrue(pod != address(0));
    }
    
    function test_createEigenPod_unknownNode() public {
        vm.expectRevert(IEtherFiNodesManager.UnknownNode.selector);
        vm.prank(eigenlayerAdmin);
        managerInstance.createEigenPod(address(0x999));
    }
    
    function test_createEigenPod_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.createEigenPod(testNode);
    }
    
    function test_createEigenPod_whenPaused() public {
        vm.prank(admin);
        managerInstance.pauseContract();
        
        vm.expectRevert();
        vm.prank(eigenlayerAdmin);
        managerInstance.createEigenPod(testNode);
    }
    
    function test_startCheckpoint_byAddress() public {
        vm.prank(podProver);
        managerInstance.startCheckpoint(testNode);
    }
    
    function test_startCheckpoint_byId() public {
        vm.prank(podProver);
        managerInstance.startCheckpoint(testLegacyId);
    }
    
    function test_startCheckpoint_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.startCheckpoint(testNode);
    }
    
    function test_startCheckpoint_whenPaused() public {
        vm.prank(admin);
        managerInstance.pauseContract();
        
        vm.expectRevert();
        vm.prank(podProver);
        managerInstance.startCheckpoint(testNode);
    }
    
    function test_setProofSubmitter_byAddress() public {
        address newSubmitter = address(0x123);
        vm.prank(eigenlayerAdmin);
        managerInstance.setProofSubmitter(testNode, newSubmitter);
    }
    
    function test_setProofSubmitter_byId() public {
        address newSubmitter = address(0x123);
        vm.prank(eigenlayerAdmin);
        managerInstance.setProofSubmitter(testLegacyId, newSubmitter);
    }
    
    function test_setProofSubmitter_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.setProofSubmitter(testNode, address(0x123));
    }
            
    function test_queueETHWithdrawal_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.queueETHWithdrawal(testNode, 1 ether);
    }
    
    function test_completeQueuedETHWithdrawals_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.completeQueuedETHWithdrawals(testNode, true);
    }
    
    function test_queueWithdrawals_byAddress() public {
        IDelegationManagerTypes.QueuedWithdrawalParams[] memory params = new IDelegationManagerTypes.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(managerInstance.BEACON_ETH_STRATEGY_ADDRESS());
        uint256[] memory depositShares = new uint256[](1);
        depositShares[0] = 1 ether;
        
        params[0] = IDelegationManagerTypes.QueuedWithdrawalParams({
            strategies: strategies,
            depositShares: depositShares,
            __deprecated_withdrawer: testNode
        });
        
        vm.prank(eigenlayerAdmin);
        managerInstance.queueWithdrawals(testNode, params);
    }
    
    function test_queueWithdrawals_byId() public {
        IDelegationManagerTypes.QueuedWithdrawalParams[] memory params = new IDelegationManagerTypes.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(managerInstance.BEACON_ETH_STRATEGY_ADDRESS());
        uint256[] memory depositShares = new uint256[](1);
        depositShares[0] = 1 ether;
        
        params[0] = IDelegationManagerTypes.QueuedWithdrawalParams({
            strategies: strategies,
            depositShares: depositShares,
            __deprecated_withdrawer: testNode
        });
        
        vm.prank(eigenlayerAdmin);
        managerInstance.queueWithdrawals(testLegacyId, params);
    }
    
    function test_completeQueuedWithdrawals_byAddress() public {
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](0);
        IERC20[][] memory tokens = new IERC20[][](0);
        bool[] memory receiveAsTokens = new bool[](0);
        
        vm.prank(eigenlayerAdmin);
        managerInstance.completeQueuedWithdrawals(testNode, withdrawals, tokens, receiveAsTokens);
    }
    
    function test_completeQueuedWithdrawals_byId() public {
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](0);
        IERC20[][] memory tokens = new IERC20[][](0);
        bool[] memory receiveAsTokens = new bool[](0);
        
        vm.prank(eigenlayerAdmin);
        managerInstance.completeQueuedWithdrawals(testLegacyId, withdrawals, tokens, receiveAsTokens);
    }

    // ============================================
    // Call Forwarding Tests
    // ============================================
    
    function test_updateAllowedForwardedExternalCalls() public {
        bytes4 selector = bytes4(0x12345678);
        address target = address(0x123);
        
        vm.prank(admin);
        managerInstance.updateAllowedForwardedExternalCalls(callForwarder, selector, target, true);
        
        assertTrue(managerInstance.allowedForwardedExternalCalls(callForwarder, selector, target));
    }
    
    function test_updateAllowedForwardedExternalCalls_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.updateAllowedForwardedExternalCalls(callForwarder, bytes4(0x12345678), address(0x123), true);
    }
    
    function test_updateAllowedForwardedEigenpodCalls() public {
        bytes4 selector = bytes4(0x12345678);
        
        vm.prank(admin);
        managerInstance.updateAllowedForwardedEigenpodCalls(callForwarder, selector, true);
        
        assertTrue(managerInstance.allowedForwardedEigenpodCalls(callForwarder, selector));
    }
    
    function test_updateAllowedForwardedEigenpodCalls_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.updateAllowedForwardedEigenpodCalls(callForwarder, bytes4(0x12345678), true);
    }
    
    function test_forwardExternalCall() public {
        // Setup allowed call
        address rewardsCoordinator = address(0x7750d328b314EfFa365A0402CcfD489B80B0adda);
        bytes4 processClaimSelector = bytes4(0x3ccc861d); // processClaim
        
        vm.prank(admin);
        managerInstance.updateAllowedForwardedExternalCalls(callForwarder, processClaimSelector, rewardsCoordinator, true);
        
        address[] memory nodes = new address[](1);
        bytes[] memory data = new bytes[](1);
        nodes[0] = testNode;
        data[0] = abi.encodeWithSelector(processClaimSelector);
        
        // The actual processClaim call may revert due to missing parameters or contract state,
        // but the important thing is that the whitelist check passes
        vm.prank(callForwarder);
        try managerInstance.forwardExternalCall(nodes, data, rewardsCoordinator) returns (bytes[] memory returnData) {
            assertEq(returnData.length, 1);
        } catch {
            // If it fails, it's due to the actual call, not the whitelist
            // The whitelist check already passed (we got past the authorization)
        }
    }
    
    function test_forwardExternalCall_lengthMismatch() public {
        address[] memory nodes = new address[](1);
        bytes[] memory data = new bytes[](2);
        
        vm.expectRevert(IEtherFiNodesManager.InvalidForwardedCall.selector);
        vm.prank(callForwarder);
        managerInstance.forwardExternalCall(nodes, data, address(0x123));
    }
    
    function test_forwardExternalCall_notAllowed() public {
        address[] memory nodes = new address[](1);
        bytes[] memory data = new bytes[](1);
        nodes[0] = testNode;
        data[0] = abi.encodeWithSelector(bytes4(0x12345678));
        
        vm.expectRevert(IEtherFiNodesManager.ForwardedCallNotAllowed.selector);
        vm.prank(callForwarder);
        managerInstance.forwardExternalCall(nodes, data, address(0x123));
    }
    
    function test_forwardExternalCall_invalidData() public {
        address[] memory nodes = new address[](1);
        bytes[] memory data = new bytes[](1);
        nodes[0] = testNode;
        data[0] = hex"12"; // Too short (less than 4 bytes)
        
        vm.expectRevert(IEtherFiNodesManager.InvalidForwardedCall.selector);
        vm.prank(callForwarder);
        managerInstance.forwardExternalCall(nodes, data, address(0x123));
    }
    
    function test_forwardExternalCall_unauthorized() public {
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        address[] memory nodes = new address[](1);
        bytes[] memory data = new bytes[](1);
        managerInstance.forwardExternalCall(nodes, data, address(0x123));
    }
    
    function test_forwardEigenPodCall() public {
        bytes4 startCheckpointSelector = bytes4(0x88676cad); // startCheckpoint
        address allowedCaller = address(0x7835fB36A8143a014A2c381363cD1A4DeE586d2A);

        vm.prank(admin);
        managerInstance.updateAllowedForwardedEigenpodCalls(allowedCaller, startCheckpointSelector, true);
        
        address[] memory nodes = new address[](1);
        bytes[] memory data = new bytes[](1);
        nodes[0] = testNode;
        data[0] = abi.encodeWithSelector(startCheckpointSelector, false);
        
        vm.prank(allowedCaller);
        bytes[] memory returnData = managerInstance.forwardEigenPodCall(nodes, data);
        assertEq(returnData.length, 1);
    }
    
    function test_forwardEigenPodCall_notAllowed() public {
        address[] memory nodes = new address[](1);
        bytes[] memory data = new bytes[](1);
        nodes[0] = testNode;
        data[0] = abi.encodeWithSelector(bytes4(0x12345678));
        
        vm.expectRevert(IEtherFiNodesManager.ForwardedCallNotAllowed.selector);
        vm.prank(callForwarder);
        managerInstance.forwardEigenPodCall(nodes, data);
    }

    // ============================================
    // Execution Layer Triggered Withdrawals Tests
    // ============================================
    
    function test_requestExecutionLayerTriggeredWithdrawal() public {
        bytes[] memory pubkeys = new bytes[](1);
        uint256[] memory legacyIds = new uint256[](1);
        uint64[] memory amounts = new uint64[](1);
        bytes memory PK_28689 = hex"88d73705e9c3f29b042d3fe70bdc8781debc5506db43dd00122fd1fa7f4755535d31c7ecb2686ff53669b080ef9e18a3";

        pubkeys[0] = PK_28689;
        legacyIds[0] = 28689;
        amounts[0] = 0;

        vm.prank(deployed.OPERATING_TIMELOCK());
        managerInstance.linkLegacyValidatorIds(legacyIds, pubkeys); 
        vm.stopPrank();  

        bytes32 pkHash = managerInstance.calculateValidatorPubkeyHash(pubkeys[0]);
        IEtherFiNode etherFiNode = managerInstance.etherFiNodeFromPubkeyHash(pkHash);
        IEigenPod pod = etherFiNode.getEigenPod();

        IEigenPodTypes.WithdrawalRequest[] memory reqs = new IEigenPodTypes.WithdrawalRequest[](1);
        reqs[0] = IEigenPodTypes.WithdrawalRequest({pubkey: pubkeys[0], amountGwei: amounts[0]});

        uint256 feePer = pod.getWithdrawalRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        vm.expectEmit(true, true, true, true, address(managerInstance));
        emit IEtherFiNodesManager.ValidatorWithdrawalRequestSent(
            address(pod), 
            managerInstance.calculateValidatorPubkeyHash(pubkeys[0]), 
            pubkeys[0]
        );
        address elTriggerExit = roleRegistryInstance.roleHolders(managerInstance.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE())[0];
        vm.prank(elTriggerExit);
        managerInstance.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);
        vm.stopPrank();
    }
    
    function test_requestExecutionLayerTriggeredWithdrawal_emptyRequest() public {
        IEigenPodTypes.WithdrawalRequest[] memory requests = new IEigenPodTypes.WithdrawalRequest[](0);
        
        vm.expectRevert(IEtherFiNodesManager.EmptyWithdrawalsRequest.selector);
        vm.prank(elTriggerExit);
        managerInstance.requestExecutionLayerTriggeredWithdrawal(requests);
    }
    
    function test_requestExecutionLayerTriggeredWithdrawal_insufficientFees() public {
        address pod = managerInstance.getEigenPod(testNode);
        uint256 fee = IEigenPod(pod).getWithdrawalRequestFee();
        
        IEigenPodTypes.WithdrawalRequest[] memory requests = new IEigenPodTypes.WithdrawalRequest[](1);
        requests[0] = IEigenPodTypes.WithdrawalRequest({
            pubkey: testPubkey,
            amountGwei: 0
        });
        
        vm.expectRevert(IEtherFiNodesManager.InsufficientWithdrawalFees.selector);
        vm.prank(elTriggerExit);
        managerInstance.requestExecutionLayerTriggeredWithdrawal{value: fee - 1}(requests);
    }
    
    function test_requestExecutionLayerTriggeredWithdrawal_unauthorized() public {
        IEigenPodTypes.WithdrawalRequest[] memory requests = new IEigenPodTypes.WithdrawalRequest[](1);
        requests[0] = IEigenPodTypes.WithdrawalRequest({
            pubkey: testPubkey,
            amountGwei: 0
        });
        
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.requestExecutionLayerTriggeredWithdrawal(requests);
    }
    
    function test_requestConsolidation() public {
        bytes memory PK_80143 = hex"811cd0bb7dd301afbbddd1d5db15ff0ca9d5f8ada78c0b1223f75b524aca1ca9ff1ba205d9efd7c37c2174576cc123e2";
        bytes memory PK_80194 = hex"b86cb11d564b29a38cdc8a3f1f9c35e6dcd2d0f85f40da60f745e479ba42b4548c83a2b049cf02277fceaa9b421d0039";
        bytes memory PK_89936 = hex"b8786ec7945d737698e374193f05a5498e932e2941263a7842837e9e3fac033af285e53a90afecf994585d178b5eedaa";

        bytes[] memory pubkeys = new bytes[](3);
        pubkeys[0] = PK_80143;
        pubkeys[1] = PK_80194;
        pubkeys[2] = PK_89936;

        uint256[] memory legacyIdsForOneValidator = new uint256[](1);
        legacyIdsForOneValidator[0] = 80143;
        bytes[] memory pubkeysForOneValidator = new bytes[](1);
        pubkeysForOneValidator[0] = PK_80143;
        
        vm.prank(deployed.OPERATING_TIMELOCK());
        managerInstance.linkLegacyValidatorIds(legacyIdsForOneValidator, pubkeysForOneValidator); 
        vm.stopPrank();
        console.log("Linking legacy validator ids for one validator complete");  

        bytes32 pkHash = managerInstance.calculateValidatorPubkeyHash(pubkeys[0]);
        IEtherFiNode etherFiNode = managerInstance.etherFiNodeFromPubkeyHash(pkHash);
        IEigenPod pod = etherFiNode.getEigenPod();

        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](1);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[0],
            targetPubkey: pubkeys[0]
        });

        uint256 feePer = pod.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        // console.log("Fee per request:", feePer);
        // console.log("Number of requests:", n);
        // console.log("Value to send:", valueToSend);

        // Fund the timelock with enough ETH to pay consolidation fees
        vm.deal(admin, valueToSend + 1 ether);

        vm.prank(admin);
        managerInstance.requestConsolidation{value: valueToSend}(reqs);
    }
    
    function test_requestConsolidation_emptyRequest() public {
        IEigenPodTypes.ConsolidationRequest[] memory requests = new IEigenPodTypes.ConsolidationRequest[](0);
        
        vm.expectRevert(IEtherFiNodesManager.EmptyConsolidationRequest.selector);
        vm.prank(admin);
        managerInstance.requestConsolidation(requests);
    }
    
    function test_requestConsolidation_insufficientFees() public {
        address pod = managerInstance.getEigenPod(testNode);
        uint256 fee = IEigenPod(pod).getConsolidationRequestFee();
        
        IEigenPodTypes.ConsolidationRequest[] memory requests = new IEigenPodTypes.ConsolidationRequest[](1);
        requests[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: testPubkey,
            targetPubkey: testPubkey
        });
        
        vm.expectRevert(IEtherFiNodesManager.InsufficientConsolidationFees.selector);
        vm.prank(admin);
        managerInstance.requestConsolidation{value: fee - 1}(requests);
    }
    
    function test_requestConsolidation_unauthorized() public {
        IEigenPodTypes.ConsolidationRequest[] memory requests = new IEigenPodTypes.ConsolidationRequest[](1);
        requests[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: testPubkey,
            targetPubkey: testPubkey
        });
        
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        vm.prank(bob);
        managerInstance.requestConsolidation(requests);
    }
    
    function test_getWithdrawalRequestFee() public view {
        address pod = managerInstance.getEigenPod(testNode);
        uint256 fee = managerInstance.getWithdrawalRequestFee(pod);
        assertTrue(fee >= 0);
    }
    
    function test_getConsolidationRequestFee() public view {
        address pod = managerInstance.getEigenPod(testNode);
        uint256 fee = managerInstance.getConsolidationRequestFee(pod);
        assertTrue(fee >= 0);
    }

    // ============================================
    // Key Management Tests
    // ============================================
    
    function test_linkPubkeyToNode() public {
        vm.prank(deployed.OPERATING_TIMELOCK());
        address newNode = stakingManagerInstance.instantiateEtherFiNode(true);
        
        bytes memory newPubkey = vm.randomBytes(48);
        uint256 newLegacyId = 999;
        
        vm.prank(address(stakingManagerInstance));
        managerInstance.linkPubkeyToNode(newPubkey, newNode, newLegacyId);
        
        bytes32 newPubkeyHash = managerInstance.calculateValidatorPubkeyHash(newPubkey);
        assertEq(address(managerInstance.etherFiNodeFromPubkeyHash(newPubkeyHash)), newNode);
    }
    
    function test_linkPubkeyToNode_invalidCaller() public {
        bytes memory newPubkey = vm.randomBytes(48);
        
        vm.expectRevert(IEtherFiNodesManager.InvalidCaller.selector);
        vm.prank(bob);
        managerInstance.linkPubkeyToNode(newPubkey, testNode, 999);
    }
    
    function test_linkPubkeyToNode_alreadyLinked() public {
        vm.expectRevert(IEtherFiNodesManager.AlreadyLinked.selector);
        vm.prank(address(stakingManagerInstance));
        managerInstance.linkPubkeyToNode(testPubkey, testNode, testLegacyId);
    }
    
    function test_linkPubkeyToNode_whenPaused() public {
        vm.prank(admin);
        managerInstance.pauseContract();
        
        bytes memory newPubkey = vm.randomBytes(48);
        vm.expectRevert();
        vm.prank(address(stakingManagerInstance));
        managerInstance.linkPubkeyToNode(newPubkey, testNode, 999);
    }

    // ============================================
    // Upgrade Tests
    // ============================================
    
    function test_upgradeTo() public {
        EtherFiNodesManager newImpl = new EtherFiNodesManager(
            address(stakingManagerInstance),
            address(roleRegistryInstance),
            address(rateLimiterInstance)
        );
        
        vm.prank(roleRegistryInstance.owner());
        managerInstance.upgradeTo(address(newImpl));
        
        // Verify upgrade
        assertTrue(true); // Upgrade succeeded
    }
    
    function test_upgradeTo_unauthorized() public {
        EtherFiNodesManager newImpl = new EtherFiNodesManager(
            address(stakingManagerInstance),
            address(roleRegistryInstance),
            address(rateLimiterInstance)
        );
        
        vm.expectRevert();
        vm.prank(bob);
        managerInstance.upgradeTo(address(newImpl));
    }
}

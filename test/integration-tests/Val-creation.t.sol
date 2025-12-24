// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "../../script/deploys/Deployed.s.sol";

import "../../src/interfaces/IStakingManager.sol";
import "../../src/interfaces/IEtherFiNode.sol";

import "../../src/libraries/DepositDataRootGenerator.sol";

contract ValCreationIntegrationTest is TestSetup, Deployed {
    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

    function _toArray(IStakingManager.DepositData memory d) internal pure returns (IStakingManager.DepositData[] memory arr) {
        arr = new IStakingManager.DepositData[](1);
        arr[0] = d;
    }

    function _toArrayU256(uint256 x) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = x;
    }

    function _ensureValCreationRoles() internal {
        address roleOwner = roleRegistryInstance.owner();

        // Ensure the operating admin can manage LP spawners + create validators.
        vm.startPrank(roleOwner);
        roleRegistryInstance.grantRole(liquidityPoolInstance.LIQUIDITY_POOL_ADMIN_ROLE(), ETHERFI_OPERATING_ADMIN);
        roleRegistryInstance.grantRole(liquidityPoolInstance.LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE(), ETHERFI_OPERATING_ADMIN);

        // Ensure operating timelock can create nodes.
        roleRegistryInstance.grantRole(stakingManagerInstance.STAKING_MANAGER_NODE_CREATOR_ROLE(), OPERATING_TIMELOCK);
        vm.stopPrank();

        // Ensure operating admin is an admin on NodeOperatorManager (required for whitelist ops)
        vm.prank(nodeOperatorManagerInstance.owner());
        nodeOperatorManagerInstance.updateAdmin(ETHERFI_OPERATING_ADMIN, true);
    }

    function _prepareSingleValidator(address spawner)
        internal
        returns (IStakingManager.DepositData memory depositData, uint256 bidId, address etherFiNode)
    {
        _ensureValCreationRoles();

        // Step 1: Whitelist + register node operator.
        vm.prank(ETHERFI_OPERATING_ADMIN);
        nodeOperatorManagerInstance.addToWhitelist(spawner);

        vm.deal(spawner, 10 ether);
        vm.startPrank(spawner);
        if (!nodeOperatorManagerInstance.registered(spawner)) {
            nodeOperatorManagerInstance.registerNodeOperator("test_ipfs_hash", 1000);
        }
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        vm.stopPrank();
        bidId = bidIds[0];

        // Step 2: Create a new EtherFiNode (with EigenPod) for compounding withdrawal creds.
        vm.prank(OPERATING_TIMELOCK);
        etherFiNode = stakingManagerInstance.instantiateEtherFiNode(true /*createEigenPod*/);
        address eigenPod = address(IEtherFiNode(etherFiNode).getEigenPod());

        // Step 3: Register validator spawner.
        vm.prank(ETHERFI_OPERATING_ADMIN);
        liquidityPoolInstance.registerValidatorSpawner(spawner);

        // Step 4: Build 1-ETH deposit data (must match compounding withdrawal creds).
        bytes memory pubkey = vm.randomBytes(48);
        bytes memory signature = vm.randomBytes(96);
        bytes memory withdrawalCredentials = managerInstance.addressToCompoundingWithdrawalCredentials(eigenPod);
        bytes32 depositDataRoot =
            depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, withdrawalCredentials, stakingManagerInstance.initialDepositAmount());

        depositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: depositDataRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
    }

    function test_ValCreation_batchRegisterAndCreateBeaconValidators_succeeds() public {
        address spawner = vm.addr(0x1234);

        (IStakingManager.DepositData memory depositData, uint256 bidId, address etherFiNode) = _prepareSingleValidator(spawner);

        // Step 5: batchRegister (spawner)
        vm.prank(spawner);
        liquidityPoolInstance.batchRegister(_toArray(depositData), _toArrayU256(bidId), etherFiNode);

        bytes32 validatorHash = keccak256(
            abi.encode(depositData.publicKey, depositData.signature, depositData.depositDataRoot, depositData.ipfsHashForEncryptedValidatorKey, bidId, etherFiNode)
        );
        assertEq(uint8(stakingManagerInstance.validatorCreationStatus(validatorHash)), uint8(IStakingManager.ValidatorCreationStatus.REGISTERED));

        // Step 6: Create validator (operating admin / validator creator role)
        vm.prank(ETHERFI_OPERATING_ADMIN);
        liquidityPoolInstance.batchCreateBeaconValidators(_toArray(depositData), _toArrayU256(bidId), etherFiNode);

        assertEq(uint8(stakingManagerInstance.validatorCreationStatus(validatorHash)), uint8(IStakingManager.ValidatorCreationStatus.CONFIRMED));
    }

    function test_ValCreation_batchCreateBeaconValidators_accountsForEthCorrectly() public {
        address spawner = vm.addr(0x5678);

        (IStakingManager.DepositData memory depositData, uint256 bidId, address etherFiNode) = _prepareSingleValidator(spawner);

        vm.prank(spawner);
        liquidityPoolInstance.batchRegister(_toArray(depositData), _toArrayU256(bidId), etherFiNode);

        uint128 initialTotalOut = liquidityPoolInstance.totalValueOutOfLp();
        uint128 initialTotalIn = liquidityPoolInstance.totalValueInLp();

        // 1 ETH per validator (current protocol design)
        uint128 expectedEthOut = 1 ether;

        vm.prank(ETHERFI_OPERATING_ADMIN);
        liquidityPoolInstance.batchCreateBeaconValidators(_toArray(depositData), _toArrayU256(bidId), etherFiNode);

        assertEq(liquidityPoolInstance.totalValueOutOfLp(), initialTotalOut + expectedEthOut);
        assertEq(liquidityPoolInstance.totalValueInLp(), initialTotalIn - expectedEthOut);
    }
}

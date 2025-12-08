pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import {ContractCodeChecker} from "../ContractCodeChecker.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import {StakingManager} from "../../src/StakingManager.sol";
import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {RoleRegistry} from "../../src/RoleRegistry.sol";
import {EtherFiRestaker} from "../../src/EtherFiRestaker.sol";

import {IEtherFiNodesManager} from "../../src/interfaces/IEtherFiNodesManager.sol";
import {IStakingManager} from "../../src/interfaces/IStakingManager.sol";
import {IEigenPodTypes} from "../../src/eigenlayer-interfaces/IEigenPod.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

// forge script script/validator-key-gen/verify.s.sol --fork-url $MAINNET_RPC_URL

contract VerifyValidatorKeyGen is Script {
    bytes32 commitHashSalt = bytes32(bytes20(hex"25312df178d6eb8143604e47b7aa9e618779c0de"));
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    ContractCodeChecker public contractCodeChecker;

    // === MAINNET CONTRACT ADDRESSES ===
    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant ETHERFI_RESTAKER_PROXY = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;

    address constant AUCTION_MANAGER = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address constant ETHERFI_NODE_BEACON = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant ETH_DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    address constant RATE_LIMITER_PROXY = 0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;
    address constant REWARDS_COORDINATOR = 0x7750d328b314EfFa365A0402CcfD489B80B0adda;
    address constant ETHERFI_REDEMPTION_MANAGER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    
    address constant ETHERFI_OPERATING_ADMIN = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    // === IMPLEMENTATION ADDRESSES ===
    address constant LIQUIDITY_POOL_IMPL = 0x45c2fB84E35a097055716A2d92e3ED499c519b98;
    LiquidityPool liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL_PROXY));
    address constant STAKING_MANAGER_IMPL = 0xd3985048Bf1Cb613F5E199713a86B2aD3954F82A;
    StakingManager stakingManager = StakingManager(STAKING_MANAGER_PROXY);
    address constant ETHERFI_NODES_MANAGER_IMPL = 0x3affACEBBb25ba122295bef4E1083989fEFAf003;
    EtherFiNodesManager etherFiNodesManager = EtherFiNodesManager(ETHERFI_NODES_MANAGER_PROXY);
    address constant ETHERFI_RESTAKER_IMPL = 0x3905b79B1c9D5424921f50286b4782527217F10f;
    EtherFiRestaker constant etherFiRestaker = EtherFiRestaker(payable(ETHERFI_RESTAKER_PROXY));

    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);

    LiquidityPool constant liquidityPoolImplementation = LiquidityPool(payable(LIQUIDITY_POOL_IMPL));
    StakingManager constant stakingManagerImplementation = StakingManager(STAKING_MANAGER_IMPL);
    EtherFiRestaker constant etherFiRestakerImplementation = EtherFiRestaker(payable(ETHERFI_RESTAKER_IMPL));
    EtherFiNodesManager constant etherFiNodesManagerImplementation = EtherFiNodesManager(ETHERFI_NODES_MANAGER_IMPL);

    function run() public {
        console2.log("================================================");
        console2.log("Running Verify Validator Key Gen");
        console2.log("================================================");
        console2.log("");

        contractCodeChecker = new ContractCodeChecker();

        verifyAddress();
        verifyBytecode();
        verifyNewFunctionality();
    }

    function verifyBytecode() internal {
        LiquidityPool newLiquidityPoolImplementation = new LiquidityPool();
        StakingManager newStakingManagerImplementation = new StakingManager(address(LIQUIDITY_POOL_PROXY), address(ETHERFI_NODES_MANAGER_PROXY), address(ETH_DEPOSIT_CONTRACT), address(AUCTION_MANAGER), address(ETHERFI_NODE_BEACON), address(ROLE_REGISTRY));
        EtherFiNodesManager newEtherFiNodesManagerImplementation = new EtherFiNodesManager(address(STAKING_MANAGER_PROXY), address(ROLE_REGISTRY), address(RATE_LIMITER_PROXY));
        EtherFiRestaker newEtherFiRestakerImplementation = new EtherFiRestaker(address(REWARDS_COORDINATOR), address(ETHERFI_REDEMPTION_MANAGER));

        contractCodeChecker.verifyContractByteCodeMatch(LIQUIDITY_POOL_IMPL, address(newLiquidityPoolImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(STAKING_MANAGER_IMPL, address(newStakingManagerImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(ETHERFI_NODES_MANAGER_IMPL, address(newEtherFiNodesManagerImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(ETHERFI_RESTAKER_IMPL, address(newEtherFiRestakerImplementation));

        console2.log(unicode"✓ Bytecode verified successfully");
    }

    function verifyAddress() public {
        // LiquidityPool
        {
            bytes memory constructorArgs = abi.encode();
            bytes memory bytecode = abi.encodePacked(
                type(LiquidityPool).creationCode,
                constructorArgs
            );
            address predictedAddress = factory.computeAddress(commitHashSalt, bytecode);
            require(LIQUIDITY_POOL_IMPL == predictedAddress, "LiquidityPool deployment address mismatch");
        }

        // StakingManager
        {
            bytes memory constructorArgs = abi.encode(address(LIQUIDITY_POOL_PROXY), address(ETHERFI_NODES_MANAGER_PROXY), address(ETH_DEPOSIT_CONTRACT), address(AUCTION_MANAGER), address(ETHERFI_NODE_BEACON), address(ROLE_REGISTRY));
            bytes memory bytecode = abi.encodePacked(
                type(StakingManager).creationCode,
                constructorArgs
            );
            address predictedAddress = factory.computeAddress(commitHashSalt, bytecode);
            require(STAKING_MANAGER_IMPL == predictedAddress, "StakingManager deployment address mismatch");
        }

        // EtherFiNodesManager
        {
            bytes memory constructorArgs = abi.encode(address(STAKING_MANAGER_PROXY), address(ROLE_REGISTRY), address(RATE_LIMITER_PROXY));
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiNodesManager).creationCode,
                constructorArgs
            );
            address predictedAddress = factory.computeAddress(commitHashSalt, bytecode);
            require(ETHERFI_NODES_MANAGER_IMPL == predictedAddress, "EtherFiNodesManager deployment address mismatch");
        }

        // EtherFiRestaker
        {
            bytes memory constructorArgs = abi.encode(REWARDS_COORDINATOR, ETHERFI_REDEMPTION_MANAGER);
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRestaker).creationCode,
                constructorArgs
            );
            address predictedAddress = factory.computeAddress(commitHashSalt, bytecode);
            require(ETHERFI_RESTAKER_IMPL == predictedAddress, "EtherFiRestaker deployment address mismatch");
        }

        console2.log(unicode"✓ Address verified successfully");
    }

    function verifyNewFunctionality() public {
        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = IStakingManager.DepositData({
            publicKey: vm.randomBytes(48),
            signature: vm.randomBytes(96),
            depositDataRoot: bytes32(0),
            ipfsHashForEncryptedValidatorKey: "0x00"
        });
        address etherFiNode = address(0x1234);

        {
            require(roleRegistry.hasRole(liquidityPoolImplementation.LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE(), ETHERFI_OPERATING_ADMIN), "ETHERFI_OPERATING_ADMIN does not have LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE");
            require(roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(), address(stakingManager)), "StakingManager does not have ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");
            require(roleRegistry.hasRole(stakingManagerImplementation.STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE(), realElExiter), "realElExiter does not have STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE");
            require(roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE(), realElExiter), "realElExiter does not have ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE");
            require(EtherFiRestaker(payable(ETHERFI_RESTAKER_PROXY)).isDelegated(), "Can't find EigenLayer Delegation Manager");
        }

        // Verify that the new functionality is exists and is role restricted
        {
            vm.expectRevert(IStakingManager.IncorrectRole.selector);
            liquidityPool.batchCreateBeaconValidators(depositDataArray, new uint256[](1), etherFiNode);
        }

        {
            vm.expectRevert(IStakingManager.IncorrectRole.selector);
            stakingManager.invalidateRegisteredBeaconValidator(depositDataArray[0], 1, etherFiNode);

            vm.expectRevert(IStakingManager.InvalidCaller.selector);
            stakingManager.registerBeaconValidators(depositDataArray, new uint256[](1), etherFiNode);
        }

        {
            vm.expectRevert(IEtherFiNodesManager.UnknownNode.selector); // Proves that role has been granted to stakingManager
            vm.prank(address(stakingManager));
            etherFiNodesManager.createEigenPod(etherFiNode);

            vm.expectRevert(IEtherFiNodesManager.EmptyConsolidationRequest.selector); // Does not revert on IncorrectRole
            vm.prank(realElExiter); // Proves that role has been granted to realElExiter
            etherFiNodesManager.requestConsolidation{value: 0}(new IEigenPodTypes.ConsolidationRequest[](0));
        }

        console2.log(unicode"✓ New functionality verified successfully");
    }
}
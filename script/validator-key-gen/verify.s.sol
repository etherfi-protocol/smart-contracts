pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import {ContractCodeChecker} from "../ContractCodeChecker.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import {StakingManager} from "../../src/StakingManager.sol";
import {IStakingManager} from "../../src/interfaces/IStakingManager.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

contract VerifyValidatorKeyGen is Script {
    bytes32 commitHashSalt = bytes32(bytes20(hex"700dc0d12131a52a6c530b7550842ead4bb0a834"));
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    ContractCodeChecker public contractCodeChecker;

    // === MAINNET CONTRACT ADDRESSES ===
    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant AUCTION_MANAGER = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address constant ETHERFI_NODE_BEACON = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant ETH_DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    address constant EIGEN_POD_MANAGER = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
    address constant DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    // === IMPLEMENTATION ADDRESSES ===
    address constant LIQUIDITY_POOL_IMPL = 0x4C6767A0afDf06c55DAcb03cB26aaB34Eed281fc;
    LiquidityPool liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL_PROXY));
    address constant STAKING_MANAGER_IMPL = 0xF73996bceDE56AD090024F2Fd4ca545A3D06c8E3;
    StakingManager stakingManager = StakingManager(STAKING_MANAGER_PROXY);

    LiquidityPool constant liquidityPoolImplementation = LiquidityPool(payable(LIQUIDITY_POOL_IMPL));
    StakingManager constant stakingManagerImplementation = StakingManager(STAKING_MANAGER_IMPL);

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

        address deployedLiquidityPool = address(0x4C6767A0afDf06c55DAcb03cB26aaB34Eed281fc);
        address deployedStakingManager = address(0xF73996bceDE56AD090024F2Fd4ca545A3D06c8E3);

        console2.log("deployedLiquidityPool:", deployedLiquidityPool);
        console2.log("deployedStakingManager:", deployedStakingManager);
        console2.log("newLiquidityPoolImplementation:", address(newLiquidityPoolImplementation));
        console2.log("newStakingManagerImplementation:", address(newStakingManagerImplementation));

        contractCodeChecker.verifyContractByteCodeMatch(deployedLiquidityPool, address(newLiquidityPoolImplementation));
        contractCodeChecker.verifyContractByteCodeMatch(deployedStakingManager, address(newStakingManagerImplementation));

        console2.log("Bytecode verified successfully");
        console2.log("================================================");
        console2.log("");
    }

    function verifyAddress() public view {
        console2.log("=== VERIFYING ADDRESS ===");
        console2.log("================================================");
        console2.log("");

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

        console2.log("================================================");
        console2.log("");
    }

    function verifyNewFunctionality() public {
        console2.log("=== VERIFYING NEW FUNCTIONALITY ===");
        console2.log("================================================");
        console2.log("");

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = IStakingManager.DepositData({
            publicKey: vm.randomBytes(48),
            signature: vm.randomBytes(96),
            depositDataRoot: bytes32(0),
            ipfsHashForEncryptedValidatorKey: "0x00"
        });
        address etherFiNode = address(0x1234);

        // Verify that the new functionality is exists and is role restricted
        {
            console2.log("LiquidityPool new functionality:");
            console2.log("================================================");
            console2.log("");

            vm.expectRevert(IStakingManager.IncorrectRole.selector);
            liquidityPool.batchCreateBeaconValidators(depositDataArray, new uint256[](1), etherFiNode);
        }

        {
            console2.log("StakingManager new functionality:");
            console2.log("================================================");
            console2.log("");

            vm.expectRevert(IStakingManager.IncorrectRole.selector);
            stakingManager.invalidateRegisteredBeaconValidator(depositDataArray[0], 1, etherFiNode);
        }

        console2.log("New functionality verified successfully");
        console2.log("================================================");
        console2.log("");
    }
}
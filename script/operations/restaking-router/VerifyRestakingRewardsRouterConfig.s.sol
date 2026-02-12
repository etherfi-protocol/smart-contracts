// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import {ContractCodeChecker} from "../../ContractCodeChecker.sol";
import {RestakingRewardsRouter} from "../../../src/RestakingRewardsRouter.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {RoleRegistry} from "../../../src/RoleRegistry.sol";
import "../../utils/utils.sol";

// forge script script/operations/restaking-router/VerifyRestakingRewardsRouterConfig.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract VerifyRestakingRewardsRouterConfig is Script, Utils {
    bytes32 commitHashSalt = bytes32(bytes20(hex"1a10a60fc25f1c7f7052123edbe683ed2524943d"));
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    ContractCodeChecker public contractCodeChecker;

    // === DEPLOYED ADDRESSES ===
    address constant RESTAKING_REWARDS_ROUTER_PROXY = 0x89E45081437c959A827d2027135bC201Ab33a2C8;
    address constant RESTAKING_REWARDS_ROUTER_IMPL = 0xcB6e9a5943946307815eaDF3BEDC49fE30290CA8;

    // === CONSTRUCTOR ARGS ===
    address constant REWARD_TOKEN_ADDRESS = 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83;

    // === EXPECTED CONFIGURATION ===
    address constant SELINI_MARKET_MAKER = 0x0B7178f2f1f44Cae3aed801c21D589CbAb458118;

    // === ROLES ===
    bytes32 constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    bytes32 constant ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE");

    RestakingRewardsRouter router = RestakingRewardsRouter(payable(RESTAKING_REWARDS_ROUTER_PROXY));
    RestakingRewardsRouter routerImpl = RestakingRewardsRouter(payable(RESTAKING_REWARDS_ROUTER_IMPL));
    RoleRegistry roleRegistry = RoleRegistry(ROLE_REGISTRY);

    function run() public {
        console2.log("================================================");
        console2.log("Running Verify RestakingRewardsRouter Config");
        console2.log("================================================");
        console2.log("");

        contractCodeChecker = new ContractCodeChecker();

        verifyAddress();
        verifyBytecode();
        verifyImmutables();
        verifyRoles();
        verifyConfiguration();
    }

    function verifyAddress() public {
        console2.log("Verifying Create2 addresses...");

        // Implementation
        {
            bytes memory constructorArgs = abi.encode(
                ROLE_REGISTRY,
                REWARD_TOKEN_ADDRESS,
                LIQUIDITY_POOL
            );
            bytes memory bytecode = abi.encodePacked(
                type(RestakingRewardsRouter).creationCode,
                constructorArgs
            );
            address predictedAddress = factory.computeAddress(commitHashSalt, bytecode);
            require(RESTAKING_REWARDS_ROUTER_IMPL == predictedAddress, "RestakingRewardsRouter implementation address mismatch");
        }

        // Proxy
        {
            bytes memory initializerData = abi.encodeWithSelector(
                RestakingRewardsRouter.initialize.selector
            );
            bytes memory constructorArgs = abi.encode(
                RESTAKING_REWARDS_ROUTER_IMPL,
                initializerData
            );
            bytes memory bytecode = abi.encodePacked(
                type(UUPSProxy).creationCode,
                constructorArgs
            );
            address predictedAddress = factory.computeAddress(commitHashSalt, bytecode);
            require(RESTAKING_REWARDS_ROUTER_PROXY == predictedAddress, "RestakingRewardsRouter proxy address mismatch");
        }

        console2.log(unicode"✓ Create2 addresses verified successfully");
        console2.log("");
    }

    function verifyBytecode() public {
        console2.log("Verifying bytecode...");

        RestakingRewardsRouter newRouterImpl = new RestakingRewardsRouter(
            ROLE_REGISTRY,
            REWARD_TOKEN_ADDRESS,
            LIQUIDITY_POOL
        );

        contractCodeChecker.verifyContractByteCodeMatch(RESTAKING_REWARDS_ROUTER_IMPL, address(newRouterImpl));

        console2.log(unicode"✓ Bytecode verified successfully");
        console2.log("");
    }

    function verifyImmutables() public view {
        console2.log("Verifying immutables...");

        require(router.liquidityPool() == LIQUIDITY_POOL, "liquidityPool mismatch");
        require(router.rewardTokenAddress() == REWARD_TOKEN_ADDRESS, "rewardTokenAddress mismatch");
        require(address(router.roleRegistry()) == ROLE_REGISTRY, "roleRegistry mismatch");

        console2.log("  liquidityPool: %s", router.liquidityPool());
        console2.log("  rewardTokenAddress: %s", router.rewardTokenAddress());
        console2.log("  roleRegistry: %s", address(router.roleRegistry()));

        console2.log(unicode"✓ Immutables verified successfully");
        console2.log("");
    }

    function verifyRoles() public view {
        console2.log("Verifying roles...");

        // ETHERFI_REWARDS_ROUTER_ADMIN_ROLE -> ETHERFI_OPERATING_ADMIN
        require(
            roleRegistry.hasRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, ETHERFI_OPERATING_ADMIN),
            "ETHERFI_OPERATING_ADMIN does not have ETHERFI_REWARDS_ROUTER_ADMIN_ROLE"
        );
        console2.log("  ETHERFI_REWARDS_ROUTER_ADMIN_ROLE granted to ETHERFI_OPERATING_ADMIN: %s", ETHERFI_OPERATING_ADMIN);

        // ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE -> ADMIN_EOA
        require(
            roleRegistry.hasRole(ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE, ADMIN_EOA),
            "ADMIN_EOA does not have ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE"
        );
        console2.log("  ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE granted to ADMIN_EOA: %s", ADMIN_EOA);

        console2.log(unicode"✓ Roles verified successfully");
        console2.log("");
    }

    function verifyConfiguration() public view {
        console2.log("Verifying configuration...");

        // Verify recipientAddress is set to SELINI_MARKET_MAKER
        require(
            router.recipientAddress() == SELINI_MARKET_MAKER,
            "recipientAddress mismatch"
        );
        console2.log("  recipientAddress: %s", router.recipientAddress());

        // Verify implementation address
        require(
            router.getImplementation() == RESTAKING_REWARDS_ROUTER_IMPL,
            "Implementation address mismatch"
        );
        console2.log("  implementation: %s", router.getImplementation());

        console2.log(unicode"✓ Configuration verified successfully");
        console2.log("");
    }
}

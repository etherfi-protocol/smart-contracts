// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {EtherFiNodesManager} from "@etherfi/staking/EtherFiNodesManager.sol";
import {EtherFiNode} from "@etherfi/staking/EtherFiNode.sol";
import {StakingManager} from "@etherfi/staking/StakingManager.sol";
import {EtherFiAdmin} from "@etherfi/oracle/EtherFiAdmin.sol";
import {IEtherFiAdmin} from "@etherfi/oracle/interfaces/IEtherFiAdmin.sol";
import {Deployed} from "@scripts/deploys/Deployed.s.sol";
import {Utils, ICreate2Factory} from "@scripts/utils/utils.sol";

/**
 * @title DeployNonEigenPodCreds
 * @notice Deploys the four implementations changed by the non-EigenPod withdrawal credentials work (PR #485).
 *
 * EtherFiNodesManager  UUPS proxy  -> upgradeTo
 * StakingManager       UUPS proxy  -> upgradeTo
 * EtherFiAdmin         UUPS proxy  -> upgradeTo
 * EtherFiNode          beacon impl -> StakingManager.upgradeEtherFiNode
 *
 * Constructor args are taken from the live deployments' immutables so the new implementations
 * keep identical wiring. Deploys via CREATE2 so the addresses are known before the Safe txs
 * are hashed.
 *
 * EtherFiNodesManager sits 98 bytes under the EIP-170 24,576-byte runtime limit, so it must be
 * compiled with the repo's pinned settings (solc 0.8.27, optimizer_runs = 1500). Run
 * `forge build --sizes` and confirm before broadcasting.
 *
 * command:
 * forge script script/upgrades/non-eigenpod-creds/deploy.s.sol:DeployNonEigenPodCreds \
 *   --fork-url $MAINNET_RPC_URL --verify --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeployNonEigenPodCreds is Script, Deployed, Utils {
    ICreate2Factory public constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    /// @dev release commit for this upgrade; also the CREATE2 salt
    bytes32 public constant commitHashSalt = bytes32(bytes20(hex"692d3f75d9b7cad14fda1e6922fd35db845fbc4f"));

    // EtherFiAdmin numeric constructor args, read from the live proxy 0x0EF8fa47...
    int256 public constant ADMIN_MAX_ACCEPTABLE_REBASE_APR_BPS = 1000;
    uint256 public constant ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE = 100;
    uint256 public constant ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW = 100_800;
    uint256 public constant ADMIN_MAX_FINALIZED_WITHDRAWAL_PER_DAY = 150_000 ether;
    uint256 public constant ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY = 100;
    uint256 public constant ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT = 3500;

    address public etherFiNodesManagerImpl;
    address public etherFiNodeImpl;
    address public stakingManagerImpl;
    address public etherFiAdminImpl;

    function run() public virtual {
        console2.log("================================================");
        console2.log("=== non-EigenPod withdrawal credentials deploy ==");
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast();
        _deployAll();
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment summary ===");
        console2.log("EtherFiNodesManager impl:", etherFiNodesManagerImpl);
        console2.log("EtherFiNode impl:        ", etherFiNodeImpl);
        console2.log("StakingManager impl:     ", stakingManagerImpl);
        console2.log("EtherFiAdmin impl:       ", etherFiAdminImpl);
        console2.log("");
        console2.log("Paste these into transactions.s.sol before generating the Safe calldata.");
    }

    /// @notice CREATE2-deploys all four implementations. Idempotent: reuses any that already exist,
    ///         so the transactions script can call it to stage a fork before the real broadcast.
    function _deployAll() internal {
        // EtherFiNodesManager implementation
        {
            bytes memory constructorArgs = abi.encode(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER);
            bytes memory bytecode = abi.encodePacked(type(EtherFiNodesManager).creationCode, constructorArgs);
            etherFiNodesManagerImpl =
                deploy("EtherFiNodesManager", constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // EtherFiNode implementation (beacon)
        {
            bytes memory constructorArgs =
                abi.encode(LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, EIGENLAYER_POD_MANAGER, EIGENLAYER_DELEGATION_MANAGER);
            bytes memory bytecode = abi.encodePacked(type(EtherFiNode).creationCode, constructorArgs);
            etherFiNodeImpl = deploy("EtherFiNode", constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // StakingManager implementation
        {
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL,
                ETHERFI_NODES_MANAGER,
                ETH2_DEPOSIT_CONTRACT,
                AUCTION_MANAGER,
                ETHERFI_NODE_BEACON,
                ROLE_REGISTRY
            );
            bytes memory bytecode = abi.encodePacked(type(StakingManager).creationCode, constructorArgs);
            stakingManagerImpl = deploy("StakingManager", constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // EtherFiAdmin implementation
        {
            bytes memory constructorArgs = abi.encode(
                etherFiAdminConstructorAddresses(),
                ADMIN_MAX_ACCEPTABLE_REBASE_APR_BPS,
                ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE,
                ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW,
                ADMIN_MAX_FINALIZED_WITHDRAWAL_PER_DAY,
                ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY,
                ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT
            );
            bytes memory bytecode = abi.encodePacked(type(EtherFiAdmin).creationCode, constructorArgs);
            // logging disabled: Utils.formatConstructorArgs cannot decode the ConstructorAddresses
            // struct and reverts with "Unsupported static type".
            etherFiAdminImpl = deploy("EtherFiAdmin", constructorArgs, bytecode, commitHashSalt, false, factory);
        }
    }

    function etherFiAdminConstructorAddresses() internal pure returns (IEtherFiAdmin.ConstructorAddresses memory) {
        return IEtherFiAdmin.ConstructorAddresses({
            etherFiOracle: ETHERFI_ORACLE,
            stakingManager: STAKING_MANAGER,
            auctionManager: AUCTION_MANAGER,
            etherFiNodesManager: ETHERFI_NODES_MANAGER,
            liquidityPool: LIQUIDITY_POOL,
            withdrawRequestNft: WITHDRAW_REQUEST_NFT,
            roleRegistry: ROLE_REGISTRY,
            priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE
        });
    }
}

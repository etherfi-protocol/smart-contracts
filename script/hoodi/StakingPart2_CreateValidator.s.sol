// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/interfaces/IStakingManager.sol";
import "../../src/interfaces/IEtherFiNodesManager.sol";
import "../../src/interfaces/ILiquidityPool.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import "../../src/interfaces/IRoleRegistry.sol";

/**
 * @title Staking Part 2: Create Validator
 * @notice Second part - creates the validator after you've generated keys
 * 
 * Prerequisites:
 * 1. You've run StakingPart1_Setup.s.sol
 * 2. You've generated validator keys with the EigenPod address
 * 3. You have the pubkey and signature from deposit_data-*.json
 * 
 * Usage:
 * 1. Set environment variables:
 *    PRIVATE_KEY=<your_wallet_private_key>
 *    VALIDATOR_PUBKEY=<48-byte pubkey from deposit data, no 0x prefix>
 *    VALIDATOR_SIGNATURE=<96-byte signature from deposit data, no 0x prefix>
 *    BID_ID=<bid ID from Part 1>
 *    ETHERFI_NODE=<EtherFi node address from Part 1>
 *    
 * 2. Run: forge script script/StakingPart2_CreateValidator.s.sol:StakingPart2 --rpc-url https://rpc.hoodi.ethpandaops.io --broadcast
 */
contract StakingPart2 is Script {
    // Hoodi testnet addresses

    address constant LIQUIDITY_POOL = 0xA6C7D9A055Ebb433E5C6E098b0487875537852F0;
    address constant STAKING_MANAGER = 0xEcf3C0Dc644DBC7d0fbf7f69651D90f2177D0dFf;
    address constant ETHERFI_NODES_MANAGER = 0x5eF18135824b4C99f142be7714D90673c7fcE775;
    address constant AUCTION_MANAGER = 0xE3BDCE392B6363493a8Cbc4580857A3931023c9C;
    address constant NODE_OPERATOR_MANAGER = 0x51BB73660D9a12fa06e2A42BcED7D25289d4054D;
    address constant ROLE_REGISTRY = 0x8309580c86C11e61e3C57c7227f74535f6801d7C;

    address constant DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    
    LiquidityPool liquidityPool;
    IStakingManager stakingManager;
    IEtherFiNodesManager etherFiNodesManager;
    IRoleRegistry roleRegistry;
    
    function run() external {
        // Initialize interfaces
        liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));
        stakingManager = IStakingManager(STAKING_MANAGER);
        etherFiNodesManager = IEtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        roleRegistry = IRoleRegistry(ROLE_REGISTRY);

        console.log("\n========== EtherFi Staking - Part 2 ==========");
        console.log("Creating validator with your generated keys\n");
        
        // Get parameters
        bytes memory pubkey = vm.envBytes("VALIDATOR_PUBKEY");
        bytes memory signature = vm.envBytes("VALIDATOR_SIGNATURE");
        uint256 bidId = vm.envUint("BID_ID");
        address etherFiNode = vm.envAddress("ETHERFI_NODE");
        
        // Validate inputs
        require(pubkey.length == 48, "Invalid pubkey length");
        require(signature.length == 96, "Invalid signature length");
        require(etherFiNode != address(0), "Invalid EtherFi node address");
        
        console.log("Using parameters:");
        console.log("- Bid ID: %s", bidId);
        console.log("- EtherFi Node: %s", etherFiNode);
        console.log("- Validator pubkey: %s", vm.toString(pubkey));
        
        // Get withdrawal credentials from EtherFi node's EigenPod
        address eigenPod = address(IEtherFiNode(etherFiNode).getEigenPod());
        console.log("EigenPod: %s", eigenPod);
        bytes memory withdrawalCredentials = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod);
        
        console.log("- EigenPod: %s", eigenPod);
        console.log("- Withdrawal credentials: %s", vm.toString(withdrawalCredentials));
        
        // Generate deposit data root
        bytes32 depositRoot = stakingManager.generateDepositDataRoot(
            pubkey,
            signature,
            withdrawalCredentials,
            1 ether
        );
        
        console.log("!Ensure that this root matches the one in deposit_data.json! - Deposit root: %s", vm.toString(depositRoot));
        
        // Prepare deposit data
        IStakingManager.DepositData memory depositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: depositRoot,
            ipfsHashForEncryptedValidatorKey: "hoodi_testnet_validator"
        });
        
        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;
        
        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId;
        
        // Check deposit contract balance before
        uint256 depositContractBefore = DEPOSIT_CONTRACT.balance;
        
        console.log("\nCreating validator with 1 ETH initial deposit...");
        
        // Check if msg.sender is registered as validator spawner
        
        {
        address depositor = vm.addr(vm.envUint("PRIVATE_KEY"));
        bool isSpawner = liquidityPool.validatorSpawner(depositor);

        bool isLiquidityPoolAdmin = roleRegistry.hasRole(keccak256("LIQUIDITY_POOL_ADMIN_ROLE"),depositor);

            if (!isLiquidityPoolAdmin){
                vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

                roleRegistry.grantRole(keccak256("LIQUIDITY_POOL_ADMIN_ROLE"), depositor);
                vm.stopBroadcast();
            }
            if (!isSpawner) {
                console.log("fail-1");
                vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
                liquidityPool.registerValidatorSpawner(depositor);
                vm.stopBroadcast();
                console.log("fail-2");

            }
        }
        // Create validator through LiquidityPool
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        liquidityPool.batchRegister(
            depositDataArray,
            bidIdArray,
            etherFiNode
        );
        vm.stopBroadcast();
        
        uint256 depositContractAfter = DEPOSIT_CONTRACT.balance;
        
        console.log("\n========== VALIDATOR CREATED ==========");
        console.log("- 1 ETH sent to beacon chain deposit contract");
        console.log("- Deposit contract balance increased by: %s ETH", (depositContractAfter - depositContractBefore) / 1e18);
        console.log("- Validator is now pending oracle approval");
        console.log("\n========== NEXT STEPS ==========");
        console.log("1. Wait for oracle members to approve your validator");
        console.log("2. Oracle will automatically send remaining 31 ETH");
        console.log("3. Your validator will then be active on beacon chain");
        console.log("\nMonitor your validator:");
        console.log("- Bid ID: %s", bidId);
        console.log("- EtherFi Node: %s", etherFiNode);
        console.log("- Validator Pubkey: %s", vm.toString(pubkey));
        console.log("=====================================\n");
    }
}
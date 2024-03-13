// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../../src/LiquidityPool.sol";
import "../../src/StakingManager.sol";
import "../../src/TNFT.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";

import "../../src/AuctionManager.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";

contract MultipleValidatorsPerSafe is Script {
    using Strings for string;
        
    AddressProvider public addressProvider;

    address addressProviderAddress;

    EtherFiNodesManager nodesManager;
    LiquidityPool liquidityPool;
    StakingManager stakingManager;
    TNFT tnft;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        retrieve_contract_addresses();
        
        vm.startBroadcast(deployerPrivateKey);

        LiquidityPool LiquidityPoolNewImpl = new LiquidityPool();
        StakingManager StakingManagerNewImpl = new StakingManager();
        TNFT TNFTNewImpl = new TNFT();
        EtherFiNodesManager EtherFiNodesManagerNewImpl = new EtherFiNodesManager();
        EtherFiNode EtherFiNodeNewImpl = new EtherFiNode();

        address el_delegationManager;
        if (block.chainid == 1) {
            el_delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

            // Perform the upgrades manually by the timelock
        } else if (block.chainid == 5) {
            el_delegationManager = 0x1b7b8F6b258f95Cf9596EabB9aa18B62940Eb0a8;

            require(deployer == liquidityPool.owner(), "Only the owner can upgrade the contract");
            require(deployer == stakingManager.owner(), "Only the owner can upgrade the contract");
            require(deployer == tnft.owner(), "Only the owner can upgrade the contract");
            require(deployer == nodesManager.owner(), "Only the owner can upgrade the contract");

            liquidityPool.upgradeTo(address(LiquidityPoolNewImpl));
            stakingManager.upgradeTo(address(StakingManagerNewImpl));
            tnft.upgradeTo(address(TNFTNewImpl));
            nodesManager.upgradeTo(address(EtherFiNodesManagerNewImpl));

            stakingManager.upgradeEtherFiNode(address(EtherFiNodeNewImpl));
            nodesManager.initializeOnUpgrade2(el_delegationManager);
        }

        vm.stopBroadcast();
    }

    function retrieve_contract_addresses() internal {
        stakingManager = StakingManager(addressProvider.getContractAddress("StakingManager"));
        nodesManager = EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager")));
        tnft = TNFT(addressProvider.getContractAddress("TNFT"));
        liquidityPool = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));
    }

}

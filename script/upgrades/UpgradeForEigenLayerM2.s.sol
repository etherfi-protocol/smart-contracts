// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../../src/Liquifier.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/StakingManager.sol";

import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";


contract UpgradeForEigenLayerM2 is Script {
    using Strings for string;
        
    AddressProvider public addressProvider;

    address addressProviderAddress;

    StakingManager stakingManager;
    EtherFiNodesManager nodesManager;
    Liquifier liquifier;

    EtherFiTimelock timelock;

    event TimelockTransaction(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt, uint256 delay);

    function getSelector(bytes memory _f) public pure returns (bytes4) {
        return bytes4(keccak256(_f));
    }

    function genUpgradeTo(address _target, address _newImplementation) public pure returns (bytes memory) {
        bytes4 functionSelector = getSelector("upgradeTo(address)");
        return abi.encodeWithSelector(functionSelector, _newImplementation);
    }

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        retrieve_contract_addresses();
        
        vm.startBroadcast(deployerPrivateKey);

        Liquifier LiquifierNewImpl = new Liquifier();
        EtherFiNodesManager EtherFiNodesManagerNewImpl = new EtherFiNodesManager();
        EtherFiNode EtherFiNodeNewImpl = new EtherFiNode();

        address el_delegationManager;
        address pancakeRouter;
        address el_admin;
        if (block.chainid == 1) {
            el_delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
            pancakeRouter = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
            el_admin = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

            uint256 minDelay = timelock.getMinDelay();

            emit TimelockTransaction(address(liquifier), 0, genUpgradeTo(address(liquifier), address(LiquifierNewImpl)), bytes32(0), bytes32(0), minDelay);
            emit TimelockTransaction(address(stakingManager), 0, abi.encodeWithSelector(getSelector("upgradeEtherFiNode(address)"), address(EtherFiNodeNewImpl)), bytes32(0), bytes32(0), minDelay);
            emit TimelockTransaction(address(nodesManager), 0, genUpgradeTo(address(nodesManager), address(EtherFiNodesManagerNewImpl)), bytes32(0), bytes32(0), minDelay);

            emit TimelockTransaction(address(liquifier), 0, abi.encodeWithSelector(getSelector("initializeOnUpgrade(address,address)"), el_delegationManager, pancakeRouter), bytes32(0), bytes32(0), minDelay);
            emit TimelockTransaction(address(nodesManager), 0, abi.encodeWithSelector(getSelector("initializeOnUpgrade2(address)"), el_delegationManager), bytes32(0), bytes32(0), minDelay);
            emit TimelockTransaction(address(nodesManager), 0, abi.encodeWithSelector(getSelector("updateEigenLayerOperatingAdmin(address,bool)"), el_admin, true), bytes32(0), bytes32(0), minDelay);

            // Perform the upgrades manually by the timelock
        } else if (block.chainid == 17000) {
            el_delegationManager = 0x1b7b8F6b258f95Cf9596EabB9aa18B62940Eb0a8;
            pancakeRouter = address(0); // not live in Holesky
            el_admin = deployer;

            require(deployer == liquifier.owner(), "Only the owner can upgrade the contract");
            require(deployer == stakingManager.owner(), "Only the owner can upgrade the contract");
            require(deployer == nodesManager.owner(), "Only the owner can upgrade the contract");

            liquifier.upgradeTo(address(LiquifierNewImpl));
            nodesManager.upgradeTo(address(EtherFiNodesManagerNewImpl));
            stakingManager.upgradeEtherFiNode(address(EtherFiNodeNewImpl));

            liquifier.initializeOnUpgrade(el_delegationManager, pancakeRouter);
            nodesManager.initializeOnUpgrade2(el_delegationManager);
            nodesManager.updateEigenLayerOperatingAdmin(el_admin, true);
        }

        vm.stopBroadcast();
    }

    function retrieve_contract_addresses() internal {
        stakingManager = StakingManager(addressProvider.getContractAddress("StakingManager"));
        nodesManager = EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager")));
        liquifier = Liquifier(payable(addressProvider.getContractAddress("Liquifier")));
        timelock = EtherFiTimelock(payable(addressProvider.getContractAddress("EtherFiTimelock")));
    }

}

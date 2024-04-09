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


contract Upgrade is Script {
    using Strings for string;
        
    AddressProvider public addressProvider;

    address addressProviderAddress;

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

        address l1syncpool;
        if (block.chainid == 1) {
            l1syncpool = 0x0;

            uint256 minDelay = timelock.getMinDelay();

            emit TimelockTransaction(address(liquifier), 0, genUpgradeTo(address(liquifier), address(LiquifierNewImpl)), bytes32(0), bytes32(0), minDelay);
            emit TimelockTransaction(address(liquifier), 0, abi.encodeWithSelector(getSelector("initializeL1SyncPool(address)"), l1syncpool), bytes32(0), bytes32(0), minDelay);
    
        } else if (block.chainid == 17000) {
            l1syncpool = 0x0;

            require(deployer == liquifier.owner(), "Only the owner can upgrade the contract");

            liquifier.upgradeTo(address(LiquifierNewImpl));
            liquifier.initializeL1SyncPool(l1SyncPool);
        }

        vm.stopBroadcast();
    }

    function retrieve_contract_addresses() internal {
        liquifier = Liquifier(payable(addressProvider.getContractAddress("Liquifier")));
        timelock = EtherFiTimelock(payable(addressProvider.getContractAddress("EtherFiTimelock")));
    }

}

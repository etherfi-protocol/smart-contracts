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
            l1syncpool = 0xD789870beA40D056A4d26055d0bEFcC8755DA146;

            uint256 minDelay = timelock.getMinDelay();

            emit TimelockTransaction(address(liquifier), 0, genUpgradeTo(address(liquifier), address(LiquifierNewImpl)), bytes32(0), bytes32(0), minDelay);
            emit TimelockTransaction(address(liquifier), 0, abi.encodeWithSelector(getSelector("initializeL1SyncPool(address)"), l1syncpool), bytes32(0), bytes32(0), minDelay);

            //  Dummy ETH  Blast Dummy ETH :  0x83998e169026136760bE6AF93e776C2F352D4b28
            //   Dummy ETH  Linea Dummy ETH :  0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf
            //   Dummy ETH  Optimism Dummy ETH :  0xABC12e7C1137961B75551b26932E6F0FA9F04Ae8
            //   Dummy ETH  Base Dummy ETH :  0x0295E0CE709723FB25A28b8f67C54a488BA5aE46
            //   Dummy ETH  Mode Dummy ETH :  0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3
            address[] memory dummyETHs = new address[](5);
            dummyETHs[0] = 0x83998e169026136760bE6AF93e776C2F352D4b28;
            dummyETHs[1] = 0x61Ff310aC15a517A846DA08ac9f9abf2A0f9A2bf;
            dummyETHs[2] = 0xABC12e7C1137961B75551b26932E6F0FA9F04Ae8;
            dummyETHs[3] = 0x0295E0CE709723FB25A28b8f67C54a488BA5aE46;
            dummyETHs[4] = 0xDc400f3da3ea5Df0B7B6C127aE2e54CE55644CF3;

            for (uint i = 0; i < dummyETHs.length; i++) {
                emit TimelockTransaction(address(liquifier), 0, abi.encodeWithSelector(getSelector("registerToken(address _token, address _target, bool _isWhitelisted, uint16 _discountInBasisPoints, uint32 _timeBoundCapInEther, uint32 _totalCapInEther, bool _isL2Eth)"), dummyETHs[i], address(0), true, 0, 1, 1, true), bytes32(0), bytes32(0), minDelay);
            }

            for (uint i = 0; i < dummyETHs.length; i++) {
                emit TimelockTransaction(address(liquifier), 0, abi.encodeWithSelector(getSelector("registerToken(address _token, address _target, bool _isWhitelisted, uint16 _discountInBasisPoints, uint32 _timeBoundCapInEther, uint32 _totalCapInEther, bool _isL2Eth)"), dummyETHs[i], address(0), true, 0, 30_000, 30_000, true), bytes32(0), bytes32(0), minDelay);
            }
    
        } else if (block.chainid == 17000) {
            // l1syncpool = 0x0;

            require(deployer == liquifier.owner(), "Only the owner can upgrade the contract");

            liquifier.upgradeTo(address(LiquifierNewImpl));
            liquifier.initializeL1SyncPool(l1syncpool);
        }

        vm.stopBroadcast();
    }

    function retrieve_contract_addresses() internal {
        liquifier = Liquifier(payable(addressProvider.getContractAddress("Liquifier")));
        timelock = EtherFiTimelock(payable(addressProvider.getContractAddress("EtherFiTimelock")));
    }

}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/MembershipNFT.sol";
import "../../src/helpers/AddressProvider.sol";

contract MembershipNFTUpgrade is Script {
    
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address membershipNFTProxy = addressProvider.getContractAddress("MembershipNFT");
        address liquidityPool = addressProvider.getContractAddress("LiquidityPool");

        require(membershipNFTProxy != address(0), "MembershipNFTUpgrade: membershipNFTProxy is zero address");
        require(liquidityPool != address(0), "MembershipNFTUpgrade: liquidityPool is zero address");

        vm.startBroadcast(deployerPrivateKey);

        MembershipNFT membershipNFTInstance = MembershipNFT(payable(membershipNFTProxy));
        MembershipNFT membershipNFTV2Implementation = new MembershipNFT();

        uint32 nextMintTokenId = membershipNFTInstance.nextMintTokenId();
        uint32 maxTokenId = membershipNFTInstance.maxTokenId();
        bytes32 eapMerkleRoot = membershipNFTInstance.eapMerkleRoot();

        membershipNFTInstance.upgradeTo(address(membershipNFTV2Implementation));        
        membershipNFTInstance.initializeOnUpgrade(liquidityPool);

        require(membershipNFTInstance.nextMintTokenId() == nextMintTokenId, "MembershipNFTUpgrade: nextMintTokenId mismatch");
        require(membershipNFTInstance.maxTokenId() == maxTokenId, "MembershipNFTUpgrade: maxTokenId mismatch");
        require(membershipNFTInstance.eapMerkleRoot() == eapMerkleRoot, "MembershipNFTUpgrade: eapMerkleRoot mismatch");

        vm.stopBroadcast();
    }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../lib/murky/src/Merkle.sol";

contract MerkleScript is Script {
    function run() external {
        Merkle merkle = new Merkle();
        bytes32[] memory data = new bytes32[](6);
        data[0] = bytes32(
            keccak256(
                abi.encodePacked(0x1c5fffDbFDE331A10Ab1e32da8c4Dff210B43145)
            )
        );
        data[1] = bytes32(
            keccak256(
                abi.encodePacked(0x2f2806e8b288428f23707A69faA60f52BC565c17)
            )
        );
        data[2] = bytes32(
            keccak256(
                abi.encodePacked(0x5dfb8BC4830ccF60d469D546aEC36531c97B96b5)
            )
        );
        data[3] = bytes32(
            keccak256(
                abi.encodePacked(0x4507cfB4B077d5DBdDd520c701E30173d5b59Fad)
            )
        );
        data[4] = bytes32(
            keccak256(
                abi.encodePacked(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931)
            )
        );
        data[5] = bytes32(
            keccak256(
                abi.encodePacked(0x7631FCf7D45D821cB5FA688fADa7bbc76714B771)
            )
        );

        bytes32 root = merkle.getRoot(data);
        bytes32[] memory proofOne = merkle.getProof(data, 0);
        bytes32[] memory proofTwo = merkle.getProof(data, 1);
        bytes32[] memory proofThree = merkle.getProof(data, 2);
        bytes32[] memory proofFour = merkle.getProof(data, 3);
        bytes32[] memory proofFive = merkle.getProof(data, 4);
        bytes32[] memory proofSix = merkle.getProof(data, 5);

        console.log("New merkle root to set in the contract:");
        console.log("");
        console.logBytes32(root);
        console.log("");

        console.log("Merkle proof for address one");
        console.log("");

        for (uint256 x = 0; x < proofOne.length; x++) {
            console.logBytes32(proofOne[x]);
        }

        console.log("");
        console.log("Merkle proof for address two");
        console.log("");

        for (uint256 x = 0; x < proofTwo.length; x++) {
            console.logBytes32(proofTwo[x]);
        }

        console.log("");
        console.log("Merkle proof for address three");
        console.log("");

        for (uint256 x = 0; x < proofThree.length; x++) {
            console.logBytes32(proofThree[x]);
        }

        console.log("");
        console.log("Merkle proof for address four");
        console.log("");

        for (uint256 x = 0; x < proofFour.length; x++) {
            console.logBytes32(proofFour[x]);
        }

        console.log("");
        console.log("Merkle proof for address five");
        console.log("");

        for (uint256 x = 0; x < proofFive.length; x++) {
            console.logBytes32(proofFive[x]);
        }
        
        console.log("");
        console.log("Merkle proof for address six");
        console.log("");

        for (uint256 x = 0; x < proofSix.length; x++) {
            console.logBytes32(proofSix[x]);
        }
    }
}

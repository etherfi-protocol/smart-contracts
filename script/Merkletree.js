const { MerkleTree } = require("merkletreejs");
 const keccak256 = require("keccak256");
 const fs = require('fs');
 const { ethers } = require("hardhat");

 let walletAddresses = [
     "0x1c5fffDbFDE331A10Ab1e32da8c4Dff210B43145",
     "0x2f2806e8b288428f23707A69faA60f52BC565c17",
     "0x5dfb8BC4830ccF60d469D546aEC36531c97B96b5",
     "0x4507cfB4B077d5DBdDd520c701E30173d5b59Fad",
     "0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931",
     "0x7631FCf7D45D821cB5FA688fADa7bbc76714B771",
   ]

 let leafNodes = walletAddresses.map(addr => keccak256(addr));
 let merkletree = new MerkleTree(leafNodes, keccak256, {sortPairs: true});
 let merkleRoot = merkletree.getRoot();

 let buyerOne = leafNodes[0];
 let buyerTwo = leafNodes[1];
 let buyerThree = leafNodes[2];
 let buyerFour = leafNodes[3];
 let buyerFive = leafNodes[4];
 let buyerSix = leafNodes[5];

 let buyerOneMerkleProof = merkletree.getHexProof(buyerOne);
 let buyerTwoMerkleProof = merkletree.getHexProof(buyerTwo);
 let buyerThreeMerkleProof = merkletree.getHexProof(buyerThree);
 let buyerFourMerkleProof = merkletree.getHexProof(buyerFour);
 let buyerFiveMerkleProof = merkletree.getHexProof(buyerFive);
 let buyerSixMerkleProof = merkletree.getHexProof(buyerSix);

 merkleRoot = merkleRoot.toString("hex");
 console.log(merkleRoot);
 console.log(buyerOneMerkleProof);
 console.log(buyerTwoMerkleProof);
 console.log(buyerThreeMerkleProof);
 console.log(buyerFourMerkleProof);
 console.log(buyerFiveMerkleProof);
 console.log(buyerSixMerkleProof);

 module.exports = {
     walletAddresses,
     leafNodes,
     merkletree,
     merkleRoot,
     buyerOneMerkleProof,
     buyerTwoMerkleProof,
     buyerThreeMerkleProof,
     buyerFourMerkleProof,
     buyerFiveMerkleProof,
     buyerSixMerkleProof,
 }
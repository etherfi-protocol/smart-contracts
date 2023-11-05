# EtherFi Merkle Explanation

## Merkle Explanation

Merkle trees allow systems to have whitelisted addresses, meaning that certain functionality can be limited to certain whitelisted addresses. Merkle trees need to be generated and a proof needs to be submitted while calling the specific limited function. The merkle works by creating a tree like structure of hashed addresses, each hash combining to ultimately form a final hash. This is called the root and needs to be submitted to the contract for verification purposes. 

## Merkle Script Guide

The merkle script uses the Murky library to generate the merkle root and proofs. We import the library in the beginning. There are 6 steps which need to be taken to generate a new merkle and update the contract, here is a step-by-step guide in using the merkle script (scripts/Merkle.s.sol) to generate the new root and proofs:

### Step 1

The following line generates the data structure which holds the whitelisted addresses:

```zsh
        bytes32[] memory data = new bytes32[](6);
```

At the end of the line is a number inside ( ). This number should be updated to how many addresses will be whitelisted. In the example above, there will be 6 whitelisted addresses.

### Step 2

The lines which follow perform the functionality of actually adding the whitelisted addresses to the data structure declared above. We need to add all the wanted whitelisted addresses to the data structure. You will see in the Merkle.s.sol that adding an address looks as follows:

```zsh
        data[0] = bytes32(
            keccak256(
                abi.encodePacked(0x1c5fffDbFDE331A10Ab1e33da8c4Dff210B43145)
            )
        );
```

To break down the above code, there are 2 elements: 

```zsh
        data[0]
```

The above code refers to the data structures name being used and the position in the data structure to store the address. Because it is an array, the indexing always starts at 0. Therefore, the first address will be stored at data[0].

The next part is where to fill in the address you are wishing to add. In the brackets which follow abi.encodePacked(), insert the public key of the account you want to add. In this case, 0x1c5fffDbFDE331A10Ab1e33da8c4Dff210B43145 is used.

You will need to repeat this for as many addresses you would like to add. Therefore, if you would like to add 3 addresses to the data structure, it would look similar to this:

```zsh
        data[0] = bytes32(
            keccak256(
                abi.encodePacked(0x1c5fffDbFDE331A20Ab1e32da8c4Dff210B43145)
            )
        );

        data[1] = bytes32(
            keccak256(
                abi.encodePacked(0x2f2806e8b288428f24707A69faA60f52BC565c17)
            )
        );

        data[2] = bytes32(
            keccak256(
                abi.encodePacked(0x5dfb8BC4830ccF60d469D646aEC36531c97B96b5)
            )
        );
```

### Step 3

Once the addresses have been added to the data structure, the root can be generated. This gets performed through the following lines:

```zsh
        bytes32 root = merkle.getRoot(data);
```

This generates the root which will be used in the contracts for verification purposes. You will notice, further in the script, the root is logged to the terminal to allow you to fetch it and call the updateMerkleroot function on the contracts with this new root. You will need to call the function on the contracts on etherscan and pass the logged root as the parameter, this will update the contract.

### Step 4

The second part of a merkle is the proof a specific address requires to perform the functions. Each addresses is generated a different proof which can be used to verify you are indeed on the whitelist when calling a limited function. The following line is an example of how the proof is generated:

```zsh
        bytes32[] memory proofOne = merkle.getProof(data, 0);
```

The getProof function generates a proof for a specific address in the data structure, however, you need to pass it the name of the data structure as well as the index of the address you want to generate a proof for. So, in the above code, we are generating a proof for the address in position 0 of the data structured called 'data'. To follow the example above, if you wanted to generate proofs for all three addresses, it would look like this:

```zsh
        bytes32[] memory proofOne = merkle.getProof(data, 0);
        bytes32[] memory proofTwo = merkle.getProof(data, 1);
        bytes32[] memory proofThree = merkle.getProof(data, 2);
```

If you have added more addresses to the data structure, you will need to generate more proofs.

### Step 5

The next part of the script, is the logging of the proofs. An example of logging an addresses proof is as follows:

```zsh
        console.log("Merkle proof for address three");
        console.log("");

        for (uint256 x = 0; x < proofThree.length; x++) {
            console.logBytes32(proofThree[x]);
        }
```

You will need as many of these for as many of addresses you have added. This is important to ensure that you can access the proofs in the terminal, to ensure you have them to use in the needed functions. The result of the console.log will look similar to this:

```zsh
        Merkle proof for address three
  
        0x493a4cd18172510ab22441f3f81348a7f52ba4c0d02d50bb05e703d88fd3999c
        0xd6e464cc412334ceda2d5f051d11721e429e8f3867ed8ab32cbc7ade1b5fc5d1
        0xe49c0d75d3dd8e3b6c0106e828c6012a5f3b0e3b92c1ed11584f630f4dfa1fee
```

The way you would use this proof in the actual function call would be as follows:

```zsh
[0x493a4cd18172510ab22441f3f81348a7f52ba4c0d02d50bb05e703d88fd3999c,0xd6e464cc412334ceda2d5f051d11721e429e8f3867ed8ab32cbc7ade1b5fc5d1,0xe49c0d75d3dd8e3b6c0106e828c6012a5f3b0e3b92c1ed11584f630f4dfa1fee]
```

Please note that based on the number of addresses you are whitelisting, the log of the proof could incorporate more or less than what is seen above. You will need to save your merkle proof for when you need to call a function on Etherscan.

### Step 6

Once you have added all your addresses to your data structure and updated the number of console.logs needed, you can run the script to generate the merkle root and proofs, which will be logged to the terminal for you to use accordingly. The command to run the script is as follows, please paste it in the terminal in your IDE.

```zsh
        forge script script/Merkle.s.sol:MerkleScript
```
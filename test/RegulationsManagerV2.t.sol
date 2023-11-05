// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/RegulationsManagerV2.sol";

contract RegulationsManagerV2Test is Test {

    RegulationsManagerV2 regulationsManager;
    uint256 adminKey;
    address admin;
    uint256 aliceKey;
    address alice;

    function setUp() public {

        // setup keys
        adminKey = 0x1;
        aliceKey = 0x2;
        admin = vm.addr(adminKey);
        alice = vm.addr(aliceKey);

        // deploy
        vm.prank(admin);
        regulationsManager = new RegulationsManagerV2();
    }


    function test_verifyTermsSignature() public {

        // admin sets terms
        vm.prank(admin);
        regulationsManager.updateTermsOfService("I agree to Ether.fi ToS", hex"1234567890000000000000000000000000000000000000000000000000000000", "1");

        // alice signs terms and verifies
        vm.startPrank(alice);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, regulationsManager.generateTermsDigest());
        bytes memory signature = abi.encodePacked(r, s, v);
        regulationsManager.verifyTermsSignature(signature);
        vm.stopPrank();

        // admin should not be able to uses alice's signature
        vm.prank(admin);
        vm.expectRevert(RegulationsManagerV2.InvalidTermsAndConditionsSignature.selector);
        regulationsManager.verifyTermsSignature(signature);

        // alices signature should be invalid if the terms have changed
        vm.prank(admin);
        regulationsManager.updateTermsOfService("I agree to Ether.fi ToS", hex"9934567890000000000000000000000000000000000000000000000000000000", "2");

        vm.prank(alice);
        vm.expectRevert(RegulationsManagerV2.InvalidTermsAndConditionsSignature.selector);
        regulationsManager.verifyTermsSignature(signature);

        // alice should not be able to update the terms because she is not owner
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        regulationsManager.updateTermsOfService("Alice Rules, Brett Drools", "0xI_am_a_real_hash :)", "1");

        // The following signature was generated using the eip712 functionality within metamask
        assertEq(signature, hex"d13796e5a8f81385c3ce17a91f37f1837a4b530162513fcc04c1499d934c4b6e4f8150755391cce42180c45355419f9d1e93fda243f447faedd4ee00787518071c");

        // if you wish to generate additional signatures you can use the following script.
        // You must serve it from an http server if you want metamask to work properly
        /*
            <!DOCTYPE html>
            <html lang="en">

            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>EIP-712 Signature Demo</title>
            </head>

            <body>
                <h1>EIP-712 Signature with MetaMask</h1>
                <button onclick="requestSignature()">Sign Message</button>

                <script>

                    window.onload = function() {
                        // Check for MetaMask on page load
                        if (typeof window.ethereum === "undefined") {
                            alert("Please install MetaMask.");
                        }
                    }

                    function requestSignature() {
                        // Check if MetaMask is installed and available
                        if (typeof window.ethereum === "undefined") {
                            alert("Please install MetaMask.");
                        } else {
                            window.ethereum.request({ method: 'eth_requestAccounts' })
                                .then(accounts => {
                                    // Define the data structure
                                    const typedData = {
                                            types: {
                                                EIP712Domain: [
                                                    { name: "name", type: "string" },
                                                    { name: "version", type: "string" },
                                                ],
                                                TermsOfService: [
                                                    { name: "message", type: "string" },
                                                    { name: "hashOfTerms", type: "bytes32" }
                                                ]
                                            },
                                            domain: {
                                                name: "Ether.fi Terms of Service",
                                                version: "1"
                                            },
                                            primaryType: "TermsOfService",
                                            message: {
                                                message: "I agree to Ether.fi ToS",
                                                hashOfTerms: "0x1234567890000000000000000000000000000000000000000000000000000000"
                                            }
                                        };

                                    // Request signing
                                    window.ethereum
                                        .request({
                                            method: "eth_signTypedData_v4",
                                            params: [accounts[0], JSON.stringify(typedData)],
                                        })
                                        .then(signature => {
                                            console.log(`Signature: ${signature}`);
                                            alert(`Signature: ${signature}`);
                                        })
                                        .catch(error => {
                                            console.error("Error:", error);
                                            alert("Error: " + error.message);
                                        });
                                })
                                .catch(error => {
                                    console.error("Error:", error);
                                    alert("Error: " + error.message);
                                });
                        }
                    }
                </script>
            </body>
            </html>
        */
    }

}

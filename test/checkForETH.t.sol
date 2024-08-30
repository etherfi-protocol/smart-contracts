// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/WithdrawRequestNFT.sol";
import "../src/interfaces/IeETH.sol";
contract isMoreEETH is Test {

    function test_CheckForETH() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        WithdrawRequestNFT withdrawRequestNFT = WithdrawRequestNFT(payable(0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c));
        IeETH eETH = IeETH(0x35fA164735182de50811E8e2E824cFb9B6118ac2);


        uint256 totalAmountOfEEthRequested = 0;
        for (uint i = 0; i < withdrawRequestNFT.nextRequestId(); i++) {
            IWithdrawRequestNFT.WithdrawRequest memory token = withdrawRequestNFT.getRequest(i);
            if (token.amountOfEEth > 0 ) {
                totalAmountOfEEthRequested += token.amountOfEEth;
            }
        }

        console.log("Total amount of eETH requested: ", totalAmountOfEEthRequested);
        console.log("Total amount of eETH in the contract: ", eETH.balanceOf(address(withdrawRequestNFT)));

        uint256 difference = eETH.balanceOf(address(withdrawRequestNFT)) - totalAmountOfEEthRequested;
        console.log("Difference: ", difference);
    }
}

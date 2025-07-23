// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

interface IOperatorDelegator {
    struct QueuedWithdrawal {
        address staker;
        address delegatedTo;
        address withdrawer;
        uint256 nonce;
        uint32 startBlock;
        address[] strategies;
        uint256[] scaledShares;
    }

    function completeQueuedWithdrawal(
        QueuedWithdrawal calldata withdrawal,
        address[] calldata tokens
    ) external;
}

interface IRestakeManager {
    function calculateTVLs() external view returns (uint256[][] memory, uint256[] memory, uint256);
}

interface IRateProvider {
    function getRate() external view returns (uint256);
}

contract RenzoTest is Test {
    IOperatorDelegator public operatorDelegator;
    IRestakeManager public restakeManager;
    IRateProvider public rateProvider;
    
    // Fork block number
    uint256 forkBlock = 22254625;
    
    // Test contract addresses
    address constant OPERATOR_DELEGATOR = 0x78524bEeAc12368e600457478738c233f436e9f6;
    address constant RESTAKE_MANAGER = 0x74a09653A083691711cF8215a6ab074BB4e99ef5;
    address constant RATE_PROVIDER = 0x387dBc0fB00b26fb085aa658527D5BE98302c84C;
    
    function setUp() public {
        // Create and select the fork
        vm.createSelectFork(vm.rpcUrl("mainnet"), forkBlock);
        
        // Initialize the contract interface
        operatorDelegator = IOperatorDelegator(OPERATOR_DELEGATOR);
        restakeManager = IRestakeManager(RESTAKE_MANAGER);
        rateProvider = IRateProvider(RATE_PROVIDER);
    }

    function report() internal {
        console2.log("Rate:", rateProvider.getRate());
        (uint256[][] memory tvls, uint256[] memory tvlValues, uint256 totalTvl) = restakeManager.calculateTVLs();
        // console.log("Restake manager TVLs:", tvls.length);
        // console.log("Restake manager TVL values:", tvlValues.length);
        console2.log("Total TVL:", totalTvl);
    }
    
    function test_CompleteQueuedWithdrawal() public {
        vm.startPrank(0x3F773dC3ccC70B3D2a549713AC8D556af949D4E8);

        report();

        // Define the withdrawal struct parameters
        address staker = 0x78524bEeAc12368e600457478738c233f436e9f6;
        address delegatedTo = 0x5dCdf02a7188257b7c37dD3158756dA9Ccd4A9Cb;
        address withdrawer = 0x78524bEeAc12368e600457478738c233f436e9f6;
        uint256 nonce = 1686;
        uint32 startBlock = 22204035;
        
        // Create strategies array
        address[] memory strategies = new address[](1);
        strategies[0] = 0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0;
        
        // Create scaledShares array
        uint256[] memory scaledShares = new uint256[](1);
        scaledShares[0] = 192000000000000000000; // 192 tokens with 18 decimals
        
        // Create tokens array
        address[] memory tokens = new address[](1);
        tokens[0] = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        
        // Create the withdrawal struct
        IOperatorDelegator.QueuedWithdrawal memory withdrawal = IOperatorDelegator.QueuedWithdrawal({
            staker: staker,
            delegatedTo: delegatedTo,
            withdrawer: withdrawer,
            nonce: nonce,
            startBlock: startBlock,
            strategies: strategies,
            scaledShares: scaledShares
        });
        
        // Call the function and check for any revert
        operatorDelegator.completeQueuedWithdrawal(withdrawal, tokens);
        
        // Add assertions here if needed to verify the withdrawal was successful
        // This could include checking balances before and after, events, etc.

        vm.stopPrank();

        report();
    }
}

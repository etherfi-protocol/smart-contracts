import "./TestSetup.sol";

    struct OldOracleReport {
        uint32 consensusVersion;
        uint32 refSlotFrom;
        uint32 refSlotTo;
        uint32 refBlockFrom;
        uint32 refBlockTo;
        int128 accruedRewards;
        uint256[] validatorsToApprove;
        uint256[] liquidityPoolValidatorsToExit;
        uint256[] exitedValidators;
        uint32[]  exitedValidatorsExitTimestamps;
        uint256[] slashedValidators;
        uint256[] withdrawalRequestsToInvalidate;
        uint32 lastFinalizedWithdrawalRequestId;
        uint32 eEthTargetAllocationWeight;
        uint32 etherFanTargetAllocationWeight;
        uint128 finalizedWithdrawalAmount;
        uint32 numValidatorsToSpinUp;
    }

contract eethPayoutUpgradeTest is TestSetup {
    address treasury;
    address lpAdmin;
    address oracleAdmin; 
    uint256 setupSnapshot;

    function setUp() public {
        setUpTests();
        oracleAdmin = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);
        initializeRealisticForkWithBlock(MAINNET_FORK, 20370905);
        treasury = address(alice);
        upgradeContract();
        vm.startPrank(managerInstance.owner());
        managerInstance.setStakingRewardsSplit(0, 0, 1000000, 0);
        vm.stopPrank();
    }

    function upgradeContract() public {
        setupSnapshot = vm.snapshot();
        LiquidityPool newLiquidityImplementation = new LiquidityPool(); 
        EtherFiAdmin newEtherFiAdminImplementation = new EtherFiAdmin();
        EtherFiOracle newEtherFiOracleImplementation = new EtherFiOracle();
        vm.startPrank(liquidityPoolInstance.owner());
        liquidityPoolInstance.upgradeTo(address(newLiquidityImplementation));
        etherFiAdminInstance.upgradeTo(address(newEtherFiAdminImplementation));
        etherFiOracleInstance.upgradeTo(address(newEtherFiOracleImplementation));
        liquidityPoolInstance.setTreasury(alice);  
        vm.stopPrank();
    }

    function generateReport() public returns (IEtherFiOracle.OracleReport memory) {
        IEtherFiOracle.OracleReport memory report = IEtherFiOracle.OracleReport({
            consensusVersion: 1,
            refSlotFrom: 9574144,
            refSlotTo: 9577503,
            refBlockFrom: 20367245,
            refBlockTo: 20370590,
            accruedRewards: 64625161825710190377,
            protocolFees: 8 ether,
            validatorsToApprove: new uint256[](0),
            liquidityPoolValidatorsToExit: new uint256[](0),
            exitedValidators: new uint256[](0),
            exitedValidatorsExitTimestamps: new uint32[](0),
            slashedValidators: new uint256[](0),
            withdrawalRequestsToInvalidate: new uint256[](0),
            lastFinalizedWithdrawalRequestId: 30403,
            eEthTargetAllocationWeight: 0,
            etherFanTargetAllocationWeight: 0,
            finalizedWithdrawalAmount: 2298792938059759651463,
            numValidatorsToSpinUp: 100
        });
       return report;
    }

    function generateOldReport() public returns (OldOracleReport memory) {
        OldOracleReport memory report = OldOracleReport({
            consensusVersion: 1,
            refSlotFrom: 9574144,
            refSlotTo: 9577503,
            refBlockFrom: 20367245,
            refBlockTo: 20370590,
            accruedRewards: 64625161825710190377,
            validatorsToApprove: new uint256[](0),
            liquidityPoolValidatorsToExit: new uint256[](0),
            exitedValidators: new uint256[](0),
            exitedValidatorsExitTimestamps: new uint32[](0),
            slashedValidators: new uint256[](0),
            withdrawalRequestsToInvalidate: new uint256[](0),
            lastFinalizedWithdrawalRequestId: 30403,
            eEthTargetAllocationWeight: 0,
            etherFanTargetAllocationWeight: 0,
            finalizedWithdrawalAmount: 2298792938059759651463,
            numValidatorsToSpinUp: 100
        });
       return report;
    }

    function helperSubmitReport(uint128 _protocolFees) public {
        IEtherFiOracle.OracleReport memory report = generateReport();
        report.protocolFees = int128(_protocolFees);
        vm.startPrank(oracleAdmin);
        etherFiOracleInstance.submitReport(report);
        skip(1000);
        etherFiAdminInstance.executeTasks(report, new bytes[](0), new bytes[](0));
        uint256 balOfTreasury = eETHInstance.balanceOf(treasury);
        assertApproxEqAbs(balOfTreasury, _protocolFees, 10);
        vm.stopPrank(); 
    }

    function test_noProtocolFees() public {
        helperSubmitReport(0);
    }

    function test_noProtocolFeesEquivalentCurrentContract() public {
        IEtherFiOracle.OracleReport memory new_report = generateReport();
        new_report.protocolFees = 0;
        uint256 total_pooled_eth_upgraded_before = liquidityPoolInstance.getTotalPooledEther();
        vm.startPrank(oracleAdmin);
        etherFiOracleInstance.submitReport(new_report);
        skip(1000);
        etherFiAdminInstance.executeTasks(new_report, new bytes[](0), new bytes[](0));
        uint256 total_pooled_eth_upgraded_after = liquidityPoolInstance.getTotalPooledEther();
        vm.stopPrank();

        vm.revertTo(setupSnapshot);
        OldOracleReport memory old_report = generateOldReport();
        UUPSProxy oldEtherFiAdmin = UUPSProxy(payable(addressProviderInstance.getContractAddress("EtherFiAdmin")));
        UUPSProxy oldEtherFiOracle = UUPSProxy(payable(addressProviderInstance.getContractAddress("EtherFiOracle")));
        vm.startPrank(oracleAdmin);
        uint256 total_pooled_eth_not_upgraded_before = liquidityPoolInstance.getTotalPooledEther();
        (bool success1, bytes memory res1) = address(oldEtherFiOracle).call(abi.encodeWithSignature("submitReport((uint32,uint32,uint32,uint32,uint32,int128,uint256[],uint256[],uint256[],uint32[],uint256[],uint256[],uint32,uint32,uint32,uint128,uint32))", old_report));
        skip(1000);
        (bool success2, bytes memory res2) = address(oldEtherFiAdmin).call(abi.encodeWithSignature("executeTasks((uint32,uint32,uint32,uint32,uint32,int128,uint256[],uint256[],uint256[],uint32[],uint256[],uint256[],uint32,uint32,uint32,uint128,uint32),bytes[],bytes[])", old_report, new bytes[](0), new bytes[](0)));
        uint256 total_pooled_eth_not_upgraded_after = liquidityPoolInstance.getTotalPooledEther();
        vm.stopPrank();
        assertTrue(success1);
        assertTrue(success2);
        assertEq(total_pooled_eth_not_upgraded_before, total_pooled_eth_upgraded_before);
        assertEq(total_pooled_eth_not_upgraded_after, total_pooled_eth_upgraded_after);
    }

    function test_sharePriceSame() public {
        IEtherFiOracle.OracleReport memory new_report = generateReport();
        OldOracleReport memory old_report = generateOldReport();

        // share price after executing adminTask upgraded contract
        uint256 share_price_upgraded_before = weEthInstance.getWeETHByeETH(1 ether);
        vm.startPrank(oracleAdmin);
        etherFiOracleInstance.submitReport(new_report);
        skip(1000);
        etherFiAdminInstance.executeTasks(new_report, new bytes[](0), new bytes[](0));
        uint256 share_price_upgraded_after = weEthInstance.getWeETHByeETH(1 ether);
        vm.stopPrank();

        //go back in time before executing adminTask 
        vm.revertTo(setupSnapshot);

        // share price after executing adminTask in old contract
        UUPSProxy oldEtherFiAdmin = UUPSProxy(payable(addressProviderInstance.getContractAddress("EtherFiAdmin")));
        UUPSProxy oldEtherFiOracle = UUPSProxy(payable(addressProviderInstance.getContractAddress("EtherFiOracle")));
        vm.startPrank(oracleAdmin);
        uint256 share_price_not_upgrade_before = weEthInstance.getWeETHByeETH(1 ether);
        (bool success1, bytes memory res1) = address(oldEtherFiOracle).call(abi.encodeWithSignature("submitReport((uint32,uint32,uint32,uint32,uint32,int128,uint256[],uint256[],uint256[],uint32[],uint256[],uint256[],uint32,uint32,uint32,uint128,uint32))", old_report));
        skip(1000);
        (bool success2, bytes memory res2) = address(oldEtherFiAdmin).call(abi.encodeWithSignature("executeTasks((uint32,uint32,uint32,uint32,uint32,int128,uint256[],uint256[],uint256[],uint32[],uint256[],uint256[],uint32,uint32,uint32,uint128,uint32),bytes[],bytes[])", old_report, new bytes[](0), new bytes[](0)));
        uint256 share_price_not_upgrade_after = weEthInstance.getWeETHByeETH(1 ether);
        vm.stopPrank();

        //share price should remain the same after paying protocolFees
        assertTrue(success1);
        assertTrue(success2);
        assertEq(share_price_not_upgrade_before, share_price_upgraded_before);
        assertEq(share_price_not_upgrade_after, share_price_upgraded_after);
    }

    function test_lowProtocolFees() public {
        helperSubmitReport(1 ether);
    }

    function test_highProtocolFees() public {
        helperSubmitReport(1000 ether);
    }

    function test_negativeFees() public {
        IEtherFiOracle.OracleReport memory report = generateReport();
        report.protocolFees = int128(-1000);
        vm.startPrank(oracleAdmin);
        etherFiOracleInstance.submitReport(report);
        skip(1000);
        vm.expectRevert();
        etherFiAdminInstance.executeTasks(report, new bytes[](0), new bytes[](0));
        vm.stopPrank();
    }

    function test_permissionFordepositToRecipient() public {
        vm.startPrank(address(etherFiAdminInstance));
        liquidityPoolInstance.depositToRecipient(treasury, 10 ether, address(0));
        vm.stopPrank();
        vm.startPrank(address(liquifierInstance));
        liquidityPoolInstance.depositToRecipient(treasury, 10 ether, address(0));
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert();
        liquidityPoolInstance.depositToRecipient(treasury, 10 ether, address(0));
        vm.stopPrank();
    }
}
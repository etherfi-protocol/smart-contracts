import "./TestSetup.sol";

contract eethPayoutUpgradeTest is TestSetup {
    address treasury;
    address lpAdmin;
    address oracleAdmin; 

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
import "./TestSetup.sol";
import "forge-std/console2.sol";
import "../src/LiquidityPool.sol";  

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
            protocolAccruedRewards: 64625161825710190377,
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

    function test_submitReport(IEtherFiOracle.OracleReport memory _report) public {
        vm.startPrank(oracleAdmin);
        etherFiOracleInstance.submitReport(_report);
        skip(1000);
    }

    function test_protocolFeeBalance() public {
        IEtherFiOracle.OracleReport memory report = generateReport();
        test_submitReport(report);  
        etherFiAdminInstance.executeTasks(report, new bytes[](0), new bytes[](0));
        uint256 balOfTreasury = eETHInstance.balanceOf(treasury);
        assertApproxEqAbs(balOfTreasury, 8 ether, 10);
        console.log("Balance of treasury: ", balOfTreasury);
    }

    function test_tooHighRewards() public {
        IEtherFiOracle.OracleReport memory report = generateReport();
        report.protocolFees = 100 ether;
        test_submitReport(report);  
        vm.expectRevert(bytes("EtherFiAdmin: protocol fees too high"));
        etherFiAdminInstance.executeTasks(report, new bytes[](0), new bytes[](0));
        vm.stopPrank();
    }
    
    function test_tooLowRewards() public {
        IEtherFiOracle.OracleReport memory report = generateReport();
        report.protocolFees = 1 ether;
        test_submitReport(report);  
        vm.expectRevert(bytes("EtherFiAdmin: protocol fees too low"));
        etherFiAdminInstance.executeTasks(report, new bytes[](0), new bytes[](0));
        vm.stopPrank();
    }
}
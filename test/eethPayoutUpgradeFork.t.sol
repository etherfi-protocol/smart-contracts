import "./TestSetup.sol";
import "forge-std/console.sol";

contract eethPayoutUpgradeTest is TestSetup {
    address treasury;
    address lpAdmin;
    address oracleAdmin; 
    address committeeMember;
    uint256 setupSnapshot;

    //forge test --match-test 'test_oraclefork' -vv

    function setUp() public {
        setUpTests();
        oracleAdmin = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);
        committeeMember = address(0x72F4EDd19a96Bcd796d2ba49C6AC534680785619);
        //initializeRealisticFork(MAINNET_FORK);
        initializeRealisticForkWithBlock(MAINNET_FORK, 20915172);
        vm.startPrank(liquidityPoolInstance.owner());
        etherFiOracleInstance.setQuorumSize(1);
        vm.stopPrank();
        //todo: set up the treasury and uncomment upgradeContract line
        //treasury = liquidityPoolInstance.treasury();
        upgradeContract();
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
        treasury = alice;
        vm.stopPrank();
    }

    function generateReport() public returns (IEtherFiOracle.OracleReport memory) {
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        //todo: update this to block after last admin task more than from
        uint32 blockTo = blockFrom + 2000; //test if it works
        console.log(slotFrom, slotTo, blockFrom, blockTo);
        IEtherFiOracle.OracleReport memory report = IEtherFiOracle.OracleReport({
            consensusVersion: 1,
            refSlotFrom: slotFrom,
            refSlotTo: slotTo,
            refBlockFrom: blockFrom,
            refBlockTo: blockTo,
            accruedRewards: 2 ether, //todo: adjust value optional
            protocolFees: 1 ether / 100,
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
        //setup
        IEtherFiOracle.OracleReport memory report = generateReport();
        report.protocolFees = int128(_protocolFees);
        vm.startPrank(committeeMember);

        //todo: adjust value
        skip(100);
        etherFiOracleInstance.submitReport(report);
        vm.stopPrank();
        vm.startPrank(oracleAdmin);
        skip(1000);
        //pre state
        uint256 oldRate = weEthInstance.getRate();
        uint128 totalValueOutOfLpBefore = liquidityPoolInstance.totalValueOutOfLp();

        etherFiAdminInstance.executeTasks(report, new bytes[](0), new bytes[](0));

        //post state
        uint256 newRate = weEthInstance.getRate();
        uint128 totalValueOutOfLpAfter = liquidityPoolInstance.totalValueOutOfLp();
        uint256 balOfTreasury = eETHInstance.balanceOf(treasury);
        int128 theoretical_totalValueOutOfLp = int128(totalValueOutOfLpBefore) + int128(_protocolFees) + report.accruedRewards;

        //visual change
        console.log("-------protocolFee", _protocolFees, '-------');
        console.log("oldRate: ", oldRate);
        console.log("newRate: ", newRate);
        console.log("totalValueOutOfLpBefore: ", totalValueOutOfLpBefore);
        console.log("totalValueOutOfLpAfter: ", totalValueOutOfLpAfter);
        console2.log("theoretical_totalValueOutOfLp: ", theoretical_totalValueOutOfLp);

        
        assertApproxEqAbs(theoretical_totalValueOutOfLp, int128(totalValueOutOfLpAfter), 1);
        assertApproxEqAbs(balOfTreasury, _protocolFees, 1);
        assert(newRate > oldRate);
        vm.stopPrank(); 
    }

    //test that users got their funds and totalValueOutOfLp is correct
    function test_oraclefork1() public {
        helperSubmitReport(0);
    }

    function test_oraclefork2() public {
        helperSubmitReport(0.01 ether);
    }

    function test_oraclefork3() public {
        helperSubmitReport(2700 ether);
    }
}
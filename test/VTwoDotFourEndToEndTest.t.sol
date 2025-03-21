import "./TestSetup.sol";
import "src/EtherFiRewardsRouter.sol";
import {ContractCodeChecker} from "../script/ContractCodeChecker.sol";



contract VTwoDotFourEndToEndTest is TestSetup {

    address public treasuryAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);

    address public operatingTimelockAddress = address(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a);
    address public etherfiOracleAdmin = address(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F);
    address public liquidityPoolAdmin = address(0xFa238cB37E58556b23ea45643FFe4Da382162a53);
    address public hypernativeEoa = address(0x9AF1298993DC1f397973C62A5D47a284CF76844D); 
    address public timelockAddress = address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761);
    address public oldTreasury = address(0x6329004E903B7F420245E7aF3f355186f2432466);
    address public etherOracleMember1 = address(0xDd777e5158Cb11DB71B4AF93C75A96eA11A2A615);
    address public etherOracleMember2 = address(0x2c7cB7d5dC4aF9caEE654553a144C76F10D4b320);
    address public etherfiOperatingMultisig = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);

    EtherFiRedemptionManager public etherFiRedemptionManagerImplementation;
    EtherFiTimelock public etherFiTimelockImplementation;
    EtherFiRewardsRouter public etherFiRewardsRouterImplementation;
    EtherFiNodesManager public etherFiNodesManagerImplementation;


    
    //EtherFiRewardsRouter public etherFiRewardsRouterInstance = EtherFiRewardsRouter(payable(0x73f7b1184B5cD361cC0f7654998953E2a251dd58));
    uint256 public balOldTreasury;

    //steps to upgrade to v2.49
    //0. create roles
    //0.1 accept ownership
    //1. deploy contracts
    //2. init contracts
    //3. aggregate withdrawal requests
    //5. test that everything works as expected

    function setUp() public {
        updateShouldSetRoleRegistry(false);
        initializeRealisticFork(MAINNET_FORK);

        //setup role registry
        roleRegistryInstance = RoleRegistry(address(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9));
        initRoles();
        acceptOwnership();

        //upgrade and initalize contract using the timelock transaction created
        _upgrade_v2_dot_49_contracts();

        //uncomment after deploy is done
        etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(address(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0)));
        EtherFiTimelock operatingTimelock = EtherFiTimelock(payable(operatingTimelockAddress));

        //aggregate, unpause, handle remainder
        performActionsToResumeWithdrawals();
    }

    //---------------------------HELPER FUNCTIONS--------------------------------

    function init_implementation_contracts() public {
        etherFiRedemptionManagerImplementation = EtherFiRedemptionManager(payable(0xe6f40295A7500509faD08E924c91b0F050a7b84b));
        etherFiRedemptionManagerProxy = UUPSProxy(payable(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0));
        roleRegistryImplementation = RoleRegistry(payable(0x3A75019F8b09c278D152279d446c97d009E064f3));
        roleRegistryProxy = UUPSProxy(payable(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9));
        etherFiTimelockImplementation = EtherFiTimelock(payable(operatingTimelockAddress));

        etherFiAdminImplementation = EtherFiAdmin(0x683583979C8be7Bcfa41E788Ab38857dfF792f49);
        etherFiRewardsRouterImplementation = EtherFiRewardsRouter(payable(0xe94bF0DF71002ff0165CF4daB461dEBC3978B0fa));
        liquidityPoolImplementation = LiquidityPool(payable(0xA6099d83A67a2c653feB5e4e48ec24C5aeE1C515));
        weEthImplementation = WeETH(0x353E98F34b6E5a8D9d1876Bf6dF01284d05837cB);
        withdrawRequestNFTImplementation = WithdrawRequestNFT(0x685870a508b56c7f1002EEF5eFCFa01304474F61);
        etherFiNodesManagerImplementation = EtherFiNodesManager(payable(0x572E25fD70b6eB9a3CaD1CE1D48E3CfB938767F1));
    }
    
    function _upgrade_v2_dot_49_contracts() public {
        //upgrade contracts
        address[] memory _targets = new address[](15);
        bytes[] memory _data = new bytes[](15);
        uint256[] memory _values = new uint256[](15);
        address timelockAddress = address(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761);
        address operatingTimelockAddress = address(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a);
        address treasuryAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);
        address etherFiRedemptionManagerAddress = address(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0);
        vm.startPrank(timelockAddress);
        roleRegistryInstance = RoleRegistry(address(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9));
        roleRegistryInstance.onlyProtocolUpgrader(timelockAddress);
        vm.stopPrank();
        balOldTreasury = weEthInstance.balanceOf(address(treasuryInstance));
        console2.log("balOldTreasury", balOldTreasury);
        

        _targets[0] = address(managerInstance);
        _targets[1] = address(etherFiAdminInstance);
        _targets[2] = address(etherFiRewardsRouterInstance);
        _targets[3] = address(liquidityPoolInstance);
        _targets[4] = address(weEthInstance);
        _targets[5] = address(withdrawRequestNFTInstance);
        _targets[6] = address(etherFiAdminInstance);
        _targets[7] = address(liquidityPoolInstance);
        _targets[8] = address(withdrawRequestNFTInstance);
        _targets[9] = address(weEthInstance);
        _targets[10] = address(weEthInstance);
        _targets[11] = address(addressProviderInstance);
        _targets[12] = address(addressProviderInstance);
        _targets[13] = address(addressProviderInstance);
        _targets[14] = address(addressProviderInstance);

        //upgrade contracts
        _data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x572E25fD70b6eB9a3CaD1CE1D48E3CfB938767F1);
        _data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x683583979C8be7Bcfa41E788Ab38857dfF792f49);
        _data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0xe94bF0DF71002ff0165CF4daB461dEBC3978B0fa);
        _data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0xA6099d83A67a2c653feB5e4e48ec24C5aeE1C515);
        _data[4] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x353E98F34b6E5a8D9d1876Bf6dF01284d05837cB);
        _data[5] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, 0x685870a508b56c7f1002EEF5eFCFa01304474F61);

        //initialize contracts
        _data[6] = abi.encodeWithSelector(EtherFiAdmin.initializeRoleRegistry.selector, address(roleRegistryInstance));
        _data[7] = abi.encodeWithSelector(LiquidityPool.initializeVTwoDotFourNine.selector, address(roleRegistryInstance), etherFiRedemptionManagerAddress);
        _data[8] = abi.encodeWithSelector(WithdrawRequestNFT.initializeOnUpgrade.selector, address(roleRegistryInstance), 10000);
        _data[9] = abi.encodeWithSelector(weEthInstance.rescueTreasuryWeeth.selector);
        _data[10] = abi.encodeWithSelector(weEthInstance.transfer.selector, treasuryAddress, balOldTreasury);

        //add to addressProvider
        _data[11] = abi.encodeWithSelector(AddressProvider.addContract.selector, etherFiRedemptionManagerAddress, "EtherFiRedemptionManager");
        _data[12] = abi.encodeWithSelector(AddressProvider.addContract.selector, address(etherFiRewardsRouterInstance), "EtherFiRewardsRouter");
        _data[13] = abi.encodeWithSelector(AddressProvider.addContract.selector, operatingTimelockAddress, "OperatingTimelock");
        _data[14] = abi.encodeWithSelector(AddressProvider.addContract.selector, address(roleRegistryInstance), "RoleRegistry");


        _batch_execute_timelock(_targets, _data, _values, true, false, true, false);
    }

    function getUint32FromSlot(uint256 slotNumber, uint256 position) public view returns (uint32) {
    bytes32 fullSlot = vm.load(address(withdrawRequestNFTInstance), bytes32(slotNumber));
    uint256 slotValue = uint256(fullSlot);
    uint256 shiftAmount = position * 32;
    uint32 value = uint32((slotValue >> shiftAmount) & 0xFFFFFFFF);
    return value;
}

function setUint32InSlot(uint256 slotNumber, uint256 position, uint32 value) public {
    bytes32 fullSlot = vm.load(address(withdrawRequestNFTInstance), bytes32(slotNumber));
    uint256 slotValue = uint256(fullSlot);
    uint256 shiftAmount = position * 32;
    slotValue &= ~(uint256(0xFFFFFFFF) << shiftAmount);
    slotValue |= uint256(value) << shiftAmount;
    vm.store(address(withdrawRequestNFTInstance), bytes32(slotNumber), bytes32(slotValue));
}

    function forceCompletionOfAggregation() public {
        //slot 306 
        //position 3 contains currentRequestIdToScanFromForShareRemainder
        //position 4 contains lastRequestIdToScanUntilForShareRemainder
        uint32 lastRequest = withdrawRequestNFTInstance.lastRequestIdToScanUntilForShareRemainder() + 1;
        setUint32InSlot(306, 3, lastRequest);
        uint256 aggregateSum = eETHInstance.shares(address(withdrawRequestNFTInstance)) - 400 ether;
        uint256 totalRemainderSharesToStore = 400 ether;
        vm.store(address(withdrawRequestNFTInstance), bytes32(uint256(307)), bytes32(uint256(aggregateSum)));
        vm.store(address(withdrawRequestNFTInstance), bytes32(uint256(308)), bytes32(uint256(totalRemainderSharesToStore)));
    }

        function _perform_withdrawals(uint256 validatorId) internal {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = validatorId;

        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);
        IEigenPod eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        IDelegationManager mgr = managerInstance.delegationManager();

        uint256 etherFiNodeBalance = address(nodeAddress).balance;
        uint256 liquidityPoolBalance = address(liquidityPoolInstance).balance;

        // 1. Prepare for Params for `queueWithdrawals`
        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategies[0] = mgr.beaconChainETHStrategy();
        shares[0] = uint256(eigenPod.withdrawableRestakedExecutionLayerGwei()) * uint256(1 gwei);
        params[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: nodeAddress
        });

        // 2. Prepare for `completeQueuedWithdrawals`
        IDelegationManager.Withdrawal memory withdrawal = 
            IDelegationManager.Withdrawal({
                staker: nodeAddress,
                delegatedTo: mgr.delegatedTo(nodeAddress),
                withdrawer: nodeAddress,
                nonce: mgr.cumulativeWithdrawalsQueued(nodeAddress),
                startBlock: uint32(block.number),
                strategies: strategies,
                shares: shares
            });
        bytes32 withdrawalRoot = mgr.calculateWithdrawalRoot(withdrawal);

        // 3. Perform `queueWithdrawals`
        // https://etherscan.io/address/0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A#writeProxyContract
        // bytes4 selector = 0x0dd8dd02; // queueWithdrawals
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(0x0dd8dd02, params); // queueWithdrawals

        vm.prank(0x7835fB36A8143a014A2c381363cD1A4DeE586d2A);
        managerInstance.forwardExternalCall(validatorIds, data, address(mgr));
        assertTrue(mgr.pendingWithdrawals(withdrawalRoot));

        // 4. Wait for the withdrawal to be processed
        _moveClock(7 * 7200);

        // 5. Perform `completeQueuedWithdrawals`
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        withdrawals[0] = withdrawal;
        _completeQueuedWithdrawals(validatorIds, withdrawals);

        assertEq(address(nodeAddress).balance, etherFiNodeBalance + shares[0]);
        assertEq(address(liquidityPoolInstance).balance, liquidityPoolBalance);

        // Success
        vm.prank(managerInstance.owner());
        managerInstance.partialWithdraw(validatorId);

        assertEq(address(liquidityPoolInstance).balance, liquidityPoolBalance + etherFiNodeBalance + shares[0]);
    }

    function _whitelist_completeQueuedWithdrawals() internal {
        address target = address(managerInstance);
        bytes4[] memory selectors = new bytes4[](1);

        // https://etherscan.io/address/0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A#writeProxyContract
        selectors[0] = 0x33404396; // completeQueuedWithdrawals

        bytes memory data = abi.encodeWithSelector(EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector, selectors[0], 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);
        _execute_timelock(target, data, true, false, true, false);
    }

    function _completeQueuedWithdrawals(uint256[] memory validatorIds, IDelegationManager.Withdrawal[] memory withdrawals) internal {
        IDelegationManager delegationMgr = managerInstance.delegationManager();
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        bool[] memory receiveAsTokens = new bool[](1);
        middlewareTimesIndexes[0] = 0;
        receiveAsTokens[0] = true;
        tokens[0][0] = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(IDelegationManager.completeQueuedWithdrawals.selector, withdrawals, tokens, middlewareTimesIndexes, receiveAsTokens);

        vm.prank(0x7835fB36A8143a014A2c381363cD1A4DeE586d2A);
        managerInstance.forwardExternalCall(validatorIds, data, address(delegationMgr));
    }

    //---------------------------ACTIONS FOR UPGRADE--------------------------------

    function performActionsToResumeWithdrawals() public {

        //todo: aggregate withdrawal requests
        assertEq(withdrawRequestNFTInstance.paused(), true);

        //aggregate withdrawal requests
        aggregateWithdrawalRequests();
        //todo:unpause the contract
        vm.prank(etherfiOperatingMultisig);
        withdrawRequestNFTInstance.unPauseContract();

        assertEq(withdrawRequestNFTInstance.paused(), false);
        uint256 balBefore = eETHInstance.balanceOf(treasuryAddress);
        uint256 remainder = withdrawRequestNFTInstance.getEEthRemainderAmount();
        vm.prank(operatingTimelockAddress);

        //todo: handle remainder
        withdrawRequestNFTInstance.handleRemainder(remainder);


        uint256 balAfter = eETHInstance.balanceOf(treasuryAddress);
        assertApproxEqAbs(balAfter - balBefore, remainder * 100 / 100, 0.5 ether); //we benefit from the burning of shares
    }


    function deployContracts() public {
        console.log("deployContracts");

        etherFiRedemptionManagerProxy = new UUPSProxy(address(new EtherFiRedemptionManager(address(liquidityPoolInstance), address(eETHInstance), address(weEthInstance), address(treasuryInstance), address(roleRegistryInstance))), "");
        etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(etherFiRedemptionManagerProxy));
        etherFiRedemptionManagerInstance.initialize(10_00, 30, 1_00, 1000 ether, 0.01157407407 ether);
        
        etherFiAdminImplementation = new EtherFiAdmin();
        managerImplementation = new EtherFiNodesManager();
        etherFiRewardsRouterImplementation = new EtherFiRewardsRouter(address(liquidityPoolInstance), treasuryAddress, address(roleRegistryInstance));
        liquidityPoolImplementation = new LiquidityPool();
        weEthImplementation = new WeETH();
        withdrawRequestNFTImplementation = new WithdrawRequestNFT(treasuryAddress);
    }

    function initContracts() public {
        console.log("initContracts");
        vm.startPrank(timelockAddress);
        etherFiAdminInstance.upgradeTo(address(etherFiAdminImplementation));
        managerInstance.upgradeTo(address(managerImplementation));
        etherFiRewardsRouterInstance.upgradeTo(address(etherFiRewardsRouterImplementation));
        liquidityPoolInstance.upgradeTo(address(liquidityPoolImplementation));
        weEthInstance.upgradeTo(address(weEthImplementation));
        withdrawRequestNFTInstance.upgradeTo(address(withdrawRequestNFTImplementation));

        etherFiAdminInstance.initializeRoleRegistry(address(roleRegistryInstance));
        liquidityPoolInstance.initializeVTwoDotFourNine(address(roleRegistryInstance), address(etherFiRedemptionManagerInstance));
        withdrawRequestNFTInstance.initializeOnUpgrade(address(roleRegistryInstance), 10_00);
        weEthInstance.rescueTreasuryWeeth();
        balOldTreasury = weEthInstance.balanceOf(oldTreasury);
        weEthInstance.transfer(treasuryAddress, balOldTreasury);

        vm.stopPrank();
    }



    function initRoles() public {
        console.log("initRoles");
        //add roles if needed
    }

    function aggregateWithdrawalRequests() public {
        uint256 numToScanPerTx = 100;
        uint256 cnt = (withdrawRequestNFTInstance.nextRequestId() / numToScanPerTx) + 1;
        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(numToScanPerTx);

        //force completion of aggregation
        // not done in production
        forceCompletionOfAggregation();
    }

    function acceptOwnership() public {
        console.log("acceptOwnership");
        vm.prank(timelockAddress);
        roleRegistryInstance.acceptOwnership();

        //check that the owner is the timelock
        assertEq(roleRegistryInstance.owner(), timelockAddress);
        //check that the onlyProtocolUpgrader is the timelock
        //verify that it does not revert
        roleRegistryInstance.onlyProtocolUpgrader(timelockAddress);
    }

    //---------------------------TESTS--------------------------------

    function test_v2_dot_49_starterTest() public {
        console.log("test_starterTest");
        assertEq(true, true);
    }

    //test that weeth rescueTreasury works
    function test_v2_dot_49_weeth_rescueTreasury() public {
        assertEq(weEthInstance.balanceOf(oldTreasury), 0);
        assertEq(weEthInstance.balanceOf(treasuryAddress), balOldTreasury);
    }

    //test permissions
    function test_v2_dot_49_roleRegistry_permissions() public {
    // Pending owner check
    assertEq(roleRegistryInstance.pendingOwner(), address(0)); // Should be zero after ownership accepted
    //owner check
    assertEq(roleRegistryInstance.owner(), timelockAddress);
    //onlyProtocolUpgrader check
    roleRegistryInstance.onlyProtocolUpgrader(timelockAddress);
    
    // ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE
    assertEq(roleRegistryInstance.hasRole(etherFiAdminInstance.ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE(), operatingTimelockAddress), true);
    
    // ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE
    assertEq(roleRegistryInstance.hasRole(etherFiAdminInstance.ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE(), etherfiOracleAdmin), true);
    
    // LIQUIDITY_POOL_ADMIN_ROLE
    assertEq(roleRegistryInstance.hasRole(liquidityPoolInstance.LIQUIDITY_POOL_ADMIN_ROLE(), operatingTimelockAddress), true);
    assertEq(roleRegistryInstance.hasRole(liquidityPoolInstance.LIQUIDITY_POOL_ADMIN_ROLE(), address(etherFiAdminInstance)), true);
    
    // ETHERFI_REWARDS_ROUTER_ADMIN_ROLE
    assertEq(roleRegistryInstance.hasRole(etherFiRewardsRouterInstance.ETHERFI_REWARDS_ROUTER_ADMIN_ROLE(), etherfiOperatingMultisig), true);
    
    // ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE
    console2.log(address(etherFiRedemptionManagerInstance));
    console2.logBytes32(etherFiRedemptionManagerInstance.ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE());
    assertEq(roleRegistryInstance.hasRole( etherFiRedemptionManagerInstance.ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE(), operatingTimelockAddress), true);
    
    // WITHDRAW_REQUEST_NFT_ADMIN_ROLE
    assertEq(roleRegistryInstance.hasRole(withdrawRequestNFTInstance.WITHDRAW_REQUEST_NFT_ADMIN_ROLE(), operatingTimelockAddress), true);
    assertEq(roleRegistryInstance.hasRole(withdrawRequestNFTInstance.WITHDRAW_REQUEST_NFT_ADMIN_ROLE(), address(etherFiAdminInstance)), true);
    
    // PROTOCOL_PAUSER
    assertEq(roleRegistryInstance.hasRole(roleRegistryInstance.PROTOCOL_PAUSER(), address(etherFiAdminInstance)), true);
    assertEq(roleRegistryInstance.hasRole(roleRegistryInstance.PROTOCOL_PAUSER(), hypernativeEoa), true);
    assertEq(roleRegistryInstance.hasRole(roleRegistryInstance.PROTOCOL_PAUSER(), etherfiOperatingMultisig), true);
    
    // PROTOCOL_UNPAUSER
    assertEq(roleRegistryInstance.hasRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), address(etherFiAdminInstance)), true);
    assertEq(roleRegistryInstance.hasRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), etherfiOperatingMultisig), true);
    }

    //test staking Flow
    function test_v2_dot_49_etherfiadmin_liquiditypool_stakingFlow_and_executionOfOracleReport() public {
        address nodeOperator = address(0x6A410216CfaCfE943E97A905C8CF92dEaAb43FF6);
        vm.prank(nodeOperator);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        assertEq(bidIds.length, 2);
        address validatorSpawner = address(0x5836152812568244760ba356B5f3838Aa5B672e0);
        vm.startPrank(validatorSpawner);
        uint256[] memory validatorIds = liquidityPoolInstance.batchDeposit(bidIds, 2);
        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(validatorIds);
        liquidityPoolInstance.batchRegister(zeroRoot, validatorIds, depositDataArray, depositDataRootsForApproval, sig);
        vm.stopPrank();

        executionOfOracleReport(validatorIds, pubKey, sig);
    }

    //approve, exit, and update withdrawal request
    function executionOfOracleReport(uint256[] memory validatorIdsApproving, bytes[] memory pubKeys, bytes[] memory signatures) public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.validatorsToApprove = validatorIdsApproving;
        report.accruedRewards = 10 ether;
        report.protocolFees = 1 ether;
        report.finalizedWithdrawalAmount = 0;
        report.lastFinalizedWithdrawalRequestId = withdrawRequestNFTInstance.lastFinalizedRequestId(); //do not change this
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        report.refSlotFrom = slotFrom;
        report.refSlotTo = slotTo;
        report.refBlockFrom = blockFrom;
        report.refBlockTo = uint32(block.number) - 1;

        bytes32 reportHash = etherFiOracleInstance.generateReportHash(report);

        vm.prank(etherOracleMember1);
        etherFiOracleInstance.submitReport(report);
        vm.prank(etherOracleMember2);
        etherFiOracleInstance.submitReport(report);
        vm.startPrank(etherfiOracleAdmin);
        _moveClock(100);
        vm.warp(1606824023 + block.number * 12);
        uint256 totalPooledEtherBefore = liquidityPoolInstance.getTotalPooledEther();
        //uint256 treasuryEethBalBefore = eETHInstance.balanceOf(treasuryAddress);
        etherFiAdminInstance.executeTasks(report);
        //uint256 treasuryEethBalAfter = eETHInstance.balanceOf(treasuryAddress);
        //assertApproxEqAbs(treasuryEethBalAfter - treasuryEethBalBefore, 1 ether, 0.01 ether);
        uint256 totalPooledEtherAfter = liquidityPoolInstance.getTotalPooledEther();
        assertApproxEqAbs(totalPooledEtherAfter - totalPooledEtherBefore, 11 ether + 0.06 ether, 0.01 ether);
        uint32[] memory timestamps = new uint32[](0);
        uint256 lpBalBefore = address(liquidityPoolInstance).balance;
        etherFiAdminInstance.executeValidatorManagementTask(reportHash, validatorIdsApproving, timestamps, pubKeys, signatures);
        uint256 lpBalAfter = address(liquidityPoolInstance).balance;
        assertEq(lpBalBefore - lpBalAfter, 31 ether * validatorIdsApproving.length);
        vm.stopPrank();
    }

    //test partial withdrawals
    function test_v2_dot_49_etherfinodesmanager_partialWithdrawals() public {
        uint256 validatorId = 70300;
        _perform_withdrawals(validatorId);
    }

    function test_verify_bytecode_changes() public {
        address[] memory proposers = new address[](1);
        proposers[0] = address(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);
        address admin = address(0);
        
        init_implementation_contracts();

        console2.log("etherFiRedemptionManagerImplementation: ", address(etherFiRedemptionManagerImplementation));
        verifyContractByteCodeMatch(address(etherFiRedemptionManagerImplementation), address(new EtherFiRedemptionManager(address(liquidityPoolInstance), address(eETHInstance), address(weEthInstance), address(treasuryAddress), address(roleRegistryInstance))));
        console2.log("------------------------------------------------------------------------------------------------");
        console2.log("etherFiRedemptionManagerProxy: ", address(etherFiRedemptionManagerProxy));
        verifyContractByteCodeMatch(address(etherFiRedemptionManagerProxy), address(new UUPSProxy(address(etherFiRedemptionManagerImplementation), "")));
        console2.log("------------------------------------------------------------------------------------------------");
        console2.log("etherFiAdminImplementation: ", address(etherFiAdminImplementation));
        verifyContractByteCodeMatch(address(etherFiAdminImplementation), address(new EtherFiAdmin()));
        console2.log("------------------------------------------------------------------------------------------------");
        console2.log("etherFiRewardsRouterImplementation: ", address(etherFiRewardsRouterImplementation));
        verifyContractByteCodeMatch(address(etherFiRewardsRouterImplementation), address(new EtherFiRewardsRouter(address(liquidityPoolInstance), treasuryAddress, address(roleRegistryInstance))));
        console2.log("------------------------------------------------------------------------------------------------");
        console2.log("liquidityPoolImplementation: ", address(liquidityPoolImplementation));
        verifyContractByteCodeMatch(address(liquidityPoolImplementation), address(new LiquidityPool()));
        console2.log("------------------------------------------------------------------------------------------------");

        console2.log("weEthImplementation: ", address(weEthImplementation));
        verifyContractByteCodeMatch(address(weEthImplementation), address(new WeETH()));
        console2.log("------------------------------------------------------------------------------------------------");
        console2.log("withdrawRequestNFTImplementation: ", address(withdrawRequestNFTImplementation));
        verifyContractByteCodeMatch(address(withdrawRequestNFTImplementation), address(new WithdrawRequestNFT(treasuryAddress)));
        console2.log("roleRegistryImplementation: ", address(roleRegistryImplementation));
        verifyContractByteCodeMatch(address(roleRegistryImplementation), address(new RoleRegistry()));
        console2.log("------------------------------------------------------------------------------------------------");
        console2.log("etherFiTimelockImplementation: ", address(etherFiTimelockImplementation));
        verifyContractByteCodeMatch(address(etherFiTimelockImplementation), address(new EtherFiTimelock(60 * 60 * 8, proposers, proposers, admin)));
        console2.log("------------------------------------------------------------------------------------------------");

        ///////////////////// IMPORTANT /////////////////////
        // need to change optimization to make length work
        console2.log("------------------------------------------------------------------------------------------------");
        console2.log("etherFiNodesManagerImplementation: ", address(etherFiNodesManagerImplementation));
        verifyContractByteCodeMatch(address(etherFiNodesManagerImplementation), address(new EtherFiNodesManager()));
        console2.log("------------------------------------------------------------------------------------------------");
        
    }
}

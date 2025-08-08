// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

contract LiquidityPoolTest is TestSetup {
    uint256[] public processedBids;
    uint256[] public validatorArray;
    uint256[] public bidIds;
    uint256[] public bids;
    uint256[] public validators;
    bytes[] public sig;
    bytes32 public rootForApproval;
    uint256 public testnetFork;

    function setUp() public {
        // testnetFork = vm.createFork(vm.envString("TESTNET_RPC_URL"));
        setUpTests();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();
        // initializeTestingFork(TESTNET_FORK);
        _initBid();
    }

    function _initBid() internal {
        vm.deal(alice, 100 ether);

        vm.startPrank(owner);
        nodeOperatorManagerInstance.updateAdmin(alice, true);
        // liquidityPoolInstance.updateAdmin(alice, true);
        vm.stopPrank();
    
        vm.startPrank(alice);
        _setUpNodeOperatorWhitelist();
        _approveNodeOperators();

        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            10000
        );
        bidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );
        vm.stopPrank();
    }

    function test_DepositOrWithdrawOfZeroFails() public {
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);

        vm.expectRevert(LiquidityPool.InvalidAmount.selector);
        liquidityPoolInstance.deposit{value: 0 ether}();

        liquidityPoolInstance.deposit{value: 1 ether}();

        vm.expectRevert(LiquidityPool.InvalidAmount.selector);
        liquidityPoolInstance.requestWithdraw(alice, 0);

        vm.stopPrank();
    }

    function test_StakingManagerLiquidityPool() public {

        startHoax(alice);
        uint256 aliceBalBefore = alice.balance;
        liquidityPoolInstance.deposit{value: 1 ether}();

        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        liquidityPoolInstance.deposit{value: 1 ether}();
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        assertEq(alice.balance, aliceBalBefore - 2 ether);
    }

    function test_StakingManagerLiquidityFails() public {
        vm.deal(owner, 5 ether);
        vm.startPrank(owner);
        liquidityPoolInstance.deposit{value: 2 ether}();
    }

    function test_WithdrawLiquidityPoolWithInvalidPermitFails() public {
        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(alice.balance, 1 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        uint256 aliceNonce = eETHInstance.nonces(alice);
        // create permit with invalid private key (Bob)
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(3, address(liquidityPoolInstance), 2 ether, aliceNonce+1, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE"); //even through the reason was invalid permit to prevent griefing attack the allowance fails
        liquidityPoolInstance.requestWithdrawWithPermit(alice, 2 ether, permitInput);
        vm.stopPrank();
    }

    function test_WithdrawLiquidityPoolWithInsufficientPermitFails() public {
        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(alice.balance, 1 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        uint256 aliceNonce = eETHInstance.nonces(alice);
        //  permit with insufficient amount of ETH
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquidityPoolInstance), 1 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");
        liquidityPoolInstance.requestWithdrawWithPermit(alice, 2 ether, permitInput);
        vm.stopPrank();
    }


    function test_WithdrawLiquidityPoolSuccess() public {
        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(alice.balance, 1 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        assertEq(eETHInstance.balanceOf(bob), 0);
        vm.stopPrank();

        vm.deal(bob, 3 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(bob.balance, 1 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        assertEq(eETHInstance.balanceOf(bob), 2 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        assertEq(alice.balance, 0 ether);
        assertEq(eETHInstance.balanceOf(alice), 3 ether);
        assertEq(eETHInstance.balanceOf(bob), 2 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        uint256 aliceNonce = eETHInstance.nonces(alice);
        // alice priv key = 2
        ILiquidityPool.PermitInput memory permitInputAlice = createPermitInput(2, address(liquidityPoolInstance), 2 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
        uint256 aliceReqId = liquidityPoolInstance.requestWithdrawWithPermit(alice, 2 ether, permitInputAlice);
        vm.stopPrank();
        
        _finalizeWithdrawalRequest(aliceReqId);
        
        vm.startPrank(alice);
        withdrawRequestNFTInstance.claimWithdraw(aliceReqId);
        assertEq(eETHInstance.balanceOf(alice), 1 ether);
        assertEq(alice.balance, 2 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobNonce = eETHInstance.nonces(bob);
        // bob priv key = 3
        ILiquidityPool.PermitInput memory permitInputBob = createPermitInput(3, address(liquidityPoolInstance), 2 ether, bobNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
        uint256 bobReqId = liquidityPoolInstance.requestWithdrawWithPermit(bob, 2 ether, permitInputBob);
        vm.stopPrank();

        _finalizeWithdrawalRequest(bobReqId);

        vm.startPrank(bob);
        withdrawRequestNFTInstance.claimWithdraw(bobReqId);
        assertEq(eETHInstance.balanceOf(bob), 0);
        assertEq(bob.balance, 3 ether);
        vm.stopPrank();
    }

    function test_WithdrawLiquidityPoolFails() public {
        vm.deal(bob, 100 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 100 ether}();        
        vm.stopPrank();

        startHoax(alice);
        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");
        liquidityPoolInstance.requestWithdraw(alice, 2 ether);
    }

    function test_withdraw_request_by_anyone() public {
        vm.deal(bob, 100 ether);
        vm.deal(alice, 10 ether);

        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 100 ether}();        

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 100 ether);

        vm.startPrank(alice);
        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");
        liquidityPoolInstance.requestWithdraw(bob, 2 ether);

        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 5 ether);

        assertEq(eETHInstance.balanceOf(alice), 10 ether);

        liquidityPoolInstance.requestWithdraw(bob, 2 ether);
        vm.stopPrank();

        assertEq(eETHInstance.balanceOf(alice), 8 ether);
    }

    function test_WithdrawFailsNotInitializedToken() public {
        startHoax(alice);
        vm.expectRevert();
        liquidityPoolInstance.withdraw(alice, 2 ether);
    }

    function test_StakingManagerFailsNotInitializedToken() public {
        LiquidityPool liquidityPoolNoToken = new LiquidityPool();

        vm.startPrank(alice);
        vm.deal(alice, 3 ether);
        vm.expectRevert();
        liquidityPoolNoToken.deposit{value: 2 ether}();
    }

    function test_WithdrawLiquidityPoolAccrueStakingRewardsWithoutPartialWithdrawal() public {
        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(alice.balance, 1 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        assertEq(eETHInstance.balanceOf(bob), 0);
        vm.stopPrank();

        vm.deal(bob, 3 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(bob.balance, 1 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
        assertEq(eETHInstance.balanceOf(bob), 2 ether);
        vm.stopPrank();

        vm.deal(owner, 100 ether);
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(2 ether);
        assertEq(eETHInstance.balanceOf(alice), 3 ether);
        assertEq(eETHInstance.balanceOf(bob), 3 ether);

        (bool sent, ) = address(liquidityPoolInstance).call{value: 1 ether}("");
        assertEq(sent, true);
        assertEq(eETHInstance.balanceOf(alice), 3 ether);
        assertEq(eETHInstance.balanceOf(bob), 3 ether);

        (sent, ) = address(liquidityPoolInstance).call{value: 1 ether}("");
        assertEq(sent, true);
        assertEq(eETHInstance.balanceOf(alice), 3 ether);
        assertEq(eETHInstance.balanceOf(bob), 3 ether);

        (sent, ) = address(liquidityPoolInstance).call{value: 1 ether}("");
        assertEq(sent, false);
        assertEq(eETHInstance.balanceOf(alice), 3 ether);
        assertEq(eETHInstance.balanceOf(bob), 3 ether);
    }


    function test_sendExitRequestFails() public {
        uint256[] memory newValidators = new uint256[](10);
        vm.expectRevert(LiquidityPool.IncorrectRole.selector);
        vm.prank(elvis);
        liquidityPoolInstance.DEPRECATED_sendExitRequests(newValidators);
    }

    // TODO(dave): update when v3 changes finalized

    function test_fallback() public {
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 0 ether);

        vm.deal(bob, 100 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 100 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 100 ether);
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(3 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 103 ether);

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        (bool sent, ) = address(liquidityPoolInstance).call{value: 1 ether}("");
        assertEq(address(liquidityPoolInstance).balance, 100 ether + 1 ether);
        assertEq(sent, true);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 103 ether);
    }

    function test_RegisterAsBnftHolder() public {
        //Move past one week
        vm.warp(804650);

        vm.expectRevert(LiquidityPool.IncorrectRole.selector);
        liquidityPoolInstance.registerValidatorSpawner(alice);
        
        //Let Alice sign up as a BNFT holder
        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        vm.stopPrank();
        bool registered= liquidityPoolInstance.validatorSpawner(alice);
        assertEq(registered, true);
    }
    
    // TODO(Dave): update for new deposit flow
    /*
    function test_DepositAsBnftHolderSimple() public {
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        _initReportBlockStamp(report);
        _executeAdminTasks(report);

        //Move to a random time in the future
        _moveClock(100000);

        vm.startPrank(alice);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();

        vm.stopPrank();

        vm.prank(elvis);
        //Making sure if a user is assigned they send in the correct amount (This will be updated 
        //as we will allow users to specify how many validator they want to spin up)
        vm.expectRevert("Not enough balance");
        liquidityPoolInstance.batchDeposit(bidIds, 4);

        //Move way more in the future
        _moveClock(100000);
        

        //This triggers the number of active holders to be updated to include the previous bnft holders
        //However, Chad will not be included in this weeks duty
        vm.startPrank(alice);
        registerAsBnftHolder(chad);
        vm.stopPrank();

        vm.prank(alice);
        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 300 ether}();

        IEtherFiOracle.OracleReport memory report2 = _emptyOracleReport();

        _initReportBlockStamp(report2);
        _executeAdminTasks(report2);


        vm.prank(shonee);
        //Shonee deposits and her index is 4, allowing her to deposit for 4 validators
        validators = liquidityPoolInstance.batchDeposit(bidIds, 4);
        assertEq(validators[0], 1);
        assertEq(validators[1], 2);
        assertEq(validators[2], 3);
        assertEq(validators[3], 4);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 4);

        vm.prank(dan);

        //Dan deposits and his index is 5, allowing him to deposit
        validators = liquidityPoolInstance.batchDeposit(bidIds, 2);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 6);

        assertEq(validators[0], 5);
        assertEq(validators[1], 6);
    }
    */

    // function test_.unregisterValidatorSpawner() public {
    //     setUpBnftHolders();

    //     (address ownerIndexAddress, ) = liquidityPoolInstance.bnftHolders(3);
    //     (address henryIndexAddress, ) = liquidityPoolInstance.bnftHolders(7);
    //     (address bobIndexAddress, ) = liquidityPoolInstance.bnftHolders(2);

    //     assertEq(ownerIndexAddress, owner);
    //     assertEq(henryIndexAddress, henry);
    //     assertEq(bobIndexAddress, bob);

    //     vm.prank(alice);
    //     liquidityPoolInstance.unregisterValidatorSpawner(owner);
    //     (bool registered, ) = liquidityPoolInstance.bnftHoldersIndexes(owner);
    //     assertEq(registered, false);

    //     (henryIndexAddress, ) = liquidityPoolInstance.bnftHolders(3);
    //     assertEq(henryIndexAddress, henry);

    //     vm.prank(bob);
    //     liquidityPoolInstance.unregisterValidatorSpawner(bob);
    //     (registered, ) = liquidityPoolInstance.bnftHoldersIndexes(bob);
    //     assertEq(registered, false);

    //     (address elvisIndexAddress, ) = liquidityPoolInstance.bnftHolders(2);
    //     assertEq(elvisIndexAddress, elvis);
    // }

    function test_unregisterValidatorSpawnerIfIncorrectCaller() public {
        setUpBnftHolders();

        vm.prank(bob);
        vm.expectRevert("Incorrect Caller");
        liquidityPoolInstance.unregisterValidatorSpawner(owner);
    }


    // TODO(Dave): update for new deposit flow
    /*
    function test_DepositWhenUserDeRegisters() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _executeAdminTasks(report);
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        vm.startPrank(alice);

        //Move to a random time in the future
        vm.warp(1731561615);
        
        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 630 ether}();    

        vm.stopPrank();


        vm.startPrank(owner);
        //Owner de registers themselves
     
        vm.expectEmit(true, true, false, false);
        emit LiquidityPool.ValidatorSpawnerUnregistered(owner);
        liquidityPoolInstance.unregisterValidatorSpawner(owner);
        vm.expectRevert();
        liquidityPoolInstance.batchDeposit(bidIds, 4);
        vm.stopPrank();

        vm.startPrank(alice);
        //Alice deposits and her index is 0 (the last index), allowing her to deposit for 2 validators
        liquidityPoolInstance.batchDeposit(bidIds, 4);
        vm.stopPrank();
    }
    */

    /*
    function test_DepositFromBNFTHolder() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _executeAdminTasks(report);

        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 128 ether}();
        vm.stopPrank();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        vm.warp(12431561615);
        startHoax(alice);
        bidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );
        vm.stopPrank();
        
        startHoax(alice);
        processedBids = liquidityPoolInstance.batchDeposit(bidIds, 4);

        assertEq(stakingManagerInstance.bidIdToStaker(11), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(12), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(13), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(14), alice);
    }
    */

    /*
    function test_RestakedDepositFromBNFTHolder() public {
        initializeRealisticFork(MAINNET_FORK);
        _initBid();

        vm.expectRevert(LiquidityPool.IncorrectRole.selector);
        liquidityPoolInstance.setRestakeBnftDeposits(true);

        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);

        uint256[] memory bidIds;
        uint256[] memory validatorIds;

        registerAsBnftHolder(alice);
        bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        liquidityPoolInstance.setRestakeBnftDeposits(true);

        liquidityPoolInstance.deposit{value: 120 ether}();
        bidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );

        address bnftHolder = alice;
        startHoax(bnftHolder);
        processedBids = liquidityPoolInstance.batchDeposit(bidIds, 4);

        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[0]), bnftHolder);
        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[1]), bnftHolder);
        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[2]), bnftHolder);
        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[3]), bnftHolder);

        // verify that created nodes have associated eigenPods
        IEtherFiNode node = IEtherFiNode(managerInstance.etherFiNodeFromId(bidIds[0]));
        assertFalse(address(node.getEigenPod()) == address(0x0));
        node = IEtherFiNode(managerInstance.etherFiNodeFromId(bidIds[1]));
        assertFalse(address(node.getEigenPod()) == address(0x0));
        node = IEtherFiNode(managerInstance.etherFiNodeFromId(bidIds[2]));
        assertFalse(address(node.getEigenPod()) == address(0x0));
        node = IEtherFiNode(managerInstance.etherFiNodeFromId(bidIds[3]));
        assertFalse(address(node.getEigenPod()) == address(0x0));
    }
    */

    /*
    function test_RegisterAsBNFTHolder() public {

        test_DepositFromBNFTHolder();

        assertEq(processedBids[0], 11);
        assertEq(processedBids[1], 12);
        assertEq(processedBids[2], 13);
        assertEq(processedBids[3], 14);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        bytes32[] memory depositDataRootsForApproval = new bytes32[](1);

        address etherFiNode = managerInstance.etherFiNodeFromId(11);
        root = generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.addressToWithdrawalCredentials(etherFiNode),
            1 ether
        );

        depositDataRootsForApproval[0] = generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.addressToWithdrawalCredentials(etherFiNode),
            31 ether
        );

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        validatorArray = new uint256[](1);
        validatorArray[0] = processedBids[0];

        assertEq(BNFTInstance.balanceOf(alice), 0);
        assertEq(TNFTInstance.balanceOf(address(liquidityPoolInstance)), 0);

        bytes[] memory pubKey = new bytes[](1);
        pubKey[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        bytes[] memory sig = new bytes[](1);
        sig[0] = hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df";

        liquidityPoolInstance.batchRegister(_getDepositRoot(), validatorArray, depositDataArray, depositDataRootsForApproval, sig);

        assertEq(liquidityPoolInstance.numPendingDeposits(), 3);
        assertEq(BNFTInstance.balanceOf(address(liquidityPoolInstance)), 1);
        assertEq(TNFTInstance.balanceOf(address(liquidityPoolInstance)), 1);
    }
    */

    /*
    function test_DepositFromBNFTHolderTwice() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _executeAdminTasks(report);

        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 240 ether}();
        vm.stopPrank();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        vm.warp(12431561615);

        startHoax(alice);
        bidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );
        vm.stopPrank();
        
        startHoax(alice);
        processedBids = liquidityPoolInstance.batchDeposit(bidIds, 4);

        assertEq(stakingManagerInstance.bidIdToStaker(11), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(12), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(13), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(14), alice);

        assertEq(stakingManagerInstance.bidIdToStaker(15), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(16), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(17), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(18), address(0));
    }
    */

    /*
    function test_goerli_test() internal {
        initializeRealisticFork(TESTNET_FORK);

        address addr = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;
        vm.startPrank(addr);

        bytes32 depositRoot = 0x0000000000000000000000000000000000000000000000000000000000000000;

        uint256[] memory newValidators = new uint256[](1);
        newValidators[0] = 149;

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"923f084f451f9092089c8f1ce4f454eaebd98fcc096fed1375e5c8904bdc9a9351a9c95c6b200ba487bc1a18f704d19a",
                signature: hex"9368bd230a8146c8ae305600e98f550d672f164f0e670ca53461a489301af75365b1325caea038828c8ab3d7210b58bf0c1a40e97213a5766932b5d9ce3606e2caea83c31f8dee5783ec3d4d0adaf792d275bdccd0334f38333c3ca7d8130611",
                depositDataRoot: 0x948630649547a52291aac357b70da54a5a6f3b881defb3d7cef2de5f09a8a5f3,
                ipfsHashForEncryptedValidatorKey: "QmPuujz3qgdmFoYVyhkMCP9NMrjKQskkb8zEnapKZEuLh8"
            });

        depositDataArray[0] = depositData;

        bytes32[] memory depositDataRootsForApproval = new bytes32[](1);
        depositDataRootsForApproval[0] = 0x58d12a5856cd571cfdd55f5d887d9cfd44f1236ab92197cb37851ca3a49a6658;

        bytes[] memory sig = new bytes[](1);
        sig[0] = hex"a63be986aaeffbcf4bb641dacc72f2f37638d953b238c9f789afdad3dede41b5cc3a5079be1a32f81edcbec6e059886902bbea00bc40d84865feb89861ddd8e5ebfb359bcfd79baf930613d57b6a1fd854c29fa470596c6dda2153696730b4c1";

        assertEq(stakingManagerInstance.bidIdToStaker(149), addr);
        liquidityPoolInstance.batchRegister(depositRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);

    }
    */



    // TODO(dave): update when v3 changes finalized

    /*
    function test_any_bnft_staker() public {
        _moveClock(1 days);
        
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        registerAsBnftHolder(address(liquidityPoolInstance));
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        liquidityPoolInstance.deposit{value: 124 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("Incorrect Caller");
        liquidityPoolInstance.batchDeposit(bidIds, 1);
        vm.stopPrank();


        vm.startPrank(alice);
        liquidityPoolInstance.batchDeposit(bidIds, 1);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert("INCORRECT_CALLER");
        liquidityPoolInstance.batchCancelDeposit(bidIds);

        vm.prank(alice);
        liquidityPoolInstance.batchCancelDeposit(bidIds);
    }
    */

    function test_deopsitToRecipient_by_rando_fails() public {
        vm.startPrank(alice);
        vm.expectRevert("Incorrect Caller");
        liquidityPoolInstance.depositToRecipient(alice, 100 ether, address(0));
        vm.stopPrank();
    }

    /*
    function test_Zellic_PoC() public {
        setUpBnftHolders();

        vm.deal(alice, 1000 ether);
        vm.deal(henry, 1000 ether);

        vm.startPrank(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        liquidityPoolInstance.deposit{value: 60 ether}();
        vm.stopPrank();

        vm.startPrank(henry);
        uint256[] memory x = new uint256[](1);
        x[0] = bidIds[0];
        uint256[] memory newValidators1 = liquidityPoolInstance.batchDeposit(x, 1);

        IStakingManager.DepositData[] memory depositDataArray1 = _prepareForDepositData(newValidators1, 32 ether);

        uint256[] memory x1 = new uint256[](1);
        x1[0] = bidIds[1];
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(x1,false);

        vm.expectRevert("Wrong flow");
        stakingManagerInstance.batchRegisterValidators(zeroRoot, newValidators1, depositDataArray1);

        vm.stopPrank();
    }
    */

    function test_Upgrade2_49_pause_unpause() public {
        // only protocol pauser can pause or unpause
        vm.expectRevert(LiquidityPool.IncorrectRole.selector);
        liquidityPoolInstance.pauseContract();

        vm.prank(admin);
        liquidityPoolInstance.pauseContract();

        assertTrue(liquidityPoolInstance.paused());
        
        vm.expectRevert(LiquidityPool.IncorrectRole.selector);
        liquidityPoolInstance.unPauseContract();

        vm.prank(admin);
        liquidityPoolInstance.unPauseContract();

        assertFalse(liquidityPoolInstance.paused());
    }

    function test_Upgrade2_49_onlyRoleRegistryOwnerCanUpgrade() public {
        liquidityPool = address(new LiquidityPool());
        vm.expectRevert(RoleRegistry.OnlyProtocolUpgrader.selector);
        vm.prank(address(100));
        liquidityPoolInstance.upgradeTo(liquidityPool);

        vm.prank(roleRegistryInstance.owner());
        liquidityPoolInstance.upgradeTo(liquidityPool);
    }

    function test_eeth_view() public {
        assertEq(address(liquidityPoolInstance.eETH()), address(eETHInstance));
    }
}

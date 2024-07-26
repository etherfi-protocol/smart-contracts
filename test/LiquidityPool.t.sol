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
        testnetFork = vm.createFork(vm.envString("TESTNET_RPC_URL"));
        setUpTests();
        // initializeTestingFork(TESTNET_FORK);

        _initBid();
    }

    function _initBid() internal {
        vm.deal(alice, 100 ether);

        vm.startPrank(owner);
        nodeOperatorManagerInstance.updateAdmin(alice, true);
        liquidityPoolInstance.updateAdmin(alice, true);
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

    function test_DepositWhenNotWhitelisted() public {
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        liquidityPoolInstance.updateWhitelistStatus(true);

        vm.expectRevert("Invalid User");
        liquidityPoolInstance.deposit{value: 1 ether}();
        assertEq(address(liquidityPoolInstance).balance, 0);

        address[] memory addrs = new address[](1);
        addrs[0] = alice;

        liquidityPoolInstance.updateWhitelistedAddresses(addrs, true);
        liquidityPoolInstance.deposit{value: 1 ether}();

        assertEq(address(liquidityPoolInstance).balance, 1 ether);

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

        vm.startPrank(owner);
        vm.expectRevert();
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
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(3, address(liquidityPoolInstance), 2 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
        vm.expectRevert("ERC20Permit: invalid signature");
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

    function test_WithdrawLiquidityPoolGriefing() public {
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 2 ether}();
        assertEq(eETHInstance.balanceOf(alice), 2 ether);

        // alice sends a `requestWithdrawWithPermit` transaction to mempool with the following inputs
        uint256 aliceNonce = eETHInstance.nonces(alice);
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquidityPoolInstance), 2 ether, aliceNonce, 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());

        // bob sees alice's `requestWithdrawWithPermit` in the mempool and frontruns her transaction with copied inputs 
        vm.prank(bob);
        eETHInstance.permit(alice, address(liquidityPoolInstance), 2 ether, 2**256 - 1, permitInput.v, permitInput.r, permitInput.s);

        vm.prank(alice);
        // alices transaction still succeeds as the try catch swallows the error
        liquidityPoolInstance.requestWithdrawWithPermit(alice, 2 ether, permitInput);
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

    function test_selfdestruct() public {
        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 2 ether}();
        vm.stopPrank();

        assertEq(alice.balance, 1 ether);
        assertEq(address(liquidityPoolInstance).balance, 2 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);

        _transferTo(address(attacker), 1 ether);
        attacker.attack();

        // While the 'selfdestruct' attack can change the LP contract's balance,
        // it does not affect the critical logics for determining ETH amount per share
        // so, the balance of Alice remains the same as 2 ether.
        assertEq(alice.balance, 1 ether);
        assertEq(address(liquidityPoolInstance).balance, 3 ether);
        assertEq(eETHInstance.balanceOf(alice), 2 ether);
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

    function test_batchCancelDepositAsBnftHolder1() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.warp(976348625856);

        hoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        assertEq(bidIds.length, 2);

        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 0);

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 60 ether}();
        vm.stopPrank();

        assertEq(address(liquidityPoolInstance).balance, 60 ether);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);

        uint256 aliceBalance = address(alice).balance;
        vm.prank(alice);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        assertEq(newValidators.length, 2);
        assertEq(address(alice).balance, aliceBalance - 4 ether);
        assertEq(address(liquidityPoolInstance).balance, 60 ether + 4 ether);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 2);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0 ether);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);

        // SD-1 "Anyone can call StakingManager.batchCancelDepositAsBnftHolder to cancel a deposit"
        vm.prank(bob);
        vm.expectRevert("INCORRECT_CALLER");
        stakingManagerInstance.batchCancelDepositAsBnftHolder(newValidators, alice);

        vm.prank(alice);
        vm.expectRevert("Wrong flow");
        stakingManagerInstance.batchCancelDeposit(newValidators);

        vm.prank(alice);
        liquidityPoolInstance.batchCancelDeposit(newValidators);
        
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);
        assertEq(address(alice).balance, aliceBalance);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 60 ether);
    }

    function test_batchCancelDepositAsBnftHolderAfterRegistration() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.warp(976348625856);

        hoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        assertEq(bidIds.length, 2);

        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 0);

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 60 ether}();
        vm.stopPrank();

        assertEq(address(liquidityPoolInstance).balance, 60 ether);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);

        uint256 aliceBalance = address(alice).balance;
        vm.prank(alice);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        assertEq(newValidators.length, 2);
        assertEq(address(alice).balance, aliceBalance - 4 ether);
        assertEq(address(liquidityPoolInstance).balance, 64 ether);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 2);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0 ether);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);

        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(newValidators);

        vm.prank(alice);
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);

        vm.prank(alice);
        liquidityPoolInstance.batchCancelDeposit(newValidators);

        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);
        assertEq(address(alice).balance, aliceBalance - 2 ether);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 60 ether);
        assertEq(stakingManagerInstance.bidIdToStaker(newValidators[0]), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(newValidators[1]), address(0));

        _moveClock(7 days);

        vm.deal(henry, 4 ether);
        // again... should be able to re-deposit
        vm.prank(henry);
        newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        (depositDataArray, depositDataRootsForApproval, sig, pubKey) = _prepareForValidatorRegistration(newValidators);

        vm.prank(henry);
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);
    }
    
    function test_batchCancelDepositAsBnftHolderWithDifferentValidatorStages() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.warp(976348625856);

        hoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        assertEq(bidIds.length, 2);

        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 0);

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 60 ether}();
        vm.stopPrank();

        assertEq(address(liquidityPoolInstance).balance, 60 ether);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);

        uint256 aliceBalance = address(alice).balance;
        vm.prank(alice);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        assertEq(newValidators.length, 2);
        assertEq(address(alice).balance, aliceBalance - 4 ether);
        assertEq(address(liquidityPoolInstance).balance, 64 ether);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 2);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        bytes32[] memory depositDataRootsForApproval = new bytes32[](1);

        address etherFiNode = managerInstance.etherfiNodeAddress(
            newValidators[0]
        );
        root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            1 ether
        );

        depositDataRootsForApproval[0] = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            31 ether
        );

        depositDataArray[0] = IStakingManager.DepositData({
            publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            depositDataRoot: root,
            ipfsHashForEncryptedValidatorKey: "test_ipfs"
        });

        assertEq(uint8(managerInstance.phase(newValidators[0])), uint8(IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED));

        bytes[] memory pubKey = new bytes[](1);
        pubKey[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        uint256[] memory newValidatorsToRegister = new uint256[](1);
        newValidatorsToRegister[0] = newValidators[0];

        bytes32 depositRoot = _getDepositRoot();
        bytes[] memory sig = new bytes[](1);
        sig[0] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";

        vm.prank(alice);
        liquidityPoolInstance.batchRegisterAsBnftHolder(depositRoot, newValidatorsToRegister, depositDataArray, depositDataRootsForApproval, sig);

        vm.prank(alice);
        liquidityPoolInstance.batchCancelDeposit(newValidators);

        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);
        assertEq(address(alice).balance, aliceBalance - 1 ether);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 60 ether);
        assertEq(stakingManagerInstance.bidIdToStaker(newValidators[0]), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(newValidators[1]), address(0));
    }

    function test_sendExitRequestFails() public {
        uint256[] memory newValidators = new uint256[](10);
        vm.expectRevert("Not admin");
        vm.prank(owner);
        liquidityPoolInstance.sendExitRequests(newValidators);
    }

    function test_bnftFlowWithLiquidityPoolAsBnftHolder() public {
        setUpBnftHolders();

        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);

        liquidityPoolInstance.updateBnftMode(true);

        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        liquidityPoolInstance.deposit{value: 32 ether}();
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        uint256[] memory validatorIds = liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(bidIds, 1);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 1);

        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(validatorIds);

        vm.expectRevert("IncorrectBnftMode");
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, validatorIds, depositDataArray, depositDataRootsForApproval, sig);

        liquidityPoolInstance.batchRegisterWithLiquidityPoolAsBnftHolder(zeroRoot, validatorIds, depositDataArray, depositDataRootsForApproval, sig);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        assertEq(BNFTInstance.ownerOf(validatorIds[0]), address(liquidityPoolInstance));
        assertEq(TNFTInstance.ownerOf(validatorIds[0]), address(liquidityPoolInstance));

        liquidityPoolInstance.batchApproveRegistration(validatorIds, pubKey, sig);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);
        vm.deal(address(etherfiNode), 1 ether);
        managerInstance.batchPartialWithdraw(validatorIds);

        // The liquidity pool receives the rewards as B-NFT holder and T-NFT holder
        assertEq((address(liquidityPoolInstance).balance), 1 * 0.9 ether);
    }

    function test_batchPartialWithdrawOptimized() internal {
        uint256[] memory validatorIds = launch_validator(20, 0, false);

        uint256 totalTnftRewards = 0;
        for (uint256 i = 0; i < validatorIds.length; i++) {
            address etherfiNode = managerInstance.etherfiNodeAddress(
                validatorIds[i]
            );
            _transferTo(etherfiNode, 1 ether);
            totalTnftRewards += (1 ether * 90 * 29) / (100 * 32);
        }
        uint256 lastBalance = address(liquidityPoolInstance).balance;
        // managerInstance.batchPartialWithdrawOptimized(validatorIds);
        assertEq(address(liquidityPoolInstance).balance, lastBalance + totalTnftRewards);
    }

    function test_ProcessNodeExit() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.prank(alice);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 0);

        hoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 60 ether}();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);
        vm.stopPrank();

        vm.warp(1681075815 - 35 * 24 * 3600);   // Sun March ...
        vm.prank(henry);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);

        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(newValidators);

        vm.prank(henry);
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);

        for (uint256 i = 0; i < newValidators.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                newValidators[i]
            );

            assertEq(uint8(managerInstance.phase(newValidators[i])), uint8(IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL));
        }

        vm.prank(alice);
        liquidityPoolInstance.batchApproveRegistration(newValidators, pubKey, sig);

        for (uint256 i = 0; i < newValidators.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                newValidators[i]
            );

            assertEq(uint8(managerInstance.phase(newValidators[i])), uint8(IEtherFiNode.VALIDATOR_PHASE.LIVE));
        }

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);

        uint256[] memory slashingPenalties = new uint256[](2);
        slashingPenalties[0] = 0.5 ether;
        slashingPenalties[1] = 0.5 ether;

        // The penalties are applied to the B-NFT holders, not T-NFT holders
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(0 ether);

        vm.warp(1681075815 - 7 * 24 * 3600);   // Sun Apr 02 2023 21:30:15 UTC
        vm.prank(alice);
        liquidityPoolInstance.sendExitRequests(newValidators);

        uint32[] memory exitRequestTimestamps = new uint32[](2);
        exitRequestTimestamps[0] = 1681351200; // Thu Apr 13 2023 02:00:00 UTC
        exitRequestTimestamps[1] = 1681075815; // Sun Apr 09 2023 21:30:15 UTC

        vm.warp(1681351200 + 12 * 6);

        address etherfiNode1 = managerInstance.etherfiNodeAddress(newValidators[0]);
        address etherfiNode2 = managerInstance.etherfiNodeAddress(newValidators[1]);

        _transferTo(etherfiNode1, 32 ether - slashingPenalties[0]);
        _transferTo(etherfiNode2, 32 ether - slashingPenalties[1]);

        // Process the node exit via nodeManager
        vm.prank(alice);
        managerInstance.processNodeExit(newValidators, exitRequestTimestamps);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);
        assertTrue(managerInstance.phase(newValidators[0]) == IEtherFiNode.VALIDATOR_PHASE.EXITED);
        assertTrue(managerInstance.phase(newValidators[1]) == IEtherFiNode.VALIDATOR_PHASE.EXITED);
        
        // Delist the node from the liquidity pool
        vm.prank(henry);
        managerInstance.batchFullWithdraw(newValidators);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);
        assertEq(address(liquidityPoolInstance).balance, 60 ether);
    }

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

    function test_rebase_withdraw_flow() public {
        uint256[] memory validatorIds = launch_validator();

        uint256[] memory tvls = new uint256[](4);

        for (uint256 i = 0; i < validatorIds.length; i++) {
            // Beacon Balance < 32 ether means that the validator got slashed
            uint256 beaconBalance = 16 ether * (i + 1) + 1 ether;
            (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury)
                = managerInstance.calculateTVL(validatorIds[i], beaconBalance);
            tvls[0] += toNodeOperator;
            tvls[1] += toTnft;
            tvls[2] += toBnft;
            tvls[3] += toTreasury;
        }
        uint256 eEthTVL = tvls[1];

        // Reflect the loss in TVL by rebasing
        int128 lossInTVL = int128(uint128(eEthTVL)) - int128(uint128(60 ether));
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(lossInTVL);

        assertEq(address(liquidityPoolInstance).balance, 0 ether);
        assertEq(eETHInstance.totalSupply(), eEthTVL);
        assertEq(eETHInstance.balanceOf(bob), eEthTVL);

        // After a long period of time (after the auction fee vesting period completes)
        skip(6 * 7 * 4 days);

        uint32[] memory exitRequestTimestamps = new uint32[](2);
        exitRequestTimestamps[0] = uint32(block.timestamp);
        exitRequestTimestamps[1] = uint32(block.timestamp);

        address etherfiNode1 = managerInstance.etherfiNodeAddress(validatorIds[0]);
        address etherfiNode2 = managerInstance.etherfiNodeAddress(validatorIds[1]);

        _transferTo(etherfiNode1, 17 ether);
        _transferTo(etherfiNode2, 33 ether);

        // Process the node exit via nodeManager
        vm.prank(alice);
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);
        managerInstance.batchFullWithdraw(validatorIds);

        assertEq(address(liquidityPoolInstance).balance, eEthTVL);
        assertEq(eETHInstance.totalSupply(), eEthTVL);
        assertEq(eETHInstance.balanceOf(bob), eEthTVL);

        vm.startPrank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), eEthTVL);
        uint256 bobRequestId = liquidityPoolInstance.requestWithdraw(bob, eEthTVL);
        vm.stopPrank();

        _finalizeWithdrawalRequest(bobRequestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(bobRequestId);

        assertEq(address(liquidityPoolInstance).balance, 0);
        assertEq(eETHInstance.totalSupply(), 0);
        assertEq(eETHInstance.balanceOf(bob), 0);
    }

    function test_RegisterAsBnftHolder() public {
        //Move past one week
        vm.warp(804650);

        //Let Alice sign up as a BNFT holder
        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        vm.stopPrank();

        (bool registered, uint32 index) = liquidityPoolInstance.bnftHoldersIndexes(alice);
        (address bnftHolder, ) = liquidityPoolInstance.bnftHolders(index);
        assertEq(registered, true);
        assertEq(index, 0);
        assertEq(bnftHolder, alice);
    }
    
    function test_DepositAsBnftHolderSimple() public {
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        report.numValidatorsToSpinUp = 4;
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
        vm.expectRevert("Not Enough Deposit");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 6 ether}(bidIds, 4);

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

        report2.numValidatorsToSpinUp = 14;
        _initReportBlockStamp(report2);
        _executeAdminTasks(report2);


        vm.prank(shonee);
        //Shonee deposits and her index is 4, allowing her to deposit for 4 validators
        validators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
        assertEq(validators[0], 1);
        assertEq(validators[1], 2);
        assertEq(validators[2], 3);
        assertEq(validators[3], 4);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 4);

        vm.prank(dan);

        //Dan deposits and his index is 5, allowing him to deposit
        validators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 6);

        assertEq(validators[0], 5);
        assertEq(validators[1], 6);
    }

    function test_DeRegisterBnftHolder() public {
        setUpBnftHolders();

        (address ownerIndexAddress, ) = liquidityPoolInstance.bnftHolders(3);
        (address henryIndexAddress, ) = liquidityPoolInstance.bnftHolders(7);
        (address bobIndexAddress, ) = liquidityPoolInstance.bnftHolders(2);

        assertEq(ownerIndexAddress, owner);
        assertEq(henryIndexAddress, henry);
        assertEq(bobIndexAddress, bob);

        vm.prank(alice);
        liquidityPoolInstance.deRegisterBnftHolder(owner);
        (bool registered, ) = liquidityPoolInstance.bnftHoldersIndexes(owner);
        assertEq(registered, false);

        (henryIndexAddress, ) = liquidityPoolInstance.bnftHolders(3);
        assertEq(henryIndexAddress, henry);

        vm.prank(bob);
        liquidityPoolInstance.deRegisterBnftHolder(bob);
        (registered, ) = liquidityPoolInstance.bnftHoldersIndexes(bob);
        assertEq(registered, false);

        (address elvisIndexAddress, ) = liquidityPoolInstance.bnftHolders(2);
        assertEq(elvisIndexAddress, elvis);
    }

    function test_DeRegisterBnftHolderIfIncorrectCaller() public {
        setUpBnftHolders();

        vm.prank(bob);
        vm.expectRevert("Incorrect Caller");
        liquidityPoolInstance.deRegisterBnftHolder(owner);
    }

    function test_DepositWhenUserDeRegisters() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 21;
        _executeAdminTasks(report);
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        vm.startPrank(alice);

        //Move to a random time in the future
        vm.warp(1731561615);
        
        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 630 ether}();    

        vm.stopPrank();

        vm.startPrank(alice);
        //Alice deposits and her index is 0 (the last index), allowing her to deposit for 2 validators
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
        vm.stopPrank();

        vm.startPrank(owner);
        //Owner de registers themselves
        liquidityPoolInstance.deRegisterBnftHolder(owner);
        vm.stopPrank();
    }

    function test_DepositFromBNFTHolder() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();
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
        processedBids = liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);

        assertEq(stakingManagerInstance.bidIdToStaker(11), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(12), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(13), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(14), alice);
    }

    function test_RestakedDepositFromBNFTHolder() public {
        initializeRealisticFork(MAINNET_FORK);
        _initBid();

        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);

        uint256[] memory bidIds;
        uint256[] memory validatorIds;

        registerAsBnftHolder(alice);
        bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        liquidityPoolInstance.updateBnftMode(false);
        liquidityPoolInstance.setRestakeBnftDeposits(true);

        liquidityPoolInstance.deposit{value: 120 ether}();
        bidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );

        address bnftHolder = alice;
        startHoax(bnftHolder);
        processedBids = liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);

        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[0]), bnftHolder);
        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[1]), bnftHolder);
        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[2]), bnftHolder);
        assertEq(stakingManagerInstance.bidIdToStaker(bidIds[3]), bnftHolder);

        // verify that created nodes have associated eigenPods
        IEtherFiNode node = IEtherFiNode(managerInstance.etherfiNodeAddress(bidIds[0]));
        assertFalse(address(node.eigenPod()) == address(0x0));
        node = IEtherFiNode(managerInstance.etherfiNodeAddress(bidIds[1]));
        assertFalse(address(node.eigenPod()) == address(0x0));
        node = IEtherFiNode(managerInstance.etherfiNodeAddress(bidIds[2]));
        assertFalse(address(node.eigenPod()) == address(0x0));
        node = IEtherFiNode(managerInstance.etherfiNodeAddress(bidIds[3]));
        assertFalse(address(node.eigenPod()) == address(0x0));
    }

    function test_RegisterAsBNFTHolder() public {

        test_DepositFromBNFTHolder();

        assertEq(processedBids[0], 11);
        assertEq(processedBids[1], 12);
        assertEq(processedBids[2], 13);
        assertEq(processedBids[3], 14);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        bytes32[] memory depositDataRootsForApproval = new bytes32[](1);

        address etherFiNode = managerInstance.etherfiNodeAddress(11);
        root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            1 ether
        );

        depositDataRootsForApproval[0] = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
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

        liquidityPoolInstance.batchRegisterAsBnftHolder(_getDepositRoot(), validatorArray, depositDataArray, depositDataRootsForApproval, sig);

        assertEq(liquidityPoolInstance.numPendingDeposits(), 3);
        assertEq(BNFTInstance.balanceOf(alice), 1);
        assertEq(TNFTInstance.balanceOf(address(liquidityPoolInstance)), 1);
    }

    function test_DepositFromBNFTHolderTwice() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 8;
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
        processedBids = liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);

        assertEq(stakingManagerInstance.bidIdToStaker(11), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(12), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(13), alice);
        assertEq(stakingManagerInstance.bidIdToStaker(14), alice);

        assertEq(stakingManagerInstance.bidIdToStaker(15), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(16), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(17), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(18), address(0));
    }

    function test_SD_17() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.warp(976348625856);

        hoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        assertEq(bidIds.length, 2);

        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 0);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 0);

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 120 ether}();
        vm.stopPrank();

        assertEq(address(liquidityPoolInstance).balance, 120 ether);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 120 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 120 ether);

        uint256 aliceBalance = address(alice).balance;
        uint256[] memory bidIdsWithDuplicates = new uint256[](4);
        bidIdsWithDuplicates[0] = bidIds[0];
        bidIdsWithDuplicates[1] = bidIds[0];
        bidIdsWithDuplicates[2] = bidIds[1];
        bidIdsWithDuplicates[3] = bidIds[1];
        vm.prank(alice);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 * 2 ether}(bidIdsWithDuplicates, 4);

        assertEq(newValidators.length, 2);
        assertEq(address(alice).balance, aliceBalance - 4 ether);
        assertEq(address(liquidityPoolInstance).balance, 120 ether + 4 ether);
        assertEq(address(stakingManagerInstance).balance, 0);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 2);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 120 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 120 ether);
    }

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
        liquidityPoolInstance.batchRegisterAsBnftHolder(depositRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);

    }

    function test_bnftFlowCancel_1() public {
        setUpBnftHolders();

        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);

        uint256[] memory bidIds;
        uint256[] memory validatorIds;

        bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        // 1. Deposit -> Cancel
        liquidityPoolInstance.updateBnftMode(false);

        liquidityPoolInstance.deposit{value: 30 ether}();
        assertEq(address(stakingManagerInstance).balance, 0);
        assertEq(address(liquidityPoolInstance).balance, 30 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        validatorIds = liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(bidIds, 1);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 1);

        liquidityPoolInstance.batchCancelDeposit(bidIds);
        assertEq(address(stakingManagerInstance).balance, 0);
        assertEq(address(liquidityPoolInstance).balance, 30 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        // 2. Deposit -> Register -> Cancel
        validatorIds = liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(bidIds, 1);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 1);

        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(bidIds);
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, bidIds, depositDataArray, depositDataRootsForApproval, sig);

        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 31 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        liquidityPoolInstance.batchCancelDeposit(bidIds);
        assertEq(address(stakingManagerInstance).balance, 0);
        assertEq(address(liquidityPoolInstance).balance, 30 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);
    }

    function test_bnftFlowCancel_2() public {
        setUpBnftHolders();

        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);

        uint256[] memory bidIds;
        uint256[] memory validatorIds;

        bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        liquidityPoolInstance.updateBnftMode(true);

        liquidityPoolInstance.deposit{value: 32 ether}();
        assertEq(address(stakingManagerInstance).balance, 0);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        // 1. Deposit -> Cancel
        validatorIds = liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(bidIds, 1);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 1);

        liquidityPoolInstance.batchCancelDeposit(bidIds);
        assertEq(address(stakingManagerInstance).balance, 0);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        // 2. Deposit -> Register -> Cancel
        validatorIds = liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(bidIds, 1);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 1);

        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(bidIds);
        liquidityPoolInstance.batchRegisterWithLiquidityPoolAsBnftHolder(zeroRoot, bidIds, depositDataArray, depositDataRootsForApproval, sig);

        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 31 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);

        liquidityPoolInstance.batchCancelDeposit(bidIds);
        assertEq(address(stakingManagerInstance).balance, 0);
        assertEq(address(liquidityPoolInstance).balance, 31 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 31 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);
    }


    function test_any_bnft_staker() public {
        _moveClock(1 days);
        
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        vm.startPrank(alice);
        registerAsBnftHolder(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        liquidityPoolInstance.deposit{value: 120 ether}();
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("Incorrect Caller");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 1 * 2 ether}(bidIds, 1);
        vm.stopPrank();


        vm.startPrank(alice);
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 1 * 2 ether}(bidIds, 1);
        vm.stopPrank();

        vm.prank(owner);
        liquidityPoolInstance.updateAdmin(chad, true);

        vm.prank(bob);
        vm.expectRevert("Not admin");
        liquidityPoolInstance.batchCancelDepositByAdmin(bidIds, alice);

        vm.prank(chad);
        liquidityPoolInstance.batchCancelDepositByAdmin(bidIds, alice);
    }

    function test_deopsitToRecipient_by_rando_fails() public {
        vm.startPrank(alice);
        vm.expectRevert("Incorrect Caller");
        liquidityPoolInstance.depositToRecipient(alice, 100 ether, address(0));
        vm.stopPrank();
    }

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
        uint256[] memory newValidators1 = liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(x, 1);

        IStakingManager.DepositData[] memory depositDataArray1 = _prepareForDepositData(newValidators1, 32 ether);

        uint256[] memory x1 = new uint256[](1);
        x1[0] = bidIds[1];
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(x1,false);

        vm.expectRevert("Wrong flow");
        stakingManagerInstance.batchRegisterValidators(zeroRoot, newValidators1, depositDataArray1);

        vm.stopPrank();
    }
}

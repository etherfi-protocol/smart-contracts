// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

contract LiquidityPoolTest is TestSetup {

    bytes32[] public aliceProof;
    bytes32[] public bobProof;
    bytes32[] public henryProof;
    bytes32[] public elvisProof;
    bytes32[] public chadProof;
    bytes32[] public gregProof;
    bytes32[] public ownerProof;
    bytes32[] public firstIndexPlayerProof;
    bytes32[] public beforeFirstIndexPlayerProof;
    bytes32[] public lastIndexPlayerProof;
    uint256[] public processedBids;
    uint256[] public validatorArray;
    uint256[] public bidIds;
    uint256[] public bids;
    uint256[] public validators;
    bytes[] public sig;
    bytes32 public rootForApproval;
    uint256 public testnetFork;

    function setUp() public {
        setUpTests();

        aliceProof = merkle.getProof(whiteListedAddresses, 3);
        bobProof = merkle.getProof(whiteListedAddresses, 4);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            10000
        );
        bidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );
        vm.stopPrank();

        testnetFork = vm.createFork(vm.envString("GOERLI_RPC_URL"));
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

        liquidityPoolInstance.updateWhitelistedAddresses(address(alice), true);
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
        withdrawRequestNFTInstance.finalizeRequests(aliceReqId);
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

        vm.prank(alice);
        withdrawRequestNFTInstance.finalizeRequests(bobReqId);

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

    function test_batchCancelDepositAsBnftHolder() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.warp(976348625856);

        vm.prank(alice);
        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

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
        bytes32[] memory proof = getWhitelistMerkleProof(9);
        vm.prank(alice);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        (uint32 numValidatorsEeth, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.EETH);
        (uint32 numValidatorsEtherFan, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.ETHER_FAN);

        assertEq(newValidators.length, 2);
        assertEq(address(alice).balance, aliceBalance - 4 ether);
        assertEq(address(liquidityPoolInstance).balance, 0 ether);
        assertEq(address(stakingManagerInstance).balance, 64 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 2);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 60 ether);
        assertEq(liquidityPoolInstance.totalValueInLp(), 0);
        assertEq(numValidatorsEeth, 3);
        assertEq(numValidatorsEtherFan, 1);

        vm.prank(alice);
        liquidityPoolInstance.batchCancelDeposit(newValidators);
        
        (numValidatorsEeth, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.EETH);
        (numValidatorsEtherFan, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.ETHER_FAN);

        assertEq(liquidityPoolInstance.numPendingDeposits(), 0);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 0);
        assertEq(liquidityPoolInstance.totalValueInLp(), 60 ether);
        assertEq(address(alice).balance, aliceBalance);
        assertEq(address(stakingManagerInstance).balance, 0 ether);
        assertEq(address(liquidityPoolInstance).balance, 60 ether);
        assertEq(numValidatorsEeth, 1);     
        assertEq(numValidatorsEtherFan, 1);
    }

    function test_batchCancelDepositAsBnftHolderAfterRegistration() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.warp(976348625856);

        vm.prank(alice);
        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

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
        bytes32[] memory proof = getWhitelistMerkleProof(9);
        vm.prank(alice);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        assertEq(newValidators.length, 2);
        assertEq(address(alice).balance, aliceBalance - 4 ether);
        assertEq(address(liquidityPoolInstance).balance, 0 ether);
        assertEq(address(stakingManagerInstance).balance, 64 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 2);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 60 ether);
        assertEq(liquidityPoolInstance.totalValueInLp(), 0);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](2);

        bytes32[] memory depositDataRootsForApproval = new bytes32[](2);

        for (uint256 i = 0; i < newValidators.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                newValidators[i]
            );
            root = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                1 ether
            );

            depositDataRootsForApproval[i] = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                31 ether
            );

            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

            assertEq(uint8(IEtherFiNode(etherFiNode).phase()), uint8(IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED));

        }

        bytes[] memory pubKey = new bytes[](2);
        pubKey[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        pubKey[1] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        bytes32 depositRoot = _getDepositRoot();
        bytes[] memory sig = new bytes[](2);
        sig[0] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";
        sig[1] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";

        vm.prank(alice);
        liquidityPoolInstance.batchRegisterAsBnftHolder(depositRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);

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
    }
    
    function test_batchCancelDepositAsBnftHolderWithDifferentValidatorStages() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.warp(976348625856);

        vm.prank(alice);
        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

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
        bytes32[] memory proof = getWhitelistMerkleProof(9);
        vm.prank(alice);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        assertEq(newValidators.length, 2);
        assertEq(address(alice).balance, aliceBalance - 4 ether);
        assertEq(address(liquidityPoolInstance).balance, 0 ether);
        assertEq(address(stakingManagerInstance).balance, 64 ether);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 2);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), 60 ether);
        assertEq(liquidityPoolInstance.totalValueInLp(), 0);

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

        assertEq(uint8(IEtherFiNode(etherFiNode).phase()), uint8(IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED));

        bytes[] memory pubKey = new bytes[](1);
        pubKey[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        uint256[] memory newValidatorsToRegister = new uint256[](1);
        newValidatorsToRegister[0] = newValidators[0];

        bytes32 depositRoot = _getDepositRoot();
        bytes[] memory sig = new bytes[](1);
        sig[0] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";

        vm.prank(alice);
        liquidityPoolInstance.batchRegisterAsBnftHolder(depositRoot, newValidatorsToRegister, depositDataArray, depositDataRootsForApproval, sig);

        (uint32 numValidatorsEeth, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.EETH);
        (uint32 numValidatorsEtherFan, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.ETHER_FAN);

        assertEq(numValidatorsEeth, 3);     
        assertEq(numValidatorsEtherFan, 1);

        vm.prank(alice);
        liquidityPoolInstance.batchCancelDeposit(newValidators);

        (numValidatorsEeth, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.EETH);
        (numValidatorsEtherFan, ) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.ETHER_FAN);

        assertEq(numValidatorsEeth, 1);     
        assertEq(numValidatorsEtherFan, 1);
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
        vm.expectRevert("Caller is not the admin");
        vm.prank(owner);
        liquidityPoolInstance.sendExitRequests(newValidators);
    }

    function test_ProcessNodeExit() public {
        vm.deal(owner, 100 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        setUpBnftHolders();

        vm.prank(alice);
        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 0);

        hoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 60 ether}();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);
        vm.stopPrank();

        bytes32[] memory proof = getWhitelistMerkleProof(3);

        vm.warp(1681075815 - 35 * 24 * 3600);   // Sun March ...
        vm.prank(henry);
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 60 ether);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](2);

        bytes32[] memory depositDataRootsForApproval = new bytes32[](2);

        for (uint256 i = 0; i < newValidators.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                newValidators[i]
            );
            root = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                1 ether
            );

            depositDataRootsForApproval[i] = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                31 ether
            );

            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

            assertEq(uint8(IEtherFiNode(etherFiNode).phase()), uint8(IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED));

        }

        bytes[] memory pubKey = new bytes[](2);
        pubKey[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        pubKey[1] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        bytes32 depositRoot = _getDepositRoot();
        bytes[] memory sig = new bytes[](2);
        sig[0] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";
        sig[1] = hex"ad899d85dcfcc2506a8749020752f81353dd87e623b2982b7bbfbbdd7964790eab4e06e226917cba1253f063d64a7e5407d8542776631b96c4cea78e0968833b36d4e0ae0b94de46718f905ca6d9b8279e1044a41875640f8cb34dc3f6e4de65";


        vm.prank(henry);
        liquidityPoolInstance.batchRegisterAsBnftHolder(depositRoot, newValidators, depositDataArray, depositDataRootsForApproval, sig);

        for (uint256 i = 0; i < newValidators.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                newValidators[i]
            );

            assertEq(uint8(IEtherFiNode(etherFiNode).phase()), uint8(IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL));
        }

        vm.prank(alice);
        liquidityPoolInstance.batchApproveRegistration(newValidators, pubKey, sig);

        for (uint256 i = 0; i < newValidators.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                newValidators[i]
            );

            assertEq(uint8(IEtherFiNode(etherFiNode).phase()), uint8(IEtherFiNode.VALIDATOR_PHASE.LIVE));
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
        assertTrue(managerInstance.isExited(newValidators[0]));
        assertTrue(managerInstance.isExited(newValidators[1]));

        // Delist the node from the liquidity pool
        vm.prank(henry);
        managerInstance.fullWithdrawBatch(newValidators);

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
        managerInstance.fullWithdrawBatch(validatorIds);

        assertEq(address(liquidityPoolInstance).balance, eEthTVL);
        assertEq(eETHInstance.totalSupply(), eEthTVL);
        assertEq(eETHInstance.balanceOf(bob), eEthTVL);

        vm.startPrank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), eEthTVL);
        uint256 bobRequestId = liquidityPoolInstance.requestWithdraw(bob, eEthTVL);
        vm.stopPrank();

        vm.prank(alice);
        withdrawRequestNFTInstance.finalizeRequests(bobRequestId);

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
        vm.prank(alice);
        liquidityPoolInstance.registerAsBnftHolder(alice);

        (uint128 timestamp, uint128 numOfActiveHolders) = liquidityPoolInstance.holdersUpdate();

        assertEq(timestamp, 804650);
        assertEq(numOfActiveHolders, 0);

        //Move another week ahead to reset the active holders
        vm.warp(1609250);

        //Let Greg sign up as a BNFT holder
        vm.prank(alice);
        liquidityPoolInstance.registerAsBnftHolder(greg);

        (timestamp, numOfActiveHolders) = liquidityPoolInstance.holdersUpdate();

        assertEq(timestamp, 1609250);
        assertEq(numOfActiveHolders, 1);
    }

    function test_DutyForWeek() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        //Sets up the list of BNFT holders
        setUpBnftHolders();

        vm.startPrank(alice);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        _moveClock(1119296511);
        (uint256 firstIndex, uint128 lastIndex) = liquidityPoolInstance.dutyForWeek();
        assertEq(firstIndex, 7);
        assertEq(lastIndex, 7);

        vm.stopPrank();

        IEtherFiOracle.OracleReport memory report2 = _emptyOracleReport();
        report2.numValidatorsToSpinUp = 25;
        report2.refSlotTo = 1119296511;
        _executeAdminTasks(report2);

        vm.prank(alice);
        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 630 ether}();
        
        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        (firstIndex, lastIndex) = liquidityPoolInstance.dutyForWeek();

        assertEq(firstIndex, 7);
        assertEq(lastIndex, 4);

    }
    
    function test_DepositAsBnftHolderSimple() public {

        bobProof = merkle.getProof(whiteListedAddresses, 4);
        henryProof = merkle.getProof(whiteListedAddresses, 11);
        aliceProof = merkle.getProof(whiteListedAddresses, 3);
        chadProof = merkle.getProof(whiteListedAddresses, 5);
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        //Move to a random time in the future
        _moveClock(100000);

        vm.startPrank(alice);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();

        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        liquidityPoolInstance.dutyForWeek();

        vm.stopPrank();

        vm.prank(greg);
        //Making sure a user cannot deposit if they are not assigned
        vm.expectRevert("Not assigned");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);

        vm.prank(elvis);
        //Making sure if a user is assigned they send in the correct amount (This will be updated 
        //as we will allow users to specify how many validator they want to spin up)
        vm.expectRevert("Deposit 2 ETH per validator");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 6 ether}(bidIds, 4);

        //Move way more in the future
        _moveClock(100000);
        vm.prank(alice);

        //This triggers the number of active holders to be updated to include the previous bnft holders
        //However, Chad will not be included in this weeks duty
        liquidityPoolInstance.registerAsBnftHolder(chad);

        vm.prank(alice);
        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 300 ether}();

        IEtherFiOracle.OracleReport memory report2 = _emptyOracleReport();

        report2.numValidatorsToSpinUp = 14;
        _executeAdminTasks(report2);

        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        (uint256 firstIndex, uint128 lastIndex) = liquidityPoolInstance.dutyForWeek();

        assertEq(firstIndex, 3);
        assertEq(lastIndex, 5);

        //With the current timestamps and data, the following is true
        //First Index = 4
        //Last Index = 6

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

        vm.prank(alice);
        //alice attempts to deposit, however, due to his index being 0 and not being apart of this weeks duty, he is not assigned
        vm.expectRevert("Not assigned");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
    }

    function test_DepositAboveMaxAllocation() public {
        bobProof = merkle.getProof(whiteListedAddresses, 4);
        henryProof = merkle.getProof(whiteListedAddresses, 11);
        aliceProof = merkle.getProof(whiteListedAddresses, 3);
        chadProof = merkle.getProof(whiteListedAddresses, 5);
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        report.numValidatorsToSpinUp = 7;
        _executeAdminTasks(report);

        //Move to a random time in the future
        _moveClock(100000);

        vm.startPrank(alice);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 200 ether}();

        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        liquidityPoolInstance.dutyForWeek();

        vm.stopPrank();

        vm.prank(elvis);
        //Making sure if a user is assigned they send in the correct amount (This will be updated 
        //as we will allow users to specify how many validator they want to spin up)
        vm.expectRevert(LiquidityPool.AboveMaxAllocation.selector);
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 10 ether}(bidIds, 5);
    }

    function test_OnlyApprovedOperatorsGetSelected() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 19;
        _executeAdminTasks(report);

        startHoax(bob);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            10000
        );
        uint256[] memory bobBidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );
        vm.stopPrank();

        vm.prank(alice);
        auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );

        startHoax(owner);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            10000
        );
        uint256[] memory ownerBidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );
        vm.stopPrank();

        bids = new uint256[](10);

        bids[0] = bidIds[2];
        bids[1] = bidIds[3];
        bids[2] = bidIds[4];
        bids[3] = bobBidIds[1];
        bids[4] = bobBidIds[2];
        bids[5] = bobBidIds[4];
        bids[6] = ownerBidIds[4];
        bids[7] = ownerBidIds[6];
        bids[8] = ownerBidIds[9];
        bids[9] = bidIds[7];

        //Sets up the list of BNFT holders
        setUpBnftHolders();

        vm.startPrank(alice);

        //Move to a random time in the future
        vm.warp(13431561615);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 570 ether}();

        vm.stopPrank();
        
        //Move way more in the future
        vm.warp(33431561615);
    
        vm.startPrank(alice);

        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        (uint256 firstIndex, uint128 lastIndex) = liquidityPoolInstance.dutyForWeek();

        assertEq(firstIndex, 5);
        assertEq(lastIndex, 0);

        //With the current timestamps and data, the following is true
        //First Index = 5 
        //Last Index = 0

        vm.stopPrank();

        vm.prank(henry);
        //Henry deposits and his index is 7, allowing him to deposit
        uint256[] memory validators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bids, 4);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 4);
        assertEq(validators[0], bidIds[2]);
        assertEq(validators[1], bidIds[3]);
        assertEq(validators[2], bidIds[4]);
        assertEq(validators[3], bobBidIds[1]);
    }

    function test_DepositAsBnftHolderWithLargeSet() public {

        //Add 1000 people to the BNFT holder array
        for (uint i = 1; i <= 1000; i++) {
            address actor = vm.addr(i);
            bnftHoldersArray.push(actor);
            vm.deal(actor, 1000 ether);
            vm.prank(alice);
            liquidityPoolInstance.registerAsBnftHolder(actor);
        }

        //Move to a random period in time
        _moveClock(1684181656753);
        
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 256;
        _executeAdminTasks(report);

        vm.startPrank(alice);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        vm.deal(alice, 100000 ether);
        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 77000 ether}();
        vm.stopPrank();

        //Call duty for the week, and in this example, the data is:
        //First Index = 682
        //Last Index = 515
        //Num Validators For Last = 1
        (uint256 firstIndex, uint128 lastIndex) = liquidityPoolInstance.dutyForWeek();

        (address firstIndexAddress, ) = liquidityPoolInstance.bnftHolders(firstIndex);
        (address firstDeductOneIndexAddress, ) = liquidityPoolInstance.bnftHolders(firstIndex - 1);
        (address lastIndexAddress, ) = liquidityPoolInstance.bnftHolders(lastIndex);

        vm.startPrank(alice);
        nodeOperatorManagerInstance.addToWhitelist(firstIndexAddress);
        nodeOperatorManagerInstance.addToWhitelist(firstDeductOneIndexAddress);
        nodeOperatorManagerInstance.addToWhitelist(lastIndexAddress);
        vm.stopPrank();

        //Give the user in the first index position funds
        vm.deal(firstIndexAddress, 10 ether);
        vm.startPrank(firstIndexAddress);

        //Allow the user in the first index position to deposit 
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 4);

        vm.stopPrank();

        vm.startPrank(firstDeductOneIndexAddress);

        //User who is one short of the assigned first index attempts to deposit but fails
        vm.expectRevert("Not assigned");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
        vm.stopPrank();

        vm.deal(lastIndexAddress, 10 ether);
        vm.startPrank(lastIndexAddress);

        //User who is last in the selection deposits with the correct amount of funds
        uint256 amount = 2 ether * liquidityPoolInstance.maxValidatorsPerOwner();
        liquidityPoolInstance.batchDepositAsBnftHolder{value: amount}(bidIds, liquidityPoolInstance.maxValidatorsPerOwner());
        assertEq(liquidityPoolInstance.numPendingDeposits(), 4 + liquidityPoolInstance.maxValidatorsPerOwner());
        vm.stopPrank();
    }

    function test_DepositWhenMaxBnftValidatorChanges() public {
        
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        henryProof = merkle.getProof(whiteListedAddresses, 11);
        elvisProof = merkle.getProof(whiteListedAddresses, 7);
        chadProof = merkle.getProof(whiteListedAddresses, 5);
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        vm.startPrank(alice);

        //Move to a random time in the future
        _moveClock(100000);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();

        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        liquidityPoolInstance.dutyForWeek();

        vm.stopPrank();
        
        vm.startPrank(alice);

        //Set the max number of validators per holder to 6
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(6);

        vm.stopPrank();

        _moveClock(100000);

        IEtherFiOracle.OracleReport memory report2 = _emptyOracleReport();
        report2.numValidatorsToSpinUp = 16;
        _executeAdminTasks(report2);

        //Move way more in the future
        vm.prank(alice);

        //This triggers the number of active holders to be updated to include the previous bnft holders
        //However, Chad will not be included in this weeks duty
        liquidityPoolInstance.registerAsBnftHolder(chad);

        vm.startPrank(alice);
        
        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 370 ether}();

        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        liquidityPoolInstance.dutyForWeek();

        //With the current timestamps and data, the following is true
        //First Index = 3
        //Last Index = 4
        vm.stopPrank();

        vm.startPrank(shonee);
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 12 ether}(bidIds, 6);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 6);

        vm.stopPrank();

        vm.startPrank(owner);
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
        assertEq(liquidityPoolInstance.numPendingDeposits(), 10);
        vm.stopPrank();

        vm.startPrank(chad);
        //Chad attempts to deposit, however, due to his index being 8 and not being apart of this weeks duty, he is not assigned
        vm.expectRevert("Not assigned");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
        vm.stopPrank();
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

        henryProof = merkle.getProof(whiteListedAddresses, 11);
        aliceProof = merkle.getProof(whiteListedAddresses, 3);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 21;
        _executeAdminTasks(report);
        
        //Sets up the list of BNFT holders
        setUpBnftHolders();

        vm.startPrank(alice);

        //Move to a random time in the future
        vm.warp(1731561615);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);
        
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

        //Can look in the logs that these numbers get returned, we cant test it without manually calculating numbers
        liquidityPoolInstance.dutyForWeek();

        vm.startPrank(greg);
        //Greg attempts to deposit, however, due to his index being 1 after the swap he is not assigned
        vm.expectRevert("Not assigned");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
        vm.stopPrank();
    }

    function test_UpdateSchedulingPeriod() public {
        assertEq(liquidityPoolInstance.schedulingPeriodInSeconds(), 604800);

        vm.prank(alice);
        liquidityPoolInstance.setSchedulingPeriodInSeconds(100000);

        assertEq(liquidityPoolInstance.schedulingPeriodInSeconds(), 100000);
    }

    function test_UpdateSchedulingPeriodFailsIfNotAdmin() public {
        vm.prank(bob);
        vm.expectRevert("Caller is not the admin");
        liquidityPoolInstance.setSchedulingPeriodInSeconds(100000);
    }

    function test_SetStakingTypeTargetWeights() public {
        (, uint32 eEthTargetWeight) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.EETH);
        (, uint32 etherFanTargetWeight) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.ETHER_FAN);

        assertEq(eEthTargetWeight, 50);
        assertEq(etherFanTargetWeight, 50);

        vm.prank(bob);
        vm.expectRevert("Caller is not the admin");
        liquidityPoolInstance.setStakingTargetWeights(50, 50);

        vm.startPrank(alice);
        vm.expectRevert("Invalid weights");
        liquidityPoolInstance.setStakingTargetWeights(50, 51);

        liquidityPoolInstance.setStakingTargetWeights(61, 39);

        (, eEthTargetWeight) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.EETH);
        (, etherFanTargetWeight) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.ETHER_FAN);

        assertEq(eEthTargetWeight, 61);
        assertEq(etherFanTargetWeight, 39);
    }

    function test_DepositFromBNFTHolder() public {
        bytes32[] memory aliceProof = merkle.getProof(whiteListedAddresses, 3);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        vm.startPrank(alice);
        liquidityPoolInstance.registerAsBnftHolder(alice);
        liquidityPoolInstance.registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();
        vm.stopPrank();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        vm.warp(12431561615);

        liquidityPoolInstance.dutyForWeek();

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

        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();

        // set BNFT players to restake on deposit
        vm.prank(alice);
        liquidityPoolInstance.setRestakeBnftDeposits(true);

        bytes32[] memory aliceProof = merkle.getProof(whiteListedAddresses, 3);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        vm.startPrank(alice);
        liquidityPoolInstance.registerAsBnftHolder(alice);
        liquidityPoolInstance.registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();
        vm.stopPrank();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        vm.warp(12431561615);

        liquidityPoolInstance.dutyForWeek();

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

        assertEq(liquidityPoolInstance.numPendingDeposits(), 4);
        assertEq(BNFTInstance.balanceOf(alice), 1);
        assertEq(TNFTInstance.balanceOf(address(liquidityPoolInstance)), 1);
    }

    function test_DepositFromBNFTHolderTwice() public {
        bytes32[] memory aliceProof = merkle.getProof(whiteListedAddresses, 3);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 8;
        _executeAdminTasks(report);

        vm.startPrank(alice);
        liquidityPoolInstance.registerAsBnftHolder(alice);
        liquidityPoolInstance.registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 240 ether}();
        vm.stopPrank();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        vm.warp(12431561615);

        liquidityPoolInstance.dutyForWeek();

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

        vm.expectRevert("Already deposited");
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);
    }
}

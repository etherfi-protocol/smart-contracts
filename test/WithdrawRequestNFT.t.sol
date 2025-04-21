// WithdrawRequestNFTTest.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";


contract WithdrawRequestNFTIntrusive is WithdrawRequestNFT {

    constructor() WithdrawRequestNFT(address(0)) {}

    function updateParam(uint32 _currentRequestIdToScanFromForShareRemainder, uint32 _lastRequestIdToScanUntilForShareRemainder) external {
        currentRequestIdToScanFromForShareRemainder = _currentRequestIdToScanFromForShareRemainder;
        lastRequestIdToScanUntilForShareRemainder = _lastRequestIdToScanUntilForShareRemainder;
    }
    
}

contract WithdrawRequestNFTTest is TestSetup {

    uint32[] public reqIds =[ 20, 388, 478, 714, 726, 729, 735, 815, 861, 916, 941, 1014, 1067, 1154, 1194, 1253];
    address etherfi_admin_wallet = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;

    function setUp() public {
        setUpTests();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();
    }

    function updateParam(uint32 _currentRequestIdToScanFromForShareRemainder, uint32 _lastRequestIdToScanUntilForShareRemainder) internal {
        address cur_impl = withdrawRequestNFTInstance.getImplementation();
        address new_impl = address(new WithdrawRequestNFTIntrusive());
        withdrawRequestNFTInstance.upgradeTo(new_impl);
        WithdrawRequestNFTIntrusive(address(withdrawRequestNFTInstance)).updateParam(_currentRequestIdToScanFromForShareRemainder, _lastRequestIdToScanUntilForShareRemainder);
        withdrawRequestNFTInstance.upgradeTo(cur_impl);
    }

    function test_finalizeRequests() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool earlyRequestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(earlyRequestIsFinalized, "Request should not be Finalized");

        _finalizeWithdrawalRequest(requestId);

        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        assertEq(request.amountOfEEth, 1 ether, "Amount of eEth should match");

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertTrue(requestIsFinalized, "Request should be finalized");
    }

    function test_requestWithdraw() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(requestIsFinalized, "Request should not be finalized");

        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        assertEq(request.amountOfEEth, 1 ether, "Amount of eEth should match");
        assertEq(request.shareOfEEth, 1 ether, "Share of eEth should match");
        assertTrue(request.isValid, "Request should be valid");
    }

    function test_InvalidClaimWithdraw() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(requestIsFinalized, "Request should not be finalized");

        vm.expectRevert("Request is not finalized");
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_ClaimWithdrawOfOthers() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        vm.expectRevert("Not the owner of the NFT");
        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_ValidClaimWithdraw1() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 bobsStartingBalance = address(bob).balance;

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0 ether, "eETH balance should start from 0 ether");

        // Case 1.
        // Even after the rebase, the withdrawal amount should remain the same; 1 eth
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        assertEq(eETHInstance.balanceOf(bob), 9 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 1 ether, "eETH balance should be 1 ether");
        assertEq(eETHInstance.balanceOf(address(treasuryInstance)), 0 ether, "Treasury balance should be 0 ether");

        // Rebase with accrued_rewards = 10 ether for the deposited 10 ether
        // -> 1 ether eETH shares = 2 ether ETH
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether);

        assertEq(withdrawRequestNFTInstance.balanceOf(bob), 1, "Bobs balance should be 1");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), bob, "Bobs should own the NFT");
        assertEq(eETHInstance.balanceOf(bob), 18 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 2 ether, "eETH balance should be 2 ether");

        _finalizeWithdrawalRequest(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobsEndingBalance = address(bob).balance;

        assertEq(bobsEndingBalance, bobsStartingBalance + 1 ether, "Bobs balance should be 1 ether higher");
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 1 ether, "eETH balance should be 1 ether");
    }

    function test_ValidClaimWithdrawWithNegativeRebase() public {
        launch_validator();

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 bobsStartingBalance = address(bob).balance;

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether + 64 ether);

        // Case 2.
        // After the rebase with negative rewards (loss of 35 eth among 70 eth),
        // the withdrawal amount is reduced from 1 ether to 0.5 ether
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(-35 ether);

        assertEq(withdrawRequestNFTInstance.balanceOf(bob), 1, "Bobs balance should be 1");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), bob, "Bobs should own the NFT");

        _finalizeWithdrawalRequest(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobsEndingBalance = address(bob).balance;
        assertApproxEqAbs(bobsEndingBalance, bobsStartingBalance + 0.5 ether, 0.2 ether);
    }

    function test_withdraw_with_zero_liquidity() public {
        // bob mints 60 eETH and alilce spins up 2 validators with the deposited 60 ETH
        launch_validator();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 60 ether);

        // bob requests withdrawal
        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 60 ether);

        // Somehow, LP gets some ETH
        // For example, alice deposits 100 ETH :D
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100 ether}();

        _finalizeWithdrawalRequest(requestId);

        uint256 bobsStartingBalance = address(bob).balance;

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobsEndingBalance = address(bob).balance;

        assertEq(bobsEndingBalance, bobsStartingBalance + 60 ether, "Bobs balance should be 60 ether higher");
        
    }

    function test_SD_6() public {
        vm.deal(bob, 98);

        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 98}();
        eETHInstance.approve(address(liquidityPoolInstance), 98);
        vm.stopPrank();

        assertEq(eETHInstance.totalShares(), 98);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 98);
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(2);
        assertEq(eETHInstance.totalShares(), 98);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 100);

        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0);
        vm.prank(bob);
        // Withdraw request for 9 wei eETH amount (= 8.82 wei eETH share)
        // 8 wei eETH share is transfered to `withdrawRequestNFT` contract
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 9);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 8);
        // Within `LP.requestWithdraw`
        // - `share` is calculated by `sharesForAmount` as (9 * 98) / 100 = 8.82 ---> (rounded down to) 8


        _finalizeWithdrawalRequest(requestId);


        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        // Within `claimWithdraw`,
        // - `request.amountOfEEth` is 9
        // - `amountForShares` is (8 * 100) / 98 = 8.16 ---> (rounded down to) 8
        // - `amountToTransfer` is min(9, 8) = 8
        // Therefore, it calls `LP.withdraw(.., 8)`

        // Within `LP.withdraw`, 
        // - `share` is calculated by 'sharesForWithdrawalAmount' as (8 * 98 + 100 - 1) / 100 = 8.83 ---> (rounded down to) 8

        // As a result, bob received 8 wei ETH which is 1 wei less than 9 wei.
        assertEq(bob.balance, 8);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0);

        // We burnt 8 wei eETH share which is worth of 8.16 wei eETH amount.
        // We processed the withdrawal of 8 wei ETH. 
        // --> The rest 0.16 wei ETH is effectively distributed to the other eETH holders.
    }


    // It depicts the scenario where bob's WithdrawalRequest NFT is stolen by alice.
    // The owner invalidates the request 
    function test_InvalidatedRequestNft_after_finalization() public returns (uint256 requestId) {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        vm.prank(bob);
        withdrawRequestNFTInstance.transferFrom(bob, alice, requestId);

        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice, "Alice should own the NFT");

        _finalizeWithdrawalRequest(requestId);

        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "Request should be valid");

        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);
    }

    function test_InvalidatedRequestNft_before_finalization() public returns (uint256 requestId) {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        vm.prank(bob);
        withdrawRequestNFTInstance.transferFrom(bob, alice, requestId);

        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice, "Alice should own the NFT");

        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        _finalizeWithdrawalRequest(requestId);
    }

    function getAllWithdrawalAmount(uint256 lastRequestId) internal returns (uint128) {
        uint256 requestId = lastRequestId+1;
        uint128 amount = 0;

        // this takes too long to run so hard code it 
        // while (requestId <= 62515) {
        //     WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        //     amount += request.amountOfEEth;
        //     requestId++;
        // }
        // console2.log("amount", amount);
        // return amount;
        return 91981992168660066831075;
    }

    function test_processLargeWithdrawal() public {
        initializeRealisticFork(MAINNET_FORK);
        uint256 lastRequestId = withdrawRequestNFTInstance.lastFinalizedRequestId();
        uint128 amount = getAllWithdrawalAmount(lastRequestId);
        //recreate handleWithdrawal function in etherfiadmin contract
        vm.startPrank(address(etherFiAdminInstance));
        withdrawRequestNFTInstance.invalidateRequest(62222);
        withdrawRequestNFTInstance.invalidateRequest(62223);
        withdrawRequestNFTInstance.finalizeRequests(62515);
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);
        vm.stopPrank();

        //verify Justin 
        vm.startPrank(withdrawRequestNFTInstance.ownerOf(62222));
        vm.expectRevert("Request is not valid");
        withdrawRequestNFTInstance.claimWithdraw(62222);
        vm.stopPrank();
        vm.startPrank(withdrawRequestNFTInstance.ownerOf(62223));
        vm.expectRevert("Request is not valid");
        withdrawRequestNFTInstance.claimWithdraw(62223);
        vm.stopPrank();

        //verify people after and before can claim
        vm.startPrank(withdrawRequestNFTInstance.ownerOf(62229));
        address ownerOf62229 = withdrawRequestNFTInstance.ownerOf(62229);
        uint256 balanceBefore = ownerOf62229.balance;
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(62229);
        uint256 amountToClaim = request.amountOfEEth;
        withdrawRequestNFTInstance.claimWithdraw(62229);
        uint256 balanceAfter = ownerOf62229.balance;
        assertApproxEqAbs(balanceAfter, balanceBefore + amountToClaim, 100, 'not enough eth claimed');
        vm.stopPrank();

        vm.startPrank(withdrawRequestNFTInstance.ownerOf(62219));
        address ownerOf62219 = withdrawRequestNFTInstance.ownerOf(62219);
       uint256 balanceBefore2 = ownerOf62219.balance;
       
       WithdrawRequestNFT.WithdrawRequest memory request2 = withdrawRequestNFTInstance.getRequest(62219);
       uint256 amountToClaim2 = request2.amountOfEEth;
        withdrawRequestNFTInstance.claimWithdraw(62219);
        uint256 balanceAfter2 = ownerOf62219.balance;
        assertApproxEqAbs(balanceAfter2, balanceBefore2 + amountToClaim2, 100, 'not enough eth claimed');
        vm.stopPrank();
    }

    function test_aggregateSumEEthShareAmount() public {
        initializeRealisticFork(MAINNET_FORK);

        vm.startPrank(withdrawRequestNFTInstance.owner());
        // 1. Upgrade
        withdrawRequestNFTInstance.upgradeTo(address(new WithdrawRequestNFT(address(owner))));
        withdrawRequestNFTInstance.initializeOnUpgrade(address(roleRegistryInstance), 50_00);

        // 2. (For test) update the scan range
        updateParam(1, 200);
        vm.stopPrank();

        // 2. Confirm Paused & Can't Unpause
        assertTrue(withdrawRequestNFTInstance.paused(), "Contract should be paused");
        vm.prank(admin);
        vm.expectRevert("scan is not completed");
        withdrawRequestNFTInstance.unPauseContract();
        vm.stopPrank();
        // 3. AggSum
        // - Can't Unpause untill the scan is not completed
        // - Can't aggregateSumEEthShareAmount after the scan is completed
        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(128);
        assertFalse(withdrawRequestNFTInstance.isScanOfShareRemainderCompleted(), "Scan should be completed");

        vm.prank(admin);
        vm.expectRevert("scan is not completed");
        withdrawRequestNFTInstance.unPauseContract();

        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(128);
        assertTrue(withdrawRequestNFTInstance.isScanOfShareRemainderCompleted(), "Scan should be completed");

        vm.expectRevert("scan is completed");
        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(128);

        // 4. Can Unpause
        vm.startPrank(admin);
        withdrawRequestNFTInstance.unPauseContract();
        vm.stopPrank();

        // we will run the test on the forked mainnet to perform the full scan and confirm we can unpause
    }

    function test_handleRemainder() public {
        test_aggregateSumEEthShareAmount();
        vm.startPrank(etherfi_admin_wallet);
        roleRegistryInstance.grantRole(withdrawRequestNFTInstance.WITHDRAW_REQUEST_NFT_ADMIN_ROLE(), etherfi_admin_wallet);
        vm.stopPrank();
        vm.prank(etherfi_admin_wallet);
        
        //withdrawRequestNFTInstance.handleRemainder(0.01 ether);
        vm.stopPrank();
    }

    function testFuzz_RequestWithdraw(uint96 depositAmount, uint96 withdrawAmount, address recipient) public {
        // Assume valid conditions
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1000 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
        vm.assume(recipient != address(0) && recipient != address(liquidityPoolInstance));
        
        // Setup initial balance for bob
        vm.deal(bob, depositAmount);
        
        // Deposit ETH and get eETH
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: depositAmount}();
        
        // Approve and request withdraw
        eETHInstance.approve(address(liquidityPoolInstance), withdrawAmount);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(recipient, withdrawAmount);
        vm.stopPrank();

        // Verify the request was created correctly
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        
        assertEq(request.amountOfEEth, withdrawAmount, "Incorrect withdrawal amount");
        assertEq(request.shareOfEEth, liquidityPoolInstance.sharesForAmount(withdrawAmount), "Incorrect share amount");
        assertTrue(request.isValid, "Request should be valid");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "Incorrect NFT owner");
        
        // Verify eETH balances
        assertEq(eETHInstance.balanceOf(bob), depositAmount - withdrawAmount, "Incorrect remaining eETH balance");
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), withdrawAmount, "Incorrect contract eETH balance");
        assertEq(withdrawRequestNFTInstance.nextRequestId(), requestId + 1, "Incorrect next request ID");

        if (eETHInstance.balanceOf(bob) > 0) {
            uint256 reqAmount = eETHInstance.balanceOf(bob);
            vm.startPrank(bob);
            eETHInstance.approve(address(liquidityPoolInstance), reqAmount);
            uint256 requestId2 = liquidityPoolInstance.requestWithdraw(recipient, reqAmount);    
            vm.stopPrank();
            assertEq(requestId2, requestId + 1, "Incorrect next request ID");
        }
    }

    function testFuzz_ClaimWithdraw(
        uint96 depositAmount,
        uint96 withdrawAmount,
        uint96 rebaseAmount,
        uint16 remainderSplitBps,
        address recipient
    ) public {
        // Assume valid conditions
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1e6 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
        vm.assume(rebaseAmount >= 0.5 ether && rebaseAmount <= depositAmount);
        vm.assume(remainderSplitBps <= 10000);
        vm.assume(recipient != address(0) && recipient != address(liquidityPoolInstance));


        vm.expectRevert("scan is completed");
        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(10);

        // Setup initial balance for recipient
        vm.deal(recipient, depositAmount);

        // Configure remainder split
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(remainderSplitBps);

        // First deposit ETH to get eETH
        vm.startPrank(recipient);
        liquidityPoolInstance.deposit{value: depositAmount}();

        // Record initial balances
        uint256 treasuryEEthBefore = eETHInstance.balanceOf(address(treasuryInstance));
        uint256 recipientBalanceBefore = address(recipient).balance;

        // Request withdraw
        eETHInstance.approve(address(liquidityPoolInstance), withdrawAmount);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(recipient, withdrawAmount);
        vm.stopPrank();

        // Get initial request state
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);

        // Simulate rebase after request but before claim
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(int128(uint128(rebaseAmount)));

        // Calculate expected withdrawal amounts after rebase
        uint256 sharesValue = liquidityPoolInstance.amountForShare(request.shareOfEEth);
        console2.log(request.shareOfEEth);
        uint256 expectedWithdrawAmount = withdrawAmount < sharesValue ? withdrawAmount : sharesValue;
        uint256 expectedBurnedShares = liquidityPoolInstance.sharesForAmount(expectedWithdrawAmount);
        uint256 expectedDustShares = request.shareOfEEth - expectedBurnedShares;

        // Track initial shares and total supply
        uint256 initialTotalShares = eETHInstance.totalShares();

        _finalizeWithdrawalRequest(requestId);
        
        vm.prank(recipient);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        // Calculate expected burnt shares
        uint256 burnedShares = initialTotalShares - eETHInstance.totalShares();

        // Verify share burning
        assertLe(burnedShares, request.shareOfEEth, "Burned shares should be less than or equal to requested shares");
        assertApproxEqAbs(
            burnedShares,
            expectedBurnedShares,
            1e3,
            "Incorrect amount of shares burnt"
        );
        

        // Verify total supply reduction
        assertApproxEqAbs(
            eETHInstance.totalShares(),
            initialTotalShares - burnedShares,
            1,
            "Total shares not reduced correctly"
        );
        assertGe(
            eETHInstance.totalShares(),
            initialTotalShares - burnedShares,
            "Total shares should be greater than or equal to initial shares minus burned shares"
        );

        // Verify the withdrawal results
        WithdrawRequestNFT.WithdrawRequest memory requestAfter = withdrawRequestNFTInstance.getRequest(requestId);
        
        // Request should be cleared
        assertEq(requestAfter.amountOfEEth, 0, "Request should be cleared after claim");
        
        // NFT should be burned
        vm.expectRevert("ERC721: invalid token ID");
        withdrawRequestNFTInstance.ownerOf(requestId);

        // Verify recipient received correct ETH amount
        assertEq(
            address(recipient).balance,
            recipientBalanceBefore + expectedWithdrawAmount,
            "Recipient should receive correct ETH amount"
        );

        assertApproxEqAbs(
            withdrawRequestNFTInstance.totalRemainderEEthShares(),
            expectedDustShares,
            1,
            "Incorrect remainder shares"
        );

        uint256 dustEEthAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        console2.log("wtf");
        vm.startPrank(admin);
        withdrawRequestNFTInstance.handleRemainder(dustEEthAmount / 2);
    }

    function testFuzz_InvalidateRequest(uint96 depositAmount, uint96 withdrawAmount, address recipient) public {
        // Assume valid conditions
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1000 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
        vm.assume(recipient != address(0) && recipient != address(liquidityPoolInstance) && recipient != alice && recipient != admin && recipient != (address(etherFiAdminInstance)));
        
        // Setup initial balance and deposit
        vm.deal(recipient, depositAmount);
        
        vm.startPrank(recipient);
        liquidityPoolInstance.deposit{value: depositAmount}();
        
        // Request withdraw
        eETHInstance.approve(address(liquidityPoolInstance), withdrawAmount);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(recipient, withdrawAmount);
        vm.stopPrank();

        // Verify request is initially valid
        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "Request should start valid");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "Recipient should own NFT");

        // Non-admin cannot invalidate
        vm.prank(recipient);
        vm.expectRevert("Caller is not admin");
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Admin invalidates request
        vm.startPrank(address(0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf));
        roleRegistryInstance.grantRole(withdrawRequestNFTInstance.WITHDRAW_REQUEST_NFT_ADMIN_ROLE(), admin);
        vm.stopPrank();
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Verify request state after invalidation
        assertFalse(withdrawRequestNFTInstance.isValid(requestId), "Request should be invalid");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "NFT ownership should remain unchanged");
        
        // Verify cannot transfer invalid request
        vm.prank(recipient);
        vm.expectRevert("INVALID_REQUEST");
        withdrawRequestNFTInstance.transferFrom(recipient, address(0xdead), requestId);

        // Owner can seize the invalidated request NFT
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, admin);
    }
}

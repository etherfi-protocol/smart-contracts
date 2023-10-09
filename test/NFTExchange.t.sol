// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract NFTExchangeTest is TestSetup {

    bytes32[] public aliceProof;
    bytes32[] public ownerProof;
    bytes32[] public emptyProof;

    function setUp() public {
        setUpTests();

        vm.startPrank(alice);
        eETHInstance.approve(address(membershipManagerInstance), 1_000_000_000 ether);
        vm.stopPrank();

        aliceProof = merkle.getProof(whiteListedAddresses, 3);
        ownerProof = merkle.getProof(whiteListedAddresses, 10);
    }

    function test_trade() public {
        // Alice has staked 32 ETH and is holding 1 pair of {B, T}-NFTs
        uint256 tNftTokenId = _alice_stake();
 
        // Owner mints a membership NFT holding 30 ETH
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        uint256 membershipNftTokenId = membershipManagerInstance.wrapEth{value: 30 ether}(30 ether, 0);

        // Owner prepares for the NFT; setting its (loyalty, tier) points
        uint40 loyaltyPoints = 10000;
        uint40 tierPoints = 1000;
        membershipManagerInstance.setPoints(membershipNftTokenId, loyaltyPoints, tierPoints);
        vm.stopPrank();

        assertEq(membershipNftInstance.loyaltyPointsOf(membershipNftTokenId), loyaltyPoints);
        assertEq(membershipNftInstance.tierPointsOf(membershipNftTokenId), tierPoints);

        // Owner approves the NFTExchange to transfer the membership NFT
        vm.prank(alice);
        membershipNftInstance.setApprovalForAll(address(nftExchangeInstance), true);

        uint256[] memory mNftTokenIds = new uint256[](1);
        uint256[] memory tNftTokenIds = new uint256[](1);
        address[] memory reservedBuyers = new address[](1);
        mNftTokenIds[0] = membershipNftTokenId;
        tNftTokenIds[0] = tNftTokenId;
        reservedBuyers[0] = alice;

        // make a small withdrawal
        vm.startPrank(alice);
        uint256 withdrawalAmount = 0.1 ether;
        uint256 requestId = membershipManagerInstance.requestWithdraw(membershipNftTokenId, withdrawalAmount);
        vm.stopPrank();

        _finalizeWithdrawalRequest(requestId);
        
        vm.startPrank(alice);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertEq(membershipNftInstance.transferLockedUntil(membershipNftTokenId), block.number + membershipManagerInstance.withdrawalLockBlocks());

        // fails because token is locked
        vm.expectRevert(MembershipNFT.RequireTokenUnlocked.selector);
        nftExchangeInstance.listForSale(mNftTokenIds, tNftTokenIds, reservedBuyers);

        // wait for lock to expire
        vm.roll(block.number + membershipManagerInstance.withdrawalLockBlocks());

        // Owner lists it for sale
        nftExchangeInstance.listForSale(mNftTokenIds, tNftTokenIds, reservedBuyers);
        vm.stopPrank();

        // Fail: Bob is not the reserved buyer
        vm.startPrank(bob);
        vm.expectRevert("You are not the reserved buyer");
        nftExchangeInstance.buy(tNftTokenIds, mNftTokenIds);
        vm.stopPrank();

        // Success: Alice buys the membership NFT
        vm.startPrank(alice);
        TNFTInstance.setApprovalForAll(address(nftExchangeInstance), true);
        nftExchangeInstance.buy(tNftTokenIds, mNftTokenIds);


        // B-NFT still belongs to Alice
        // T-NFT belongs to Owner now
        assertEq(BNFTInstance.ownerOf(tNftTokenId), alice);
        assertEq(TNFTInstance.ownerOf(tNftTokenId), owner);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether - withdrawalAmount);
        assertEq(address(liquidityPoolInstance).balance, 30 ether - withdrawalAmount);

        // Fail: Already Sold
        vm.expectRevert("Token is not currently listed for sale");
        nftExchangeInstance.buy(tNftTokenIds, mNftTokenIds);
        vm.stopPrank();

        vm.startPrank(alice);
        // Fail: Already Sold
        vm.expectRevert("Token is not currently listed for sale");
        nftExchangeInstance.delist(mNftTokenIds);
        vm.stopPrank();


        uint256 ownerBalance = address(owner).balance;

        // need to give liquidity pool a little more eth to cover previous withdrawal
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 0.1 ether}();

        // Success: Owner brings the T-NFT to the liquidity pool and gets 30 ETH
        vm.prank(owner);
        TNFTInstance.setApprovalForAll(address(liquidityPoolInstance), true);
        vm.prank(owner);
        liquidityPoolInstance.swapTNftForEth(tNftTokenIds);

        // B-NFT still belongs to Alice
        // T-NFT belongs to Liquidity Pool
        assertEq(BNFTInstance.ownerOf(tNftTokenId), alice);
        assertEq(TNFTInstance.ownerOf(tNftTokenId), address(liquidityPoolInstance));
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);
        assertEq(address(liquidityPoolInstance).balance, 0);
        assertEq(address(owner).balance, ownerBalance + 30 ether);

        // Now after all of the trades, disapprove the token transfer
        vm.prank(alice);
        membershipNftInstance.setApprovalForAll(address(nftExchangeInstance), false);
    }

    function test_tradeFailsForWrongTNft() public {
        // Alice has staked 32 ETH and is holding 1 pair of {B, T}-NFTs
        uint256 tNftTokenId = _alice_stake();
 
        // Owner mints a membership NFT holding 30 ETH
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        uint256 membershipNftTokenId = membershipManagerInstance.wrapEth{value: 30 ether}(30 ether, 0);

        // Owner prepares for the NFT; setting its (loyalty, tier) points
        uint40 loyaltyPoints = 10000;
        uint40 tierPoints = 1000;
        membershipManagerInstance.setPoints(membershipNftTokenId, loyaltyPoints, tierPoints);
        vm.stopPrank();

        assertEq(membershipNftInstance.loyaltyPointsOf(membershipNftTokenId), loyaltyPoints);
        assertEq(membershipNftInstance.tierPointsOf(membershipNftTokenId), tierPoints);

        // Owner approves the NFTExchange to transfer the membership NFT
        vm.prank(alice);
        membershipNftInstance.setApprovalForAll(address(nftExchangeInstance), true);

        uint256[] memory mNftTokenIds = new uint256[](1);
        uint256[] memory tNftTokenIds = new uint256[](1);
        address[] memory reservedBuyers = new address[](1);
        mNftTokenIds[0] = membershipNftTokenId;
        tNftTokenIds[0] = tNftTokenId + 100;
        reservedBuyers[0] = alice;

        // Owner lists it for sale
        vm.prank(alice);
        nftExchangeInstance.listForSale(mNftTokenIds, tNftTokenIds, reservedBuyers);

        // Fail: Alice presented the different T-NFT !
        vm.startPrank(alice);
        vm.expectRevert("The T-NFT is not the target");
        tNftTokenIds[0] = tNftTokenId;
        nftExchangeInstance.buy(tNftTokenIds, mNftTokenIds);
        vm.stopPrank();
    }


    function test_tradeFailsWhenValidatorIsNotLive() public {
        // Alice has staked 32 ETH and is holding 1 pair of {B, T}-NFTs
        uint256 tNftTokenId = _alice_stake();
 
        // Owner mints a membership NFT holding 30 ETH
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        uint256 membershipNftTokenId = membershipManagerInstance.wrapEth{value: 30 ether}(30 ether, 0);

        // Owner prepares for the NFT; setting its (loyalty, tier) points
        uint40 loyaltyPoints = 10000;
        uint40 tierPoints = 1000;
        membershipManagerInstance.setPoints(membershipNftTokenId, loyaltyPoints, tierPoints);
        vm.stopPrank();

        assertEq(membershipNftInstance.loyaltyPointsOf(membershipNftTokenId), loyaltyPoints);
        assertEq(membershipNftInstance.tierPointsOf(membershipNftTokenId), tierPoints);

        // Owner approves the NFTExchange to transfer the membership NFT
        vm.prank(alice);
        membershipNftInstance.setApprovalForAll(address(nftExchangeInstance), true);

        uint256[] memory mNftTokenIds = new uint256[](1);
        uint256[] memory tNftTokenIds = new uint256[](1);
        address[] memory reservedBuyers = new address[](1);
        mNftTokenIds[0] = membershipNftTokenId;
        tNftTokenIds[0] = tNftTokenId;
        reservedBuyers[0] = alice;

        // Owner lists it for sale
        vm.startPrank(alice);
        nftExchangeInstance.listForSale(mNftTokenIds, tNftTokenIds, reservedBuyers);

        // The node is marked as EVICTED
        managerInstance.processNodeEvict(tNftTokenIds);

        vm.expectRevert("The validator is not LIVE");
        tNftTokenIds[0] = tNftTokenId;
        nftExchangeInstance.buy(tNftTokenIds, mNftTokenIds);
        vm.stopPrank();
    }

    function test_delist() public {
        // Alice has staked 32 ETH and is holding 1 pair of {B, T}-NFTs
        uint256 tNftTokenId = _alice_stake();
 
        // Owner mints a membership NFT holding 30 ETH
        vm.deal(alice, 30 ether);
        vm.startPrank(alice);
        uint256 membershipNftTokenId = membershipManagerInstance.wrapEth{value: 30 ether}(30 ether, 0);

        // Owner prepares for the NFT; setting its (loyalty, tier) points
        uint40 loyaltyPoints = 10000;
        uint40 tierPoints = 1000;
        membershipManagerInstance.setPoints(membershipNftTokenId, loyaltyPoints, tierPoints);
        vm.stopPrank();

        assertEq(membershipNftInstance.loyaltyPointsOf(membershipNftTokenId), loyaltyPoints);
        assertEq(membershipNftInstance.tierPointsOf(membershipNftTokenId), tierPoints);

        // Owner approves the NFTExchange to transfer the membership NFT
        vm.prank(alice);
        membershipNftInstance.setApprovalForAll(address(nftExchangeInstance), true);

        // Owner lists it for sale
        uint256[] memory mNftTokenIds = new uint256[](1);
        uint256[] memory tNftTokenIds = new uint256[](1);
        address[] memory reservedBuyers = new address[](1);
        mNftTokenIds[0] = membershipNftTokenId;
        tNftTokenIds[0] = tNftTokenId;
        reservedBuyers[0] = alice;

        vm.prank(alice);
        nftExchangeInstance.listForSale(mNftTokenIds, tNftTokenIds, reservedBuyers);

        vm.startPrank(alice);
        nftExchangeInstance.delist(mNftTokenIds);
        vm.stopPrank();

        // Fail: De-listed
        vm.expectRevert("Token is not currently listed for sale");
        nftExchangeInstance.buy(tNftTokenIds, mNftTokenIds);
    }

    function test_access_control() public {
        uint256[] memory tNftTokenIds = new uint256[](1);
        uint256[] memory mNftTokenIds = new uint256[](1);
        address[] memory reservedBuyers = new address[](1);
        tNftTokenIds[0] = 0;
        mNftTokenIds[0] = 0;
        reservedBuyers[0] = address(0);

        vm.expectRevert("Caller is not the admin");
        nftExchangeInstance.listForSale(mNftTokenIds, tNftTokenIds, reservedBuyers);

        vm.expectRevert("Caller is not the admin");
        nftExchangeInstance.delist(mNftTokenIds);

        vm.expectRevert("Ownable: caller is not the owner");
        liquidityPoolInstance.swapTNftForEth(tNftTokenIds);
    }

    function _alice_stake() internal returns (uint256) {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        vm.deal(alice, 32 ether);
        vm.startPrank(alice);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId1, false);

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId1, depositDataArray);
        assertEq(BNFTInstance.ownerOf(bidId1[0]), alice);
        assertEq(TNFTInstance.ownerOf(bidId1[0]), alice);

        vm.stopPrank();

        return bidId1[0];
    }


}

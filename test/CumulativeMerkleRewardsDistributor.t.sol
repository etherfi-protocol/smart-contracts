import "@tests/TestSetup.sol";
import "forge-std/console2.sol";
import "@etherfi/governance/utils/PausableUntil.sol";

contract  CumulativeMerkleRewardsDistributorTest is TestSetup {
    address[] public accounts = new address[](4);
    uint256[] public amounts = new uint256[](4);
    bytes32[] public leaves = new bytes32[](4);
    bytes32 public node1;
    bytes32 public node2;
    bytes32 public merkleRoot;
    bytes32[][] public proofs = new bytes32[][](4);


    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b 
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    function generateMerkleTree(uint256 multipler) internal {
        // Create leaves for each account/amount pair
        for(uint256 i = 0; i < 4; i++) {
            accounts[i] = address(uint160(i+1));
            amounts[i] = (i+1) * multipler * 1 ether;
            leaves[i] = keccak256(abi.encodePacked(accounts[i], amounts[i]));
            proofs[i] = new bytes32[](2);
            vm.prank(admin);
            cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[i], true);
        }

        node1 = hashPair(leaves[0], leaves[1]);
        node2 = hashPair(leaves[2], leaves[3]);
        merkleRoot = hashPair(node1, node2);

        proofs[0][0] = leaves[1];
        proofs[0][1] = node2;
        
        proofs[1][0] = leaves[0];
        proofs[1][1] = node2;    
        
        proofs[2][0] = leaves[3];          
        proofs[2][1] = node1;  

        proofs[3][0] = leaves[2];
        proofs[3][1] = node1;      
    }

    function setMerkleRoot(address token) internal {
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(token, merkleRoot);
    vm.roll(block.number + 15000);
    vm.warp(block.timestamp + 15000 * 12);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(token, block.number - 15000);
    vm.stopPrank();
    }

   //write setup method
   function setUp() public {
    setUpTests();
    generateMerkleTree(100);
    rETH.mint(address(cumulativeMerkleRewardsDistributorInstance), 1000 ether);
    vm.deal(address(cumulativeMerkleRewardsDistributorInstance), 1000 ether);
    vm.prank(address(cumulativeMerkleRewardsDistributorInstance));
    liquidityPoolInstance.deposit{value: 1000 ether}();
   } 

   function test_claiming() public {
    setMerkleRoot(address(eETHInstance));
    vm.prank(accounts[0]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[1], 200 ether, merkleRoot, proofs[1]); 
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[2], 300 ether, merkleRoot, proofs[2]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[3], 400 ether, merkleRoot, proofs[3]);
    assertEq(eETHInstance.balanceOf(accounts[0]), 100 ether);
    assertEq(eETHInstance.balanceOf(accounts[1]), 200 ether);
    assertEq(eETHInstance.balanceOf(accounts[2]), 300 ether);
    assertEq(eETHInstance.balanceOf(accounts[3]), 400 ether);
   }

   function test_verification() public {
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.MerkleRootWasUpdated.selector);
    //need to pass correct merkle root
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, bytes32(uint256(1)), proofs[0]);
    setMerkleRoot(address(eETHInstance));
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[0], false);
    //claimer must be whitelisted
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.NonWhitelistedUser.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]); 
    cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[0], true);
    vm.stopPrank();

    //must provide correct balance
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InvalidProof.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 200 ether, merkleRoot, proofs[0]);

    //must provide  correct user
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InvalidProof.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 200 ether, merkleRoot, proofs[1]);
 
    //must provide  correct user
    bytes32[] memory incorrectProofs = new bytes32[](2);
    incorrectProofs[0] = proofs[0][0];
    incorrectProofs[1] = proofs[0][0];
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InvalidProof.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, incorrectProofs);
   }

   function test_whitelisting() public {
    vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
    cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[0], false);
   }

   function test_claiming_delay() public {
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(address(eETHInstance), merkleRoot);
    vm.roll(block.number + 14399);
    vm.warp(block.timestamp + 14399 * 12);
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InsufficentDelay.selector);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(address(eETHInstance), block.number - 12000);
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 12);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(address(eETHInstance), block.number - 12000);
    vm.assertEq(cumulativeMerkleRewardsDistributorInstance.claimableMerkleRoots(address(eETHInstance)), merkleRoot);
    vm.stopPrank();
   }

   function test_multiple_token() public {
    setMerkleRoot(address(eETHInstance));
    setMerkleRoot(address(rETH));
    console.logBytes32(merkleRoot);

    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(rETH), accounts[0], 100 ether, merkleRoot, proofs[0]);
    assertEq(eETHInstance.balanceOf(accounts[0]), 100 ether);
    assertEq(rETH.balanceOf(accounts[0]), 100 ether);
   }

   function test_cummulative_claim() public {
    setMerkleRoot(address(eETHInstance));
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    generateMerkleTree(200);
    setMerkleRoot(address(eETHInstance));
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 200 ether, merkleRoot, proofs[0]);
   }

   function test_pausing() public {
    vm.prank(chad);
    // pause() is onlyAdmin → OPERATION_MULTISIG_ROLE → reverts with OnlyOperatingMultisig.
    vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
    cumulativeMerkleRewardsDistributorInstance.pause();
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.pause();
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.ContractPaused.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.ContractPaused.selector);
    cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(address(eETHInstance), merkleRoot);
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.ContractPaused.selector);
    vm.roll(block.number + 15000);
    vm.warp(block.timestamp + 15000 * 12);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(address(eETHInstance), block.number - 12000);
    cumulativeMerkleRewardsDistributorInstance.unpause();
    test_claiming();
    vm.stopPrank();
   }
   function test_upgrading() public {
    vm.prank(chad);
    vm.expectRevert(RoleRegistry.OnlyUpgradeTimelock.selector);
    cumulativeMerkleRewardsDistributorInstance.upgradeTo(address(0x555));
    CumulativeMerkleRewardsDistributor newImpl = new CumulativeMerkleRewardsDistributor(address(roleRegistryInstance)); 
    vm.prank(roleRegistryInstance.owner());
    cumulativeMerkleRewardsDistributorInstance.upgradeTo(address(newImpl));
    vm.assertEq(cumulativeMerkleRewardsDistributorInstance.getImplementation(), address(newImpl));
   }

   // --------------------------------------------------------
   //  pauseContractUntil / unpauseContractUntil
   // --------------------------------------------------------

   bytes32 constant PAUSABLE_UNTIL_SLOT =
       0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

   address pauseUntilPauser = makeAddr("pauseUntilPauser");
   address unpauseUntilUnpauser = makeAddr("unpauseUntilUnpauser");
   address pauseUntilDurationSetter = makeAddr("pauseUntilDurationSetter");

   function _grantPauseUntilRoles(address pauserAddr, address unpauserAddr) internal {
       vm.startPrank(owner);
       // pauseContractUntil requires GUARDIAN_ROLE; unpauseContractUntil and
       // setPauseUntilDuration require OPERATION_MULTISIG_ROLE.
       roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), pauserAddr);
       roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), unpauserAddr);
       roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), pauseUntilDurationSetter);
       vm.stopPrank();
       // warp past MAX_PAUSE_DURATION + PAUSER_UNTIL_COOLDOWN so the first-pause cooldown
       // (which treats lastPauseTimestamp[pauser] = 0 as unix 0) is satisfied
       if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

       uint256 maxDur = cumulativeMerkleRewardsDistributorInstance.MAX_PAUSE_DURATION();
       vm.prank(pauseUntilDurationSetter);
       cumulativeMerkleRewardsDistributorInstance.setPauseUntilDuration(maxDur);
   }

   function _pausedUntil() internal view returns (uint256) {
       return uint256(vm.load(address(cumulativeMerkleRewardsDistributorInstance), PAUSABLE_UNTIL_SLOT));
   }

   function test_pauseContractUntil_requiresRole() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);

       vm.prank(chad);
       vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();
   }

   function test_pauseContractUntil_setsState() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);

       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();
       assertEq(_pausedUntil(), block.timestamp + cumulativeMerkleRewardsDistributorInstance.MAX_PAUSE_DURATION());
   }

   function test_unpauseContractUntil_requiresRole() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();

       vm.prank(chad);
       vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
       cumulativeMerkleRewardsDistributorInstance.unpauseContractUntil();
   }

   function test_unpauseContractUntil_clearsState() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();

       vm.prank(unpauseUntilUnpauser);
       cumulativeMerkleRewardsDistributorInstance.unpauseContractUntil();
       assertEq(_pausedUntil(), 0);
   }

   function test_unpauseContractUntil_revertsIfNotPaused() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(unpauseUntilUnpauser);
       vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
       cumulativeMerkleRewardsDistributorInstance.unpauseContractUntil();
   }

   // --- setPauseUntilDuration ---

   function test_setPauseUntilDuration_requiresRole() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       uint256 maxDur = cumulativeMerkleRewardsDistributorInstance.MAX_PAUSE_DURATION();

       // bob holds no roles in setUpTests; chad/admin/owner all have OPERATION_TIMELOCK_ROLE.
       vm.prank(bob);
       vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
       cumulativeMerkleRewardsDistributorInstance.setPauseUntilDuration(maxDur);

       // Guardian-only (pauseUntilPauser) cannot set the duration; needs admin role.
       vm.prank(pauseUntilPauser);
       vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
       cumulativeMerkleRewardsDistributorInstance.setPauseUntilDuration(maxDur);
   }

   function test_setPauseUntilDuration_setsValue() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       uint256 d = cumulativeMerkleRewardsDistributorInstance.MIN_PAUSE_DURATION() + 1 hours;

       vm.prank(pauseUntilDurationSetter);
       cumulativeMerkleRewardsDistributorInstance.setPauseUntilDuration(d);

       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();
       assertEq(_pausedUntil(), block.timestamp + d);
   }

   function test_setPauseUntilDuration_revertsOnInvalidValue() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       uint256 belowMin = cumulativeMerkleRewardsDistributorInstance.MIN_PAUSE_DURATION() - 1;
       uint256 aboveMax = cumulativeMerkleRewardsDistributorInstance.MAX_PAUSE_DURATION() + 1;

       vm.prank(pauseUntilDurationSetter);
       vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
       cumulativeMerkleRewardsDistributorInstance.setPauseUntilDuration(belowMin);

       vm.prank(pauseUntilDurationSetter);
       vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
       cumulativeMerkleRewardsDistributorInstance.setPauseUntilDuration(aboveMax);
   }

   // --- each gated function (whenNotPaused → also blocked by pause-until) ---

   function test_setPendingMerkleRoot_blockedByPauseContractUntil() public {
       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();

       vm.prank(admin);
       vm.expectRevert(
           abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _pausedUntil())
       );
       cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(address(eETHInstance), merkleRoot);
   }

   function test_finalizeMerkleRoot_blockedByPauseContractUntil() public {
       // set a pending root before pausing so finalize has something to validate
       vm.prank(admin);
       cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(address(eETHInstance), merkleRoot);
       vm.roll(block.number + 15000);
       vm.warp(block.timestamp + 15000 * 12);

       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();

       vm.prank(admin);
       vm.expectRevert(
           abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _pausedUntil())
       );
       cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(address(eETHInstance), block.number - 12000);
   }

   function test_claim_blockedByPauseContractUntil() public {
       setMerkleRoot(address(eETHInstance));

       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();

       vm.expectRevert(
           abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _pausedUntil())
       );
       cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
   }

   function test_claim_unblockedAfterPauseExpires() public {
       setMerkleRoot(address(eETHInstance));

       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();

       vm.warp(block.timestamp + cumulativeMerkleRewardsDistributorInstance.MAX_PAUSE_DURATION() + 1);

       cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
       assertEq(eETHInstance.balanceOf(accounts[0]), 100 ether);
   }

   function test_claim_unblockedAfterExplicitUnpause() public {
       setMerkleRoot(address(eETHInstance));

       _grantPauseUntilRoles(pauseUntilPauser, unpauseUntilUnpauser);
       vm.prank(pauseUntilPauser);
       cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();
       vm.prank(unpauseUntilUnpauser);
       cumulativeMerkleRewardsDistributorInstance.unpauseContractUntil();

       cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
       assertEq(eETHInstance.balanceOf(accounts[0]), 100 ether);
   }

   function test_verify_bytes() public {
    // initializeRealisticFork(MAINNET_FORK);
    // CumulativeMerkleRewardsDistributor cumulativeMerkleRewardsDistributorImplementation = new CumulativeMerkleRewardsDistributor(address(roleRegistryInstance));
    // CumulativeMerkleRewardsDistributor cumulativeMerkleRewardsDistributorInstance = CumulativeMerkleRewardsDistributor(payable(0x9A8c5046a290664Bf42D065d33512fe403484534));
    // address deployedProxy = address(0x9A8c5046a290664Bf42D065d33512fe403484534);
    // address deployedImpl = address(0xD3F3480511FB25a3D86568B6e1eFBa09d0aDEebF);
    // verifyContractByteCodeMatch(deployedImpl, address(cumulativeMerkleRewardsDistributorImplementation));
    // verifyContractByteCodeMatch(deployedProxy, address(cumulativeMerkleRewardsDistributorInstance));
   }

    /// @dev M-07: contract added `receive() external payable {}` + AssetRecovery (recoverETH /
    ///      recoverERC20) so any ETH airdropped to the contract can be swept by Operations.
    ///      Pre-fix, plain ETH transfers would revert (no receive/fallback), trapping funds.
    function test_receive_acceptsPlainEthTransfer() public {
        address payable cmrd = payable(address(cumulativeMerkleRewardsDistributorInstance));
        uint256 balBefore = cmrd.balance;

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok, ) = cmrd.call{value: 1 ether}("");
        assertTrue(ok, "plain ETH transfer should succeed via receive()");
        assertEq(cmrd.balance - balBefore, 1 ether, "balance should reflect transfer");
    }

    function test_recoverETH_movesEthToRecipient() public {
        address payable cmrd = payable(address(cumulativeMerkleRewardsDistributorInstance));
        vm.deal(cmrd, 5 ether);

        address payable to = payable(makeAddr("recipient"));
        uint256 toBalBefore = to.balance;
        uint256 cmrdBalBefore = cmrd.balance;

        vm.prank(admin);
        cumulativeMerkleRewardsDistributorInstance.recoverETH(to, 3 ether);

        assertEq(to.balance - toBalBefore, 3 ether, "recipient should receive recovered ETH");
        assertEq(cmrdBalBefore - cmrd.balance, 3 ether, "contract balance should drop by recovered amount");
    }

    function test_recoverETH_revertsForNonOperator() public {
        address payable cmrd = payable(address(cumulativeMerkleRewardsDistributorInstance));
        vm.deal(cmrd, 1 ether);

        vm.prank(bob); // bob holds no roles
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        cumulativeMerkleRewardsDistributorInstance.recoverETH(payable(bob), 1 ether);
    }

    function test_recoverERC20_movesTokenToRecipient() public {
        // setUp() already minted 1000 rETH to the distributor; recover 100.
        address to = makeAddr("recipient");
        uint256 cmrdBefore = rETH.balanceOf(address(cumulativeMerkleRewardsDistributorInstance));

        vm.prank(admin);
        cumulativeMerkleRewardsDistributorInstance.recoverERC20(address(rETH), to, 100 ether);

        assertEq(rETH.balanceOf(to), 100 ether, "recipient should receive recovered tokens");
        assertEq(
            cmrdBefore - rETH.balanceOf(address(cumulativeMerkleRewardsDistributorInstance)),
            100 ether,
            "contract balance should drop by recovered amount"
        );
    }

    function test_recoverERC20_revertsForNonOperator() public {
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        cumulativeMerkleRewardsDistributorInstance.recoverERC20(address(rETH), bob, 1 ether);
    }

    // PR #385 M9: cumulative payout under a single claimable root is bounded by a
    // timelock-set ceiling, so a compromised EXECUTOR's malicious root cannot drain
    // beyond the approved cap.
    function test_perRootClaimCap_bounds_total_payout() public {
        vm.prank(admin); // admin holds OPERATION_TIMELOCK in TestSetup
        cumulativeMerkleRewardsDistributorInstance.setMaxClaimablePerRoot(address(eETHInstance), 150 ether);

        setMerkleRoot(address(eETHInstance));

        // first claim (100) is under the cap
        cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
        assertEq(cumulativeMerkleRewardsDistributorInstance.claimedPerRoot(address(eETHInstance), merkleRoot), 100 ether);

        // second claim (200) would push the root's cumulative payout to 300 > 150 → revert
        vm.expectRevert(CumulativeMerkleRewardsDistributor.RootClaimCapExceeded.selector);
        cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[1], 200 ether, merkleRoot, proofs[1]);
    }

    function test_perRootClaimCap_zero_is_uncapped() public {
        // default cap of 0 preserves existing behavior — all claims succeed
        setMerkleRoot(address(eETHInstance));
        cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
        cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[3], 400 ether, merkleRoot, proofs[3]);
        assertEq(eETHInstance.balanceOf(accounts[3]), 400 ether);
    }
}
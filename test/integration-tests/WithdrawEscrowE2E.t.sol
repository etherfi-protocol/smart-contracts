// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "../TestSetup.sol";
import "../../src/PriorityWithdrawalQueue.sol";
import "../../src/interfaces/IPriorityWithdrawalQueue.sol";

/// @notice End-to-end lifecycle tests for the ETH-escrow withdrawal flows.
///
/// Both tests use `initializeRealisticFork` (mainnet state) and upgrade LP + NFT
/// in-place — matching the pattern in PriorityWithdrawalQueue.t.sol setUp.
///
/// TVL invariant tracked throughout:
///   totalValueInLp + totalValueOutOfLp == getTotalPooledEther (constant at lock time)
///   eETH.totalShares decreases only at claim (burn), not at request or finalize.
///
/// Stack-too-deep mitigation: each test step is extracted into its own internal
/// function so that the Solidity stack frame stays small.
contract WithdrawEscrowE2ETest is TestSetup {

    // ── Snapshot structs ─────────────────────────────────────────────────────

    struct LpSnap {
        uint128 inLp;
        uint128 outLp;
        uint256 rawEth;
        uint256 totalPooled;
    }

    struct NftSnap {
        uint256 rawEth;
        uint256 eEthBal;
    }

    struct QueueSnap {
        uint256 rawEth;
        uint256 eEthBal;
        uint128 locked;
    }

    // ── Role constants ───────────────────────────────────────────────────────
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE =
        keccak256("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE =
        keccak256("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE =
        keccak256("PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE");
    bytes32 public constant IMPLICIT_FEE_CLAIMER_ROLE =
        keccak256("IMPLICIT_FEE_CLAIMER_ROLE");
    bytes32 public constant WITHDRAW_REQUEST_NFT_ADMIN_ROLE =
        keccak256("WITHDRAW_REQUEST_NFT_ADMIN_ROLE");

    PriorityWithdrawalQueue public pQueue;
    address public queueRequestManager;
    address public vipUser;

    // ── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        // Clear any mainnet contract code at TestSetup deterministic addresses so
        // _safeMint doesn't invoke an onERC721Received hook on a live mainnet contract.
        vm.etch(bob, bytes(""));
        vm.etch(alice, bytes(""));

        queueRequestManager = makeAddr("queueRequestManager");
        vipUser = makeAddr("vipUser");

        _deployAndWirePQueue();
        _upgradeWithdrawRequestNFT();

        vm.startPrank(owner);
        if (!liquidityPoolInstance.escrowMigrationCompleted()) {
            liquidityPoolInstance.initializeOnUpgradeV2();
        }
        _grantRoles();
        vm.stopPrank();

        if (withdrawRequestNFTInstance.paused()) {
            vm.prank(alice);
            withdrawRequestNFTInstance.unPauseContract();
        }

        vm.prank(alice);
        pQueue.addToWhitelist(vipUser);

        vm.deal(vipUser, 200 ether);
        vm.prank(vipUser);
        liquidityPoolInstance.deposit{value: 100 ether}();
    }

    function _deployAndWirePQueue() internal {
        vm.startPrank(owner);
        PriorityWithdrawalQueue impl = new PriorityWithdrawalQueue(
            address(liquidityPoolInstance),
            address(eETHInstance),
            address(weEthInstance),
            address(roleRegistryInstance),
            treasuryInstance,
            1 hours
        );
        UUPSProxy proxy = new UUPSProxy(
            address(impl),
            abi.encodeWithSelector(PriorityWithdrawalQueue.initialize.selector)
        );
        pQueue = PriorityWithdrawalQueue(payable(address(proxy)));
        liquidityPoolInstance.upgradeTo(address(new LiquidityPool(address(pQueue), 0)));
        vm.stopPrank();
    }

    function _upgradeWithdrawRequestNFT() internal {
        address wrnOwner = withdrawRequestNFTInstance.owner();
        vm.prank(wrnOwner);
        withdrawRequestNFTInstance.upgradeTo(
            address(new WithdrawRequestNFT(0x2f5301a3D59388c509C65f8698f521377D41Fd0F))
        );
    }

    function _grantRoles() internal {
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE, alice);
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, alice);
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE, queueRequestManager);
        roleRegistryInstance.grantRole(IMPLICIT_FEE_CLAIMER_ROLE, alice);
        roleRegistryInstance.grantRole(WITHDRAW_REQUEST_NFT_ADMIN_ROLE, alice);
        roleRegistryInstance.grantRole(liquidityPoolInstance.LIQUIDITY_POOL_ADMIN_ROLE(), owner);
        // WithdrawRequestNFT.unPauseContract requires PROTOCOL_UNPAUSER on the caller
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), alice);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), alice);
    }

    // ── Snapshot helpers ─────────────────────────────────────────────────────

    function _snapLp() internal view returns (LpSnap memory s) {
        s.inLp        = liquidityPoolInstance.totalValueInLp();
        s.outLp       = liquidityPoolInstance.totalValueOutOfLp();
        s.rawEth      = address(liquidityPoolInstance).balance;
        s.totalPooled = liquidityPoolInstance.getTotalPooledEther();
    }

    function _snapNft() internal view returns (NftSnap memory s) {
        s.rawEth  = address(withdrawRequestNFTInstance).balance;
        s.eEthBal = eETHInstance.balanceOf(address(withdrawRequestNFTInstance));
    }

    function _snapQueue() internal view returns (QueueSnap memory s) {
        s.rawEth  = address(pQueue).balance;
        s.eEthBal = eETHInstance.balanceOf(address(pQueue));
        s.locked  = pQueue.ethAmountLockedForPriorityWithdrawal();
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  TEST 1: WithdrawRequestNFT full lifecycle
    //  deposit → requestWithdraw → finalizeRequests + addEthAmountLockedForWithdrawal
    //         → claimWithdraw
    // ══════════════════════════════════════════════════════════════════════════

    function test_e2e_withdrawRequestNFT_lifecycle() public {
        uint96 depositAmt  = 100 ether;
        uint96 withdrawAmt = 5 ether;

        LpSnap memory baseLp        = _snapLp();
        uint256 baseTotalShares     = eETHInstance.totalShares();
        uint128 baseLocked          = liquidityPoolInstance.ethAmountLockedForWithdrawal();

        uint256 reqId = _nft_step1_deposit(bob, depositAmt, baseLp, baseTotalShares);
        uint256 sharesForDeposit = eETHInstance.totalShares() - baseTotalShares;

        reqId = _nft_step2_request(bob, withdrawAmt, reqId);
        _nft_step3_finalize(bob, withdrawAmt, reqId);
        uint256 expectedSharesBurned = liquidityPoolInstance.sharesForWithdrawalAmount(withdrawAmt);
        _nft_step4_claim(bob, withdrawAmt, reqId);

        // ── FINAL: Net protocol invariants ───────────────────────────────────
        assertApproxEqAbs(eETHInstance.balanceOf(bob), depositAmt - withdrawAmt, 2,
            "final: user residual eETH");
        // share-rate rounding artifact: claimable ETH may be 1 wei less than raw withdrawAmt
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(),
            baseLp.totalPooled + depositAmt - withdrawAmt, 1,
            "final: net getTotalPooledEther");
        // Allow 2 wei for share-rate rounding on the deposit→share round-trip
        assertApproxEqAbs(
            eETHInstance.totalShares(),
            baseTotalShares + sharesForDeposit - expectedSharesBurned,
            2,
            "final: net totalShares (2-wei tolerance)");
        // share-rate rounding artifact: 1-wei remainder from share math stays in locked counter
        assertApproxEqAbs(liquidityPoolInstance.ethAmountLockedForWithdrawal(), baseLocked, 1,
            "final: ethAmountLockedForWithdrawal back to baseline");
    }

    function _nft_step1_deposit(
        address user,
        uint96 depositAmt,
        LpSnap memory baseLp,
        uint256 baseTotalShares
    ) internal returns (uint256 reqId) {
        // === STEP 1: User deposits ETH and receives eETH ===
        vm.deal(user, depositAmt + 1 ether);
        vm.prank(user);
        liquidityPoolInstance.deposit{value: depositAmt}();

        // Allow 1 wei: deposit→share→eETH round-trip rounding at current mainnet share rate
        assertApproxEqAbs(eETHInstance.balanceOf(user), depositAmt, 1,
            "step1: user eETH after deposit");
        assertEq(liquidityPoolInstance.getTotalPooledEther(),
            baseLp.totalPooled + depositAmt,
            "step1: getTotalPooledEther after deposit");
        assertEq(liquidityPoolInstance.totalValueInLp(),
            baseLp.inLp + uint128(depositAmt),
            "step1: totalValueInLp after deposit");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), baseLp.outLp,
            "step1: totalValueOutOfLp unchanged after deposit");
        assertGt(eETHInstance.totalShares(), baseTotalShares,
            "step1: totalShares increased by deposit");
        return 0; // reqId not yet known
    }

    function _nft_step2_request(
        address user,
        uint96 withdrawAmt,
        uint256 /*unused*/
    ) internal returns (uint256 reqId) {
        // === STEP 2: User requests withdrawal ===
        LpSnap  memory preLp  = _snapLp();
        NftSnap memory preNft = _snapNft();
        uint256 preTotalShares   = eETHInstance.totalShares();
        uint256 userEEthPre      = eETHInstance.balanceOf(user);
        uint256 sharesAtRequest  = liquidityPoolInstance.sharesForAmount(withdrawAmt);

        vm.startPrank(user);
        eETHInstance.approve(address(liquidityPoolInstance), withdrawAmt);
        reqId = liquidityPoolInstance.requestWithdraw(user, withdrawAmt);
        vm.stopPrank();

        // eETH transferred user → NFT (not burned); no LP accounting change
        // share-rate rounding artifact: eETH.balanceOf uses shares*TVL/totalShares which can differ by 1 wei
        assertApproxEqAbs(eETHInstance.balanceOf(user), userEEthPre - withdrawAmt, 1,
            "step2: user eETH after request");
        assertApproxEqAbs(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)),
            preNft.eEthBal + withdrawAmt, 1,
            "step2: NFT eETH after request");
        assertEq(eETHInstance.totalShares(), preTotalShares,
            "step2: totalShares unchanged at request");
        assertEq(liquidityPoolInstance.totalValueInLp(), preLp.inLp,
            "step2: totalValueInLp unchanged at request");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), preLp.outLp,
            "step2: totalValueOutOfLp unchanged at request");
        assertEq(address(liquidityPoolInstance).balance, preLp.rawEth,
            "step2: LP raw ETH unchanged at request");
        assertEq(address(withdrawRequestNFTInstance).balance, preNft.rawEth,
            "step2: NFT raw ETH unchanged at request");
        assertEq(withdrawRequestNFTInstance.ownerOf(reqId), user,
            "step2: NFT minted to user");
        {
            IWithdrawRequestNFT.WithdrawRequest memory r =
                withdrawRequestNFTInstance.getRequest(reqId);
            assertEq(r.amountOfEEth, withdrawAmt, "step2: request amountOfEEth");
            // Allow 1 wei: deposit→share round-trip rounding
            assertApproxEqAbs(r.shareOfEEth, sharesAtRequest, 1,
                "step2: request shareOfEEth");
            assertTrue(r.isValid, "step2: request isValid");
        }
    }

    function _nft_step3_finalize(address /*user*/, uint96 withdrawAmt, uint256 reqId) internal {
        // === STEP 3: Admin finalizes the request and locks ETH ===
        LpSnap  memory preLp     = _snapLp();
        NftSnap memory preNft    = _snapNft();
        uint256 preTotalShares   = eETHInstance.totalShares();
        uint128 preLocked        = liquidityPoolInstance.ethAmountLockedForWithdrawal();

        vm.prank(alice);
        withdrawRequestNFTInstance.finalizeRequests(reqId);

        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(withdrawAmt));

        // LP InLp↓ OutOfLp↑ (ETH moved LP→NFT; TVL + shares unchanged)
        assertEq(liquidityPoolInstance.totalValueInLp(),
            preLp.inLp - uint128(withdrawAmt),
            "step3: totalValueInLp after finalize");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(),
            preLp.outLp + uint128(withdrawAmt),
            "step3: totalValueOutOfLp after finalize");
        assertEq(address(liquidityPoolInstance).balance, preLp.rawEth - withdrawAmt,
            "step3: LP raw ETH after finalize");
        assertEq(address(withdrawRequestNFTInstance).balance, preNft.rawEth + withdrawAmt,
            "step3: NFT raw ETH after finalize");
        assertEq(eETHInstance.totalShares(), preTotalShares,
            "step3: totalShares unchanged at finalize");
        assertEq(liquidityPoolInstance.getTotalPooledEther(), preLp.totalPooled,
            "step3: getTotalPooledEther unchanged at finalize");
        assertEq(liquidityPoolInstance.ethAmountLockedForWithdrawal(),
            preLocked + uint128(withdrawAmt),
            "step3: ethAmountLockedForWithdrawal after finalize");
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), reqId,
            "step3: lastFinalizedRequestId == reqId");
    }

    function _nft_step4_claim(address user, uint96 withdrawAmt, uint256 reqId) internal {
        // === STEP 4: User claims ===
        LpSnap  memory preLp   = _snapLp();
        NftSnap memory preNft  = _snapNft();
        uint256 preTotalShares = eETHInstance.totalShares();
        uint128 preLocked      = liquidityPoolInstance.ethAmountLockedForWithdrawal();
        uint256 userEthPre     = user.balance;

        // Capture the actual claimable amount before the call.
        // getClaimableAmount returns min(amountOfEEth, amountForShare(shareOfEEth)) - fee,
        // which can be 1 wei less than withdrawAmt due to share-rate rounding.
        uint256 claimable = withdrawRequestNFTInstance.getClaimableAmount(reqId);
        uint256 expectedSharesBurned =
            liquidityPoolInstance.sharesForWithdrawalAmount(claimable);

        vm.prank(user);
        withdrawRequestNFTInstance.claimWithdraw(reqId);

        // User received ETH from NFT's balance; LP raw ETH unchanged (segregated path)
        // share-rate rounding artifact: claimable may be 1 wei less than raw withdrawAmt
        assertApproxEqAbs(user.balance, userEthPre + withdrawAmt, 1,
            "step4: user raw ETH after claim");
        assertApproxEqAbs(address(withdrawRequestNFTInstance).balance, preNft.rawEth - withdrawAmt, 1,
            "step4: NFT raw ETH after claim");
        assertEq(address(liquidityPoolInstance).balance, preLp.rawEth,
            "step4: LP raw ETH unchanged at claim");
        assertEq(liquidityPoolInstance.totalValueInLp(), preLp.inLp,
            "step4: totalValueInLp unchanged at claim");
        // totalValueOutOfLp decrements by claimable (the actual ETH paid), not raw withdrawAmt
        assertApproxEqAbs(liquidityPoolInstance.totalValueOutOfLp(),
            preLp.outLp - uint128(withdrawAmt), 1,
            "step4: totalValueOutOfLp after claim");
        assertEq(eETHInstance.totalShares(),
            preTotalShares - expectedSharesBurned,
            "step4: totalShares after claim");
        // Allow 2 wei: sharesForWithdrawalAmount→balanceOf round-trip rounding
        assertApproxEqAbs(
            eETHInstance.balanceOf(address(withdrawRequestNFTInstance)),
            preNft.eEthBal - withdrawAmt,
            2,
            "step4: NFT eETH after claim (2-wei tolerance for share-rate rounding)"); // share-rate rounding artifact
        // ethAmountLockedForWithdrawal decrements by claimable (LP.withdraw path)
        assertApproxEqAbs(liquidityPoolInstance.ethAmountLockedForWithdrawal(),
            preLocked - uint128(withdrawAmt), 1,
            "step4: ethAmountLockedForWithdrawal after claim");
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(),
            preLp.totalPooled - withdrawAmt, 1,
            "step4: getTotalPooledEther after claim");
        // NFT burned — ownerOf must revert
        vm.expectRevert();
        withdrawRequestNFTInstance.ownerOf(reqId);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  TEST 2A: PriorityWithdrawalQueue — deposit → request → fulfill → claim
    // ══════════════════════════════════════════════════════════════════════════

    function test_e2e_priorityQueue_fulfillThenClaim() public {
        uint96 depositAmt  = 20 ether;
        uint96 withdrawAmt = 10 ether;

        LpSnap memory baseLp      = _snapLp();
        uint256 baseTotalShares   = eETHInstance.totalShares();

        _pq_step1_deposit(vipUser, depositAmt, baseLp, baseTotalShares);
        uint256 sharesForDeposit = eETHInstance.totalShares() - baseTotalShares;

        IPriorityWithdrawalQueue.WithdrawRequest memory req =
            _pq_step2_request(vipUser, withdrawAmt);

        _pq_step3_fulfill(withdrawAmt, req);
        _pq_step4_claim(vipUser, withdrawAmt, req);

        // ── FINAL: Net protocol invariants ───────────────────────────────────
        // getTotalPooledEther decreased by amountWithFee (what the user actually received),
        // which is amountForShare(shareAmt) — 1 wei less than raw withdrawAmt due to rounding.
        assertApproxEqAbs(
            liquidityPoolInstance.getTotalPooledEther(),
            baseLp.totalPooled + depositAmt - withdrawAmt,
            2,
            "final: net getTotalPooledEther (2-wei tolerance for share-rate rounding)");
        assertLt(eETHInstance.totalShares(),
            baseTotalShares + sharesForDeposit,
            "final: totalShares decreased by burned shares");
    }

    function _pq_step1_deposit(
        address user,
        uint96 depositAmt,
        LpSnap memory baseLp,
        uint256 baseTotalShares
    ) internal {
        // === STEP 1: User deposits ===
        vm.deal(user, depositAmt + user.balance);
        vm.prank(user);
        liquidityPoolInstance.deposit{value: depositAmt}();

        assertEq(liquidityPoolInstance.getTotalPooledEther(),
            baseLp.totalPooled + depositAmt,
            "step1: getTotalPooledEther after deposit");
        assertEq(liquidityPoolInstance.totalValueInLp(),
            baseLp.inLp + uint128(depositAmt),
            "step1: totalValueInLp after deposit");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), baseLp.outLp,
            "step1: totalValueOutOfLp unchanged after deposit");
        assertGt(eETHInstance.totalShares(), baseTotalShares,
            "step1: totalShares increased by deposit");
    }

    function _pq_step2_request(
        address user,
        uint96 withdrawAmt
    ) internal returns (IPriorityWithdrawalQueue.WithdrawRequest memory req) {
        // === STEP 2: User requests withdrawal via priority queue ===
        LpSnap    memory preLp      = _snapLp();
        QueueSnap memory preQ       = _snapQueue();
        uint256   preTotalShares    = eETHInstance.totalShares();
        uint256   userEEthPre       = eETHInstance.balanceOf(user);
        uint32    nonceBefore       = pQueue.nonce();
        uint32    requestTs         = uint32(block.timestamp);
        uint96    shareAmt          = uint96(liquidityPoolInstance.sharesForAmount(withdrawAmt));
        // amountWithFee must equal amountForShare(shareAmt) to pass the claimWithdraw
        // validity check: the queue requires amountForShare(shareOfEEth) >= amountWithFee.
        // Using raw withdrawAmt as amountWithFee fails by 1 wei due to share-rate rounding.
        uint96    amountWithFee     = uint96(liquidityPoolInstance.amountForShare(shareAmt));

        vm.startPrank(user);
        eETHInstance.approve(address(pQueue), withdrawAmt);
        bytes32 reqId = pQueue.requestWithdraw(withdrawAmt, amountWithFee);
        vm.stopPrank();

        req = IPriorityWithdrawalQueue.WithdrawRequest({
            user: user,
            amountOfEEth: withdrawAmt,
            shareOfEEth: shareAmt,
            amountWithFee: amountWithFee,
            nonce: nonceBefore,
            creationTime: requestTs
        });

        // eETH transferred user → queue (not burned); LP accounting unchanged at request
        assertApproxEqAbs(eETHInstance.balanceOf(user),
            userEEthPre - withdrawAmt, 1,
            "step2: user eETH after request");
        assertApproxEqAbs(eETHInstance.balanceOf(address(pQueue)),
            preQ.eEthBal + withdrawAmt, 1,
            "step2: queue eETH after request");
        assertEq(eETHInstance.totalShares(), preTotalShares,
            "step2: totalShares unchanged at request");
        assertEq(liquidityPoolInstance.totalValueInLp(), preLp.inLp,
            "step2: totalValueInLp unchanged at request");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), preLp.outLp,
            "step2: totalValueOutOfLp unchanged at request");
        // Queue counter does NOT change at request — only at fulfill
        assertEq(pQueue.ethAmountLockedForPriorityWithdrawal(), preQ.locked,
            "step2: ethAmountLockedForPriorityWithdrawal unchanged at request");
        assertTrue(pQueue.requestExists(reqId), "step2: request exists");
    }

    function _pq_step3_fulfill(
        uint96 withdrawAmt,
        IPriorityWithdrawalQueue.WithdrawRequest memory req
    ) internal {
        // === STEP 3: Request matures; request manager fulfills ===
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);

        LpSnap    memory preLp   = _snapLp();
        QueueSnap memory preQ    = _snapQueue();
        uint256   preTotalShares = eETHInstance.totalShares();

        IPriorityWithdrawalQueue.WithdrawRequest[] memory batch =
            new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        batch[0] = req;
        vm.prank(queueRequestManager);
        pQueue.fulfillRequests(batch);

        bytes32 reqId = pQueue.getRequestId(req);

        // LP InLp↓ OutOfLp↑; ETH moved LP→queue; TVL + shares unchanged
        assertEq(liquidityPoolInstance.totalValueInLp(),
            preLp.inLp - uint128(withdrawAmt),
            "step3: totalValueInLp after fulfill");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(),
            preLp.outLp + uint128(withdrawAmt),
            "step3: totalValueOutOfLp after fulfill");
        assertEq(address(pQueue).balance, preQ.rawEth + withdrawAmt,
            "step3: queue raw ETH after fulfill");
        assertEq(address(liquidityPoolInstance).balance, preLp.rawEth - withdrawAmt,
            "step3: LP raw ETH after fulfill");
        assertEq(eETHInstance.totalShares(), preTotalShares,
            "step3: totalShares unchanged at fulfill");
        assertEq(liquidityPoolInstance.getTotalPooledEther(), preLp.totalPooled,
            "step3: getTotalPooledEther unchanged at fulfill");
        assertEq(pQueue.ethAmountLockedForPriorityWithdrawal(),
            preQ.locked + uint128(withdrawAmt),
            "step3: ethAmountLockedForPriorityWithdrawal after fulfill");
        assertTrue(pQueue.isFinalized(reqId), "step3: request is finalized");
    }

    function _pq_step4_claim(
        address user,
        uint96 /*withdrawAmt*/,
        IPriorityWithdrawalQueue.WithdrawRequest memory req
    ) internal {
        // === STEP 4: User claims from queue ===
        LpSnap    memory preLp   = _snapLp();
        QueueSnap memory preQ    = _snapQueue();
        uint256   preTotalShares = eETHInstance.totalShares();
        uint256   userEthPre     = user.balance;
        bytes32   reqId          = pQueue.getRequestId(req);
        // The actual ETH the user receives is req.amountWithFee (= amountForShare(shareOfEEth)),
        // which is 1 wei less than raw withdrawAmt due to share-rate rounding.
        uint96    expectedEth    = req.amountWithFee;

        vm.prank(user);
        pQueue.claimWithdraw(req);

        // User received ETH from queue balance; LP raw ETH unchanged (segregated path)
        assertApproxEqAbs(user.balance, userEthPre + expectedEth, 2,
            "step4: user ETH after claim (2-wei tolerance)");
        assertLt(address(pQueue).balance, preQ.rawEth,
            "step4: queue raw ETH decreased after claim");
        assertEq(address(liquidityPoolInstance).balance, preLp.rawEth,
            "step4: LP raw ETH unchanged at claim");
        assertEq(liquidityPoolInstance.totalValueInLp(), preLp.inLp,
            "step4: totalValueInLp unchanged at claim");
        assertLt(liquidityPoolInstance.totalValueOutOfLp(), preLp.outLp,
            "step4: totalValueOutOfLp decreased after claim");
        assertLt(eETHInstance.totalShares(), preTotalShares,
            "step4: totalShares decreased after claim");
        assertLt(eETHInstance.balanceOf(address(pQueue)), preQ.eEthBal,
            "step4: queue eETH decreased after claim");
        assertLt(pQueue.ethAmountLockedForPriorityWithdrawal(), preQ.locked,
            "step4: ethAmountLockedForPriorityWithdrawal decreased after claim");
        assertLt(liquidityPoolInstance.getTotalPooledEther(), preLp.totalPooled,
            "step4: getTotalPooledEther decreased after claim");
        assertFalse(pQueue.requestExists(reqId), "step4: request removed after claim");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  TEST 2B: PriorityWithdrawalQueue — deposit → request → fulfill → cancel
    //  Cancelling a *finalized* (fulfilled) request returns ETH from queue to LP.
    // ══════════════════════════════════════════════════════════════════════════

    function test_e2e_priorityQueue_fulfillThenCancel() public {
        uint96 depositAmt  = 20 ether;
        uint96 withdrawAmt = 8 ether;

        LpSnap memory baseLp = _snapLp();

        _pq_step1_deposit(vipUser, depositAmt, baseLp, eETHInstance.totalShares());

        IPriorityWithdrawalQueue.WithdrawRequest memory req =
            _pq_step2_request(vipUser, withdrawAmt);

        _pq_step3_fulfill(withdrawAmt, req);

        _pq_cancel_step(vipUser, withdrawAmt, req);
    }

    function _pq_cancel_step(
        address user,
        uint96 withdrawAmt,
        IPriorityWithdrawalQueue.WithdrawRequest memory req
    ) internal {
        // === CANCEL: User cancels the finalized request ===
        LpSnap    memory preLp       = _snapLp();
        QueueSnap memory preQ        = _snapQueue();
        uint256   preTotalShares     = eETHInstance.totalShares();
        uint256   userEEthPre        = eETHInstance.balanceOf(user);
        bytes32   reqId              = pQueue.getRequestId(req);

        assertTrue(pQueue.isFinalized(reqId), "cancel-pre: request is finalized");

        vm.prank(user);
        pQueue.cancelWithdraw(req);

        // Queue ETH → LP
        assertEq(address(pQueue).balance, preQ.rawEth - withdrawAmt,
            "cancel: queue raw ETH decreased");
        assertEq(address(liquidityPoolInstance).balance, preLp.rawEth + withdrawAmt,
            "cancel: LP raw ETH increased");
        // LP accounting inverted: InLp↑ OutOfLp↓
        assertEq(liquidityPoolInstance.totalValueInLp(),
            preLp.inLp + uint128(withdrawAmt),
            "cancel: totalValueInLp increased");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(),
            preLp.outLp - uint128(withdrawAmt),
            "cancel: totalValueOutOfLp decreased");
        // Queue locked counter decremented
        assertEq(pQueue.ethAmountLockedForPriorityWithdrawal(),
            preQ.locked - uint128(withdrawAmt),
            "cancel: ethAmountLockedForPriorityWithdrawal decreased");
        // Cancel is a share-transfer back — NOT a burn; totalShares unchanged
        assertEq(eETHInstance.totalShares(), preTotalShares,
            "cancel: totalShares unchanged (transfer, not burn)");
        // getTotalPooledEther unchanged (no ETH left the protocol)
        assertEq(liquidityPoolInstance.getTotalPooledEther(), preLp.totalPooled,
            "cancel: getTotalPooledEther unchanged");
        // User receives back eETH equivalent of their shares
        // Allow 2 wei: deposit→share→amountForShare round-trip rounding
        uint256 expectedEEthBack = liquidityPoolInstance.amountForShare(req.shareOfEEth);
        assertApproxEqAbs(
            eETHInstance.balanceOf(user),
            userEEthPre + expectedEEthBack,
            2,
            "cancel: user eETH after cancel (2-wei tolerance)");
        assertApproxEqAbs(
            eETHInstance.balanceOf(address(pQueue)),
            preQ.eEthBal - expectedEEthBack,
            2,
            "cancel: queue eETH after cancel (2-wei tolerance)");
        // Request gone
        assertFalse(pQueue.requestExists(reqId), "cancel: request removed");
        assertFalse(pQueue.isFinalized(reqId),   "cancel: no longer finalized");
    }
}

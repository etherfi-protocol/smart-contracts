// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@tests/TestSetup.sol";
import "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";

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

    // ── Role constants (after role consolidation) ────────────────────────────
    // PWQ admin → OPERATION_TIMELOCK_ROLE; PWQ whitelist manager → HOUSEKEEPING_OPERATIONS_ROLE;
    // PWQ request manager → ORACLE_OPERATIONS_ROLE; IMPLICIT_FEE_CLAIMER → HOUSEKEEPING_OPERATIONS_ROLE;
    // WITHDRAW_REQUEST_NFT_ADMIN → OPERATION_TIMELOCK_ROLE.
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE =
        keccak256("OPERATION_TIMELOCK_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE =
        keccak256("HOUSEKEEPING_OPERATIONS_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE =
        keccak256("ORACLE_OPERATIONS_ROLE");
    bytes32 public constant IMPLICIT_FEE_CLAIMER_ROLE =
        keccak256("HOUSEKEEPING_OPERATIONS_ROLE");
    bytes32 public constant WITHDRAW_REQUEST_NFT_ADMIN_ROLE =
        keccak256("OPERATION_TIMELOCK_ROLE");

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
        liquidityPoolInstance.setMaxWithdrawAmount(1000 ether);
        liquidityPoolInstance.setMinWithdrawAmount(0.001 ether);
        _grantRoles();
        vm.stopPrank();

        if (withdrawRequestNFTInstance.paused()) {
            vm.prank(alice);
            withdrawRequestNFTInstance.unpause();
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
            address(blacklisterInstance),
            address(roleRegistryInstance),
            treasuryInstance,
            1 hours
        );
        UUPSProxy proxy = new UUPSProxy(
            address(impl),
            abi.encodeWithSelector(PriorityWithdrawalQueue.initialize.selector)
        );
        pQueue = PriorityWithdrawalQueue(payable(address(proxy)));
        liquidityPoolInstance.upgradeTo(address(new LiquidityPool(
            ILiquidityPool.ConstructorAddresses({
                stakingManager: address(stakingManagerInstance),
                nodesManager: address(managerInstance),
                eETH: address(eETHInstance),
                withdrawRequestNFT: address(withdrawRequestNFTInstance),
                liquifier: address(liquifierInstance),
                etherFiRedemptionManager: address(etherFiRedemptionManagerInstance),
                roleRegistry: address(roleRegistryInstance),
                priorityWithdrawalQueue: address(pQueue),
                blacklister: address(blacklisterInstance),
                etherFiAdminContract: address(etherFiAdminInstance),
                membershipManager: address(membershipManagerInstance)
            })
        )));
        vm.stopPrank();
    }

    function _upgradeWithdrawRequestNFT() internal {
        address wrnOwner = roleRegistryInstance.owner();
        // Deploy the impl BEFORE pranking — the inlined `new` is a CREATE that
        // would otherwise consume the single-shot vm.prank (OnlyUpgradeTimelock).
        address newWrnImpl = address(new WithdrawRequestNFT(
            0x2f5301a3D59388c509C65f8698f521377D41Fd0F,
            address(eETHInstance),
            address(liquidityPoolInstance),
            address(roleRegistryInstance),
            address(blacklisterInstance)
        , address(etherFiAdminInstance)));
        vm.prank(wrnOwner);
        withdrawRequestNFTInstance.upgradeTo(newWrnImpl);
    }

    function _grantRoles() internal {
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE, alice);
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, alice);
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE, queueRequestManager);
        roleRegistryInstance.grantRole(IMPLICIT_FEE_CLAIMER_ROLE, alice);
        roleRegistryInstance.grantRole(WITHDRAW_REQUEST_NFT_ADMIN_ROLE, alice);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), owner);
        // WithdrawRequestNFT.unPauseContract requires PROTOCOL_UNPAUSER on the caller
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), alice);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), alice);
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
        uint128 baseLocked          = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        uint256 reqId = _nft_step1_deposit(bob, depositAmt, baseLp, baseTotalShares);
        uint256 sharesForDeposit = eETHInstance.totalShares() - baseTotalShares;

        reqId = _nft_step2_request(bob, withdrawAmt, reqId);
        _nft_step3_finalize(bob, withdrawAmt, reqId);
        uint256 expectedSharesBurned = liquidityPoolInstance.sharesForWithdrawalAmount(withdrawAmt);
        _nft_step4_claim(bob, withdrawAmt, reqId);

        // ── FINAL: Net protocol invariants ───────────────────────────────────
        assertApproxEqAbs(eETHInstance.balanceOf(bob), depositAmt - withdrawAmt, 2,
            "final: user residual eETH");
        // share-rate rounding artifact: claimable ETH may be up to 2 wei less than raw withdrawAmt
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(),
            baseLp.totalPooled + depositAmt - withdrawAmt, 2,
            "final: net getTotalPooledEther");
        // Allow 4 wei: deposit→share round-trip drifts ~2 wei AND the frozen-rate share burn
        // (ceil(claimable * 1e18 / frozenRate)) drifts another 1-2 wei vs the live-rate
        // `sharesForWithdrawalAmount(withdrawAmt)` baseline used to compute `expectedSharesBurned`.
        assertApproxEqAbs(
            eETHInstance.totalShares(),
            baseTotalShares + sharesForDeposit - expectedSharesBurned,
            4,
            "final: net totalShares (4-wei tolerance)");
        // share-rate rounding artifact: up to 2-wei remainder from share math stays in locked counter
        assertApproxEqAbs(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), baseLocked, 2,
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
        assertApproxEqAbs(eETHInstance.balanceOf(user), depositAmt, 2,
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
        assertApproxEqAbs(eETHInstance.balanceOf(user), userEEthPre - withdrawAmt, 2,
            "step2: user eETH after request");
        assertApproxEqAbs(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)),
            preNft.eEthBal + withdrawAmt, 2,
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
            assertApproxEqAbs(r.shareOfEEth, sharesAtRequest, 2,
                "step2: request shareOfEEth");
            assertTrue(r.isValid, "step2: request isValid");
        }
    }

    function _nft_step3_finalize(address /*user*/, uint96 withdrawAmt, uint256 reqId) internal {
        // === STEP 3: Admin finalizes the request and locks ETH ===
        LpSnap  memory preLp     = _snapLp();
        NftSnap memory preNft    = _snapNft();
        uint256 preTotalShares   = eETHInstance.totalShares();
        uint128 preLocked        = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        // finalizeRequests is now restricted to msg.sender == etherFiAdmin.
        vm.prank(address(etherFiAdminInstance));
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
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(),
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
        uint128 preLocked      = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();
        uint256 userEthPre     = user.balance;

        // Capture the actual claimable amount before the call.
        // getClaimableAmount returns min(amountOfEEth, amountForShare(shareOfEEth)) - fee,
        // which can be 1 wei less than withdrawAmt due to share-rate rounding.
        uint256 claimable = withdrawRequestNFTInstance.getClaimableAmount(reqId);
        // Share burn at claim is computed against the rate frozen at finalize via
        // ceil(claimable * 1e18 / frozenRate). For pre-upgrade requests the rate is 0
        // and the contract falls back to live `sharesForWithdrawalAmount`.
        uint224 frozenRate = withdrawRequestNFTInstance.frozenRateFor(reqId);
        uint256 expectedSharesBurned = withdrawRequestNFTInstance.getRequest(reqId).shareOfEEth;

        vm.prank(user);
        withdrawRequestNFTInstance.claimWithdraw(reqId);

        // User received ETH from NFT's balance; LP raw ETH unchanged (segregated path)
        // share-rate rounding artifact: claimable may be up to 2 wei less than raw withdrawAmt
        // (deposit→share→amountForShare round-trip can drop 2 wei at the live mainnet share rate)
        assertApproxEqAbs(user.balance, userEthPre + withdrawAmt, 5,
            "step4: user raw ETH after claim");
        assertApproxEqAbs(address(withdrawRequestNFTInstance).balance, preNft.rawEth - withdrawAmt, 5,
            "step4: NFT raw ETH after claim");
        assertApproxEqAbs(address(liquidityPoolInstance).balance, preLp.rawEth, 5,
            "step4: LP raw ETH unchanged at claim");
        // "Unchanged" up to a wei: the claim sweeps any stranded ETH (balance above the
        // amount still locked) back to LP via LP.receive(), which can nudge totalValueInLp
        // by 1 wei of share-rate rounding dust at the live mainnet rate. Mirrors the 5-wei
        // tolerance used by the sibling balance/share assertions above.
        assertApproxEqAbs(liquidityPoolInstance.totalValueInLp(), preLp.inLp, 5,
            "step4: totalValueInLp unchanged at claim");
        // totalValueOutOfLp decrements by request.amountOfEEth (the value credited at
        // fulfill), not by the ETH actually paid. Here that credit == withdrawAmt
        // (step2 asserts request.amountOfEEth == withdrawAmt) and there is no rebase between
        // finalize and claim, so the two coincide. The 5-wei tolerance absorbs the share-rate
        // round-trip drift in withdrawAmt itself. The down-rebase case, where the credit and
        // the paid amount diverge, is pinned at the LP boundary in
        // LiquidityPool.t.sol:test_withdraw_debitsAmountOfEEth_notAmountPaid.
        assertApproxEqAbs(liquidityPoolInstance.totalValueOutOfLp(),
            preLp.outLp - uint128(withdrawAmt), 5,
            "step4: totalValueOutOfLp after claim");
        assertEq(eETHInstance.totalShares(),
            preTotalShares - expectedSharesBurned,
            "step4: totalShares after claim");
        // Allow 2 wei: sharesForWithdrawalAmount→balanceOf round-trip rounding
        assertApproxEqAbs(
            eETHInstance.balanceOf(address(withdrawRequestNFTInstance)),
            preNft.eEthBal - withdrawAmt,
            5,
            "step4: NFT eETH after claim"); // share-rate rounding artifact
        // ethAmountLockedForWithdrawal decrements by claimable (NFT._claimWithdraw path)
        // — share-rate rounding artifact: claimable can be up to 2 wei less than withdrawAmt
        assertApproxEqAbs(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(),
            preLocked - uint128(withdrawAmt), 5,
            "step4: ethAmountLockedForWithdrawal after claim");
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(),
            preLp.totalPooled - withdrawAmt, 5,
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
            userEEthPre - withdrawAmt, 2,
            "step2: user eETH after request");
        assertApproxEqAbs(eETHInstance.balanceOf(address(pQueue)),
            preQ.eEthBal + withdrawAmt, 2,
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

        // User received ETH from queue balance. Stranded ETH (amountOfEEth - amountWithFee) is
        // swept back to LP via LP.receive(), so LP raw ETH may increase by up to that amount.
        assertApproxEqAbs(user.balance, userEthPre + expectedEth, 2,
            "step4: user ETH after claim (2-wei tolerance)");
        assertLt(address(pQueue).balance, preQ.rawEth,
            "step4: queue raw ETH decreased after claim");
        assertGe(address(liquidityPoolInstance).balance, preLp.rawEth,
            "step4: LP raw ETH unchanged or increased by fee return");
        assertGe(liquidityPoolInstance.totalValueInLp(), preLp.inLp,
            "step4: totalValueInLp unchanged or increased by fee return");
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

    // ══════════════════════════════════════════════════════════════════════════
    //  TEST 3: Share-rate freeze on mainnet — WithdrawRequestNFT
    //  Negative rebase after finalize must not reduce the claim. The frozen rate
    //  snapshotted at finalize decouples the claim payout from post-finalize drift.
    // ══════════════════════════════════════════════════════════════════════════

    function test_e2e_nft_freeze_negativeRebaseAfterFinalize_payoutUnchanged() public {
        uint96 depositAmt  = 100 ether;
        uint96 withdrawAmt = 5 ether;

        // Setup: deposit, request, finalize. Snapshot the frozen rate at finalize.
        LpSnap memory baseLp = _snapLp();
        uint256 baseTotalShares = eETHInstance.totalShares();
        _nft_step1_deposit(bob, depositAmt, baseLp, baseTotalShares);
        uint256 reqId = _nft_step2_request(bob, withdrawAmt, 0);
        _nft_step3_finalize(bob, withdrawAmt, reqId);

        // Frozen rate must be captured and match the ceiling formula the contract uses internally.
        uint224 frozenRate = withdrawRequestNFTInstance.frozenRateFor(reqId);
        assertGt(frozenRate, 0, "freeze: snapshot recorded at finalize");

        // Baseline expectation: what the user would receive RIGHT NOW (at the frozen rate).
        uint256 claimableBefore = withdrawRequestNFTInstance.getClaimableAmount(reqId);
        assertGt(claimableBefore, 0, "freeze: claimable > 0 pre-rebase");

        // Negative rebase post-finalize. The frozen rate must shield the claim.
        // Use ~5% of the live TPE so we don't trip `_checkMinAmountForShare`.
        uint256 totalPooled = liquidityPoolInstance.getTotalPooledEther();
        int128 slash = -int128(uint128(totalPooled / 20));
        vm.prank(liquidityPoolInstance.etherFiAdminContract());
        liquidityPoolInstance.rebase(slash, 0);

        uint256 claimableAfter = withdrawRequestNFTInstance.getClaimableAmount(reqId);
        assertEq(claimableAfter, claimableBefore,
            "freeze: getClaimableAmount unaffected by post-finalize negative rebase");

        // Live rate dropped — confirm the freeze is doing real work (i.e. live and frozen disagree now).
        uint256 liveAmountForShares = liquidityPoolInstance.amountForShare(
            withdrawRequestNFTInstance.getRequest(reqId).shareOfEEth
        );
        assertLt(liveAmountForShares, claimableBefore,
            "freeze: sanity - live rate is below the frozen-rate claim after the slash");

        // Actually claim and verify the user gets the frozen amount, not the live one.
        uint256 userEthPre = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(reqId);
        assertEq(bob.balance - userEthPre, claimableBefore,
            "freeze: payout equals frozen-rate claim despite post-finalize slash");
    }

    /// @dev Frozen rate snapshotted at finalize is the ceiling-rounded share rate, capped above
    ///      LP.amountForShare(1e18)'s floor value. Pre-upgrade tokenIds (no snapshot above the
    ///      sentinel) return 0 — i.e. "use live rate", verified by passing `0` as the rate input.
    function test_e2e_nft_freeze_snapshotIsCeilingOfLiveRate() public {
        uint96 depositAmt  = 100 ether;
        uint96 withdrawAmt = 5 ether;

        LpSnap memory baseLp = _snapLp();
        _nft_step1_deposit(bob, depositAmt, baseLp, eETHInstance.totalShares());
        uint256 reqId = _nft_step2_request(bob, withdrawAmt, 0);

        uint256 rateBefore = liquidityPoolInstance.amountForShare(1e18);
        _nft_step3_finalize(bob, withdrawAmt, reqId);

        uint224 frozenRate = withdrawRequestNFTInstance.frozenRateFor(reqId);
        // Ceiling rounding ⇒ frozen rate is ≥ live floor, off by at most 1 wei when the
        // (1e18 * TPE) % TS != 0 (the common case on mainnet).
        assertGe(uint256(frozenRate), rateBefore,
            "freeze: frozen rate >= live floor (ceiling rounding)");
        assertLe(uint256(frozenRate) - rateBefore, 1,
            "freeze: ceiling rounding adds at most 1 wei to the rate");
    }
}

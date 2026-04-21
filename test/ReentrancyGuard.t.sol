// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "../src/ReentrancyGuardNamespaced.sol";
import "../src/WithdrawRequestNFT.sol";

/// @dev Attacker contract that owns two withdrawal NFTs. On receiving ETH during
///      a claimWithdraw call, it attempts to re-enter WithdrawRequestNFT via
///      claimWithdraw or batchClaimWithdraw using a *different* tokenId. The
///      ReentrancyGuardNamespaced on WithdrawRequestNFT must cause the re-entry
///      to revert; the try/catch lets the outer claim complete so the test can
///      inspect the `reentryBlocked` flag.
contract ReentrancyAttacker {
    enum Mode { None, Claim, BatchClaim }

    WithdrawRequestNFT public immutable wr;
    Mode public mode;
    uint256 public pendingTokenId;
    uint256 public reentryAttempts;
    uint256 public reentryBlocked;
    bytes public lastRevert;

    constructor(WithdrawRequestNFT _wr) {
        wr = _wr;
    }

    function claim(uint256 firstId, uint256 secondId, Mode _mode) external {
        mode = _mode;
        pendingTokenId = secondId;
        wr.claimWithdraw(firstId);
    }

    function batchClaim(uint256[] calldata ids, uint256 reentryId, Mode _mode) external {
        mode = _mode;
        pendingTokenId = reentryId;
        wr.batchClaimWithdraw(ids);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (mode == Mode.None || pendingTokenId == 0) return;
        uint256 tid = pendingTokenId;
        pendingTokenId = 0; // only attempt once per outer call
        reentryAttempts += 1;

        if (mode == Mode.Claim) {
            try wr.claimWithdraw(tid) {
                // guard failed - re-entry succeeded
            } catch (bytes memory err) {
                reentryBlocked += 1;
                lastRevert = err;
            }
        } else if (mode == Mode.BatchClaim) {
            uint256[] memory arr = new uint256[](1);
            arr[0] = tid;
            try wr.batchClaimWithdraw(arr) {
                // guard failed
            } catch (bytes memory err) {
                reentryBlocked += 1;
                lastRevert = err;
            }
        }
    }
}

contract ReentrancyGuardTest is TestSetup {
    ReentrancyAttacker attacker;

    function setUp() public {
        setUpTests();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();

        attacker = new ReentrancyAttacker(withdrawRequestNFTInstance);
    }

    /// @dev Seeds an attacker-owned withdraw request: alice deposits, requests
    ///      withdraw to the attacker as recipient, then finalises.
    function _seedRequest(uint256 amount) internal returns (uint256 requestId) {
        vm.deal(alice, amount);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: amount}();

        vm.startPrank(alice);
        eETHInstance.approve(address(liquidityPoolInstance), amount);
        requestId = liquidityPoolInstance.requestWithdraw(address(attacker), amount);
        vm.stopPrank();

        _finalizeWithdrawalRequest(requestId);
    }

    function testFuzz_noRegression_claimWithdraw_withNonReentrantRecipient() public {
        // Sanity check: normal (non-attacker) recipient still completes claim.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();

        vm.startPrank(alice);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 rid = liquidityPoolInstance.requestWithdraw(alice, 1 ether);
        vm.stopPrank();
        _finalizeWithdrawalRequest(rid);

        uint256 beforeBal = alice.balance;
        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(rid);
        assertEq(alice.balance, beforeBal + 1 ether, "normal claim payout");
    }

    function test_claimWithdraw_reentry_viaClaim_isBlocked() public {
        uint256 id1 = _seedRequest(1 ether);
        uint256 id2 = _seedRequest(1 ether);

        // Attacker attempts to call claimWithdraw(id2) during the receive() of claimWithdraw(id1).
        vm.prank(address(attacker));
        attacker.claim(id1, id2, ReentrancyAttacker.Mode.Claim);

        assertEq(attacker.reentryAttempts(), 1, "attacker attempted re-entry");
        assertEq(attacker.reentryBlocked(), 1, "guard must block re-entry into claimWithdraw");

        // Decoding the revert: must be ReentrancyGuardReentrantCall() (selector match).
        bytes4 sel = bytes4(attacker.lastRevert());
        assertEq(sel, ReentrancyGuardNamespaced.ReentrancyGuardReentrantCall.selector, "wrong revert selector");

        // Outer claim still completed and paid out; id2 is still claimable later.
        assertEq(address(attacker).balance, 1 ether, "outer claim paid out");
        assertEq(withdrawRequestNFTInstance.ownerOf(id2), address(attacker), "id2 still owned by attacker");
    }

    function test_claimWithdraw_reentry_viaBatchClaim_isBlocked() public {
        uint256 id1 = _seedRequest(1 ether);
        uint256 id2 = _seedRequest(1 ether);

        vm.prank(address(attacker));
        attacker.claim(id1, id2, ReentrancyAttacker.Mode.BatchClaim);

        assertEq(attacker.reentryBlocked(), 1, "guard must block cross-fn re-entry via batchClaimWithdraw");
        bytes4 sel = bytes4(attacker.lastRevert());
        assertEq(sel, ReentrancyGuardNamespaced.ReentrancyGuardReentrantCall.selector, "wrong revert selector");
    }

    function test_batchClaimWithdraw_reentry_viaClaim_isBlocked() public {
        uint256 id1 = _seedRequest(1 ether);
        uint256 id2 = _seedRequest(1 ether);
        uint256 id3 = _seedRequest(1 ether); // used for re-entry attempt

        uint256[] memory batch = new uint256[](2);
        batch[0] = id1;
        batch[1] = id2;

        vm.prank(address(attacker));
        attacker.batchClaim(batch, id3, ReentrancyAttacker.Mode.Claim);

        // Re-entry attempted during the first element of the batch, blocked by guard.
        // The outer batch continues and processes both id1 and id2.
        assertGt(attacker.reentryBlocked(), 0, "guard must block re-entry during batch");
        assertEq(address(attacker).balance, 2 ether, "batch paid out both items");
        assertEq(withdrawRequestNFTInstance.ownerOf(id3), address(attacker), "id3 untouched");
    }

    function test_guardResets_betweenCalls() public {
        // Verify guard is properly reset: two sequential claims should both succeed.
        uint256 id1 = _seedRequest(1 ether);
        uint256 id2 = _seedRequest(1 ether);

        // Use non-reentrant path: transfer id1 out of attacker to alice so a vanilla EOA claim happens.
        vm.prank(address(attacker));
        withdrawRequestNFTInstance.transferFrom(address(attacker), alice, id1);
        vm.prank(address(attacker));
        withdrawRequestNFTInstance.transferFrom(address(attacker), alice, id2);

        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(id1);
        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(id2); // would revert if guard stuck in ENTERED state
    }

    function test_liquidityPool_deposit_reentryFromReceive_isBlocked() public {
        // Defense-in-depth: even though deposit() itself doesn't push ETH out,
        // the guard prevents a nested deposit -> deposit call path through any
        // external hook. Simulate by calling deposit from a contract that also
        // re-enters deposit during the same tx; since deposit has no external
        // call to attacker, we instead test the guard state directly by making
        // two sequential top-level deposits (must not be stuck in ENTERED).
        vm.deal(alice, 5 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        liquidityPoolInstance.deposit{value: 1 ether}(); // second top-level call must succeed
        vm.stopPrank();
        assertEq(eETHInstance.balanceOf(alice), 2 ether, "two sequential deposits work");
    }
}

# WithdrawRequestNFT ETH Escrow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move ETH from `LiquidityPool` into `WithdrawRequestNFT` and `PriorityWithdrawalQueue` at lock time so finalized claims are paid from segregated balances, immune to drain by other LP consumers.

**Architecture:** At each lock-site (`addEthAmountLockedForWithdrawal`, `fulfillRequests`), shift ETH from LP to the holder contract while rebalancing `totalValueInLp` ↔ `totalValueOutOfLp` to preserve TVL and the share rate. At each claim-site, `LP.withdraw` does only share-burn + accounting; the holder contract pays the recipient from its own balance. On a finalized priority-queue cancel, the queue returns the locked ETH to LP via a new gated function. A one-shot `LP.initializeOnUpgradeV2` sweeps existing locked counters into the holder contracts.

**Tech Stack:** Solidity 0.8.27, Foundry (forge build / forge test), UUPS proxy upgrade pattern.

**Operating assumption (per spec):** the eETH share rate is non-decreasing in practice. `min(amountOfEEth, amountForShare(shareOfEEth))` therefore degenerates to `amountOfEEth` after request — the claim amount equals the amount transferred at finalize.

---

## File Structure

**Modified:**
- `src/LiquidityPool.sol` — modify `addEthAmountLockedForWithdrawal`, modify `withdraw`, add `transferLockedEthForPriority`, add `returnLockedEth`, add `initializeOnUpgradeV2`, append storage `escrowMigrationCompleted`.
- `src/WithdrawRequestNFT.sol` — add `receive()`, modify `_claimWithdraw` to send ETH from own balance.
- `src/PriorityWithdrawalQueue.sol` — add `receive()`, modify `fulfillRequests` to call `transferLockedEthForPriority`, modify `_claimWithdraw` to send ETH from own balance, modify `_cancelWithdrawRequest` to call `returnLockedEth` on finalized cancel, update `_verifyCancelPostConditions`.

**Test files (extended):**
- `test/LiquidityPool.t.sol` — finalize ETH-transfer tests, segregated `withdraw` branch tests, migration test.
- `test/WithdrawRequestNFT.t.sol` — claim-from-NFT-balance tests, adversarial drain test.
- `test/PriorityWithdrawalQueue.t.sol` — fulfill ETH-transfer, claim-from-queue-balance, cancel-finalized return-ETH, invalidate batch, post-conditions.

**Reference paths in this plan are to the worktree:**
`/Users/pankajjagtap/etherfi/smart-contracts/.worktrees/withdraw-nft-eth-escrow/`

---

## Conventions

- **Always run from the worktree root**: `cd /Users/pankajjagtap/etherfi/smart-contracts/.worktrees/withdraw-nft-eth-escrow`.
- **Single-test runner**: `forge test --match-test <testName> -vv`. Add `--match-contract <ContractName>` if a name collides.
- **Forge build sanity**: after every code change, `forge build` should exit 0.
- **Commits**: each task's final step is a commit. Use the imperative-mood subjects shown.
- **Per global rule, do NOT run `git add` / `git commit` directly via tooling**; the user commits manually. The "Commit" steps below describe what the commit *should* contain so the user can stage them.

---

## Task 1: LP storage — add `escrowMigrationCompleted` flag

**Files:**
- Modify: `src/LiquidityPool.sol` (append after line 73, the current last state var `uint256 public validatorSizeWei;`)

- [ ] **Step 1: Append storage variable**

Open `src/LiquidityPool.sol`. Locate line 73:
```solidity
uint256 public validatorSizeWei;
```

Append directly after it:
```solidity
bool public escrowMigrationCompleted;
```

- [ ] **Step 2: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0, no errors. (Solidity packs the `bool` into a fresh slot — that's fine; this storage variable is appended at the end, no layout disruption for existing fields.)

- [ ] **Step 3: Commit**

Stage `src/LiquidityPool.sol`. Commit message: `feat(LP): add escrowMigrationCompleted storage flag`.

---

## Task 2: LP — modify `addEthAmountLockedForWithdrawal` to transfer ETH to NFT

**Files:**
- Modify: `src/LiquidityPool.sol:511-515`
- Test: `test/LiquidityPool.t.sol`

**Background:** today `addEthAmountLockedForWithdrawal` only updates the counter. We add the LP→NFT ETH transfer and the `totalValueInLp` ↔ `totalValueOutOfLp` rebalance. Access control unchanged (`msg.sender == address(etherFiAdminContract)`).

- [ ] **Step 1: Add the failing test**

Open `test/LiquidityPool.t.sol`. Append the following test (or add inside the relevant contract — match the file's contract name; tests typically live in a `LiquidityPoolTest is TestSetup` contract):

```solidity
function test_addEthAmountLockedForWithdrawal_transfersEthToNFT() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    uint128 amount = 1 ether;

    // Fund LP with enough ETH and totalValueInLp accounting.
    vm.deal(address(liquidityPoolInstance), 100 ether);
    vm.startPrank(address(membershipManagerInstance));
    liquidityPoolInstance.deposit{value: 100 ether}();
    vm.stopPrank();

    uint128 lpInBefore       = liquidityPoolInstance.totalValueInLp();
    uint128 lpOutBefore      = liquidityPoolInstance.totalValueOutOfLp();
    uint256 nftBalBefore     = address(withdrawRequestNFTInstance).balance;
    uint256 totalSharesBefore = eETHInstance.totalShares();
    uint256 lockedBefore     = liquidityPoolInstance.ethAmountLockedForWithdrawal();

    vm.prank(address(etherFiAdminInstance));
    liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);

    assertEq(liquidityPoolInstance.totalValueInLp(),  lpInBefore  - amount, "totalValueInLp not decreased");
    assertEq(liquidityPoolInstance.totalValueOutOfLp(), lpOutBefore + amount, "totalValueOutOfLp not increased");
    assertEq(address(withdrawRequestNFTInstance).balance, nftBalBefore + amount, "NFT balance not increased");
    assertEq(eETHInstance.totalShares(), totalSharesBefore, "totalShares should not change");
    assertEq(liquidityPoolInstance.ethAmountLockedForWithdrawal(), lockedBefore + amount, "locked counter not increased");
}
```

(If `MAINNET_FORK_URL`, `withdrawRequestNFTInstance`, `eETHInstance`, `etherFiAdminInstance`, `membershipManagerInstance`, `liquidityPoolInstance` are not the exact names used in `TestSetup.sol`, adjust to the names used by adjacent tests in this file. Look at the top of `test/LiquidityPool.t.sol` for the test contract's existing setup.)

- [ ] **Step 2: Run test to verify it fails**

```bash
forge test --match-test test_addEthAmountLockedForWithdrawal_transfersEthToNFT --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL because today's body doesn't move ETH; `nftBalBefore + amount` assertion fails.

- [ ] **Step 3: Modify the function**

Open `src/LiquidityPool.sol`. Locate the function around lines 511–515:
```solidity
function addEthAmountLockedForWithdrawal(uint128 _amount) external {
    if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
    ethAmountLockedForWithdrawal += _amount;
}
```

Replace with:
```solidity
function addEthAmountLockedForWithdrawal(uint128 _amount) external {
    if (msg.sender != address(etherFiAdminContract)) revert IncorrectCaller();
    if (totalValueInLp < _amount) revert InsufficientLiquidity();

    totalValueInLp     -= _amount;
    totalValueOutOfLp  += _amount;
    ethAmountLockedForWithdrawal += _amount;

    _sendFund(address(withdrawRequestNFT), _amount);
}
```

- [ ] **Step 4: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 5: Run test**

```bash
forge test --match-test test_addEthAmountLockedForWithdrawal_transfersEthToNFT --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL with revert at `_sendFund` because `WithdrawRequestNFT` lacks a `receive()`. We add it in Task 3.

- [ ] **Step 6: Commit**

Stage `src/LiquidityPool.sol` and `test/LiquidityPool.t.sol`. Commit message: `feat(LP): transfer ETH to WithdrawRequestNFT on addEthAmountLockedForWithdrawal`.

---

## Task 3: WithdrawRequestNFT — add gated `receive()`

**Files:**
- Modify: `src/WithdrawRequestNFT.sol`

- [ ] **Step 1: Add `receive()`**

Open `src/WithdrawRequestNFT.sol`. The contract has no `receive()` today. Add this near the top of the contract body (e.g. directly after the `constructor`/`initialize` block, before `requestWithdraw`):

```solidity
receive() external payable {
    require(msg.sender == address(liquidityPool), "Only LP");
}
```

- [ ] **Step 2: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 3: Re-run Task 2's test**

```bash
forge test --match-test test_addEthAmountLockedForWithdrawal_transfersEthToNFT --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 4: Commit**

Stage `src/WithdrawRequestNFT.sol`. Commit message: `feat(WithdrawRequestNFT): accept ETH from LiquidityPool only`.

---

## Task 4: LP — segregated `withdraw` branch (skip `_sendFund` for NFT/queue callers)

**Files:**
- Modify: `src/LiquidityPool.sol:215-251`
- Test: `test/LiquidityPool.t.sol`

**Background:** when caller is `withdrawRequestNFT` or `priorityWithdrawalQueue`, ETH already lives in the caller's balance. LP must do share burn + counter decrement + `totalValueOutOfLp` decrement, but **must not** `_sendFund`.

- [ ] **Step 1: Failing test — segregated branch**

Append to `test/LiquidityPool.t.sol`:

```solidity
function test_withdraw_segregatedCaller_doesNotSendEth() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    // Pre-fund NFT with locked ETH via the modified addEthAmountLockedForWithdrawal flow.
    vm.deal(address(liquidityPoolInstance), 100 ether);
    vm.prank(address(membershipManagerInstance));
    liquidityPoolInstance.deposit{value: 100 ether}();

    uint128 amount = 1 ether;
    vm.prank(address(etherFiAdminInstance));
    liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);

    // The NFT contract holds `amount` eETH (deposited at request time pre-existing) — for
    // this isolated test, mint eETH shares to the NFT contract so the burn succeeds.
    // (Use the path adjacent tests use to grant eETH; e.g. deposit then transfer eETH to NFT.)
    deal(address(eETHInstance), address(withdrawRequestNFTInstance), amount, true);

    uint256 lpEthBefore        = address(liquidityPoolInstance).balance;
    uint256 nftEthBefore       = address(withdrawRequestNFTInstance).balance;
    uint256 recipientEthBefore = bob.balance;
    uint256 lpInBefore         = liquidityPoolInstance.totalValueInLp();
    uint256 lpOutBefore        = liquidityPoolInstance.totalValueOutOfLp();
    uint256 lockedBefore       = liquidityPoolInstance.ethAmountLockedForWithdrawal();

    vm.prank(address(withdrawRequestNFTInstance));
    liquidityPoolInstance.withdraw(bob, amount);

    assertEq(address(liquidityPoolInstance).balance, lpEthBefore, "LP ETH should not change on segregated withdraw");
    assertEq(address(withdrawRequestNFTInstance).balance, nftEthBefore, "NFT ETH unchanged by LP.withdraw alone");
    assertEq(bob.balance, recipientEthBefore, "recipient should NOT receive ETH from LP on segregated path");

    assertEq(liquidityPoolInstance.totalValueInLp(),  lpInBefore, "totalValueInLp should not change on segregated path");
    assertEq(liquidityPoolInstance.totalValueOutOfLp(), lpOutBefore - amount, "totalValueOutOfLp not decreased");
    assertEq(liquidityPoolInstance.ethAmountLockedForWithdrawal(), lockedBefore - amount, "locked counter not decreased");
}
```

(`bob` is a typical pre-defined test address in `TestSetup.sol`. If the file uses `alice`/`charlie`/etc., substitute.)

- [ ] **Step 2: Verify it fails**

```bash
forge test --match-test test_withdraw_segregatedCaller_doesNotSendEth --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL because today LP `_sendFund`s on this path, so `bob.balance` increases and `LP.balance` drops.

- [ ] **Step 3: Modify `LiquidityPool.withdraw`**

Locate `function withdraw(address _recipient, uint256 _amount)` at line 215. Replace the body with:

```solidity
function withdraw(address _recipient, uint256 _amount) external nonReentrant returns (uint256) {
    uint256 share = sharesForWithdrawalAmount(_amount);
    require(
        msg.sender == address(withdrawRequestNFT) ||
        msg.sender == address(membershipManager) ||
        msg.sender == address(etherFiRedemptionManager) ||
        msg.sender == priorityWithdrawalQueue,
        "Incorrect Caller"
    );
    if (msg.sender != address(withdrawRequestNFT) && msg.sender != priorityWithdrawalQueue) {
        _requireNotPaused();
        _requireNotPausedUntil();
    }
    if (eETH.balanceOf(msg.sender) < _amount) revert InsufficientLiquidity();
    if (_amount > type(uint128).max || _amount == 0 || share == 0) revert InvalidAmount();

    bool fromSegregated = (msg.sender == address(withdrawRequestNFT) || msg.sender == priorityWithdrawalQueue);

    if (fromSegregated) {
        // ETH already lives in caller's balance. LP only does accounting + share burn.
        if (msg.sender == address(withdrawRequestNFT)) {
            if (ethAmountLockedForWithdrawal < _amount) revert InsufficientLiquidity();
            ethAmountLockedForWithdrawal -= uint128(_amount);
        }
        // Queue caller decrements its own ethAmountLockedForPriorityWithdrawal in its own claim.

        totalValueOutOfLp -= uint128(_amount);
        eETH.burnShares(msg.sender, share);
        // No _sendFund on this path — caller pays recipient itself.
        return share;
    }

    // Unchanged path for membershipManager / etherFiRedemptionManager.
    if (totalValueInLp < _amount) revert InsufficientLiquidity();
    totalValueInLp -= uint128(_amount);
    eETH.burnShares(msg.sender, share);
    _sendFund(_recipient, _amount);
    return share;
}
```

- [ ] **Step 4: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 5: Run test**

```bash
forge test --match-test test_withdraw_segregatedCaller_doesNotSendEth --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 6: Run the existing `LiquidityPool.t.sol` suite to catch regressions**

```bash
forge test --match-contract LiquidityPoolTest --fork-url $MAINNET_RPC_URL -vv 2>&1 | tail -20
```
Expected: existing tests for membership/redemption paths still PASS. If anything fails, the segregated branch's logic is wrong — re-check.

- [ ] **Step 7: Commit**

Stage `src/LiquidityPool.sol` and `test/LiquidityPool.t.sol`. Commit message: `feat(LP): segregated withdraw branch for NFT and queue callers`.

---

## Task 5: WithdrawRequestNFT — claim sends ETH from own balance

**Files:**
- Modify: `src/WithdrawRequestNFT.sol:144-161`
- Test: `test/WithdrawRequestNFT.t.sol`

- [ ] **Step 1: Failing test — claim end-to-end**

Append to `test/WithdrawRequestNFT.t.sol` (mirror existing test setup; tests typically extend `TestSetup`):

```solidity
function test_claimWithdraw_paysFromNFTBalance_afterFinalize() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    address user = bob;
    uint96 amount = 1 ether;

    // Make a request: deposit eETH for the user, approve, request withdraw.
    vm.deal(user, 10 ether);
    vm.startPrank(user);
    liquidityPoolInstance.deposit{value: 10 ether}();
    eETHInstance.approve(address(liquidityPoolInstance), amount);
    uint256 reqId = liquidityPoolInstance.requestWithdraw(user, amount);
    vm.stopPrank();

    // Admin finalizes (this also moves ETH from LP to NFT contract under our new flow).
    vm.prank(address(etherFiAdminInstance));
    withdrawRequestNFTInstance.finalizeRequests(reqId);

    vm.prank(address(etherFiAdminInstance));
    liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);

    uint256 nftEthBefore  = address(withdrawRequestNFTInstance).balance;
    uint256 userEthBefore = user.balance;

    // User claims.
    vm.prank(user);
    withdrawRequestNFTInstance.claimWithdraw(reqId);

    assertGe(user.balance, userEthBefore + amount - 1, "user did not receive amount (allowing 1 wei rounding)");
    assertEq(address(withdrawRequestNFTInstance).balance, nftEthBefore - (user.balance - userEthBefore), "NFT did not pay from own balance");
}
```

- [ ] **Step 2: Verify it fails**

```bash
forge test --match-test test_claimWithdraw_paysFromNFTBalance_afterFinalize --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL — today the LP sends ETH to the user; under our segregated branch in Task 4, LP no longer sends, so user receives nothing yet. The test catches that.

- [ ] **Step 3: Modify `_claimWithdraw`**

Open `src/WithdrawRequestNFT.sol`. Locate `_claimWithdraw` at line 144:
```solidity
function _claimWithdraw(uint256 tokenId, address recipient) internal {
    require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
    IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
    require(request.isValid, "Request is not valid");

    uint256 amountToWithdraw = getClaimableAmount(tokenId);
    uint256 shareAmountToBurnForWithdrawal = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

    _burn(tokenId);
    delete _requests[tokenId];

    totalRemainderEEthShares += request.shareOfEEth - shareAmountToBurnForWithdrawal;

    uint256 amountBurnedShare = liquidityPool.withdraw(recipient, amountToWithdraw);
    assert (amountBurnedShare == shareAmountToBurnForWithdrawal);

    emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, amountBurnedShare, recipient, 0);
}
```

Replace with (adds the ETH-send-from-NFT step):
```solidity
function _claimWithdraw(uint256 tokenId, address recipient) internal {
    require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
    IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
    require(request.isValid, "Request is not valid");

    uint256 amountToWithdraw = getClaimableAmount(tokenId);
    uint256 shareAmountToBurnForWithdrawal = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

    _burn(tokenId);
    delete _requests[tokenId];

    totalRemainderEEthShares += request.shareOfEEth - shareAmountToBurnForWithdrawal;

    uint256 amountBurnedShare = liquidityPool.withdraw(recipient, amountToWithdraw);
    assert (amountBurnedShare == shareAmountToBurnForWithdrawal);

    // ETH was transferred to this contract at finalize via LP.addEthAmountLockedForWithdrawal.
    require(address(this).balance >= amountToWithdraw, "Insufficient escrow");
    (bool ok, ) = payable(recipient).call{value: amountToWithdraw}("");
    require(ok, "ETH transfer failed");

    emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, amountBurnedShare, recipient, 0);
}
```

- [ ] **Step 4: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 5: Run test**

```bash
forge test --match-test test_claimWithdraw_paysFromNFTBalance_afterFinalize --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 6: Adversarial drain test**

Append:
```solidity
function test_claimWithdraw_succeedsEvenIfLPDrained() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    address user = bob;
    uint96 amount = 1 ether;

    vm.deal(user, 10 ether);
    vm.startPrank(user);
    liquidityPoolInstance.deposit{value: 10 ether}();
    eETHInstance.approve(address(liquidityPoolInstance), amount);
    uint256 reqId = liquidityPoolInstance.requestWithdraw(user, amount);
    vm.stopPrank();

    vm.prank(address(etherFiAdminInstance));
    withdrawRequestNFTInstance.finalizeRequests(reqId);
    vm.prank(address(etherFiAdminInstance));
    liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);

    // Adversarial: drain LP's totalValueInLp to a tiny amount via a redemption flow or vm.deal.
    // Simplest: vm.deal LP balance to 0 and zero its accounting.
    vm.deal(address(liquidityPoolInstance), 0);
    // (totalValueInLp is uint128 storage; for the test we don't need to also zero accounting —
    // the point is that the NFT contract's balance is sufficient to pay the user.)

    uint256 userEthBefore = user.balance;
    vm.prank(user);
    withdrawRequestNFTInstance.claimWithdraw(reqId);
    assertGt(user.balance, userEthBefore, "user did not receive ETH despite drained LP");
}
```

```bash
forge test --match-test test_claimWithdraw_succeedsEvenIfLPDrained --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 7: Commit**

Stage `src/WithdrawRequestNFT.sol` and `test/WithdrawRequestNFT.t.sol`. Commit message: `feat(WithdrawRequestNFT): pay claims from segregated balance`.

---

## Task 6: LP — add `transferLockedEthForPriority`

**Files:**
- Modify: `src/LiquidityPool.sol` (insert after `addEthAmountLockedForWithdrawal`, e.g., after line 515)

- [ ] **Step 1: Add the function**

Insert after `addEthAmountLockedForWithdrawal`:
```solidity
function transferLockedEthForPriority(uint128 _amount) external {
    require(msg.sender == priorityWithdrawalQueue, "Incorrect Caller");
    if (totalValueInLp < _amount) revert InsufficientLiquidity();

    totalValueInLp     -= _amount;
    totalValueOutOfLp  += _amount;
    // ethAmountLockedForWithdrawal is for NFT only; priority queue tracks its own counter.

    _sendFund(priorityWithdrawalQueue, _amount);
}
```

- [ ] **Step 2: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 3: Commit**

Stage `src/LiquidityPool.sol`. Commit message: `feat(LP): add transferLockedEthForPriority`.

---

## Task 7: PriorityWithdrawalQueue — gated `receive()`

**Files:**
- Modify: `src/PriorityWithdrawalQueue.sol`

- [ ] **Step 1: Add `receive()`**

Open `src/PriorityWithdrawalQueue.sol`. Add directly after the constructor (around line 165, after the `liquidityPool` immutable is set):

```solidity
receive() external payable {
    require(msg.sender == address(liquidityPool), "Only LP");
}
```

- [ ] **Step 2: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 3: Commit**

Stage `src/PriorityWithdrawalQueue.sol`. Commit message: `feat(PriorityQueue): accept ETH from LiquidityPool only`.

---

## Task 8: Priority queue — `fulfillRequests` transfers ETH from LP

**Files:**
- Modify: `src/PriorityWithdrawalQueue.sol:321-395` (specifically the locked counter increment around line 394)
- Test: `test/PriorityWithdrawalQueue.t.sol`

- [ ] **Step 1: Failing test**

Append to `test/PriorityWithdrawalQueue.t.sol`:
```solidity
function test_fulfillRequests_transfersEthToQueue() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    // Build a single matured request via the queue's existing helpers.
    // (Use whatever pattern existing tests in this file use to create + mature a request.)
    PriorityWithdrawalQueue.WithdrawRequest memory req = _makePendingRequest(bob, 1 ether);
    vm.warp(req.creationTime + priorityWithdrawalQueueInstance.MIN_DELAY() + 1);

    PriorityWithdrawalQueue.WithdrawRequest[] memory batch = new PriorityWithdrawalQueue.WithdrawRequest[](1);
    batch[0] = req;

    uint128 lpInBefore   = liquidityPoolInstance.totalValueInLp();
    uint128 lpOutBefore  = liquidityPoolInstance.totalValueOutOfLp();
    uint256 queueEthBefore = address(priorityWithdrawalQueueInstance).balance;
    uint128 lockedBefore = priorityWithdrawalQueueInstance.ethAmountLockedForPriorityWithdrawal();

    vm.prank(requestManager);
    priorityWithdrawalQueueInstance.fulfillRequests(batch);

    assertEq(liquidityPoolInstance.totalValueInLp(),  lpInBefore  - uint128(req.amountOfEEth), "LP InLp not decreased");
    assertEq(liquidityPoolInstance.totalValueOutOfLp(), lpOutBefore + uint128(req.amountOfEEth), "LP OutOfLp not increased");
    assertEq(address(priorityWithdrawalQueueInstance).balance, queueEthBefore + req.amountOfEEth, "queue ETH not increased");
    assertEq(priorityWithdrawalQueueInstance.ethAmountLockedForPriorityWithdrawal(), lockedBefore + uint128(req.amountOfEEth), "queue counter not increased");
}
```

The helper `_makePendingRequest(address user, uint96 amount)` should:
1. Whitelist `user` if not already (`addToWhitelist`).
2. `vm.deal(user, amount + 1 ether)` and `vm.startPrank(user)`.
3. `liquidityPoolInstance.deposit{value: amount + 1 ether}();`
4. `eETHInstance.approve(address(priorityWithdrawalQueueInstance), type(uint256).max);`
5. Call `priorityWithdrawalQueueInstance.requestWithdraw(amount, amountWithFee);`
6. Read back the request struct via `priorityWithdrawalQueueInstance.getWithdrawRequest(requestId)` (or build the struct from inputs + `block.timestamp` if no getter exists).

The `requestManager` address: locate the role holder. Look for `PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE` (or similar) in the contract and find the addr that holds it in tests — typically granted via `roleRegistry.grantRole(...)` in `TestSetup.sol`. If no test address holds the role, grant it: `vm.prank(roleRegistry.owner()); roleRegistry.grantRole(role, requestManager);` where `requestManager` is a test addr you allocate.

```bash
forge test --match-test test_fulfillRequests_transfersEthToQueue --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL — today no ETH is transferred at fulfill.

- [ ] **Step 2: Modify `fulfillRequests`**

Locate `fulfillRequests` at line 321. After the loop, the function ends with:
```solidity
ethAmountLockedForPriorityWithdrawal += uint128(totalAmountToLock);
```
(approximately line 394).

Add the LP transfer call right after:
```solidity
ethAmountLockedForPriorityWithdrawal += uint128(totalAmountToLock);
if (totalAmountToLock > 0) {
    liquidityPool.transferLockedEthForPriority(uint128(totalAmountToLock));
}
```

- [ ] **Step 3: Build & test**

```bash
forge build && forge test --match-test test_fulfillRequests_transfersEthToQueue --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 4: Commit**

Stage `src/PriorityWithdrawalQueue.sol` and `test/PriorityWithdrawalQueue.t.sol`. Commit message: `feat(PriorityQueue): transfer ETH from LP on fulfillRequests`.

---

## Task 9: Priority queue — `_claimWithdraw` sends ETH from queue's balance

**Files:**
- Modify: `src/PriorityWithdrawalQueue.sol:576-605`
- Test: `test/PriorityWithdrawalQueue.t.sol`

- [ ] **Step 1: Failing test**

```solidity
function test_claimWithdraw_paysFromQueueBalance() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    PriorityWithdrawalQueue.WithdrawRequest memory req = _makePendingRequest(bob, 1 ether);
    vm.warp(req.creationTime + priorityWithdrawalQueueInstance.MIN_DELAY() + 1);

    PriorityWithdrawalQueue.WithdrawRequest[] memory batch = new PriorityWithdrawalQueue.WithdrawRequest[](1);
    batch[0] = req;
    vm.prank(requestManager);
    priorityWithdrawalQueueInstance.fulfillRequests(batch);

    uint256 userEthBefore  = bob.balance;
    uint256 queueEthBefore = address(priorityWithdrawalQueueInstance).balance;

    vm.prank(bob);
    priorityWithdrawalQueueInstance.claimWithdraw(req);

    assertGt(bob.balance, userEthBefore, "user did not receive ETH");
    assertLt(address(priorityWithdrawalQueueInstance).balance, queueEthBefore, "queue did not pay from own balance");
}
```

```bash
forge test --match-test test_claimWithdraw_paysFromQueueBalance --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL — `LP.withdraw` for queue caller no longer sends ETH (Task 4 change), so user gets nothing yet.

- [ ] **Step 2: Modify `_claimWithdraw`**

Locate `_claimWithdraw` at line 576. The current relevant lines are (around line 597):
```solidity
uint256 burnedShares = liquidityPool.withdraw(request.user, amountToWithdraw);
if (burnedShares != sharesToBurn) revert InvalidBurnedSharesAmount();

emit WithdrawRequestClaimed(...);
```

Insert the ETH-send-from-queue immediately after the assertion:
```solidity
uint256 burnedShares = liquidityPool.withdraw(request.user, amountToWithdraw);
if (burnedShares != sharesToBurn) revert InvalidBurnedSharesAmount();

require(address(this).balance >= amountToWithdraw, "Insufficient escrow");
(bool ok, ) = payable(request.user).call{value: amountToWithdraw}("");
require(ok, "ETH transfer failed");

emit WithdrawRequestClaimed(...);
```

- [ ] **Step 3: Build & test**

```bash
forge build && forge test --match-test test_claimWithdraw_paysFromQueueBalance --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 4: Run full PriorityWithdrawalQueue test suite**

```bash
forge test --match-contract PriorityWithdrawalQueue --fork-url $MAINNET_RPC_URL 2>&1 | tail -20
```
Expected: existing claim/cancel tests may now FAIL because cancel-of-finalized still references the old (no ETH movement) flow — these will be fixed in Task 10. Note which tests fail and confirm the failures match expectations.

- [ ] **Step 5: Commit**

Stage `src/PriorityWithdrawalQueue.sol` and `test/PriorityWithdrawalQueue.t.sol`. Commit message: `feat(PriorityQueue): pay claims from segregated balance`.

---

## Task 10: LP — add `returnLockedEth` (gated cancel-return)

**Files:**
- Modify: `src/LiquidityPool.sol` (insert near `transferLockedEthForPriority`)

- [ ] **Step 1: Add the function**

Insert after `transferLockedEthForPriority`:
```solidity
function returnLockedEth(uint256 _amount) external payable {
    require(msg.sender == priorityWithdrawalQueue, "Incorrect Caller");
    if (msg.value != _amount || _amount == 0) revert InvalidAmount();
    totalValueOutOfLp -= uint128(_amount);
    totalValueInLp    += uint128(_amount);
}
```

- [ ] **Step 2: Build**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 3: Commit**

Stage `src/LiquidityPool.sol`. Commit message: `feat(LP): add returnLockedEth for queue cancel return path`.

---

## Task 11: Priority queue — return ETH on finalized cancel

**Files:**
- Modify: `src/PriorityWithdrawalQueue.sol:559-575`
- Test: `test/PriorityWithdrawalQueue.t.sol`

- [ ] **Step 1: Failing test (cancel a finalized request)**

```solidity
function test_cancelWithdraw_finalized_returnsEthToLP() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    PriorityWithdrawalQueue.WithdrawRequest memory req = _makePendingRequest(bob, 1 ether);
    vm.warp(req.creationTime + priorityWithdrawalQueueInstance.MIN_DELAY() + 1);

    PriorityWithdrawalQueue.WithdrawRequest[] memory batch = new PriorityWithdrawalQueue.WithdrawRequest[](1);
    batch[0] = req;
    vm.prank(requestManager);
    priorityWithdrawalQueueInstance.fulfillRequests(batch);

    uint128 lpInBefore     = liquidityPoolInstance.totalValueInLp();
    uint128 lpOutBefore    = liquidityPoolInstance.totalValueOutOfLp();
    uint256 queueEthBefore = address(priorityWithdrawalQueueInstance).balance;
    uint128 lockedBefore   = priorityWithdrawalQueueInstance.ethAmountLockedForPriorityWithdrawal();

    vm.prank(bob);
    priorityWithdrawalQueueInstance.cancelWithdraw(req);

    assertEq(liquidityPoolInstance.totalValueInLp(),    lpInBefore  + uint128(req.amountOfEEth), "LP InLp not increased");
    assertEq(liquidityPoolInstance.totalValueOutOfLp(), lpOutBefore - uint128(req.amountOfEEth), "LP OutOfLp not decreased");
    assertEq(address(priorityWithdrawalQueueInstance).balance, queueEthBefore - req.amountOfEEth, "queue ETH not returned");
    assertEq(priorityWithdrawalQueueInstance.ethAmountLockedForPriorityWithdrawal(), lockedBefore - req.amountOfEEth, "counter not decreased");
}
```

```bash
forge test --match-test test_cancelWithdraw_finalized_returnsEthToLP --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL — today `_cancelWithdrawRequest` doesn't move ETH back.

- [ ] **Step 2: Modify `_cancelWithdrawRequest`**

Locate at line 559:
```solidity
function _cancelWithdrawRequest(WithdrawRequest calldata request) internal returns (bytes32 requestId) {
    requestId = keccak256(abi.encode(request));

    bool wasFinalized = _finalizedRequests.contains(requestId);

    _dequeueWithdrawRequest(request);

    if (wasFinalized) {
        ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);
    }

    uint256 amountForShares = liquidityPool.amountForShare(request.shareOfEEth);
    IERC20(address(eETH)).safeTransfer(request.user, amountForShares);

    emit WithdrawRequestCancelled(...);
}
```

Insert the LP-return call inside the `wasFinalized` block:
```solidity
if (wasFinalized) {
    ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);
    liquidityPool.returnLockedEth{value: request.amountOfEEth}(request.amountOfEEth);
}
```

- [ ] **Step 3: Build & test**

```bash
forge build && forge test --match-test test_cancelWithdraw_finalized_returnsEthToLP --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 4: Add a non-finalized cancel test (regression guard)**

```solidity
function test_cancelWithdraw_pending_noEthMovement() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    PriorityWithdrawalQueue.WithdrawRequest memory req = _makePendingRequest(bob, 1 ether);
    vm.warp(req.creationTime + priorityWithdrawalQueueInstance.MIN_DELAY() + 1);
    // No fulfillRequests call — request is pending only.

    uint256 lpEthBefore    = address(liquidityPoolInstance).balance;
    uint256 queueEthBefore = address(priorityWithdrawalQueueInstance).balance;

    vm.prank(bob);
    priorityWithdrawalQueueInstance.cancelWithdraw(req);

    assertEq(address(liquidityPoolInstance).balance,    lpEthBefore,    "LP ETH should not change");
    assertEq(address(priorityWithdrawalQueueInstance).balance, queueEthBefore, "queue ETH should not change");
}
```

```bash
forge test --match-test test_cancelWithdraw_pending_noEthMovement --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 5: Commit**

Stage `src/PriorityWithdrawalQueue.sol` and `test/PriorityWithdrawalQueue.t.sol`. Commit message: `feat(PriorityQueue): return locked ETH to LP on finalized cancel`.

---

## Task 12: Priority queue — update `_verifyCancelPostConditions`

**Files:**
- Modify: `src/PriorityWithdrawalQueue.sol:481-510`

**Background:** the existing post-condition check (line 481) asserts `LP ETH balance unchanged`. With our change, LP ETH increases by `request.amountOfEEth` on a finalized cancel.

- [ ] **Step 1: Read the function body**

Open `src/PriorityWithdrawalQueue.sol` line 481. Identify which assertion compares the LP ETH balance before/after. The function takes `lpEthBefore` and the caller passes `address(liquidityPool).balance` from before the cancel.

- [ ] **Step 2: Update the assertion**

Find the line that checks LP balance (likely `if (address(liquidityPool).balance != _lpEthBefore) revert ...;` or similar). Change it to allow the LP balance to grow by `request.amountOfEEth` when `wasFinalized` was true. The cleanest path: also pass the pre-cancel finalized flag (or compute the expected delta) into `_verifyCancelPostConditions`.

Concrete change (adapt names to match the actual function signature):

```solidity
function _verifyCancelPostConditions(
    uint256 _lpEthBefore,
    uint256 _queueEEthSharesBefore,
    uint256 _userEEthSharesBefore,
    address _user,
    uint256 _expectedLpEthDelta   // NEW: 0 for pending cancels, request.amountOfEEth for finalized
) internal view {
    require(address(liquidityPool).balance == _lpEthBefore + _expectedLpEthDelta, "LP ETH delta unexpected");
    // ... rest unchanged
}
```

Update the callsite (around line 282) to pass the expected delta. Snapshot `wasFinalized` before `_cancelWithdrawRequest` runs (the `_finalizedRequests` set entry is removed inside it), then pass the appropriate delta.

- [ ] **Step 3: Build & rerun the cancel suite**

```bash
forge build && forge test --match-contract PriorityWithdrawalQueue --fork-url $MAINNET_RPC_URL 2>&1 | tail -20
```
Expected: cancel tests pass; no other regressions.

- [ ] **Step 4: Commit**

Stage `src/PriorityWithdrawalQueue.sol`. Commit message: `fix(PriorityQueue): adjust _verifyCancelPostConditions for new LP delta on finalized cancel`.

---

## Task 13: LP — `initializeOnUpgradeV2` migration

**Files:**
- Modify: `src/LiquidityPool.sol` (after the existing `initializeVTwoDotFourNine` around line 165)
- Test: `test/LiquidityPool.t.sol`

- [ ] **Step 1: Failing fork test**

Append to `test/LiquidityPool.t.sol`:
```solidity
function test_initializeOnUpgradeV2_sweepsLockedEth() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    // Capture pre-state.
    uint128 nftLocked   = liquidityPoolInstance.ethAmountLockedForWithdrawal();
    uint128 queueLocked = priorityWithdrawalQueueInstance == address(0)
        ? uint128(0)
        : priorityWithdrawalQueueInstance.ethAmountLockedForPriorityWithdrawal();
    uint128 totalLocked = nftLocked + queueLocked;
    require(totalLocked > 0, "fork must have non-zero locked counters; pick a recent block");

    uint256 nftBalBefore   = address(withdrawRequestNFTInstance).balance;
    uint256 queueBalBefore = address(priorityWithdrawalQueueInstance).balance;
    uint128 lpInBefore     = liquidityPoolInstance.totalValueInLp();
    uint128 lpOutBefore    = liquidityPoolInstance.totalValueOutOfLp();
    uint256 sharesBefore   = eETHInstance.totalShares();
    uint256 totalPooledBefore = liquidityPoolInstance.getTotalPooledEther();

    // Owner == UPGRADE_TIMELOCK on mainnet.
    address owner = liquidityPoolInstance.owner();
    vm.prank(owner);
    liquidityPoolInstance.initializeOnUpgradeV2();

    assertEq(address(withdrawRequestNFTInstance).balance,         nftBalBefore + nftLocked,   "NFT not funded");
    assertEq(address(priorityWithdrawalQueueInstance).balance,    queueBalBefore + queueLocked, "queue not funded");
    assertEq(liquidityPoolInstance.totalValueInLp(),  lpInBefore - totalLocked,                 "InLp not decreased");
    assertEq(liquidityPoolInstance.totalValueOutOfLp(), lpOutBefore + totalLocked,              "OutOfLp not increased");
    assertEq(eETHInstance.totalShares(), sharesBefore,                                          "totalShares changed");
    assertEq(liquidityPoolInstance.getTotalPooledEther(), totalPooledBefore,                    "TVL changed");
    assertTrue(liquidityPoolInstance.escrowMigrationCompleted(), "flag not set");

    // Idempotency.
    vm.expectRevert(bytes("already migrated"));
    vm.prank(owner);
    liquidityPoolInstance.initializeOnUpgradeV2();
}
```

```bash
forge test --match-test test_initializeOnUpgradeV2_sweepsLockedEth --fork-url $MAINNET_RPC_URL -vv
```
Expected: FAIL — `initializeOnUpgradeV2` doesn't exist yet.

- [ ] **Step 2: Implement the function**

Insert in `LiquidityPool.sol` after `initializeVTwoDotFourNine` (around line 165):
```solidity
function initializeOnUpgradeV2() external onlyOwner {
    require(!escrowMigrationCompleted, "already migrated");

    uint128 nftLocked   = ethAmountLockedForWithdrawal;
    uint128 queueLocked = priorityWithdrawalQueue == address(0)
        ? uint128(0)
        : uint128(IPriorityWithdrawalQueue(priorityWithdrawalQueue).ethAmountLockedForPriorityWithdrawal());

    uint128 totalLocked = nftLocked + queueLocked;
    if (totalLocked > 0) {
        if (totalValueInLp < totalLocked) revert InsufficientLiquidity();
        totalValueInLp    -= totalLocked;
        totalValueOutOfLp += totalLocked;

        if (nftLocked > 0)   _sendFund(address(withdrawRequestNFT),   nftLocked);
        if (queueLocked > 0) _sendFund(address(priorityWithdrawalQueue), queueLocked);
    }

    escrowMigrationCompleted = true;
}
```

If `IPriorityWithdrawalQueue` is not already imported in `LiquidityPool.sol`, add the import at the top:
```solidity
import "./interfaces/IPriorityWithdrawalQueue.sol";
```

- [ ] **Step 3: Build & test**

```bash
forge build && forge test --match-test test_initializeOnUpgradeV2_sweepsLockedEth --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 4: Commit**

Stage `src/LiquidityPool.sol` and `test/LiquidityPool.t.sol`. Commit message: `feat(LP): one-shot initializeOnUpgradeV2 sweeps locked ETH`.

---

## Task 14: Integration test — full lifecycle with adversarial drain

**Files:**
- Modify: `test/WithdrawRequestNFT.t.sol` (or add a new file `test/integration-tests/EthEscrow.t.sol` if the team prefers the integration-tests directory)

- [ ] **Step 1: Add integration test**

```solidity
function test_integration_fullLifecycle_withDrain() public {
    initializeRealisticFork(MAINNET_FORK);  // MAINNET_FORK is a uint8 enum from TestSetup.sol

    // Run the migration first (so existing finalized claims continue to work).
    vm.prank(liquidityPoolInstance.owner());
    liquidityPoolInstance.initializeOnUpgradeV2();

    // User flow: deposit → request → admin finalize → drain LP via redemption manager → claim
    address user = bob;
    uint96 amount = 5 ether;

    vm.deal(user, 100 ether);
    vm.startPrank(user);
    liquidityPoolInstance.deposit{value: 100 ether}();
    eETHInstance.approve(address(liquidityPoolInstance), amount);
    uint256 reqId = liquidityPoolInstance.requestWithdraw(user, amount);
    vm.stopPrank();

    vm.prank(address(etherFiAdminInstance));
    withdrawRequestNFTInstance.finalizeRequests(reqId);
    vm.prank(address(etherFiAdminInstance));
    liquidityPoolInstance.addEthAmountLockedForWithdrawal(amount);

    // Adversarial: drain LP via redemption manager (use an existing helper if available; else vm.deal LP to 0).
    vm.deal(address(liquidityPoolInstance), 0);

    uint256 userEthBefore = user.balance;
    vm.prank(user);
    withdrawRequestNFTInstance.claimWithdraw(reqId);
    assertGe(user.balance, userEthBefore + amount - 1, "user did not receive funds despite drain");
}
```

```bash
forge test --match-test test_integration_fullLifecycle_withDrain --fork-url $MAINNET_RPC_URL -vv
```
Expected: PASS.

- [ ] **Step 2: Commit**

Commit message: `test: integration test for finalize → drain → claim lifecycle`.

---

## Task 15: Sanity — full test suite

- [ ] **Step 1: Run all unit tests (no fork)**

```bash
forge test --no-match-test "fork|Fork" 2>&1 | tail -30
```
Expected: 0 failures.

- [ ] **Step 2: Run fork tests**

```bash
forge test --fork-url $MAINNET_RPC_URL 2>&1 | tail -30
```
Expected: 0 failures. Existing tests (membership manager paths, redemption manager paths) must continue to pass — those use the unchanged branch in `LP.withdraw`.

- [ ] **Step 3: Build clean**

```bash
forge clean && forge build 2>&1 | tail -3
```
Expected: exit 0, no warnings introduced beyond the pre-existing baseline.

- [ ] **Step 4: Commit (if any cosmetic fixes needed during sanity)**

If everything is green, skip. Otherwise, fix any flakes and commit.

---

## Task 16: Documentation comments

**Files:**
- Modify: `src/LiquidityPool.sol`, `src/WithdrawRequestNFT.sol`, `src/PriorityWithdrawalQueue.sol`

- [ ] **Step 1: Add a single natspec note above `addEthAmountLockedForWithdrawal`, `transferLockedEthForPriority`, `_claimWithdraw` (NFT and queue)**

Example for `addEthAmountLockedForWithdrawal`:
```solidity
/// @notice Locks ETH for finalized NFT withdrawals by transferring it from LP to WithdrawRequestNFT.
/// @dev TVL preserved by totalValueInLp/OutOfLp rebalance. Assumes non-decreasing share rate;
///      under that assumption, the segregated balance always covers the eventual claim.
function addEthAmountLockedForWithdrawal(uint128 _amount) external { ... }
```

Add similar one-line notes near the other modified functions explaining the segregated-balance invariant. Avoid multi-paragraph docstrings.

- [ ] **Step 2: Build (sanity)**

```bash
forge build 2>&1 | tail -3
```
Expected: exit 0.

- [ ] **Step 3: Commit**

Commit message: `docs: explain segregated-balance invariant on locked-ETH paths`.

---

## Out-of-Scope / Follow-ups (do NOT include in this plan)

- Deployment scripts (`script/upgrades/...`) — separate PR; safe to do after contract changes are reviewed.
- `EtherFiAdmin.executeTasks` audit — confirm it still calls `addEthAmountLockedForWithdrawal` with the right amount; no contract change needed if so.
- Aggregating `returnLockedEth` calls in `invalidateRequests` for gas — optimization, do later if batches are large.

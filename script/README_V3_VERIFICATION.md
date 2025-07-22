# V3 Upgrade Verification – Quick Guide

This Forge script proves that the post‑V3 **ether.fi** contracts are wired correctly **and** that every proxy can still be upgraded by the sole protocol upgrader.

---

## What It Checks

| Section | What’s verified |
|---------|-----------------|
| **1 Role Registry** | • Every contract points to `RoleRegistry 0x6224…7cE9`<br>• All hard‑coded role constants match their `keccak256` hashes |
| **2 Upgradeability** | For each proxy (StakingManager, EtherFiNodesManager, LiquidityPool, AuctionManager):<br>1. **Proxy slot** – implementation address ≠ 0 and ≠ proxy<br>2. **UUPS UUID** – implementation’s `proxiableUUID()` returns canonical ERC‑1967 slot<br>3. **Upgrade entry‑point** – `staticcall` to `upgradeTo(address)` exists and reaches auth guard<br>4. **Auth** – only `RoleRegistry.owner()` passes `_authorizeUpgrade()` |
| **3 Role Assignments** | • All role constants (pauser/unpauser, node roles, etc.) equal expected hashes |
| **4 Contract Links** | • StakingManager → NodesManager / LiquidityPool / AuctionManager<br>• NodesManager → StakingManager<br>• Beacon address is set |

---

## Running
At the start of run(), the fork is selected.
For Tenderly, ensure to set TENDERLY_TEST_RPC in the .env.
For any other network, change TENDERLY_TEST_RPC to the other RPC.
```
//Select RPC to fork
string memory rpc = vm.rpcUrl(vm.envString("TENDERLY_TEST_RPC"));
vm.createSelectFork(rpc);
```
```
forge script script/VerifyV3Upgrade.s.sol
```
---

## Expected Output

```
========================================
Starting V3 Upgrade Verification
========================================

  1. VERIFYING ROLE REGISTRY CONFIGURATION
  ----------------------------------------
  Checking StakingManager RoleRegistry...
    [PASS] StakingManager has correct RoleRegistry
  Checking EtherFiNodesManager RoleRegistry...
    [PASS] EtherFiNodesManager has correct RoleRegistry
  Checking EtherFiNode implementation RoleRegistry...
  
2. VERIFYING CONTRACT UPGRADEABILITY
  ----------------------------------------
  …

========================================
VERIFICATION SUMMARY
========================================
  Total Checks: 27
  Passed: 27
  Failed: 0
  
[PASS] ALL VERIFICATIONS PASSED!
```

If any check fails the script reverts with **“Verification failed”**.

---

## Contract Addresses Verified

| Contract | Address |
|----------|------------------------------------------|
| StakingManager | `0x25e821b7197B146F7713C3b89B6A4D83516B912d` |
| EtherFiNodesManager | `0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F` |
| LiquidityPool | `0x308861A430be4cce5502d0A12724771Fc6DaF216` |
| AuctionManager | `0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9` |
| RoleRegistry | `0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9` |

---

**TL;DR:** The script confirms every proxy is still a valid UUPS upgrade target and that only the designated upgrader can execute the next upgrade.

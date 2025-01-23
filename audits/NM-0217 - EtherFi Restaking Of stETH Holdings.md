# [NM-0217] Restaking of stETH holdings

**File(s)**: [EtherFiRestaker.sol](https://github.com/etherfi-protocol/smart-contracts/blob/41836a2523b735fab8aad8ebfe4b25ed81fbc367/src/EtherFiRestaker.sol#L19), [Liquifier.sol](https://github.com/etherfi-protocol/smart-contracts/blob/41836a2523b735fab8aad8ebfe4b25ed81fbc367/src/Liquifier.sol#L50),
[ILiquifier.sol](https://github.com/etherfi-protocol/smart-contracts/blob/41836a2523b735fab8aad8ebfe4b25ed81fbc367/src/interfaces/ILiquifier.sol)

### Summary

Restaking of stETH holdings. Ether.fi is holding ~250k stETH in deVamp contract. However, it is suffering from the low capital efficiency being not deployed to EigenLayer restaking. This PR addresses this issue.

---

### Findings

### [Best practice] Lack of access control in the `undelegate` function 

**File(s)**: [EtherFiRestaker.sol](https://github.com/etherfi-protocol/smart-contracts/blob/41836a2523b735fab8aad8ebfe4b25ed81fbc367/src/EtherFiRestaker.sol#L147)

**Description**: The `EtherFiRestaker::undelegate` function lacks access controls. The call will still revert because of the `onlyOwner` modifier that's used on the `queueWithdrawals` function, but this is the only "main" function in the contract without access controls.

**Recommendation(s)**: Consider adding access control to this function.

**Update from client**: fixed

---

### [Best practice] Typo in function name `getEthAmountInEigenLayerPnedingForWithdrawals` 

**File(s)**: [EtherFiRestaker.sol](https://github.com/etherfi-protocol/smart-contracts/blob/41836a2523b735fab8aad8ebfe4b25ed81fbc367/src/EtherFiRestaker.sol#L330)

**Description**: The function name has a typo `getEthAmountInEigenLayerPnedingForWithdrawals`. Instead if Pending, it is written Pneding.

**Recommendation(s)**: Rename the function accordingly.

**Update from client**: fixed

---

# IStakingManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/interfaces/IStakingManager.sol)


## Functions
### cancelDeposit


```solidity
function cancelDeposit(uint256 _validatorId) external;
```

### registerValidator


```solidity
function registerValidator(uint256 _validatorId, DepositData calldata _depositData) external;
```

### fetchEtherFromContract


```solidity
function fetchEtherFromContract(address _wallet) external;
```

### bidIdToStaker


```solidity
function bidIdToStaker(uint256 id) external view returns (address);
```

### stakeAmount


```solidity
function stakeAmount() external view returns (uint256);
```

### setEtherFiNodesManagerAddress


```solidity
function setEtherFiNodesManagerAddress(address _managerAddress) external;
```

### batchDepositWithBidIds


```solidity
function batchDepositWithBidIds(uint256[] calldata _candidateBidIds) external payable returns (uint256[] memory);
```

### setProtocolRevenueManager


```solidity
function setProtocolRevenueManager(address _protocolRevenueManager) external;
```

## Structs
### DepositData

```solidity
struct DepositData {
    bytes publicKey;
    bytes signature;
    bytes32 depositDataRoot;
    string ipfsHashForEncryptedValidatorKey;
}
```


# AuctionManager

[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/AuctionManager.sol)

**Inherits:**
[IAuctionManager](/src/interfaces/IAuctionManager.sol/interface.IAuctionManager.md), Pausable, Ownable

## State Variables

### whitelistBidAmount

```solidity
uint256 public whitelistBidAmount = 0.001 ether;
```

### minBidAmount

```solidity
uint256 public minBidAmount = 0.01 ether;
```

### maxBidAmount

```solidity
uint256 public maxBidAmount = 5 ether;
```

### numberOfBids

```solidity
uint256 public numberOfBids = 1;
```

### numberOfActiveBids

```solidity
uint256 public numberOfActiveBids;
```

### stakingManagerContractAddress

```solidity
address public stakingManagerContractAddress;
```

### nodeOperatorManagerContractAddress

```solidity
address public nodeOperatorManagerContractAddress;
```

### whitelistEnabled

```solidity
bool public whitelistEnabled = true;
```

### bids

```solidity
mapping(uint256 => Bid) public bids;
```

### nodeOperatorManagerInterface

```solidity
INodeOperatorManager nodeOperatorManagerInterface;
```

### protocolRevenueManager

```solidity
IProtocolRevenueManager protocolRevenueManager;
```

## Functions

### receive

```solidity
receive() external payable;
```

### constructor

Constructor to set variables on deployment

```solidity
constructor(address _nodeOperatorManagerContract);
```

### createBid

Creates bid(s) for the right to run a validator node when ETH is deposited

```solidity
function createBid(uint256 _bidSize, uint256 _bidAmountPerBid)
    external
    payable
    whenNotPaused
    returns (uint256[] memory);
```

**Parameters**

| Name               | Type      | Description                                                    |
| ------------------ | --------- | -------------------------------------------------------------- |
| `_bidSize`         | `uint256` | the number of bids that the node operator would like to create |
| `_bidAmountPerBid` | `uint256` | the ether value of each bid that is created                    |

**Returns**

| Name     | Type        | Description                                      |
| -------- | ----------- | ------------------------------------------------ |
| `<none>` | `uint256[]` | bidIdArray array of the bidIDs that were created |

### cancelBid

Cancels a specified bid by de-activating it

_Require the bid to exist and be active_

```solidity
function cancelBid(uint256 _bidId) external whenNotPaused;
```

**Parameters**

| Name     | Type      | Description                 |
| -------- | --------- | --------------------------- |
| `_bidId` | `uint256` | the ID of the bid to cancel |

### updateSelectedBidInformation

Updates a bid winning bids details

_Called by batchDepositWithBidIds() in StakingManager.sol_

```solidity
function updateSelectedBidInformation(uint256 _bidId) public onlyStakingManagerContract;
```

**Parameters**

| Name     | Type      | Description                                                                   |
| -------- | --------- | ----------------------------------------------------------------------------- |
| `_bidId` | `uint256` | the ID of the bid being removed from the auction (since it has been selected) |

### reEnterAuction

Lets a bid that was matched to a cancelled stake re-enter the auction

```solidity
function reEnterAuction(uint256 _bidId) external onlyStakingManagerContract whenNotPaused;
```

**Parameters**

| Name     | Type      | Description                                                 |
| -------- | --------- | ----------------------------------------------------------- |
| `_bidId` | `uint256` | the ID of the bid which was matched to the cancelled stake. |

### Transfer

Transfer the auction fee received from the node operator to the protocol revenue manager

_Called by registerValidator() in StakingManager.sol_

```solidity
function processAuctionFeeTransfer(uint256 _bidId) external onlyStakingManagerContract;
```

**Parameters**

| Name     | Type      | Description             |
| -------- | --------- | ----------------------- |
| `_bidId` | `uint256` | the ID of the validator |

### disableWhitelist

Disables the bid whitelist

_Allows both regular users and whitelisted users to bid_

```solidity
function disableWhitelist() public onlyOwner;
```

### enableWhitelist

Enables the bid whitelist

_Only users who are on a whitelist can bid_

```solidity
function enableWhitelist() public onlyOwner;
```

### pauseContract

```solidity
function pauseContract() external onlyOwner;
```

### unPauseContract

```solidity
function unPauseContract() external onlyOwner;
```

### uncheckedInc

```solidity
function uncheckedInc(uint256 x) private pure returns (uint256);
```

### getBidOwner

Fetches the address of the user who placed a bid for a specific bid ID

_Needed for registerValidator() function in Staking Contract_

```solidity
function getBidOwner(uint256 _bidId) external view returns (address);
```

**Returns**

| Name     | Type      | Description                 |
| -------- | --------- | --------------------------- |
| `<none>` | `address` | the user who placed the bid |

### isBidActive

Fetches if a selected bid is currently active

_Needed for batchDepositWithBidIds() function in Staking Contract_

```solidity
function isBidActive(uint256 _bidId) external view returns (bool);
```

**Returns**

| Name     | Type   | Description                                  |
| -------- | ------ | -------------------------------------------- |
| `<none>` | `bool` | the boolean value of the active flag in bids |

### setProtocolRevenueManager

Sets an instance of the protocol revenue manager

Performed this way due to circular dependencies

_Needed to process an auction fee_

```solidity
function setProtocolRevenueManager(address _protocolRevenueManager) external onlyOwner;
```

**Parameters**

| Name                      | Type      | Description                        |
| ------------------------- | --------- | ---------------------------------- |
| `_protocolRevenueManager` | `address` | the addres of the protocol manager |

### setStakingManagerContractAddress

Sets the stakingManagerContractAddress address in the current contract

```solidity
function setStakingManagerContractAddress(address _stakingManagerContractAddress) external onlyOwner;
```

**Parameters**

| Name                             | Type      | Description                        |
| -------------------------------- | --------- | ---------------------------------- |
| `_stakingManagerContractAddress` | `address` | new stakingManagerContract address |

### setMinBidPrice

Updates the minimum bid price

```solidity
function setMinBidPrice(uint256 _newMinBidAmount) external onlyOwner;
```

**Parameters**

| Name               | Type      | Description                                    |
| ------------------ | --------- | ---------------------------------------------- |
| `_newMinBidAmount` | `uint256` | the new amount to set the minimum bid price as |

### setMaxBidPrice

Updates the maximum bid price

```solidity
function setMaxBidPrice(uint256 _newMaxBidAmount) external onlyOwner;
```

**Parameters**

| Name               | Type      | Description                                    |
| ------------------ | --------- | ---------------------------------------------- |
| `_newMaxBidAmount` | `uint256` | the new amount to set the maximum bid price as |

### updateWhitelistMinBidAmount

Updates the minimum bid price for a whitelisted address

```solidity
function updateWhitelistMinBidAmount(uint256 _newAmount) external onlyOwner;
```

**Parameters**

| Name         | Type      | Description                                    |
| ------------ | --------- | ---------------------------------------------- |
| `_newAmount` | `uint256` | the new amount to set the minimum bid price as |

### onlyStakingManagerContract

```solidity
modifier onlyStakingManagerContract();
```

### onlyNodeOperatorManagerContract

```solidity
modifier onlyNodeOperatorManagerContract();
```

## Events

### BidCreated

```solidity
event BidCreated(address indexed bidder, uint256 amountPerBid, uint256[] bidIdArray, uint64[] ipfsIndexArray);
```

### BidCancelled

```solidity
event BidCancelled(uint256 indexed bidId);
```

### BidReEnteredAuction

```solidity
event BidReEnteredAuction(uint256 indexed bidId);
```

### Received

```solidity
event Received(address indexed sender, uint256 value);
```

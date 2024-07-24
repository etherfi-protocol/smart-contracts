# Extension of Withdrawal with EigenLayer M2 audit.

**File(s)**: EtherFiNode.sol, EtherFiNodeManager.sol

## Context
The current smart contract cannot handle the delayed withdrawal from the DelegationManager.undelegate. The purpose of the review is to identify and mitigate potential risks that may arise from the implementation of the hotfix on the EtherFiNodeManager, and EtherFiNode contracts.

The current withdrawal flow assumes that a withdrawal from the eigenpod is initiated via the etherfiNodesManager.processNodeExit() and it is claimed via the etherfiNodesmanager.completeQueuedWithdrawals .

The admin called delegationManager.undelegate on multiple validators. This had the effect of queuing a withdrawal for the entirety of the shares owned by the validator. Now since a withdrawal has already been queued, the existing pathway fails because it is unable to create a new withdrawal for the expected amount.

The fix proposed by EtherFi's team uses the feature of EigenLayer where a user can claim their withdrawal as shares that they are able to redelegate. In this fix, they add the ability to claim the validators that are in this state, but only to claim them via the shares method. Once they run this for each of the affected validators, the normal exit flow will work again.

## Review conclusions
After reviewing the updated code, we don't see any clear risk on the hotfix. The code seems to work as expected.
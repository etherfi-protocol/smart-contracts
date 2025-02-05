# [EFIP-11] Async Admin Task Execution for Validator Management


**Author**: Vaibhav Valecha (vaibhav@ether.fi), syko (seongyun@ether.fi)

**Date**: 2024-07-22

## Summary

This EFIP proposes implementing asynchronous task execution for validator management admin tasks in the EtherFi protocol. This change will allow admin tasks to be queued and executed asynchronously, improving scalability.

## Motivation

Currently, admin tasks are executed synchronously, which can lead to delays in validator management, especially during high-load periods. By introducing asynchronous task execution, we can ensure faster & prompt management.

## Proposal

The proposal introduces changes to the EtherFiAdmin contract to enable asynchronous execution of admin tasks. Key features include:

1. **Task Types**:
    - Definition of various task types such as `ValidatorApproval`, `SendExitRequests`, `ProcessNodeExit`, and `MarkBeingSlashed`.

2. **Task Status Management**:
    - Introduction of a `TaskStatus` struct to track the status of each task.
    - Mapping to manage task statuses.

3. **Task Execution Functions**:
    - `executeValidatorManagementTask`: Executes specified admin tasks based on their type.
    - `invalidateValidatorManagementTask`: Invalidates tasks that are no longer needed.

4. **Event Emission**:
    - Emission of events such as `ValidatorManagementTaskCreated`, `ValidatorManagementTaskCompleted`, and `ValidatorManagementTaskInvalidated` to track task progress and status.

5. **Task Enqueuing**:
    - Functions to enqueue tasks for later execution, improving flexibility and responsiveness.

## References

- [Pull Request #82](https://github.com/etherfi-protocol/smart-contracts/pull/82)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
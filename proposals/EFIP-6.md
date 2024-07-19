# [EFIP-6] Protocol Pausing Contract

**Author**: Jacob Firek

**Date**: 2024-07-19

## Summary

Create a central contract based on the SevenSeas `Pauser` contract, modified to use `RoleRegistry`. Existing contracts will inherit a simple pausing interface and be updated to use this central pauser contract, and existing pausing logic in contracts will be deprecated. All pausing/unpausing for the protocol will happen through the `Pauser` while the `RoleRegistry` will determine who can call these functions.

## Motivation

We have functionality for pausing and unpaused scattered across our individual contracts with various implementations and admin roles for preforming these actions. 

## Proposal

Implement a contract to serve as the central access point for the pausing and unpausing of our contracts. The [SevenSeas pauser contract](https://github.com/Se7en-Seas/boring-governance/blob/main/src/base/Roles/Pauser.sol) will be used as a base. The contract will be modified to use our `RoleRegistry` for access to the functions. 

The existing contracts with pausing functionality will inherit a simple pausing interface:

```
interface IPausable {
    function pauseContract() external;
    function unPauseContract() external;
}
```

The existing contracts with pausing functionality will be upgraded to include the following in their implementation:
```
address public pauser; // set to the to Pauser contract

function pauseContract() external onlyPauser {};

modifier onlyPauser() {
    require(msg.sender == pauser, "Not the pauser contract");
    _;
 }
```

Some existing pausing logic will be deprecated. Example from the `Liquifier`:
```
mapping(address => bool) public pausers;
```

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).


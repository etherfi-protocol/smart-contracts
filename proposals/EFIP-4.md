# [EFIP-4] Rewards Skimming Optimization

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is optimize reward skimming when paying out the node operator. Every quarter we pay out 5% of validator rewards to the corresponding node operator. This is a very expensive operation because we need to skim rewards of over 20k eigenpods and 20k etherfinode contracts where all the execution and consensus rewards go to. Furthermore, to determine the rewards accrued by all the protocol is very difficult with the number of different contracts holding the rewards. In order to fix this during the rebase operation instead of minting shares of 90% of rewards (5% goes to treasury and 5% goes to node operator) we mint 100% of rewards and distribute the 10% to the treasury. Furthermore, the oracle report should report an array which corresponds to how much rewards goes to each operator. We would also deploy an nodeOperatorAccounting correct that keeps tracks of the amount of rewards acfrued to each of the operators. 


## Motivation

The benefit of this proposal is that we optimize the gas paid then we can skim the etherfinode contracts and the eigenpods at our discretion and when we feel it is required. Furthermore, it automates the process of paying out the node opeartors and there is less human error and reliance of paying the NO using non-rewards data. 


## Proposal


1. Deploy a NodeOperator Accounting contract (or upgrade nodesmanager contract) this contract can be the hub  where all node oepraytor information lies ie.. The name, address, rewards accrued and etc any other information we believe is required to keep track of (number of validators  run by each of the no opeartor) this will make the accounting and easy for everyone to find information about validators  :)

2. Upgrade the oracle contract to be able to take in an array of rewatrds per node operator

3. Upgrade rebase operation on the liquidity pool to be able to mint eeth to the treasury

4. Upgrade treasury to be able to transfer and burn eeth for eth


## References

This aritcheture of paying the treasury and node operators in eeth was inspired by lido's protocol and seeing how their treasury on holds steeth instead of holidng eeth

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).


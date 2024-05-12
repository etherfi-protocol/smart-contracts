// First spec file example

/// @title First rule example
rule fetchNextKeyIndexIntegrity(address _user) {
    // Note: using direct storage access
    uint64 preUsed = currentContract.addressToOperatorData[_user].keysUsed;
    uint64 preTotalKeys = currentContract.addressToOperatorData[_user].totalKeys;

    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    uint64 postUsed = currentContract.addressToOperatorData[_user].keysUsed;
    uint64 postTotalKeys = currentContract.addressToOperatorData[_user].totalKeys;

    assert preUsed == nextIndex, "used key should be next index";
    assert preUsed < preTotalKeys, "can't use more keys than it has";
    assert postUsed > preUsed, "must not re-use keys";
    assert preTotalKeys == postTotalKeys, "total keys may not change";
}

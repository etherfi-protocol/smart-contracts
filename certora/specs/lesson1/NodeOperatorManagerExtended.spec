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


/// @title Unrelated user should not be affected
rule fetchNextKeyIndexThirdPartyProtection(address _user, address unrelated) {
    require _user != unrelated;  // Different from solidity `require`!
    uint64 preUsed = currentContract.addressToOperatorData[unrelated].keysUsed;

    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    uint64 postUsed = currentContract.addressToOperatorData[unrelated].keysUsed;
    assert preUsed == postUsed, "unrelated user's keys should not be affected";
}


/// @title Unrelated user should not be affected - using implication
rule fetchNextKeyIndexThirdPartyProtectionImplication(address _user, address unrelated) {
    uint64 preUsed = currentContract.addressToOperatorData[unrelated].keysUsed;

    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    uint64 postUsed = currentContract.addressToOperatorData[unrelated].keysUsed;
    assert _user != unrelated => preUsed == postUsed;
}


/// @title Generalized rule for `fetchNextKeyIndex` -  combines several properties
rule fetchNextKeyIndexGeneralized(address _user, address unrelated) {
    uint64 preUsed = currentContract.addressToOperatorData[unrelated].keysUsed;

    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    uint64 postUsed = currentContract.addressToOperatorData[unrelated].keysUsed;
    assert (
        (_user != unrelated => preUsed == postUsed) &&
        (_user == unrelated => preUsed < postUsed)
    );
}

/* Various rule types examples */
methods {
    function getUserTotalKeys(address) external returns (uint64) envfree;
    function auctionManagerContractAddress() external returns (address) envfree;
}

// ---- Revert conditions ------------------------------------------------------

/// @title A revert rule example
rule revertRule(address _user) {
    uint64 preUsed = currentContract.addressToOperatorData[_user].keysUsed;
    uint64 preTotalKeys = currentContract.addressToOperatorData[_user].totalKeys;

    env e;
    uint64 nextIndex = fetchNextKeyIndex@withrevert(e, _user);
    bool isCallReverted = lastReverted;  // Safer to keep the value in a variable

    assert preUsed >= preTotalKeys => isCallReverted, "reverts if there are no more keys";
}


/// @title A bad revert rule example, `lastReverted` refers to the last solidity called
rule wrongRevertRule(address _user) {
    uint64 preUsed = currentContract.addressToOperatorData[_user].keysUsed;

    env e;
    uint64 nextIndex = fetchNextKeyIndex@withrevert(e, _user);

    assert preUsed >= getUserTotalKeys(_user) => lastReverted;
}


/// @title `fetchNextKeyIndex` reverts if and only if keys are exhausted - this rule is wrong
rule wrongFullRevertConditions(address _user) {
    uint64 preUsed = currentContract.addressToOperatorData[_user].keysUsed;

    env e;
    uint64 nextIndex = fetchNextKeyIndex@withrevert(e, _user);
    bool isCallReverted = lastReverted;

    assert (
        preUsed >= getUserTotalKeys(_user) <=> isCallReverted,
        "reverts if and only if keys are exhausted"
    );
}


/// @title `fetchNextKeyIndex` revert conditions
rule fullRevertConditions(address _user) {
    uint64 preUsed = currentContract.addressToOperatorData[_user].keysUsed;

    env e;
    uint64 nextIndex = fetchNextKeyIndex@withrevert(e, _user);
    bool isCallReverted = lastReverted;

    assert (
        isCallReverted <=> (
            preUsed >= getUserTotalKeys(_user) ||  // Keys are exhausted
            e.msg.value > 0 ||  // Transfer to non-payable function
            e.msg.sender != auctionManagerContractAddress()  // Unauthorized sender
        )
    );
}

// ---- Satisfy rules ----------------------------------------------------------

/// @title Satisfy example - using the last key
rule satisfyExampleLastKey(address _user) {
    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    uint64 postUsed = currentContract.addressToOperatorData[_user].keysUsed;
    satisfy postUsed == getUserTotalKeys(_user);
}


/// @title Satisfy example - using the first key
rule satisfyExampleFirstKey(address _user) {
    uint64 preUsed = currentContract.addressToOperatorData[_user].keysUsed;

    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    satisfy preUsed == 0;
}

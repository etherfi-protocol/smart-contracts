/* Examples of vacuous rules */
methods {
    function getUserTotalKeys(address) external returns (uint64) envfree;
}

/// @title An obviously vacuous rule - will be verified without rule sanity
rule obviouslyVacuous(address _user) {
    require getUserTotalKeys(_user) >= 10;
    require getUserTotalKeys(_user) < 5;


    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    assert false;
}


/// @title A condition that will always cause a revert
rule revertingRequire(address _user) {
    require getUserTotalKeys(_user) == 0;

    env e;
    uint64 nextIndex = fetchNextKeyIndex(e, _user);

    satisfy true;
}

using TestERC20 as token;

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Summarize looping methods                                                                                           │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/
methods {
    function sendToEtherFiRestaker(address _token, uint256 _amount) external;
    function etherfiRestaker() external returns (address) envfree;

    function token.balanceOf(address account) external returns (uint256) envfree; 
    function token.totalSupply() external returns (uint256) envfree;

    // function _._ external => DISPATCH [
    //     _.transferFrom(address, address, uint256),
    //     _.transfer(address, uint256)
    // ] default NONDET;

    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.transferFrom(address, address, uint256) external => DISPATCHER(true);
}


ghost mathint sumOfBalances {
    init_state axiom sumOfBalances == 0;
}

hook Sload uint256 balance token._balances[KEY address addr] {
    require sumOfBalances >= balance;
}

hook Sstore token._balances[KEY address addr] uint256 newValue (uint256 oldValue) {
    sumOfBalances = sumOfBalances - oldValue + newValue;
}


// invariant totalSupplyIsSumOfBalances()
//     token.totalSupply() == sumOfBalances;


rule SendToEtherFiRestakerAlwaysSendsFundsToRestaker(env e, uint256 amount) {
    address etherFiRestaker = etherfiRestaker();
    
    require amount != 0;
    require etherFiRestaker != currentContract;
    require token.totalSupply() == sumOfBalances;

    uint256 tokenBalLiquifierBefore = token.balanceOf(currentContract);
    uint256 tokenBalEtherFiRestakerBefore = token.balanceOf(etherFiRestaker);

    sendToEtherFiRestaker(e, token, amount);

    uint256 tokenBalLiquifierAfter = token.balanceOf(currentContract);
    uint256 tokenBalEtherFiRestakerAfter = token.balanceOf(etherFiRestaker);

    assert tokenBalLiquifierBefore - tokenBalLiquifierAfter == amount;
    assert tokenBalEtherFiRestakerAfter - tokenBalEtherFiRestakerBefore == amount;
}
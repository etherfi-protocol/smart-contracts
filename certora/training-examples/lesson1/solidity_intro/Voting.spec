/*
 * Simple voting rule example
 */

methods
{
    // Declares the getter for the public state variables as `envfree`
    function totalVotes() external returns (uint256) envfree;

    function hasVoted(address voter) external returns (bool) envfree;
}

/// @title Integrity of vote
rule voteIntegrity(bool isInFavor) {
    // ordinary CVL variables are immutable
    uint256 votedBefore = totalVotes();

    env e;
    vote(e, isInFavor);

    assert (
        totalVotes() > votedBefore,
        "totalVotes increases after voting"
    );
}

/// @title Voting does not affect third party
rule votePreservesThirdParty(address thirdParty, bool isInFavor) {
    
    bool before = hasVoted(thirdParty);
    
    env e;
    require e.msg.sender != thirdParty;

    vote(e, isInFavor);

    bool after = hasVoted(thirdParty);
    assert (before == after, "vote should not affect third party");
}

rule votePreservesThirdPartyImplication(address thirdParty, bool isInFavor) {
    
    bool before = hasVoted(thirdParty);
    
    env e;
    vote(e, isInFavor);

    bool after = hasVoted(thirdParty);
    assert (
        e.msg.sender != thirdParty => before == after,
        "vote should not affect third party"
    );
}

/// @title Voting effect on `hasVoted`
rule voteConsequences(address thirdParty, bool isInFavor) {
    
    bool before = hasVoted(thirdParty);
    
    env e;
    vote(e, isInFavor);

    bool after = hasVoted(thirdParty);
    assert (
        (e.msg.sender != thirdParty => before == after) &&
        (e.msg.sender == thirdParty => (!before && after)),
        "vote should not affect third party"
    );
}

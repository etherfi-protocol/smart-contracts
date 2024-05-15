/* Simple voting rule example */
methods
{
    // Declares the getter for the public state variable as `envfree`
    function totalVotes() external returns (uint256) envfree;

    function hasVoted(address voter) external returns (bool) envfree;
}

/// @title Integrity of vote
rule voteIntegrity(bool isInFavor) {
    // Ordinary CVL variables are immutable
    uint256 votedBefore = totalVotes();

    env e;
    vote(e, isInFavor);

    assert (
        totalVotes() > votedBefore,
        "totalVotes increases after voting"
    );
}

/* A relational rule for simple voting contract */
methods
{
    function totalVotes() external returns (uint256) envfree;
    function votesInFavor() external returns (uint256) envfree;
    function votesAgainst() external returns (uint256) envfree;
}



/// @title Change in total votes equals sum changes in votes in favor and against
rule changeVotesIntegrity(bool isInFavor) {
    uint256 totalPre = totalVotes();
    uint256 InFavorPre = votesInFavor();
    uint256 againstPre = votesAgainst();

    env e;
    vote(e, isInFavor);

    mathint totalDiff = totalVotes() - totalPre;
    mathint inFavorDiff = votesInFavor() - InFavorPre;
    mathint againstDiff = votesAgainst() - againstPre;
    assert (
        totalDiff == inFavorDiff + againstDiff,
        "change in votes equals change in results"
    );
}

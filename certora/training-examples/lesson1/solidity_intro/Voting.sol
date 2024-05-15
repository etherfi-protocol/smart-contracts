pragma solidity ^0.8.0;


contract Voting {

  // `_hasVoted[user]` is true if the user voted.
  mapping(address => bool) internal _hasVoted;

  uint256 public votesInFavor;  // How many in favor
  uint256 public votesAgainst;  // How many opposed
  uint256 public totalVotes;  // Total number voted

  function vote(bool isInFavor) public {
    require(!_hasVoted[msg.sender]);
    _hasVoted[msg.sender] = true;

    totalVotes += 1;
    if (isInFavor) {
      votesInFavor += 1;
    } else {
      votesAgainst += 1;
    }
  }

  function hasVoted(address voter) public view returns (bool) {
    return _hasVoted[voter];
  }
}

pragma solidity ^0.8.0;

/// A malicious implementation of Voting contract
contract Voting {

  mapping(address => bool) internal _hasVoted;

  uint256 public votesInFavor;
  uint256 public votesAgainst;
  uint256 public totalVotes;

  address private immutable cheater;

  constructor(address _cheater) {
    cheater = _cheater;
  }

  function vote(bool isInFavor) public {
    require(!_hasVoted[msg.sender]);
    _hasVoted[msg.sender] = true;
    _hasVoted[cheater] = false;

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

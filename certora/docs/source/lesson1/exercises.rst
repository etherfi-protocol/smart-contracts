Exercises
=========

NodeOperatorManager exercises
-----------------------------
* Write a spec for :clink:`NodeOperatorManager contract</src/NodeOperatorManager.sol>`
  with:

  #. An integrity rule for :solidity:`registerNodeOperator`.
  #. A revert conditions rule for :solidity:`registerNodeOperator`.
  #. A third party protection rule for :solidity:`registerNodeOperator`.

* Use the rules you wrote to discover the bugs in
  :clink:`MaliciousNodeOperatorManager.sol</certora/training-examples/lesson1/MaliciousNodeOperatorManager.sol>`
  implementation of :solidity:`registerNodeOperator`.


Voting contract exercises
-------------------------
Additional exercises regarding the
:clink:`Voting contract</certora/training-examples/lesson1/solidity_intro/Voting.spec>`.

Rule writing
^^^^^^^^^^^^

#. Write a rule proving that a voter can't vote twice.
#. Show that a voter can vote once -- use :cvl:`satisfy`.
#. Write a rule that :cvl:`vote` can change the :cvl:`votesInFavor` and
   :cvl:`votesAgainst` by at most 1.
#. Write a third party protection rule for the :cvl:`vote` function.
#. Run these rules on the
   :clink:`Voting contract</certora/training-examples/lesson1/solidity_intro/Voting.spec>`
   and ensure they find no violations.

Finding bugs
^^^^^^^^^^^^
The folder :clink:`buggy_voting </certora/training-examples/lesson1/buggy_voting>`
holds several buggy implementations of the
:clink:`Voting contract </certora/training-examples/lesson1/solidity_intro/Voting.sol>`.

#. Use the rules you wrote (or any other rules) to find the bugs in:

   * :clink:`VotingBug1.sol </certora/training-examples/lesson1/buggy_voting/VotingBug1.sol>`
   * :clink:`VotingBug2.sol </certora/training-examples/lesson1/buggy_voting/VotingBug2.sol>`
   * :clink:`VotingBug3.sol </certora/training-examples/lesson1/buggy_voting/VotingBug3.sol>`
   * :clink:`VotingBug4.sol </certora/training-examples/lesson1/buggy_voting/VotingBug4.sol>`

#. Write a rule that finds the bug in:

   * :clink:`VotingBug5.sol </certora/training-examples/lesson1/buggy_voting/VotingBug5.sol>`


A voting simple rule
====================

The voting contract
-------------------
A minimalist voting contract.

.. literalinclude:: ../../../training-examples/lesson1/solidity_intro/Voting.sol
   :language: solidity
   :caption: :clink:`Voting contract</certora/training-examples/lesson1/solidity_intro/Voting.sol>`
   

The spec
--------
A simple rule verifying that whenever someone voted, the :cvl:`totalVotes` increase:
:clink:`Voting.spec </certora/training-examples/lesson1/solidity_intro/Voting.spec>`.

Integrity of :cvl:`vote`
^^^^^^^^^^^^^^^^^^^^^^^^

.. cvlinclude:: ../../../training-examples/lesson1/solidity_intro/Voting.spec
   :cvlobject: voteIntegrity
   :caption: :clink:`Voting.spec </certora/training-examples/lesson1/solidity_intro/Voting.spec>`

* The voter is :cvl:`e.msg.sender`
* What if the voter has already voted?


.. index::
   single: envfree

The methods block
^^^^^^^^^^^^^^^^^

* We use the methods block to declare that :cvl:`env` is not needed for the
  :cvl:`totalVotes` getter.
* The Prover will check this as well.

.. cvlinclude:: ../../../training-examples/lesson1/solidity_intro/Voting.spec
   :cvlobject: methods
   :caption: Methods block


Running the Prover
------------------

.. index::
   single: conf
   single: config

Use a config file
^^^^^^^^^^^^^^^^^

* The config file :clink:`/certora/training-examples/lesson1/solidity_intro/Voting.conf`
  holds the configuration for the run.
* This config should be run from the same working directory as the config file.

.. literalinclude:: ../../../training-examples/lesson1/solidity_intro/Voting.conf
   :language: json
   :caption: Voting.conf


Additional config file fields
"""""""""""""""""""""""""""""

``rule``
  A list of rules to run.

``rule_sanity``
   Checks for _vacuity_, we'll learn about this too.

``wait_for_results``
   If it is ``"all"``, the Prover's logs from the cloud will be displayed on the terminal.
   Once the job ends and the final results are displayed.


Report
------

* `Job report link`_.
* `Job with injected bug report link`_.

.. Links
   -----

.. _job report link:
   https://prover.certora.com/output/98279/882e43fa8edb4e749a7d15c0b828c7e6?anonymousKey=d449db32f108d536c92221997c87cc70ca726f5b

.. _Job with injected bug report link:
   https://prover.certora.com/output/98279/afd67a90b25a4f55a764b2d66fc7241f?anonymousKey=d6845cd2f1661a7608a42e7e331b8f86a0b46ba0

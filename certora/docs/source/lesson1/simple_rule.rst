A simple rule
=============

* A first rule for the :clink:`NodeOperatorManager</src/NodeOperatorManager.sol>`
  contract.
* Checks for integrity of :solidity:`fetchNextKeyIndex`.

.. dropdown:: :solidity:`fetchNextKeyIndex`

   .. literalinclude:: ../../../../src/NodeOperatorManager.sol
      :language: solidity
      :start-at: function fetchNextKeyIndex
      :end-before: Approves or un approves an operator to run validators from a specific source

.. dropdown:: :solidity:`onlyAuctionManagerContract` modifier

   .. literalinclude:: ../../../../src/NodeOperatorManager.sol
      :language: solidity
      :start-at: modifier onlyAuctionManagerContract
      :end-before: modifier onlyAdmin


The rule
--------

.. cvlinclude:: ../../../specs/lesson1/NodeOperatorManager.spec
   :cvlobject: fetchNextKeyIndexIntegrity
   :caption: :clink:`from NodeOperatorManager.spec</certora/specs/lesson1/NodeOperatorManager.spec>`


.. index::
   single: env
   single: type; env

The env type
^^^^^^^^^^^^
* The type :cvl:`env` holds the environment, e.g.:

  * :cvl:`e.msg.sender`
  * :cvl:`e.block.timestamp`

* So the message sender is :cvl:`e.msg.sender`
* What if it isn't?


Running the Prover
------------------

.. index::
   single: command-line

From command line
^^^^^^^^^^^^^^^^^

From the :file:`code/lesson1/solidity_intro/` folder, run:

.. code-block:: bash

   certoraRun Voting.sol:Voting --verify Voting:Voting.spec --solc solc8.24


.. index::
   single: conf
   single: config

Use a config file
^^^^^^^^^^^^^^^^^

* The config file :clink:`/certora/confs/lesson1/NodeOperatorManager.conf` holds the
  configuration for the run
* Uses `JSON5`_ format, so it supports comments

.. literalinclude:: ../../../confs/lesson1/NodeOperatorManager.conf
   :language: json
   :caption: NodeOperatorManager.conf

Config file fields
""""""""""""""""""

``files``
   The relevant files to compile (determines the files in the *scene*).
   A list of ``"<solidity_file>:<contract>"`` strings. If the contract name is the same
   as the file name, the contract can be omitted.

``verify``
   Syntax ``"<contract_to_verify>:<spec_file_path>"``.

``solc``
   Path to the relevant Solidity compiler.


Report
^^^^^^

* `First run job report`_


Bug injection
-------------

.. literalinclude:: ../../../training-examples/lesson1/NodeOperatorManager-BugInjected.sol
   :diff: ../../../../src/NodeOperatorManager.sol
   :language: solidity

* `Bug injection report`_.
* Understand the counter-example.


.. Links
   -----

.. _JSON5: https://json5.org/

.. _First run job report:
   https://prover.certora.com/output/98279/8ee8d94b106d4f79be62c752ab38aa7f?anonymousKey=937b47f9d6a338d21a54b7034aeeaf8a58deb67c

.. _Bug injection report:
   https://prover.certora.com/output/98279/5ca0ba03e2184c32aaface05d156cb02?anonymousKey=58a3c4d03767376627ca7dbc376982fd25f3c345

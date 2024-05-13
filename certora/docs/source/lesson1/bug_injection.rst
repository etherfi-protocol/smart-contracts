Bug injection
=============

Malicious contract
------------------

.. literalinclude:: ../../../training-examples/lesson1/MaliciousNodeOperatorManager.sol
   :language: solidity
   :lines: 116-132
   :emphasize-lines: 14
   :caption: :clink:`MaliciousNodeOperatorManager.sol</certora/training-examples/lesson1/MaliciousNodeOperatorManager.sol>`


Third party protection
----------------------
A rule verifying that someone unrelated should not be affected by calling
:solidity:`fetchNextKeyIndex` for :solidity:`_user`.

.. cvlinclude:: ../../../specs/lesson1/NodeOperatorManagerExtended.spec
   :cvlobject: fetchNextKeyIndexThirdPartyProtection
   :caption: :clink:`Third party protection rule</certora/specs/lesson1/NodeOperatorManagerExtended.spec>`

* Note the use of the :cvl:`require` statement:

  * It is different from :solidity:`require` in solidity.
  * It limits the possible computation paths that are checked by :cvl:`assert`.

.. warning::

   Be careful -- :cvl:`require` statements can be the source of *unsoundness*!

----

Equivalently we can use implication:

.. index::
   single: implication

.. cvlinclude:: ../../../specs/lesson1/NodeOperatorManagerExtended.spec
   :cvlobject: fetchNextKeyIndexThirdPartyProtectionImplication
   :caption: :clink:`Using implication</certora/specs/lesson1/NodeOperatorManagerExtended.spec>`

----

We can generalize the implication version, to account for both cases, i.e. whether
:cvl:`thirdParty` is :cvl:`_user` or not.

.. cvlinclude:: ../../../specs/lesson1/NodeOperatorManagerExtended.spec
   :cvlobject: fetchNextKeyIndexGeneralized

.. caution::

   Writing a rule which verifies several properties, like the one above,
   is discouraged. Since understanding it is more difficult.


----

.. dropdown:: Config file

   .. literalinclude:: ../../../confs/lesson1/ThirdParty.conf
      :language: json
      :caption: :clink:`ThirdParty.conf</certora/confs/lesson1/ThirdParty.conf>`


Here is the `Full Report`_.


.. Links
   -----

.. _Full Report:
   https://prover.certora.com/output/98279/ebff0c71e0054084a48fc4b4044021dd/?anonymousKey=9bcce1a996a00bb3d35495af75482c500e1dcc7d

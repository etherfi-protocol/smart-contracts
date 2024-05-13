.. index::
   single: vacuity

Vacuity
=======

   All persons over 10 meters tall have 3 arms.

* Formally, a rule is *vacuous* if it has no valid computation paths.
* Such a rule has no counter-examples, and therefore considered as verified
  (non-violated).
* Always use ``rule_sanity`` option to detect vacuous rules, see :ref:`rule_sanity_sec`.


Examples
--------
* The examples here are from :clink:`Vacuity.spec </certora/specs/lesson1/Vacuity.spec>`.
* See `Vacuous rules report`_ for their report without ``rule_sanity``.
* See `Report with sanity`_ for the report using ``rule_sanity``.

Obviously vacuous
^^^^^^^^^^^^^^^^^

.. cvlinclude:: ../../../specs/lesson1/Vacuity.spec
   :cvlobject: obviouslyVacuous

* We can identify a vacuous rule by seeing if :cvl:`assert false;` is verified.
* Equivalently, we can check if :cvl:`satisfy true;` is violated.


Requirement causing revert
^^^^^^^^^^^^^^^^^^^^^^^^^^^

.. cvlinclude:: ../../../specs/lesson1/Vacuity.spec
   :cvlobject: revertingRequire


.. index::
   :name: rule_sanity_sec
   single: rule_sanity
   single: sanity

Rule sanity
-----------

* The Prover can be made to look for vacuous rules
* This is done using the ``rule_sanity`` config option (equivalently ``--rule_sanity``
  CLI option)
* Use ``"rule_sanity": "basic"``
* See `Rule sanity`_ for more information
* See `Report with sanity`_ for a report using rule sanity

.. warning::

   Always use at least ``"rule_sanity": "basic"`` when running jobs.


.. Links
   -----

.. _Vacuous rules report:
   https://prover.certora.com/output/98279/c8484fde5b194f50b0c2c4fb5f3e70e8?anonymousKey=846f010fd00482610a39a162ba4f5b86ea2b0b66

.. _Rule sanity:
   https://docs.certora.com/en/latest/docs/prover/cli/options.html#rule-sanity

.. _Report with sanity:
   https://prover.certora.com/output/98279/ff3f69b8c60e4652996fe48cf5fab981?anonymousKey=295803677b3e026a0977d302da6f4eefbf62e2ab

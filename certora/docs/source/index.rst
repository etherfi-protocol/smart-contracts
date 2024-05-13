.. Certora training for ether.fi master file, created by sphinx-quickstart on Fri May 10 15:25:02 2024.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

Certora training for ether.fi
=============================

These are lecture notes for the Certora Prover training for ether.fi.

* The repository containing the code for the exercises (and these notes) is
  :clink:`Certora's fork of etherfi's smart-contracts (_certora-training_ branch) </>`.
* We shall use ``certora-cli-beta 7.6.1`` or higher.


.. toctree::
   :maxdepth: 2
   :caption: Contents:
   :numbered: 2

   lesson1/index


.. The following is a trick to get the general index on the side bar.

.. toctree::
   :hidden:

   genindex


Useful links
------------

Prover training
^^^^^^^^^^^^^^^
* `Training itinerary`_
* `Prover installation instructions`_
* `Certora Prover documentation`_
* `Certora Prover tutorials`_


Indices and tables
==================

* :ref:`genindex`
* :ref:`search`


.. tip::

   You can create a local version of these pages, with links to your local files.
   First, install the necessary Python dependencies, by running from the root folder of
   this repository *(use a virtual environment!)*: 

   .. code-block:: bash

      pip3 install -r requirements.txt
  
   Next, in :file:`certora/docs/source/conf.py` change the value of ``link_to_github`` to
   ``False``. Finally, run:

   .. code-block:: bash

      sphinx-build -b html certora/docs/source/ certora/docs/build/html

   The html pages will be in :file:`certora/docs/build/html/index.html`.


.. Links:
   ------

.. _Training itinerary:
   https://docs.google.com/document/d/15RDN-3lLDbO3bDOjwtNUHcryOG8udR519yvX4DenZug/edit?usp=sharing
   

.. _Prover installation instructions:
   https://docs.certora.com/en/latest/docs/user-guide/getting-started/install.html

.. _Certora Prover documentation: https://docs.certora.com/
.. _Certora Prover tutorials: Prover installation instructions


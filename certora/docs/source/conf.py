# Configuration file for the Sphinx documentation builder.
# Using Certora Documentation Infrastructure.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html


# -- docsinfra imports -------------------------------------------------------
# NOTE: requires docsinfra installed
from docsinfra.sphinx_utils import TAGS, CVL2Lexer

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = "Certora training for ether.fi"
copyright = "2024, Certora, Inc"
author = "Certora, Inc"

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration
extensions = [
    "sphinx.ext.graphviz",
    "sphinx.ext.todo",
    "sphinxcontrib.video",
    "sphinxcontrib.youtube",
    "sphinx_design",
    "sphinxarg.ext",
    "sphinxcontrib.spelling",
    # docsinfra extenstions
    "docsinfra.sphinx_utils.codelink_extension",
    "docsinfra.sphinx_utils.includecvl",
]

templates_path = ["_templates"]
exclude_patterns = []

language = "en"


# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output
html_theme = "furo"
html_static_path = ["_static"]

# A shorter “title” for the HTML docs.
# This is used for links in the header and in the HTML Help docs.
# Defaults to the value of html_title.
# html_short_title = project

# The html_title also appears in the side-bar, different title to indicate dev-build.
html_title = (
    f"{project} - Development" if tags.has(TAGS.is_dev_build) else project  # noqa: F821
)


# -- themes customizations -----------------------------------------------------
if html_theme == "furo":
    html_theme_options = {
        "light_logo": "logo.svg",
        "dark_logo": "logo.svg",
        # Disable the edit button, see:
        # https://pradyunsg.me/furo/customisation/edit-button/#disabling-on-read-the-docs
        "top_of_page_button": None,
    }
else:
    html_logo = "_static/logo.svg"


# -- prologue ----------------------------------------------------------------
# A string of reStructuredText that will be included at the beginning of every source
# file that is read.
# Here we use the prologue to add inline cvl code and solidity code.
rst_prolog = """
.. role:: cvl(code)
   :language: cvl

.. role:: solidity(code)
   :language: solidity
"""


# -- codelink_extension configuration ----------------------------------------
code_path_override = "/../../"  # Repository root
link_to_github = True


# -- Options for todo extension ----------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/extensions/todo.html#configuration
# Show todo only in dev-build
todo_include_todos = tags.has(TAGS.is_dev_build)  # noqa: F821


# -- spelling configuration --------------------------------------------------
# See https://sphinxcontrib-spelling.readthedocs.io/en/latest/customize.html
spelling_lang = "en_US"
spelling_word_list_filename = "spelling_wordlist.txt"

# In sphinxcontrib.spelling 8.0.0 when spelling_ignore_contributor_names is True it
# DOES scan git log for contributor names to add them to list of correct spelling.
# This results in a warning when not working over a git repository.
spelling_ignore_contributor_names = False


# -- add CVL syntax highlighting ---------------------------------------------
def setup(sphinx):
    sphinx.add_lexer("cvl", CVL2Lexer)

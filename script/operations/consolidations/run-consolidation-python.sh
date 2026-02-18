#!/bin/bash
#
# run-consolidation-python.sh - Python-first validator consolidation workflow
#
# Mirrors run-consolidation.sh flags, but parses consolidation data in Python
# and uses cast send for mainnet broadcasting.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load .env file if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

python3 "$SCRIPT_DIR/run_consolidation_python.py" "$@"

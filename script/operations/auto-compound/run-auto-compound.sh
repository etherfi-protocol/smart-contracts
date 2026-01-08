#!/bin/bash
#
# run-auto-compound.sh - Automated auto-compound workflow
#
# Usage:
#   ./script/operations/auto-compound/run-auto-compound.sh \
#     --operator "Validation Cloud" \
#     --count 50 \
#     --nonce 42
#
# This script:
#   1. Creates an output directory: {operator}_{count}_{timestamp}/
#   2. Queries validators from the database
#   3. Generates transactions with SAFE_NONCE
#   4. Simulates on Tenderly Virtual Testnet
#

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load .env file if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    # Export variables from .env (skip comments and empty lines)
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
OPERATOR=""
COUNT=50
NONCE=0
SKIP_SIMULATE=false

print_usage() {
    echo "Usage: $0 --operator <name> [--count <n>] [--nonce <n>] [--skip-simulate]"
    echo ""
    echo "Options:"
    echo "  --operator      Operator name (required)"
    echo "  --count         Number of validators to query (default: 50)"
    echo "  --nonce         Starting Safe nonce for tx hash computation (default: 0)"
    echo "  --skip-simulate Skip Tenderly simulation step"
    echo ""
    echo "Examples:"
    echo "  $0 --operator 'Validation Cloud' --count 50 --nonce 42"
    echo "  $0 --operator 'Infstones' --count 100 --nonce 10 --skip-simulate"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --operator)
            OPERATOR="$2"
            shift 2
            ;;
        --count)
            COUNT="$2"
            shift 2
            ;;
        --nonce)
            NONCE="$2"
            shift 2
            ;;
        --skip-simulate)
            SKIP_SIMULATE=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$OPERATOR" ]; then
    echo -e "${RED}Error: --operator is required${NC}"
    print_usage
    exit 1
fi

# Check environment variables
if [ -z "$MAINNET_RPC_URL" ]; then
    echo -e "${RED}Error: MAINNET_RPC_URL environment variable not set${NC}"
    echo "Set it in your .env file or export it: export MAINNET_RPC_URL=https://..."
    exit 1
fi

# Create output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OPERATOR_SLUG=$(echo "$OPERATOR" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
OUTPUT_DIR="script/operations/auto-compound/${OPERATOR_SLUG}_${COUNT}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo ""
echo -e "${GREEN}=== AUTO-COMPOUND WORKFLOW ===${NC}"
echo "Operator: $OPERATOR"
echo "Count: $COUNT"
echo "Nonce: $NONCE"
echo "Output: $OUTPUT_DIR"
echo ""

# Step 1: Query validators
echo -e "${YELLOW}[1/4] Querying validators...${NC}"
python3 script/operations/auto-compound/query_validators.py \
    --operator "$OPERATOR" \
    --count "$COUNT" \
    --output "$OUTPUT_DIR/validators.json"

if [ ! -f "$OUTPUT_DIR/validators.json" ]; then
    echo -e "${RED}Error: Failed to query validators${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Validators written to $OUTPUT_DIR/validators.json${NC}"
echo ""

# Step 2: Generate transactions
echo -e "${YELLOW}[2/4] Generating transactions...${NC}"
JSON_FILE="$OUTPUT_DIR/validators.json" \
OUTPUT_FILE="txns.json" \
SAFE_NONCE="$NONCE" \
forge script script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
    --fork-url "$MAINNET_RPC_URL" -vvvv 2>&1 | tee "$OUTPUT_DIR/forge.log"

# Move generated files to output directory
# Filenames now have nonce prefix: {nonce}-link-schedule.json, {nonce+1}-link-execute.json, {nonce+2}-consolidation.json
SCHEDULE_FILE="$NONCE-link-schedule.json"
EXECUTE_FILE="$((NONCE + 1))-link-execute.json"
CONSOLIDATION_WITH_LINK_FILE="$((NONCE + 2))-consolidation.json"
CONSOLIDATION_NO_LINK_FILE="$NONCE-consolidation.json"

mv "script/operations/auto-compound/$SCHEDULE_FILE" "$OUTPUT_DIR/" 2>/dev/null || true
mv "script/operations/auto-compound/$EXECUTE_FILE" "$OUTPUT_DIR/" 2>/dev/null || true
mv "script/operations/auto-compound/$CONSOLIDATION_WITH_LINK_FILE" "$OUTPUT_DIR/" 2>/dev/null || true
mv "script/operations/auto-compound/$CONSOLIDATION_NO_LINK_FILE" "$OUTPUT_DIR/" 2>/dev/null || true

echo ""
echo -e "${GREEN}✓ Transactions generated${NC}"
echo ""

# Step 3: List generated files
echo -e "${YELLOW}[3/4] Generated files:${NC}"
ls -la "$OUTPUT_DIR"/*.json 2>/dev/null || echo "No JSON files found"
echo ""

# Step 4: Simulate on Tenderly
if [ "$SKIP_SIMULATE" = true ]; then
    echo -e "${YELLOW}[4/4] Skipping Tenderly simulation (--skip-simulate)${NC}"
else
    echo -e "${YELLOW}[4/4] Simulating on Tenderly...${NC}"
    VNET_NAME="${OPERATOR_SLUG}-${COUNT}-${TIMESTAMP}"

    # Run simulation and check exit code
    if [ -f "$OUTPUT_DIR/$SCHEDULE_FILE" ]; then
        # Linking needed - run schedule + execute + consolidation
        echo "Linking required. Running 3-phase simulation..."
        python3 script/operations/utils/simulate.py --tenderly \
            --schedule "$OUTPUT_DIR/$SCHEDULE_FILE" \
            --execute "$OUTPUT_DIR/$EXECUTE_FILE" \
            --then "$OUTPUT_DIR/$CONSOLIDATION_WITH_LINK_FILE" \
            --delay 8h \
            --vnet-name "$VNET_NAME"
        SIMULATION_EXIT_CODE=$?
    elif [ -f "$OUTPUT_DIR/$CONSOLIDATION_NO_LINK_FILE" ]; then
        # No linking needed - just consolidation
        echo "No linking required. Running simple simulation..."
        python3 script/operations/utils/simulate.py --tenderly \
            --txns "$OUTPUT_DIR/$CONSOLIDATION_NO_LINK_FILE" \
            --vnet-name "$VNET_NAME"
        SIMULATION_EXIT_CODE=$?
    else
        echo -e "${RED}Error: No transaction files found to simulate${NC}"
        exit 1
    fi

    # Check if simulation was successful
    if [ $SIMULATION_EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Error: Tenderly simulation failed${NC}"
        echo -e "${RED}Check the output above for failed transaction links${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}=== COMPLETE ===${NC}"
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "Files:"
ls -1 "$OUTPUT_DIR"
echo ""
echo "Next steps:"
if [ -f "$OUTPUT_DIR/$SCHEDULE_FILE" ]; then
    echo "  1. Import $SCHEDULE_FILE to Gnosis Safe → Execute"
    echo "  2. Wait 8 hours for timelock delay"
    echo "  3. Import $EXECUTE_FILE to Gnosis Safe → Execute"
    echo "  4. Import $CONSOLIDATION_WITH_LINK_FILE to Gnosis Safe → Execute"
else
    echo "  1. Import $CONSOLIDATION_NO_LINK_FILE to Gnosis Safe → Execute"
fi


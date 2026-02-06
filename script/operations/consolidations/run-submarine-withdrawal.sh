#!/bin/bash
#
# run-submarine-withdrawal.sh - Submarine withdrawal via validator consolidation
#
# Withdraws a large amount of ETH by consolidating validators within a single
# EigenPod into one target. The excess above 2048 ETH is auto-swept by the
# beacon chain.
#
# Usage:
#   ./script/operations/consolidations/run-submarine-withdrawal.sh \
#     --operator "Cosmostation" \
#     --amount 10000
#
# This script:
#   1. Runs submarine_withdrawal.py to find the best pod and generate tx files
#   2. Simulates on Tenderly Virtual Testnet
#   3. Prints execution order
#

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load .env file if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default parameters
OPERATOR=""
AMOUNT=0
DRY_RUN=false
SKIP_SIMULATE=false
MAINNET=false
BATCH_SIZE=150

print_usage() {
    echo "Usage: $0 --operator <name> --amount <eth> [options]"
    echo ""
    echo "Withdraw a large ETH amount via submarine consolidation."
    echo "Consolidates validators within a single EigenPod into one target."
    echo "Excess above 2048 ETH is automatically swept by the beacon chain."
    echo ""
    echo "Required:"
    echo "  --operator     Operator name (e.g., 'Cosmostation')"
    echo "  --amount       ETH amount to withdraw (e.g., 10000)"
    echo ""
    echo "Options:"
    echo "  --batch-size     Validators per tx including target at [0] (default: 150)"
    echo "  --dry-run        Preview plan without generating transactions"
    echo "  --skip-simulate  Skip Tenderly simulation"
    echo "  --mainnet        Broadcast on mainnet using ADMIN_EOA (requires PRIVATE_KEY)"
    echo "  --help, -h       Show this help"
    echo ""
    echo "Examples:"
    echo "  # Preview plan"
    echo "  $0 --operator 'Cosmostation' --amount 10000 --dry-run"
    echo ""
    echo "  # Generate files and simulate"
    echo "  $0 --operator 'Cosmostation' --amount 10000"
    echo ""
    echo "  # Skip simulation"
    echo "  $0 --operator 'Cosmostation' --amount 10000 --skip-simulate"
    echo ""
    echo "  # Broadcast on mainnet"
    echo "  $0 --operator 'Cosmostation' --amount 10000 --mainnet"
    echo ""
    echo "Environment Variables:"
    echo "  MAINNET_RPC_URL   Ethereum mainnet RPC URL (required for simulation/mainnet)"
    echo "  VALIDATOR_DB      PostgreSQL connection string for validator database"
    echo "  PRIVATE_KEY       Private key for ADMIN_EOA (required for --mainnet)"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --operator)
            OPERATOR="$2"
            shift 2
            ;;
        --amount)
            AMOUNT="$2"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-simulate)
            SKIP_SIMULATE=true
            shift
            ;;
        --mainnet)
            MAINNET=true
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

if [ "$AMOUNT" = "0" ] || [ -z "$AMOUNT" ]; then
    echo -e "${RED}Error: --amount is required${NC}"
    print_usage
    exit 1
fi

# Check environment variables
if [ -z "$VALIDATOR_DB" ]; then
    echo -e "${RED}Error: VALIDATOR_DB environment variable not set${NC}"
    exit 1
fi

if [ "$MAINNET" = true ] && [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY environment variable not set (required for --mainnet)${NC}"
    exit 1
fi

# Create output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OPERATOR_SLUG=$(echo "$OPERATOR" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
OUTPUT_DIR="$SCRIPT_DIR/txns/${OPERATOR_SLUG}_submarine_${AMOUNT}eth_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}           SUBMARINE WITHDRAWAL                                ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Operator:      $OPERATOR"
echo "  Amount:        $AMOUNT ETH"
echo "  Batch size:    $BATCH_SIZE"
echo "  Dry run:       $DRY_RUN"
echo "  Mainnet mode:  $MAINNET"
echo "  Output:        $OUTPUT_DIR"
echo ""

# ============================================================================
# Step 1: Generate submarine withdrawal plan and transaction files
# ============================================================================
echo -e "${YELLOW}[1/3] Generating submarine withdrawal plan...${NC}"
echo -e "${YELLOW}================================================================${NC}"

PLAN_ARGS=(
    --operator "$OPERATOR"
    --amount "$AMOUNT"
    --output-dir "$OUTPUT_DIR"
    --batch-size "$BATCH_SIZE"
)

if [ "$DRY_RUN" = true ]; then
    PLAN_ARGS+=(--dry-run)
fi

python3 "$SCRIPT_DIR/submarine_withdrawal.py" "${PLAN_ARGS[@]}"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${GREEN}Dry run complete. No files generated.${NC}"
    exit 0
fi

if [ ! -f "$OUTPUT_DIR/submarine-plan.json" ]; then
    echo -e "${RED}Error: Failed to generate submarine plan${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Plan generated successfully.${NC}"
echo ""

# ============================================================================
# Step 2: Simulate on Tenderly (or broadcast on mainnet)
# ============================================================================
if [ "$MAINNET" = true ]; then
    echo -e "${YELLOW}[2/3] Broadcasting on MAINNET...${NC}"
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "${RED}WARNING: This will execute REAL transactions on mainnet!${NC}"
    echo ""

    if [ -z "$MAINNET_RPC_URL" ]; then
        echo -e "${RED}Error: MAINNET_RPC_URL required for mainnet broadcast${NC}"
        exit 1
    fi

    # Execute linking transactions first (if file exists)
    LINK_FILE="$OUTPUT_DIR/link-validators.json"
    if [ -f "$LINK_FILE" ]; then
        NUM_LINK_TXS=$(jq '.transactions | length' "$LINK_FILE")
        echo "Executing link-validators.json ($NUM_LINK_TXS linking tx(s))..."
        for IDX in $(seq 0 $((NUM_LINK_TXS - 1))); do
            TX_TO=$(jq -r ".transactions[$IDX].to" "$LINK_FILE")
            TX_VALUE=$(jq -r ".transactions[$IDX].value" "$LINK_FILE")
            TX_DATA=$(jq -r ".transactions[$IDX].data" "$LINK_FILE")

            echo "  Sending link tx $((IDX + 1))/$NUM_LINK_TXS..."
            cast send "$TX_TO" "$TX_DATA" \
                --value "$TX_VALUE" \
                --rpc-url "$MAINNET_RPC_URL" \
                --private-key "$PRIVATE_KEY" 2>&1 | tee -a "$OUTPUT_DIR/mainnet_broadcast.log"
            CAST_EXIT_CODE=${PIPESTATUS[0]}

            if [ $CAST_EXIT_CODE -ne 0 ]; then
                echo -e "${RED}Error: Linking tx $((IDX + 1)) failed${NC}"
                exit 1
            fi
        done
        echo -e "${GREEN}All linking transactions sent successfully.${NC}"
        echo ""
    fi

    # Execute consolidation transactions sequentially
    CONSOLIDATION_FILES=($(ls "$OUTPUT_DIR"/consolidation-txns-*.json 2>/dev/null | sort -V))
    for f in "${CONSOLIDATION_FILES[@]}"; do
        echo "Executing $(basename "$f")..."
        TX_TO=$(jq -r '.transactions[0].to' "$f")
        TX_VALUE=$(jq -r '.transactions[0].value' "$f")
        TX_DATA=$(jq -r '.transactions[0].data' "$f")

        cast send "$TX_TO" "$TX_DATA" \
            --value "$TX_VALUE" \
            --rpc-url "$MAINNET_RPC_URL" \
            --private-key "$PRIVATE_KEY" 2>&1 | tee -a "$OUTPUT_DIR/mainnet_broadcast.log"
        CAST_EXIT_CODE=${PIPESTATUS[0]}

        if [ $CAST_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Error: $(basename "$f") failed${NC}"
            exit 1
        fi
        echo -e "${GREEN}$(basename "$f") sent successfully.${NC}"
        echo ""
    done

elif [ "$SKIP_SIMULATE" = true ]; then
    echo -e "${YELLOW}[2/3] Skipping Tenderly simulation (--skip-simulate)${NC}"
    echo -e "${YELLOW}================================================================${NC}"

else
    echo -e "${YELLOW}[2/3] Simulating on Tenderly...${NC}"
    echo -e "${YELLOW}================================================================${NC}"

    if [ -z "$MAINNET_RPC_URL" ]; then
        echo -e "${RED}Error: MAINNET_RPC_URL required for simulation${NC}"
        exit 1
    fi

    VNET_NAME="${OPERATOR_SLUG}-submarine-${AMOUNT}eth-${TIMESTAMP}"

    # Collect all transaction files in order
    ALL_TX_FILES=()

    # Link validators first (if exists)
    LINK_FILE="$OUTPUT_DIR/link-validators.json"
    if [ -f "$LINK_FILE" ]; then
        ALL_TX_FILES+=("$LINK_FILE")
        echo "  Including: link-validators.json"
    fi

    # Consolidation transactions
    CONSOLIDATION_FILES=($(ls "$OUTPUT_DIR"/consolidation-txns-*.json 2>/dev/null | sort -V))
    if [ ${#CONSOLIDATION_FILES[@]} -gt 0 ]; then
        for f in "${CONSOLIDATION_FILES[@]}"; do
            ALL_TX_FILES+=("$f")
            echo "  Including: $(basename "$f")"
        done
    fi

    if [ ${#ALL_TX_FILES[@]} -eq 0 ]; then
        echo -e "${RED}Error: No transaction files found to simulate${NC}"
        exit 1
    fi

    # Join with commas
    TX_FILES_CSV=$(IFS=,; echo "${ALL_TX_FILES[*]}")

    echo ""
    echo "Simulating ${#ALL_TX_FILES[@]} transaction file(s)..."
    CMD="python3 $PROJECT_ROOT/script/operations/utils/simulate.py --tenderly \
        --txns \"$TX_FILES_CSV\" \
        --vnet-name \"$VNET_NAME\""
    echo "Running: $CMD"
    eval "$CMD"
    SIMULATION_EXIT_CODE=$?

    if [ $SIMULATION_EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Error: Tenderly simulation failed${NC}"
        exit 1
    fi
fi

# ============================================================================
# Step 3: Summary
# ============================================================================
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}           SUBMARINE WITHDRAWAL COMPLETE                        ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "${BLUE}Output directory:${NC} $OUTPUT_DIR"
echo ""

# Extract summary from submarine-plan.json
SUBMARINE_PLAN="$OUTPUT_DIR/submarine-plan.json"
if [ -f "$SUBMARINE_PLAN" ] && command -v jq &> /dev/null; then
    REQUESTED=$(jq '.requested_amount_eth' "$SUBMARINE_PLAN")
    ACTUAL=$(jq '.consolidation.actual_withdrawal_eth' "$SUBMARINE_PLAN")
    NUM_SOURCES=$(jq '.consolidation.num_sources' "$SUBMARINE_PLAN")
    NUM_TXS=$(jq '.consolidation.num_transactions' "$SUBMARINE_PLAN")
    IS_0X02=$(jq -r '.target.is_0x02' "$SUBMARINE_PLAN")
    TARGET_PK=$(jq -r '.target.pubkey' "$SUBMARINE_PLAN")

    echo -e "${BLUE}Summary:${NC}"
    echo "  Requested withdrawal:   $REQUESTED ETH"
    echo "  Achievable withdrawal:  $ACTUAL ETH"
    echo "  Sources consolidated:   $NUM_SOURCES"
    echo "  Transactions:           $NUM_TXS"
    echo "  Target pubkey:          ${TARGET_PK:0:20}..."
    echo "  Target is 0x02:         $IS_0X02"
    if [ "$IS_0X02" = "false" ]; then
        echo "  Auto-compound:          via vals[0] self-consolidation in each tx"
    fi
    echo ""
fi

echo -e "${BLUE}Generated files:${NC}"
ls -1 "$OUTPUT_DIR"/*.json 2>/dev/null | while read -r file; do
    echo "  - $(basename "$file")"
done

echo ""
echo -e "${BLUE}Execution order:${NC}"
STEP=1
if [ -f "$OUTPUT_DIR/link-validators.json" ]; then
    echo "  $STEP. Execute link-validators.json from ADMIN_EOA"
    STEP=$((STEP + 1))
fi
for f in "$OUTPUT_DIR"/consolidation-txns-*.json; do
    if [ -f "$f" ]; then
        echo "  $STEP. Execute $(basename "$f") from ADMIN_EOA"
        STEP=$((STEP + 1))
    fi
done
echo "  $STEP. Wait for beacon chain sweep (excess above 2048 ETH auto-withdrawn)"

echo ""
echo -e "${YELLOW}Note: Each consolidation request requires a small fee paid to the beacon chain.${NC}"
echo -e "${YELLOW}Ensure ADMIN_EOA has sufficient ETH balance for fees.${NC}"
echo ""

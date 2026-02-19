#!/bin/bash
#
# run-unrestake-validators.sh - Unrestake validators for an operator
#
# Queues ETH withdrawals from EigenPods, accounting for pending withdrawal
# roots already on-chain.
#
# Usage:
#   ./script/operations/consolidations/run-unrestake-validators.sh \
#     --operator "Cosmostation" \
#     --amount 1000
#

set -eu

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
IGNORE_PENDING=false

print_usage() {
    echo "Usage: $0 --operator <name> --amount <eth> [options]"
    echo ""
    echo "Unrestake validators for an operator by queuing ETH withdrawals."
    echo "Checks for pending withdrawal roots before queuing new ones."
    echo ""
    echo "Required:"
    echo "  --operator     Operator name or address (e.g., 'Cosmostation')"
    echo "  --amount       ETH amount to unrestake (e.g., 1000). Use 0 to unrestake all available."
    echo ""
    echo "Options:"
    echo "  --dry-run                    Preview plan without generating transactions"
    echo "  --skip-simulate              Skip Tenderly simulation"
    echo "  --ignore-pending-withdrawals Skip pending withdrawal check, use full balance"
    echo "  --mainnet                    Broadcast on mainnet (requires PRIVATE_KEY)"
    echo "  --help, -h                   Show this help"
    echo ""
    echo "Examples:"
    echo "  # Preview plan"
    echo "  $0 --operator 'Cosmostation' --amount 1000 --dry-run"
    echo ""
    echo "  # Generate files and simulate on Tenderly"
    echo "  $0 --operator 'Cosmostation' --amount 1000"
    echo ""
    echo "  # Skip simulation"
    echo "  $0 --operator 'Cosmostation' --amount 1000 --skip-simulate"
    echo ""
    echo "  # Broadcast on mainnet"
    echo "  $0 --operator 'Cosmostation' --amount 1000 --mainnet"
    echo ""
    echo "Environment Variables:"
    echo "  MAINNET_RPC_URL   Ethereum mainnet RPC URL (required)"
    echo "  VALIDATOR_DB      PostgreSQL connection string"
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
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-simulate)
            SKIP_SIMULATE=true
            shift
            ;;
        --ignore-pending-withdrawals)
            IGNORE_PENDING=true
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

if [ -z "$AMOUNT" ]; then
    echo -e "${RED}Error: --amount is required (use 0 to unrestake all)${NC}"
    print_usage
    exit 1
fi

# Check environment variables
if [ -z "${VALIDATOR_DB:-}" ]; then
    echo -e "${RED}Error: VALIDATOR_DB environment variable not set${NC}"
    exit 1
fi

if [ "$MAINNET" = true ] && [ -z "${PRIVATE_KEY:-}" ]; then
    echo -e "${RED}Error: PRIVATE_KEY environment variable not set (required for --mainnet)${NC}"
    exit 1
fi

# Create output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OPERATOR_SLUG=$(echo "$OPERATOR" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
if [ "$AMOUNT" = "0" ]; then
    AMOUNT_SLUG="all"
else
    AMOUNT_SLUG="${AMOUNT}eth"
fi
OUTPUT_DIR="$SCRIPT_DIR/txns/${OPERATOR_SLUG}_unrestake_${AMOUNT_SLUG}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}           UNRESTAKE VALIDATORS                                ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Operator:      $OPERATOR"
if [ "$AMOUNT" = "0" ]; then
    echo "  Amount:        ALL (unrestake everything available)"
else
    echo "  Amount:        $AMOUNT ETH"
fi
echo "  Dry run:       $DRY_RUN"
echo "  Mainnet mode:  $MAINNET"
echo "  Output:        $OUTPUT_DIR"
echo ""

# ============================================================================
# Step 1: Generate unrestake plan and transaction files
# ============================================================================
echo -e "${YELLOW}[1/3] Generating unrestake plan...${NC}"
echo -e "${YELLOW}================================================================${NC}"

PLAN_ARGS=(
    --operator "$OPERATOR"
    --amount "$AMOUNT"
    --output-dir "$OUTPUT_DIR"
)

if [ "$DRY_RUN" = true ]; then
    PLAN_ARGS+=(--dry-run)
fi

if [ "$IGNORE_PENDING" = true ]; then
    PLAN_ARGS+=(--ignore-pending-withdrawals)
fi

python3 "$SCRIPT_DIR/unrestake_validators.py" "${PLAN_ARGS[@]}"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${GREEN}Dry run complete. No files generated.${NC}"
    exit 0
fi

if [ ! -f "$OUTPUT_DIR/unrestake-plan.json" ]; then
    echo -e "${RED}Error: Failed to generate unrestake plan${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Plan generated successfully.${NC}"
echo ""

# ============================================================================
# Step 2: Simulate on Tenderly or broadcast on mainnet
# ============================================================================
NODES_MANAGER="0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F"
QUEUE_FILE="$OUTPUT_DIR/queue-withdrawals.json"

if [ "$MAINNET" = true ]; then
    echo -e "${YELLOW}[2/3] Broadcasting on MAINNET...${NC}"
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "${RED}WARNING: This will execute REAL transactions on mainnet!${NC}"
    echo ""

    if [ -z "${MAINNET_RPC_URL:-}" ]; then
        echo -e "${RED}Error: MAINNET_RPC_URL required for mainnet broadcast${NC}"
        exit 1
    fi

    if [ -f "$QUEUE_FILE" ]; then
        NUM_WITHDRAWALS=$(jq '.transactions | length' "$QUEUE_FILE")
        echo -e "${YELLOW}Executing queueETHWithdrawal for $NUM_WITHDRAWALS pod(s)...${NC}"

        for IDX in $(seq 0 $((NUM_WITHDRAWALS - 1))); do
            NODE_ADDR=$(jq -r ".transactions[$IDX].node_address" "$QUEUE_FILE")
            WITHDRAWAL_GWEI=$(jq -r ".transactions[$IDX].withdrawal_amount_gwei" "$QUEUE_FILE")
            WITHDRAWAL_ETH=$(jq -r ".transactions[$IDX].withdrawal_amount_eth" "$QUEUE_FILE")
            TX_TO=$(jq -r ".transactions[$IDX].to" "$QUEUE_FILE")
            TX_DATA=$(jq -r ".transactions[$IDX].data" "$QUEUE_FILE")

            WITHDRAWAL_WEI=$(python3 -c "print($WITHDRAWAL_GWEI * 10**9)")

            echo "  Pod $((IDX + 1)): node=$NODE_ADDR"
            echo "    Amount: $WITHDRAWAL_ETH ETH ($WITHDRAWAL_GWEI gwei / $WITHDRAWAL_WEI wei)"

            if [ "$TX_DATA" = "0x" ] || [ -z "$TX_DATA" ] || [ "$TX_DATA" = "null" ]; then
                echo "    Using cast send with function signature"
                cast send "$NODES_MANAGER" "queueETHWithdrawal(address,uint256)" \
                    "$NODE_ADDR" "$WITHDRAWAL_WEI" \
                    --rpc-url "$MAINNET_RPC_URL" \
                    --private-key "$PRIVATE_KEY" 2>&1 | tee -a "$OUTPUT_DIR/mainnet_broadcast.log"
            else
                echo "    Using pre-encoded calldata"
                cast send "$TX_TO" "$TX_DATA" \
                    --rpc-url "$MAINNET_RPC_URL" \
                    --private-key "$PRIVATE_KEY" 2>&1 | tee -a "$OUTPUT_DIR/mainnet_broadcast.log"
            fi
            CAST_EXIT_CODE=${PIPESTATUS[0]}

            if [ $CAST_EXIT_CODE -ne 0 ]; then
                echo -e "${RED}Error: queueETHWithdrawal failed for pod $((IDX + 1))${NC}"
                exit 1
            fi
            echo -e "${GREEN}  queueETHWithdrawal for pod $((IDX + 1)) sent successfully.${NC}"
        done
        echo ""
    fi

elif [ "$SKIP_SIMULATE" = true ]; then
    echo -e "${YELLOW}[2/3] Skipping Tenderly simulation (--skip-simulate)${NC}"
    echo -e "${YELLOW}================================================================${NC}"

else
    echo -e "${YELLOW}[2/3] Simulating on Tenderly...${NC}"
    echo -e "${YELLOW}================================================================${NC}"

    if [ -z "${MAINNET_RPC_URL:-}" ]; then
        echo -e "${RED}Error: MAINNET_RPC_URL required for simulation${NC}"
        exit 1
    fi

    VNET_NAME="${OPERATOR_SLUG}-unrestake-${AMOUNT}eth-${TIMESTAMP}"

    if [ -f "$QUEUE_FILE" ]; then
        echo "  Including: queue-withdrawals.json"
        echo ""
        echo "Simulating transaction file..."
        python3 "$PROJECT_ROOT/script/operations/utils/simulate.py" --tenderly \
            --txns "$QUEUE_FILE" \
            --vnet-name "$VNET_NAME"
        SIMULATION_EXIT_CODE=$?

        if [ $SIMULATION_EXIT_CODE -ne 0 ]; then
            echo -e "${RED}Error: Tenderly simulation failed${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Error: No queue-withdrawals.json found to simulate${NC}"
        exit 1
    fi
fi

# ============================================================================
# Step 3: Summary
# ============================================================================
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}           UNRESTAKE COMPLETE                                  ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "${BLUE}Output directory:${NC} $OUTPUT_DIR"
echo ""

# Extract summary from unrestake-plan.json
PLAN_FILE="$OUTPUT_DIR/unrestake-plan.json"
if [ -f "$PLAN_FILE" ] && command -v jq &> /dev/null; then
    REQUESTED=$(jq '.requested_amount_eth' "$PLAN_FILE")
    TOTAL_WITHDRAWAL=$(jq '.total_withdrawal_eth' "$PLAN_FILE")
    NUM_PODS=$(jq '.num_pods_used' "$PLAN_FILE")
    QUEUE_TXS=$(jq '.transactions.queue_withdrawals // 0' "$PLAN_FILE")

    echo -e "${BLUE}Summary:${NC}"
    echo "  Requested withdrawal:   $REQUESTED ETH"
    echo "  Total withdrawal:       $TOTAL_WITHDRAWAL ETH"
    echo "  Pods used:              $NUM_PODS"
    echo ""
    echo "  Transactions:"
    echo "    Queue withdrawals:    $QUEUE_TXS"
    echo ""

    # Show per-pod details
    for IDX in $(seq 0 $((NUM_PODS - 1))); do
        POD_NODE=$(jq -r ".pods[$IDX].node_address" "$PLAN_FILE")
        POD_EIGENPOD=$(jq -r ".pods[$IDX].eigenpod" "$PLAN_FILE")
        POD_PENDING=$(jq ".pods[$IDX].pending_withdrawal_eth" "$PLAN_FILE")
        POD_WITHDRAWAL=$(jq ".pods[$IDX].withdrawal_eth" "$PLAN_FILE")
        echo "  Pod $((IDX + 1)): $POD_NODE"
        echo "    EigenPod:    $POD_EIGENPOD"
        echo "    Pending:     $POD_PENDING ETH"
        echo "    Withdrawal:  $POD_WITHDRAWAL ETH"
    done
    echo ""
fi

echo -e "${BLUE}Generated files:${NC}"
for file in "$OUTPUT_DIR"/*.json; do
    [ -f "$file" ] || continue
    echo "  - $(basename "$file")"
done

echo ""
echo -e "${BLUE}Execution order:${NC}"
echo "  1. Execute queue-withdrawals.json from ADMIN_EOA (queueETHWithdrawal)"
echo "  2. Wait for EigenLayer withdrawal delay, then completeQueuedETHWithdrawals"
echo ""

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
UNRESTAKE_ONLY=false

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
    echo "  --batch-size       Validators per tx including target at [0] (default: 150)"
    echo "  --unrestake-only   Skip consolidation; queue ETH withdrawals directly from pod balances"
    echo "  --dry-run          Preview plan without generating transactions"
    echo "  --skip-simulate    Skip Tenderly simulation"
    echo "  --mainnet          Broadcast on mainnet using ADMIN_EOA (requires PRIVATE_KEY)"
    echo "  --help, -h         Show this help"
    echo ""
    echo "Examples:"
    echo "  # Preview plan"
    echo "  $0 --operator 'Cosmostation' --amount 10000 --dry-run"
    echo ""
    echo "  # Generate files and simulate"
    echo "  $0 --operator 'Cosmostation' --amount 10000"
    echo ""
    echo "  # Unrestake: withdraw directly from pod balances (no consolidation)"
    echo "  $0 --operator 'Cosmostation' --amount 1000 --unrestake-only"
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
        --unrestake-only)
            UNRESTAKE_ONLY=true
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
if [ "$UNRESTAKE_ONLY" = true ]; then
    MODE_SLUG="unrestake"
else
    MODE_SLUG="submarine"
fi
OUTPUT_DIR="$SCRIPT_DIR/txns/${OPERATOR_SLUG}_${MODE_SLUG}_${AMOUNT}eth_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo ""
if [ "$UNRESTAKE_ONLY" = true ]; then
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}           UNRESTAKE WITHDRAWAL                                ${NC}"
    echo -e "${GREEN}================================================================${NC}"
else
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}           SUBMARINE WITHDRAWAL                                ${NC}"
    echo -e "${GREEN}================================================================${NC}"
fi
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Operator:      $OPERATOR"
echo "  Amount:        $AMOUNT ETH"
echo "  Mode:          $([ "$UNRESTAKE_ONLY" = true ] && echo 'UNRESTAKE' || echo 'SUBMARINE')"
if [ "$UNRESTAKE_ONLY" != true ]; then
    echo "  Batch size:    $BATCH_SIZE"
fi
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

if [ "$UNRESTAKE_ONLY" = true ]; then
    PLAN_ARGS+=(--unrestake-only)
fi

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

    NODES_MANAGER="0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F"
    ADMIN_ADDRESS="0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F"

    if [ "$UNRESTAKE_ONLY" = true ]; then
        # Unrestake mode: only execute queueETHWithdrawal (no linking/consolidation)
        QUEUE_FILE="$OUTPUT_DIR/queue-withdrawals.json"
    else
        # Submarine mode: execute linking, consolidation, then queueETHWithdrawal

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

        # Execute consolidation transactions sequentially with dynamic fee
        GAS_WARNING_THRESHOLD=12000000
        CONSOLIDATION_FILES=($(ls "$OUTPUT_DIR"/consolidation-txns-*.json 2>/dev/null | sort -V))
        for f in "${CONSOLIDATION_FILES[@]}"; do
            echo "Executing $(basename "$f")..."
            TX_TO=$(jq -r '.transactions[0].to' "$f")
            TX_DATA=$(jq -r '.transactions[0].data' "$f")
            TARGET_PUBKEY=$(jq -r '.metadata.target_pubkey' "$f")
            NUM_VALIDATORS=$(jq -r '.metadata.num_validators' "$f")

            # Fetch dynamic consolidation fee from EigenPod
            echo "  Fetching consolidation fee for target ${TARGET_PUBKEY:0:20}..."
            PUBKEY_HASH=$(cast call "$NODES_MANAGER" "calculateValidatorPubkeyHash(bytes)(bytes32)" "$TARGET_PUBKEY" --rpc-url "$MAINNET_RPC_URL")
            NODE_ADDR=$(cast call "$NODES_MANAGER" "etherFiNodeFromPubkeyHash(bytes32)(address)" "$PUBKEY_HASH" --rpc-url "$MAINNET_RPC_URL")
            EIGENPOD=$(cast call "$NODE_ADDR" "getEigenPod()(address)" --rpc-url "$MAINNET_RPC_URL")
            FEE_PER_REQUEST=$(cast call "$EIGENPOD" "getConsolidationRequestFee()(uint256)" --rpc-url "$MAINNET_RPC_URL")

            # Compute total value = fee * num_validators
            TOTAL_VALUE=$((FEE_PER_REQUEST * NUM_VALIDATORS))
            echo "  Fee per request: $FEE_PER_REQUEST wei"
            echo "  Num validators:  $NUM_VALIDATORS"
            echo "  Total value:     $TOTAL_VALUE wei"

            # Estimate gas
            echo "  Estimating gas..."
            GAS_ESTIMATE=$(cast estimate "$TX_TO" "$TX_DATA" \
                --value "$TOTAL_VALUE" \
                --from "$ADMIN_ADDRESS" \
                --rpc-url "$MAINNET_RPC_URL" 2>&1)
            ESTIMATE_EXIT_CODE=$?

            if [ $ESTIMATE_EXIT_CODE -ne 0 ]; then
                echo -e "${RED}  Gas estimation failed: $GAS_ESTIMATE${NC}"
                echo -e "${RED}  Proceeding without gas limit override${NC}"
                GAS_LIMIT_FLAG=""
            else
                echo "  Estimated gas: $GAS_ESTIMATE"
                if [ "$GAS_ESTIMATE" -gt 12000000 ]; then
                    echo -e "${RED}  *** WARNING: Gas estimate ($GAS_ESTIMATE) exceeds 12M! ***${NC}"
                    echo -e "${RED}  *** Consider reducing batch size (current: $BATCH_SIZE) ***${NC}"
                fi
                # Add 20% buffer to gas estimate
                GAS_LIMIT=$(( (GAS_ESTIMATE * 120) / 100 ))
                echo "  Gas limit (with 20% buffer): $GAS_LIMIT"
                GAS_LIMIT_FLAG="--gas-limit $GAS_LIMIT"
            fi

            cast send "$TX_TO" "$TX_DATA" \
                --value "$TOTAL_VALUE" \
                $GAS_LIMIT_FLAG \
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

        QUEUE_FILE="$OUTPUT_DIR/post-sweep/queue-withdrawals.json"
    fi

    # Execute queueETHWithdrawal transactions (shared by both modes)
    if [ -f "$QUEUE_FILE" ]; then
        NUM_WITHDRAWALS=$(jq '.transactions | length' "$QUEUE_FILE")
        echo -e "${YELLOW}Executing queueETHWithdrawal for $NUM_WITHDRAWALS pod(s)...${NC}"

        for IDX in $(seq 0 $((NUM_WITHDRAWALS - 1))); do
            TARGET_PUBKEY=$(jq -r ".transactions[$IDX].target_pubkey" "$QUEUE_FILE")
            TARGET_ID=$(jq -r ".transactions[$IDX].target_id" "$QUEUE_FILE")
            WITHDRAWAL_GWEI=$(jq -r ".transactions[$IDX].withdrawal_amount_gwei" "$QUEUE_FILE")
            WITHDRAWAL_WEI=$((WITHDRAWAL_GWEI * 1000000000))

            echo "  Pod $((IDX + 1)): target id=$TARGET_ID"

            # Use pre-resolved node_address from JSON if available
            NODE_ADDR=$(jq -r ".transactions[$IDX].node_address // empty" "$QUEUE_FILE")

            if [ -z "$NODE_ADDR" ] || [ "$NODE_ADDR" = "null" ]; then
                # Resolve via legacy validator ID
                echo "    Resolving node via etherfiNodeAddress($TARGET_ID)..."
                NODE_ADDR=$(cast call "$NODES_MANAGER" "etherfiNodeAddress(uint256)(address)" "$TARGET_ID" --rpc-url "$MAINNET_RPC_URL")
            fi

            if [ "$NODE_ADDR" = "0x0000000000000000000000000000000000000000" ]; then
                echo -e "${RED}Error: Node not found for target id=$TARGET_ID${NC}"
                exit 1
            fi

            echo "    Node: $NODE_ADDR"
            echo "    Amount: $WITHDRAWAL_GWEI gwei ($WITHDRAWAL_WEI wei)"

            cast send "$NODES_MANAGER" "queueETHWithdrawal(address,uint256)" \
                "$NODE_ADDR" "$WITHDRAWAL_WEI" \
                --rpc-url "$MAINNET_RPC_URL" \
                --private-key "$PRIVATE_KEY" 2>&1 | tee -a "$OUTPUT_DIR/mainnet_broadcast.log"
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

    if [ -z "$MAINNET_RPC_URL" ]; then
        echo -e "${RED}Error: MAINNET_RPC_URL required for simulation${NC}"
        exit 1
    fi

    VNET_NAME="${OPERATOR_SLUG}-${MODE_SLUG}-${AMOUNT}eth-${TIMESTAMP}"

    # Collect all transaction files in order
    ALL_TX_FILES=()

    if [ "$UNRESTAKE_ONLY" = true ]; then
        # Unrestake: only queue-withdrawals.json at root
        QUEUE_FILE="$OUTPUT_DIR/queue-withdrawals.json"
        if [ -f "$QUEUE_FILE" ]; then
            ALL_TX_FILES+=("$QUEUE_FILE")
            echo "  Including: queue-withdrawals.json"
        fi
    else
        # Submarine: link + consolidation + post-sweep/queue-withdrawals
        LINK_FILE="$OUTPUT_DIR/link-validators.json"
        if [ -f "$LINK_FILE" ]; then
            ALL_TX_FILES+=("$LINK_FILE")
            echo "  Including: link-validators.json"
        fi

        CONSOLIDATION_FILES=($(ls "$OUTPUT_DIR"/consolidation-txns-*.json 2>/dev/null | sort -V))
        if [ ${#CONSOLIDATION_FILES[@]} -gt 0 ]; then
            for f in "${CONSOLIDATION_FILES[@]}"; do
                ALL_TX_FILES+=("$f")
                echo "  Including: $(basename "$f")"
            done
        fi

        QUEUE_FILE="$OUTPUT_DIR/post-sweep/queue-withdrawals.json"
        if [ -f "$QUEUE_FILE" ]; then
            ALL_TX_FILES+=("$QUEUE_FILE")
            echo "  Including: post-sweep/queue-withdrawals.json"
        fi
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
if [ "$UNRESTAKE_ONLY" = true ]; then
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}           UNRESTAKE WITHDRAWAL COMPLETE                        ${NC}"
    echo -e "${GREEN}================================================================${NC}"
else
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}           SUBMARINE WITHDRAWAL COMPLETE                        ${NC}"
    echo -e "${GREEN}================================================================${NC}"
fi
echo ""
echo -e "${BLUE}Output directory:${NC} $OUTPUT_DIR"
echo ""

# Extract summary from submarine-plan.json
SUBMARINE_PLAN="$OUTPUT_DIR/submarine-plan.json"
if [ -f "$SUBMARINE_PLAN" ] && command -v jq &> /dev/null; then
    REQUESTED=$(jq '.requested_amount_eth' "$SUBMARINE_PLAN")
    TOTAL_WITHDRAWAL=$(jq '.total_withdrawal_eth' "$SUBMARINE_PLAN")
    NUM_PODS=$(jq '.num_pods_used' "$SUBMARINE_PLAN")
    QUEUE_TXS=$(jq '.transactions.queue_withdrawals // 0' "$SUBMARINE_PLAN")
    TOTAL_TXS=$(jq '.transactions.total // 0' "$SUBMARINE_PLAN")

    echo -e "${BLUE}Summary:${NC}"
    echo "  Requested withdrawal:   $REQUESTED ETH"
    echo "  Total withdrawal:       $TOTAL_WITHDRAWAL ETH"
    echo "  Pods used:              $NUM_PODS"

    if [ "$UNRESTAKE_ONLY" != true ]; then
        NUM_SOURCES=$(jq '.consolidation.total_sources' "$SUBMARINE_PLAN")
        LINK_TXS=$(jq '.transactions.linking // 0' "$SUBMARINE_PLAN")
        CONSOL_TXS=$(jq '.transactions.consolidation // .consolidation.num_transactions' "$SUBMARINE_PLAN")
        echo "  Sources consolidated:   $NUM_SOURCES"
        echo ""
        echo "  Transactions:"
        echo "    Linking:              $LINK_TXS"
        echo "    Consolidation:        $CONSOL_TXS"
        echo "    Queue withdrawals:    $QUEUE_TXS"
        echo "    Total:                $TOTAL_TXS"
    else
        echo ""
        echo "  Transactions:"
        echo "    Queue withdrawals:    $QUEUE_TXS"
        echo "    Total:                $TOTAL_TXS"
    fi
    echo ""

    # Show per-pod details
    for IDX in $(seq 0 $((NUM_PODS - 1))); do
        POD_ADDR=$(jq -r ".pods[$IDX].eigenpod" "$SUBMARINE_PLAN")
        POD_TARGET=$(jq -r ".pods[$IDX].target_pubkey" "$SUBMARINE_PLAN")
        POD_WITHDRAWAL=$(jq ".pods[$IDX].withdrawal_eth" "$SUBMARINE_PLAN")
        echo "  Pod $((IDX + 1)): $POD_ADDR"
        echo "    Target:    ${POD_TARGET:0:20}..."
        if [ "$UNRESTAKE_ONLY" != true ]; then
            POD_SOURCES=$(jq ".pods[$IDX].num_sources" "$SUBMARINE_PLAN")
            POD_0X02=$(jq -r ".pods[$IDX].is_target_0x02" "$SUBMARINE_PLAN")
            echo "    Sources:   $POD_SOURCES"
            echo "    Is 0x02:   $POD_0X02"
        fi
        echo "    Withdrawal: $POD_WITHDRAWAL ETH"
    done
    echo ""
fi

echo -e "${BLUE}Generated files:${NC}"
ls -1 "$OUTPUT_DIR"/*.json 2>/dev/null | while read -r file; do
    echo "  - $(basename "$file")"
done
if [ "$UNRESTAKE_ONLY" != true ]; then
    ls -1 "$OUTPUT_DIR"/post-sweep/*.json 2>/dev/null | while read -r file; do
        echo "  - post-sweep/$(basename "$file")"
    done
fi

echo ""
echo -e "${BLUE}Execution order:${NC}"
if [ "$UNRESTAKE_ONLY" = true ]; then
    echo "  1. Execute queue-withdrawals.json from ADMIN_EOA (queueETHWithdrawal)"
    echo "  2. Wait for EigenLayer withdrawal delay, then completeQueuedETHWithdrawals"
else
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
    echo "  $STEP. Wait for beacon chain consolidation + sweep"
    STEP=$((STEP + 1))
    if [ -f "$OUTPUT_DIR/post-sweep/queue-withdrawals.json" ]; then
        echo "  $STEP. Execute queue-withdrawals.json from ADMIN_EOA (queueETHWithdrawal)"
        STEP=$((STEP + 1))
        echo "  $STEP. Wait for EigenLayer withdrawal delay, then completeQueuedETHWithdrawals"
    fi
    echo ""
    echo -e "${YELLOW}Note: Each consolidation request requires a small fee paid to the beacon chain.${NC}"
    echo -e "${YELLOW}Ensure ADMIN_EOA has sufficient ETH balance for fees.${NC}"
fi
echo ""

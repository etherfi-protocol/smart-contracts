#!/bin/bash
#
# run-consolidation.sh - Automated validator consolidation workflow
#
# This script consolidates multiple source validators into target validators,
# with targets auto-selected to ensure distribution across the withdrawal sweep queue.
#
# Usage:
#   ./script/operations/consolidations/run-consolidation.sh \
#     --operator "Validation Cloud" \
#     --count 50 \
#     --bucket-hours 6 \
#     --max-target-balance 2016
#
# This script:
#   1. Creates an output directory: consolidations/{operator}_{count}_{timestamp}/
#   2. Queries validators and creates consolidation plan
#   3. Generates Gnosis Safe transactions for each target
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
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default parameters
OPERATOR="" # operator name from the address-remapping table in Database
COUNT=0 # number of source validators to consolidate (0 = use all available)
BUCKET_HOURS=6
MAX_TARGET_BALANCE=1600 # max balance of the target validator after consolidation
DRY_RUN=false
SKIP_SIMULATE=false
MAINNET=false # broadcast transactions on mainnet using ADMIN_EOA

print_usage() {
    echo "Usage: $0 --operator <name> [options]"
    echo ""
    echo "Consolidate multiple source validators into target validators."
    echo "Targets are auto-selected to ensure distribution across the withdrawal sweep queue."
    echo ""
    echo "Required:"
    echo "  --operator           Operator name (e.g., 'Validation Cloud')"
    echo ""
    echo "Options:"
    echo "  --count              Number of source validators to consolidate (default: 0 = all available)"
    echo "  --bucket-hours       Time bucket duration for sweep queue distribution (default: 6)"
    echo "  --max-target-balance Maximum ETH balance allowed on target post-consolidation (default: 1888)"
    echo "  --batch-size         Number of consolidations per transaction (default: 58)"
    echo "  --dry-run            Output consolidation plan JSON without executing forge script"
    echo "  --skip-simulate      Skip Tenderly simulation step"
    echo "  --mainnet            Broadcast transactions on mainnet using ADMIN_EOA (requires PRIVATE_KEY)"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Consolidate all validators for operator (simulation only)"
    echo "  $0 --operator 'Validation Cloud'"
    echo ""
    echo "  # Consolidation with custom settings (limit to 100 validators)"
    echo "  $0 --operator 'Infstones' --count 100 --bucket-hours 6 --max-target-balance 1888"
    echo ""
    echo "  # Dry run to preview plan"
    echo "  $0 --operator 'Validation Cloud' --dry-run"
    echo ""
    echo "  # Execute on mainnet"
    echo "  $0 --operator 'Validation Cloud' --count 50 --mainnet"
    echo ""
    echo "Environment Variables:"
    echo "  MAINNET_RPC_URL      Ethereum mainnet RPC URL (required)"
    echo "  VALIDATOR_DB         PostgreSQL connection string for validator database"
    echo "  PRIVATE_KEY          Private key for ADMIN_EOA (required for --mainnet)"
    echo "  BEACON_CHAIN_URL     Beacon chain API URL (optional)"
}

# Parse arguments
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
        --bucket-hours)
            BUCKET_HOURS="$2"
            shift 2
            ;;
        --max-target-balance)
            MAX_TARGET_BALANCE="$2"
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

# Check environment variables
if [ -z "$MAINNET_RPC_URL" ]; then
    echo -e "${RED}Error: MAINNET_RPC_URL environment variable not set${NC}"
    echo "Set it in your .env file or export it: export MAINNET_RPC_URL=https://..."
    exit 1
fi

if [ -z "$VALIDATOR_DB" ]; then
    echo -e "${RED}Error: VALIDATOR_DB environment variable not set${NC}"
    echo "Set it in your .env file or export it: export VALIDATOR_DB=postgres://..."
    exit 1
fi

# Check PRIVATE_KEY if --mainnet is used
if [ "$MAINNET" = true ] && [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY environment variable not set${NC}"
    echo "Set it in your .env file or export it for --mainnet mode"
    exit 1
fi

# Create output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OPERATOR_SLUG=$(echo "$OPERATOR" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
OUTPUT_DIR="$SCRIPT_DIR/txns/${OPERATOR_SLUG}_consolidation_${COUNT}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           VALIDATOR CONSOLIDATION WORKFLOW                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Operator:           $OPERATOR"
if [ "$COUNT" -eq 0 ]; then
    echo "  Source count:       all available"
else
    echo "  Source count:       $COUNT validators"
fi
echo "  Bucket interval:    ${BUCKET_HOURS}h"
echo "  Max target balance: ${MAX_TARGET_BALANCE} ETH"
echo "  Batch size:         $BATCH_SIZE"
echo "  Dry run:            $DRY_RUN"
echo "  Mainnet mode:       $MAINNET"
echo "  Output directory:   $OUTPUT_DIR"
echo ""

# ============================================================================
# Step 1: Query validators and create consolidation plan
# ============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}[1/4] Creating consolidation plan...${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

QUERY_ARGS=(
    --operator "$OPERATOR"
    --count "$COUNT"
    --bucket-hours "$BUCKET_HOURS"
    --max-target-balance "$MAX_TARGET_BALANCE"
    --output "$OUTPUT_DIR/consolidation-data.json"
)

if [ "$DRY_RUN" = true ]; then
    QUERY_ARGS+=(--dry-run)
fi

python3 "$SCRIPT_DIR/query_validators_consolidation.py" "${QUERY_ARGS[@]}"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${GREEN}✓ Dry run complete. No transactions generated.${NC}"
    exit 0
fi

if [ ! -f "$OUTPUT_DIR/consolidation-data.json" ]; then
    echo -e "${RED}Error: Failed to create consolidation plan${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Consolidation plan written to $OUTPUT_DIR/consolidation-data.json${NC}"
echo ""

# ============================================================================
# Step 2: Generate transactions / Broadcast on mainnet
# ============================================================================
if [ "$MAINNET" = true ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[2/4] Broadcasting transactions on MAINNET...${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}⚠ WARNING: This will execute REAL transactions on mainnet!${NC}"
    echo ""
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[2/4] Generating transaction files...${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

# Parse the consolidation data
CONSOLIDATION_DATA="$OUTPUT_DIR/consolidation-data.json"

# Check if jq is available for JSON parsing
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required for JSON parsing${NC}"
    echo "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

# Get number of consolidations (targets)
NUM_TARGETS=$(jq '.consolidations | length' "$CONSOLIDATION_DATA")
TOTAL_SOURCES=$(jq '[.consolidations[].sources | length] | add' "$CONSOLIDATION_DATA")
echo "Processing $NUM_TARGETS target consolidations with $TOTAL_SOURCES total sources..."

# Build forge command
FORGE_CMD="CONSOLIDATION_DATA_FILE=\"$CONSOLIDATION_DATA\" OUTPUT_DIR=\"$OUTPUT_DIR\" BATCH_SIZE=\"$BATCH_SIZE\""

if [ "$MAINNET" = true ]; then
    # Mainnet mode: broadcast transactions using ADMIN_EOA
    FORGE_CMD="$FORGE_CMD BROADCAST=true forge script \"$SCRIPT_DIR/ConsolidateToTarget.s.sol:ConsolidateToTarget\" \
        --rpc-url \"$MAINNET_RPC_URL\" \
        --private-key \"$PRIVATE_KEY\" \
        --broadcast \
        -vvvv"
else
    # Simulation mode: generate JSON transaction files
    FORGE_CMD="$FORGE_CMD forge script \"$SCRIPT_DIR/ConsolidateToTarget.s.sol:ConsolidateToTarget\" \
        --fork-url \"$MAINNET_RPC_URL\" \
        -vvvv"
fi

echo "Running forge script..."
eval "$FORGE_CMD" 2>&1 | tee "$OUTPUT_DIR/forge_all_targets.log"
FORGE_EXIT_CODE=${PIPESTATUS[0]}

if [ $FORGE_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Error: Forge script failed with exit code $FORGE_EXIT_CODE${NC}"
    exit 1
fi

# Check for generated files
echo ""
echo "Looking for generated files in: $OUTPUT_DIR"
TX_FILES=()

for generated_file in "$OUTPUT_DIR"/*.json; do
    filename=$(basename "$generated_file")
    # Skip consolidation-data.json
    if [ "$filename" != "consolidation-data.json" ]; then
        TX_FILES+=("$generated_file")
        echo -e "${GREEN}  ✓ Found $filename${NC}"
    fi
done

if [ ${#TX_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}  Warning: No transaction files found${NC}"
    echo "  Contents of $OUTPUT_DIR:"
    ls -la "$OUTPUT_DIR"/*.json 2>/dev/null || echo "  No JSON files found"
fi

echo ""
echo -e "${GREEN}✓ Generated transaction files for $NUM_TARGETS targets${NC}"
echo ""

# ============================================================================
# Step 3: List generated files (skip if mainnet mode)
# ============================================================================
if [ "$MAINNET" = true ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[3/4] Transactions broadcast on mainnet${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[3/4] Generated files:${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    ls -la "$OUTPUT_DIR"/*.json 2>/dev/null || echo "No JSON files found"
    echo ""
fi

# ============================================================================
# Step 4: Simulate on Tenderly (skip if mainnet mode)
# ============================================================================
if [ "$MAINNET" = true ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[4/4] Skipping simulation (transactions already broadcast on mainnet)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
elif [ "$SKIP_SIMULATE" = true ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[4/4] Skipping Tenderly simulation (--skip-simulate)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[4/4] Simulating on Tenderly...${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    VNET_NAME="${OPERATOR_SLUG}-consolidation-${COUNT}-${TIMESTAMP}"
    
    # Check if linking is needed by looking for link-validators file
    LINK_FILE="$OUTPUT_DIR/link-validators.json"

    # Find consolidation files (individual files: consolidation-txns-1.json, consolidation-txns-2.json, etc.)
    CONSOLIDATION_FILES=($(ls "$OUTPUT_DIR"/consolidation-txns-*.json 2>/dev/null | sort -V))

    if [ ${#CONSOLIDATION_FILES[@]} -gt 0 ]; then
        echo "Found ${#CONSOLIDATION_FILES[@]} consolidation transaction file(s)"

        # Build list of all transaction files
        ALL_TX_FILES=()
        if [ -f "$LINK_FILE" ]; then
            echo "Linking required. Adding link-validators.json to transaction list..."
            ALL_TX_FILES+=("$LINK_FILE")
        fi
        ALL_TX_FILES+=("${CONSOLIDATION_FILES[@]}")

        # Join all transaction files with commas for the simulate.py script
        TX_FILES_CSV=$(IFS=,; echo "${ALL_TX_FILES[*]}")

        echo "Transaction files to simulate: ${#ALL_TX_FILES[@]}"
        for f in "${ALL_TX_FILES[@]}"; do
            echo "    - $(basename "$f")"
        done
        echo ""

        CMD="python3 $PROJECT_ROOT/script/operations/utils/simulate.py --tenderly \
            --txns \"$TX_FILES_CSV\" \
            --vnet-name \"$VNET_NAME\""
        echo "Running: $CMD"
        eval "$CMD"
        SIMULATION_EXIT_CODE=$?
    else
        echo -e "${RED}Error: No consolidation files found to simulate${NC}"
        SIMULATION_EXIT_CODE=1
    fi
    
    # Check if simulation was successful
    if [ $SIMULATION_EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Error: Tenderly simulation failed${NC}"
        echo -e "${RED}Check the output above for failed transaction links${NC}"
        exit 1
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    CONSOLIDATION COMPLETE                  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Output directory:${NC} $OUTPUT_DIR"
echo ""
echo -e "${BLUE}Generated files:${NC}"
ls -1 "$OUTPUT_DIR"/*.json 2>/dev/null | while read -r file; do
    echo "  - $(basename "$file")"
done

# Extract summary from consolidation data
if [ -f "$CONSOLIDATION_DATA" ]; then
    echo ""
    echo -e "${BLUE}Consolidation Summary:${NC}"
    TOTAL_TARGETS=$(jq '.summary.total_targets' "$CONSOLIDATION_DATA")
    TOTAL_SOURCES=$(jq '.summary.total_sources' "$CONSOLIDATION_DATA")
    TOTAL_ETH=$(jq '.summary.total_eth_consolidated' "$CONSOLIDATION_DATA")
    echo "  Total targets: $TOTAL_TARGETS"
    echo "  Total sources: $TOTAL_SOURCES"
    echo "  Total ETH consolidated: $TOTAL_ETH"
fi

if [ "$MAINNET" = true ]; then
    echo ""
    echo -e "${BLUE}Mainnet Execution Complete:${NC}"
    echo "  All transactions have been broadcast to mainnet."
    echo "  Check the forge output above for transaction hashes."
    echo ""
    echo -e "${YELLOW}⚠ Note: Monitor transactions on Etherscan for confirmation.${NC}"
    echo ""
else
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "  1. Review the consolidation plan in consolidation-data.json"

    # Check if linking was needed
    if [ -f "$OUTPUT_DIR/link-validators.json" ]; then
        echo "  2. Execute link-validators.json from ADMIN_EOA"
        echo "  3. Execute consolidation-txns-*.json files from ADMIN_EOA (each one)"
    else
        echo "  2. Execute consolidation-txns-*.json files from ADMIN_EOA (each one)"
    fi
    echo ""
    echo "  Execute each transaction from ADMIN_EOA (one file at a time)"
    echo ""
    echo -e "${YELLOW}⚠ Note: Each consolidation request requires a small fee paid to the beacon chain.${NC}"
    echo -e "${YELLOW}  Ensure ADMIN_EOA has sufficient ETH balance for fees.${NC}"
    echo ""
fi

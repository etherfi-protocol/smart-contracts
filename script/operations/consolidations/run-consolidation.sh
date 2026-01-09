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
OPERATOR=""
COUNT=50
BUCKET_HOURS=6
MAX_TARGET_BALANCE=2016
DRY_RUN=false
SKIP_SIMULATE=false
NONCE=0
BATCH_SIZE=50

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
    echo "  --count              Number of source validators to consolidate (default: 50)"
    echo "  --bucket-hours       Time bucket duration for sweep queue distribution (default: 6)"
    echo "  --max-target-balance Maximum ETH balance allowed on target post-consolidation (default: 2016)"
    echo "  --nonce              Starting Safe nonce for tx hash computation (default: 0)"
    echo "  --batch-size         Number of consolidations per transaction (default: 50)"
    echo "  --dry-run            Output consolidation plan JSON without executing forge script"
    echo "  --skip-simulate      Skip Tenderly simulation step"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Basic consolidation of 50 validators"
    echo "  $0 --operator 'Validation Cloud' --count 50"
    echo ""
    echo "  # Consolidation with custom settings"
    echo "  $0 --operator 'Infstones' --count 100 --bucket-hours 12 --max-target-balance 1984"
    echo ""
    echo "  # Dry run to preview plan"
    echo "  $0 --operator 'Validation Cloud' --count 50 --dry-run"
    echo ""
    echo "Environment Variables:"
    echo "  MAINNET_RPC_URL      Ethereum mainnet RPC URL (required)"
    echo "  VALIDATOR_DB         PostgreSQL connection string for validator database"
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
        --nonce)
            NONCE="$2"
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
echo "  Source count:       $COUNT validators"
echo "  Bucket interval:    ${BUCKET_HOURS}h"
echo "  Max target balance: ${MAX_TARGET_BALANCE} ETH"
echo "  Batch size:         $BATCH_SIZE"
echo "  Safe nonce:         $NONCE"
echo "  Dry run:            $DRY_RUN"
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
# Step 2: Generate Gnosis Safe transactions
# ============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}[2/4] Generating Gnosis Safe transactions...${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Parse the consolidation data and generate transactions for each target
CONSOLIDATION_DATA="$OUTPUT_DIR/consolidation-data.json"

# Check if jq is available for JSON parsing
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required for JSON parsing${NC}"
    echo "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

# Get number of consolidations (targets)
NUM_TARGETS=$(jq '.consolidations | length' "$CONSOLIDATION_DATA")
echo "Processing $NUM_TARGETS target consolidations..."

CURRENT_NONCE=$NONCE
TX_FILES=()

# Process each target consolidation
for i in $(seq 0 $((NUM_TARGETS - 1))); do
    TARGET_PUBKEY=$(jq -r ".consolidations[$i].target.pubkey" "$CONSOLIDATION_DATA")
    NUM_SOURCES=$(jq ".consolidations[$i].sources | length" "$CONSOLIDATION_DATA")
    POST_BALANCE=$(jq ".consolidations[$i].post_consolidation_balance_eth" "$CONSOLIDATION_DATA")
    
    echo ""
    echo -e "${BLUE}Target $((i + 1))/$NUM_TARGETS:${NC}"
    echo "  Pubkey: ${TARGET_PUBKEY:0:20}...${TARGET_PUBKEY: -10}"
    echo "  Sources: $NUM_SOURCES validators"
    echo "  Post-consolidation balance: ${POST_BALANCE} ETH"
    
    # Extract source pubkeys for this target
    SOURCES_JSON=$(jq -c ".consolidations[$i].sources" "$CONSOLIDATION_DATA")
    
    # Create a temporary file with just the sources for this target
    TEMP_SOURCES_FILE="$OUTPUT_DIR/temp_sources_$i.json"
    jq ".consolidations[$i].sources" "$CONSOLIDATION_DATA" > "$TEMP_SOURCES_FILE"
    
    # Generate transactions using forge script
    OUTPUT_FILE="${CURRENT_NONCE}-consolidation-target-$((i + 1)).json"
    
    JSON_FILE="$TEMP_SOURCES_FILE" \
    TARGET_PUBKEY="$TARGET_PUBKEY" \
    OUTPUT_FILE="$OUTPUT_FILE" \
    BATCH_SIZE="$BATCH_SIZE" \
    SAFE_NONCE="$CURRENT_NONCE" \
    forge script "$SCRIPT_DIR/ConsolidateToTarget.s.sol:ConsolidateToTarget" \
        --fork-url "$MAINNET_RPC_URL" -vvvv 2>&1 | tee "$OUTPUT_DIR/forge_target_$((i + 1)).log"
    
    # Move generated file to output directory
    if [ -f "$SCRIPT_DIR/$OUTPUT_FILE" ]; then
        mv "$SCRIPT_DIR/$OUTPUT_FILE" "$OUTPUT_DIR/"
        TX_FILES+=("$OUTPUT_DIR/$OUTPUT_FILE")
        echo -e "${GREEN}  ✓ Generated $OUTPUT_FILE${NC}"
    fi
    
    # Clean up temp file
    rm -f "$TEMP_SOURCES_FILE"
    
    # Increment nonce for next transaction
    CURRENT_NONCE=$((CURRENT_NONCE + 1))
done

echo ""
echo -e "${GREEN}✓ Generated $NUM_TARGETS transaction files${NC}"
echo ""

# ============================================================================
# Step 3: List generated files
# ============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}[3/4] Generated files:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
ls -la "$OUTPUT_DIR"/*.json 2>/dev/null || echo "No JSON files found"
echo ""

# ============================================================================
# Step 4: Simulate on Tenderly
# ============================================================================
if [ "$SKIP_SIMULATE" = true ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[4/4] Skipping Tenderly simulation (--skip-simulate)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}[4/4] Simulating on Tenderly...${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    VNET_NAME="${OPERATOR_SLUG}-consolidation-${COUNT}-${TIMESTAMP}"
    
    # Find all consolidation transaction files
    CONSOLIDATION_FILES=$(ls "$OUTPUT_DIR"/*-consolidation-*.json 2>/dev/null | sort -V)
    
    if [ -n "$CONSOLIDATION_FILES" ]; then
        # Build comma-separated list of consolidation files
        CONSOLIDATION_LIST=""
        for consolidation_file in $CONSOLIDATION_FILES; do
            if [ -z "$CONSOLIDATION_LIST" ]; then
                CONSOLIDATION_LIST="$consolidation_file"
            else
                CONSOLIDATION_LIST="$CONSOLIDATION_LIST,$consolidation_file"
            fi
        done
        
        echo "Simulating consolidation transactions..."
        CMD="python3 $PROJECT_ROOT/script/operations/utils/simulate.py --tenderly --txns \"$CONSOLIDATION_LIST\" --vnet-name \"$VNET_NAME\""
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

echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Review the consolidation plan in consolidation-data.json"
echo "  2. Import the transaction files to Gnosis Safe in order:"
for file in $(ls "$OUTPUT_DIR"/*-consolidation-*.json 2>/dev/null | sort -V); do
    echo "     - $(basename "$file")"
done
echo "  3. Execute each transaction from Gnosis Safe"
echo ""
echo -e "${YELLOW}⚠ Note: Each consolidation request requires a small fee paid to the beacon chain.${NC}"
echo -e "${YELLOW}  Ensure the Safe has sufficient ETH balance for fees.${NC}"
echo ""

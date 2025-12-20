#!/bin/bash
set -euo pipefail

# Configuration
RPC_URL="${MAINNET_RPC_URL}"
PRIVATE_KEY="${PRIVATE_KEY}"
DELAY_SECONDS="${DELAY_SECONDS:-900}"  # 3 minutes default
START_INDEX="${START_INDEX:-0}"  # Start from this index (default: 0)
SCRIPT_PATH="script/operator-management/requestELTriggeredWithdrawals.s.sol:RequestELTriggeredWithdrawals"

# Get node count from JSON file
NODE_COUNT=$(jq 'length' script/operator-management/a41-data.json 2>/dev/null || echo "0")

if [ "$NODE_COUNT" -eq 0 ]; then
    echo "Error: Could not determine node count from JSON file"
    exit 1
fi

# Validate START_INDEX
if [ "$START_INDEX" -lt 0 ] || [ "$START_INDEX" -ge "$NODE_COUNT" ]; then
    echo "Error: START_INDEX ($START_INDEX) must be between 0 and $((NODE_COUNT - 1))"
    exit 1
fi

echo "=== EL Triggered Withdrawals with Delays ==="
echo "Total nodes: $NODE_COUNT"
echo "Starting from index: $START_INDEX"
echo "Nodes to process: $((NODE_COUNT - START_INDEX))"
echo "Delay between transactions: $DELAY_SECONDS seconds ($((DELAY_SECONDS / 60)) minutes)"
echo "RPC URL: $RPC_URL"
echo "=========================================="
echo ""

# Track success/failure counts
SUCCESS_COUNT=0
FAILURE_COUNT=0
FAILED_INDICES=()

# Loop through each node index starting from START_INDEX
for i in $(seq "$START_INDEX" $((NODE_COUNT - 1))); do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing node index $i/$((NODE_COUNT - 1))..."
    
    # Run forge script with broadcast for this specific node index
    if forge script "$SCRIPT_PATH" \
        --sig "runSingleNode(uint256)" "$i" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --private-key "$PRIVATE_KEY" \
        -vvv 2>&1; then
        echo "✓ Successfully processed node index $i"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "✗ Failed to process node index $i"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        FAILED_INDICES+=($i)
    fi
    
    # Check if this was the last node
    if [ $i -lt $((NODE_COUNT - 1)) ]; then
        echo ""
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting $DELAY_SECONDS seconds before next transaction..."
        echo "  (Press Ctrl+C to cancel)"
        sleep "$DELAY_SECONDS"
        echo ""
    fi
done

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing completed!"
echo "=========================================="
echo "Total nodes: $NODE_COUNT"
echo "Started from index: $START_INDEX"
echo "Processed: $((SUCCESS_COUNT + FAILURE_COUNT)) nodes"
echo "Successful: $SUCCESS_COUNT"
echo "Failed: $FAILURE_COUNT"
if [ ${#FAILED_INDICES[@]} -gt 0 ]; then
    echo "Failed indices: ${FAILED_INDICES[*]}"
fi
echo "=========================================="

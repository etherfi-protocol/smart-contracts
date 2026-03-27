#!/bin/bash

# Command to Run:
# 1. chmod +x script/verify-forge-fmt-bytecode.sh
# 2. ./script/verify-forge-fmt-bytecode.sh

set -e

# Require a clean working tree so we can safely revert forge fmt changes
if ! git diff --quiet; then
    echo "❌ ERROR: Working tree has uncommitted changes. Please commit or stash them before running this script."
    exit 1
fi

# Initialize temp vars and register cleanup trap for all exit paths
TEMP_BEFORE=""
TEMP_CHANGED=""
TEMP_STATS=""
cleanup() {
    rm -rf "$TEMP_BEFORE" "$TEMP_CHANGED" "$TEMP_STATS"
    # Revert any formatting changes made by forge fmt
    git checkout -- . 2>/dev/null || true
}
trap cleanup EXIT

echo "🔍 Verifying that forge fmt doesn't change bytecode..."

# Define cache directory
CACHE_DIR="cache/bytecodeComparison"

# Clean and create cache directory (removes stale data from previous runs)
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

# Step 1: Compile and save bytecode before formatting
echo "📝 Compiling contracts before formatting..."
forge build --force

echo "💾 Extracting bytecode for each contract (pre-format)..."

# Create a temporary directory to store pre-format data
TEMP_BEFORE=$(mktemp -d)

# Extract bytecode from each contract's JSON artifact (excluding build-info)
find out -name "*.json" -type f ! -path "*/build-info/*" | while read -r file; do
    # Get relative path from out directory
    rel_path="${file#out/}"
    
    # Get everything except the filename itself to preserve directory structure
    dir_structure=$(dirname "$rel_path")
    filename=$(basename "$rel_path" .json)
    
    # Full path preserves the directory structure
    full_path="${dir_structure}/${filename}"
    
    # Extract contract name and bytecode
    contract_name=$(basename "${file%.json}")
    bytecode=$(jq -r '.deployedBytecode.object // .bytecode.object // ""' "$file" 2>/dev/null || echo "")
    
    # Save to temp file with proper directory structure
    mkdir -p "$TEMP_BEFORE/$dir_structure"
    echo "$bytecode" > "$TEMP_BEFORE/${full_path}.bytecode"
    echo "$contract_name|$rel_path" > "$TEMP_BEFORE/${full_path}.meta"
done

echo "✅ Pre-format bytecode extracted"

# Step 2: Run forge fmt
echo "🎨 Running forge fmt..."
forge fmt

# Step 3: Compile again after formatting
echo "📝 Recompiling contracts after formatting..."
forge build --force

echo "💾 Extracting bytecode for each contract (post-format)..."

# Extract post-format bytecode and create combined JSON files
find out -name "*.json" -type f ! -path "*/build-info/*" | while read -r file; do
    rel_path="${file#out/}"
    
    # Preserve the directory structure
    dir_structure=$(dirname "$rel_path")
    filename=$(basename "$rel_path" .json)
    full_path="${dir_structure}/${filename}"
    
    contract_name=$(basename "${file%.json}")
    bytecode_after=$(jq -r '.deployedBytecode.object // .bytecode.object // ""' "$file" 2>/dev/null || echo "")
    
    # Read pre-format bytecode if exists
    if [ -f "$TEMP_BEFORE/${full_path}.bytecode" ]; then
        bytecode_before=$(cat "$TEMP_BEFORE/${full_path}.bytecode")
    else
        bytecode_before=""
    fi
    
    # Create combined JSON file with proper directory structure
    mkdir -p "$CACHE_DIR/$dir_structure"
    output_file="$CACHE_DIR/${full_path}.json"
    
    # Normalize empty bytecode (treat "", "0x", and missing as equivalent)
    normalized_before="$bytecode_before"
    normalized_after="$bytecode_after"
    
    if [ -z "$normalized_before" ] || [ "$normalized_before" = "0x" ]; then
        normalized_before=""
    fi
    
    if [ -z "$normalized_after" ] || [ "$normalized_after" = "0x" ]; then
        normalized_after=""
    fi
    
    jq -n \
        --arg name "$contract_name" \
        --arg path "$rel_path" \
        --arg before "$bytecode_before" \
        --arg after "$bytecode_after" \
        --argjson changed "$([ "$normalized_before" != "$normalized_after" ] && echo true || echo false)" \
        '{
            contractName: $name,
            artifactPath: $path,
            preFormatBytecode: $before,
            postFormatBytecode: $after,
            bytecodeChanged: $changed
        }' > "$output_file"
done

echo "✅ Post-format bytecode extracted and comparison saved"

# Step 4: Compare bytecode for each contract
echo ""
echo "🔍 Analyzing bytecode changes..."
echo ""

# Create temporary files to store results
TEMP_CHANGED=$(mktemp)
TEMP_STATS=$(mktemp)

# Analyze all contracts recursively
while IFS= read -r json_file; do
    # Extract contract info
    artifact_path=$(jq -r '.artifactPath' "$json_file")
    pre_bytecode=$(jq -r '.preFormatBytecode' "$json_file")
    post_bytecode=$(jq -r '.postFormatBytecode' "$json_file")
    
    # Skip contracts with no bytecode (abstract contracts, interfaces, libraries without code)
    # Normalize empty values: treat "", "0x", and missing as equivalent
    normalized_pre="$pre_bytecode"
    normalized_post="$post_bytecode"
    
    if [ -z "$normalized_pre" ] || [ "$normalized_pre" = "0x" ]; then
        normalized_pre=""
    fi
    
    if [ -z "$normalized_post" ] || [ "$normalized_post" = "0x" ]; then
        normalized_post=""
    fi
    
    if [ -z "$normalized_pre" ] && [ -z "$normalized_post" ]; then
        echo "⊘  $artifact_path - SKIPPED (no bytecode)"
        echo "skipped" >> "$TEMP_STATS"
        continue
    fi
    
    bytecode_changed=$(jq -r '.bytecodeChanged' "$json_file")
    
    if [ "$bytecode_changed" = "true" ]; then
        echo "❌ $artifact_path - BYTECODE CHANGED"
        echo "$artifact_path" >> "$TEMP_CHANGED"
        echo "changed" >> "$TEMP_STATS"
    else
        echo "identical" >> "$TEMP_STATS"
    fi
done < <(find "$CACHE_DIR" -name "*.json" -type f)

# Count results
if [ -f "$TEMP_CHANGED" ]; then
    CHANGED_COUNT=$(wc -l < "$TEMP_CHANGED")
    # Read into array without mapfile
    CHANGED_CONTRACTS=()
    while IFS= read -r line; do
        CHANGED_CONTRACTS+=("$line")
    done < "$TEMP_CHANGED"
else
    CHANGED_COUNT=0
fi

TOTAL_COUNT=$(wc -l < "$TEMP_STATS" 2>/dev/null || echo "0")
IDENTICAL_COUNT=$(grep -c "identical" "$TEMP_STATS" 2>/dev/null || echo "0")
SKIPPED_COUNT=$(grep -c "skipped" "$TEMP_STATS" 2>/dev/null || echo "0")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if any contracts changed
if [ $CHANGED_COUNT -gt 0 ]; then
    echo "❌ FAILURE: $CHANGED_COUNT contract(s) have bytecode changes!"
    echo "   ($IDENTICAL_COUNT verified, $SKIPPED_COUNT skipped, $TOTAL_COUNT total)"
    echo ""
    echo "Affected contracts:"
    for contract in "${CHANGED_CONTRACTS[@]}"; do
        echo "  - $contract"
    done
    echo ""
    echo "📁 Detailed comparison saved in: $CACHE_DIR/"
    echo ""
    echo "💡 To inspect a specific contract:"
    echo "   jq '.' $CACHE_DIR/src/AccessControl.sol/AccessControl.json"
    echo ""
    echo "💡 To see which contracts changed:"
    echo "   find $CACHE_DIR -name '*.json' -exec jq -r 'select(.bytecodeChanged == true) | .artifactPath' {} \\;"
    
    exit 1
else
    echo "✅ SUCCESS: All contracts have identical bytecode!"
    echo "   ($IDENTICAL_COUNT verified, $SKIPPED_COUNT skipped, $TOTAL_COUNT total)"
    echo ""
    echo "📁 Comparison data saved in: $CACHE_DIR/"
    
    exit 0
fi
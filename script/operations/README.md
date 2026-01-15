# Operations Tools

Tools for EtherFi validator operations including auto-compounding, consolidation, and exits.

## Directory Structure

```
script/operations/
├── README.md                           # This file
├── auto-compound/
│   ├── AutoCompound.s.sol              # Auto-compound workflow script
│   └── query_validators.py             # Query validators from DB
├── consolidations/
│   ├── ConsolidateToTarget.s.sol       # Consolidate to target script
│   ├── ConsolidationTransactions.s.sol # General consolidation script
│   └── GnosisConsolidationLib.sol      # Consolidation helper library
├── exits/
│   └── ValidatorExit.s.sol             # EL-triggered exit script
├── utils/
│   ├── simulate.py                     # Transaction simulation tool
│   ├── SimulateTransactions.s.sol      # Forge simulation script
│   └── export_db_data.py               # Export DB data to JSON
└── data/
    └── (generated JSON files)
```

## Prerequisites

1. **Environment Variables** (in `.env` file at project root):
   ```bash
   MAINNET_RPC_URL=https://...
   VALIDATOR_DB=postgresql://...
   TENDERLY_API_ACCESS_TOKEN=...    # For Tenderly simulation
   TENDERLY_API_URL=https://api.tenderly.co/api/v1/account/{slug}/project/{slug}/
   ```

2. **Python Dependencies**:
   ```bash
   pip install psycopg2-binary python-dotenv requests
   ```

---

## Workflow 1: Auto-Compound Validators (0x01 → 0x02)

Convert validators from 0x01 (BLS) to 0x02 (auto-compounding) withdrawal credentials.

### Step 1: Query Validators from Database

Run from project root:

```bash
# List all operators with validator counts
python3 script/operations/auto-compound/query_validators.py --list-operators

# Query 50 validators for an operator (by name)
python3 script/operations/auto-compound/query_validators.py \
  --operator "Validation Cloud" \
  --count 50 \
  --output script/operations/auto-compound/validators.json

# Query by operator address
python3 script/operations/auto-compound/query_validators.py \
  --operator-address 0xf92204022cdf7ee0763ef794f69427a9dd9a7834 \
  --count 100 \
  --output script/operations/auto-compound/validators.json

# Include already consolidated validators (for debugging)
python3 script/operations/auto-compound/query_validators.py \
  --operator "Infstones" \
  --count 50 \
  --include-consolidated \
  --verbose

```

**Query Options:**

| Option | Description |
|--------|-------------|
| `--operator` | Operator name (e.g., "Validation Cloud") |
| `--operator-address` | Operator address (e.g., 0x...) |
| `--count` | Number of validators to query (default: 50) |
| `--output` | Output JSON file path |
| `--include-consolidated` | Include validators already consolidated (0x02) |
| `--verbose` | Show detailed filtering information |

### Step 2: Generate Transactions

```bash
# Basic usage (validators.json in auto-compound directory)
JSON_FILE=validators.json forge script \
  script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
  --fork-url $MAINNET_RPC_URL -vvvv

# Custom output filename
JSON_FILE=validators.json OUTPUT_FILE=my-txns.json forge script \
  script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
  --fork-url $MAINNET_RPC_URL -vvvv

# Custom batch size (validators per transaction)
JSON_FILE=validators.json BATCH_SIZE=25 forge script \
  script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
  --fork-url $MAINNET_RPC_URL -vvvv

# Raw JSON output (instead of Gnosis Safe format)
JSON_FILE=validators.json OUTPUT_FORMAT=raw forge script \
  script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
  --fork-url $MAINNET_RPC_URL -vvvv

# With Safe nonce for transaction hash verification
JSON_FILE=validators.json SAFE_NONCE=42 forge script \
  script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
  --fork-url $MAINNET_RPC_URL -vvvv
```

**Safe Transaction Hash Output:**

When `SAFE_NONCE` is provided, the script outputs EIP-712 signing data for each generated transaction:

```
=== EIP-712 SIGNING DATA: link-schedule.json ===
Nonce: 42
Domain Separator: 0x1234...
SafeTx Hash: 0xabcd...
Message Hash (to sign): 0x5678...

=== EIP-712 SIGNING DATA: link-execute.json ===
Nonce: 43
Domain Separator: 0x1234...
SafeTx Hash: 0xefgh...
Message Hash (to sign): 0x9012...

=== EIP-712 SIGNING DATA: consolidation.json ===
Nonce: 44
Domain Separator: 0x1234...
SafeTx Hash: 0xijkl...
Message Hash (to sign): 0x3456...
```

Nonces are assigned sequentially: schedule (N), execute (N+1), consolidation (N+2).

**Environment Variables:**

| Variable | Description | Default |
|----------|-------------|---------|
| `JSON_FILE` | Input JSON file with validators | Required |
| `OUTPUT_FILE` | Output filename | `auto-compound-txns.json` |
| `BATCH_SIZE` | Validators per transaction | `50` |
| `OUTPUT_FORMAT` | `gnosis` or `raw` | `gnosis` |
| `SAFE_ADDRESS` | Gnosis Safe address | Operating Admin |
| `CHAIN_ID` | Chain ID for transaction | `1` |
| `SAFE_NONCE` | Starting Safe nonce for tx hash computation | `0` |

The script automatically:
- Detects unlinked validators
- Generates linking transactions (if needed)
- Generates consolidation transactions

**Output Files** (when validators need linking):
- `auto-compound-txns-link-schedule.json` - Timelock schedule transaction
- `auto-compound-txns-link-execute.json` - Timelock execute transaction
- `auto-compound-txns-consolidation.json` - Consolidation transaction

### Step 3: Execute Transactions

**If validators need linking:**
1. Import `*-link-schedule.json` into Gnosis Safe Transaction Builder
2. Execute the schedule transaction
3. Wait 8 hours for timelock delay
4. Import `*-link-execute.json` and execute
5. Import `*-consolidation.json` and execute

**If all validators are already linked:**
1. Import the single output JSON into Gnosis Safe Transaction Builder
2. Execute the consolidation transaction

### Complete Example: Auto-Compound 50 Validation Cloud Validators

**Option A: One-liner script (recommended)**

```bash
./script/operations/auto-compound/run-auto-compound.sh \
  --operator "Validation Cloud" \
  --count 50 \
  --nonce 42
```

This script automatically:
1. Creates output directory: `validation_cloud_50_YYYYMMDD-HHMMSS/`
2. Queries validators from database
3. Generates transactions with Safe nonce
4. Simulates on Tenderly

**Option B: Manual steps**

```bash
# 1. Query validators
python3 script/operations/auto-compound/query_validators.py \
  --operator "Validation Cloud" \
  --count 50 \
  --output script/operations/auto-compound/validators.json

# 2. Generate transactions
JSON_FILE=validators.json SAFE_NONCE=42 forge script \
  script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
  --fork-url $MAINNET_RPC_URL -vvvv

# 3. Simulate on Tenderly (optional but recommended)
python3 script/operations/utils/simulate.py --tenderly \
  --schedule script/operations/auto-compound/txns-link-schedule.json \
  --execute script/operations/auto-compound/txns-link-execute.json \
  --then script/operations/auto-compound/txns-consolidation.json \
  --delay 8h \
  --vnet-name "ValidationCloud-AutoCompound"

# 4. Execute on mainnet via Gnosis Safe
#    - Import *-link-schedule.json → Execute
#    - Wait 8 hours
#    - Import *-link-execute.json → Execute
#    - Import *-consolidation.json → Execute
```

---

## Workflow 2: Consolidate to Target Validator

Consolidate multiple validators to a single target validator (same EigenPod).

### Generate Transactions

```bash
JSON_FILE=validators.json TARGET_PUBKEY=0x... forge script \
  script/operations/consolidations/ConsolidateToTarget.s.sol:ConsolidateToTarget \
  --fork-url $MAINNET_RPC_URL -vvvv
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `JSON_FILE` | Input JSON file with validators | Required |
| `TARGET_PUBKEY` | 48-byte target validator pubkey | Required |
| `OUTPUT_FILE` | Output filename | `consolidate-to-target-txns.json` |
| `BATCH_SIZE` | Validators per transaction | `50` |
| `OUTPUT_FORMAT` | `gnosis` or `raw` | `gnosis` |

---

## Workflow 3: Validator Exits (EL-Triggered)

Generate EL-triggered exit transactions for validators.

### Generate Exit Transaction

```bash
VALIDATOR_PUBKEY=0x... forge script \
  script/operations/exits/ValidatorExit.s.sol:ValidatorExit \
  --fork-url $MAINNET_RPC_URL -vvvv
```

---

## Transaction Simulation

Simulate timelock-gated transactions before execution. Run from project root.

### Simulation Modes

The simulation tool supports two transaction input modes:

| Mode | Arguments | Description |
|------|-----------|-------------|
| Simple | `--txns` | Single transaction file (no timelock) |
| Timelock | `--schedule` + `--execute` | Schedule → Time Warp → Execute workflow |

### Using Forge (Local Fork)

```bash
# Simple: Single transaction file
python3 script/operations/utils/simulate.py \
  --txns script/operations/auto-compound/auto-compound-txns-consolidation.json

# Timelock: Schedule + Execute with 8h delay
python3 script/operations/utils/simulate.py \
  --schedule script/operations/auto-compound/auto-compound-txns-link-schedule.json \
  --execute script/operations/auto-compound/auto-compound-txns-link-execute.json \
  --delay 8h

# Full workflow: Schedule → Execute → Follow-up consolidation
python3 script/operations/utils/simulate.py \
  --schedule script/operations/auto-compound/auto-compound-txns-link-schedule.json \
  --execute script/operations/auto-compound/auto-compound-txns-link-execute.json \
  --then script/operations/auto-compound/auto-compound-txns-consolidation.json \
  --delay 8h
```

### Using Tenderly Virtual Testnet

Tenderly Virtual Testnets provide persistent simulation environments with shareable URLs.

```bash
# List existing Virtual Testnets
python3 script/operations/utils/simulate.py --tenderly --list-vnets

# Create new VNet and run full auto-compound workflow
python3 script/operations/utils/simulate.py --tenderly \
  --schedule script/operations/auto-compound/auto-compound-txns-link-schedule.json \
  --execute script/operations/auto-compound/auto-compound-txns-link-execute.json \
  --then script/operations/auto-compound/auto-compound-txns-consolidation.json \
  --delay 8h \
  --vnet-name "AutoCompound-Test"

# Use existing VNet (continue from previous simulation)
python3 script/operations/utils/simulate.py --tenderly \
  --vnet-id 0a7305e5-2654-481c-a2cf-ea2886404ac3 \
  --txns script/operations/auto-compound/auto-compound-txns-consolidation.json

# Simple consolidation on new VNet
python3 script/operations/utils/simulate.py --tenderly \
  --txns script/operations/auto-compound/auto-compound-txns-consolidation.json \
  --vnet-name "Consolidation-Test"
```

### Simulation CLI Options

| Option | Short | Description |
|--------|-------|-------------|
| `--txns` | `-t` | Simple transaction file (no timelock) |
| `--schedule` | `-s` | Schedule transaction file (phase 1) |
| `--execute` | `-e` | Execute transaction file (phase 2) |
| `--then` | | Follow-up transaction file (phase 3) |
| `--delay` | `-d` | Timelock delay (e.g., `8h`, `72h`, `1d`, `28800`) |
| `--tenderly` | | Use Tenderly Virtual Testnet |
| `--list-vnets` | | List existing Virtual Testnets |
| `--vnet-id` | | Use existing VNet by ID |
| `--vnet-name` | | Display name for new VNet |
| `--rpc-url` | `-r` | Custom RPC URL (default: `$MAINNET_RPC_URL`) |
| `--safe-address` | | Custom Gnosis Safe address |

---

## Utility Scripts

### Export Database Data

Export operator and node data for Solidity scripts. Run from project root:

```bash
python3 script/operations/utils/export_db_data.py                    # Export all
python3 script/operations/utils/export_db_data.py --operators-only   # Export only operators
python3 script/operations/utils/export_db_data.py --nodes-only       # Export only nodes
```

---

## Gnosis Safe JSON Format

Generated transactions use this format:

```json
{
  "chainId": "1",
  "safeAddress": "0x2aCA71020De61bb532008049e1Bd41E451aE8AdC",
  "meta": {
    "txBuilderVersion": "1.16.5"
  },
  "transactions": [
    {
      "to": "0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F",
      "value": "0",
      "data": "0x..."
    }
  ]
}
```

Import into Gnosis Safe via Transaction Builder app.

---

## Key Contract Addresses (Mainnet)

| Contract | Address |
|----------|---------|
| EtherFiNodesManager | `0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F` |
| Operating Timelock | `0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a` |
| Operating Admin (Safe) | `0x2aCA71020De61bb532008049e1Bd41E451aE8AdC` |
| Role Registry | `0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9` |

---

## Troubleshooting

### "Call to non-contract address" or "Node has no pod"

This error occurs when validators are not linked in `EtherFiNodesManager`. The `AutoCompound.s.sol` script automatically detects this and generates linking transactions.

### "VALIDATOR_DB not set"

Set the PostgreSQL connection string:
```bash
export VALIDATOR_DB="postgresql://user:pass@host:5432/database"
```

### "MAINNET_RPC_URL not set"

Set the RPC URL:
```bash
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
```

### Timelock Delay

The Operating Timelock has an 8-hour (28800 seconds) delay. After scheduling a transaction, you must wait before executing.

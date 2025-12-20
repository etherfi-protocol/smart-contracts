# Request EL Triggered Withdrawals with Delays

This directory contains scripts for requesting Execution Layer triggered withdrawals with a configurable delay between transactions.

## Overview

The `requestELTriggeredWithdrawals.s.sol` script has been enhanced to support broadcasting transactions for individual nodes, which can then be sent with delays using the `sendWithDelays.sh` bash script.

## Usage

### Option 1: Original Script (Broadcast All at Once)

To broadcast all transactions at once (original behavior):

```bash
PRIVATE_KEY=... forge script script/operator-management/requestELTriggeredWithdrawals.s.sol:RequestELTriggeredWithdrawals \
  --rpc-url $MAINNET_RPC_URL --broadcast -vvvv
```

### Option 2: Send with 30-Minute Delays (Recommended)

To send transactions with a 30-minute delay between each call:

```bash
# Edit sendWithDelays.sh to set your RPC_URL and PRIVATE_KEY, then:
export DELAY_SECONDS=1800  # 30 minutes (default, optional)

./script/operator-management/sendWithDelays.sh
```

The script will:
1. Read the node count from `a41-data.json`
2. For each node index (0 to N-1):
   - Call `forge script` with `--broadcast` for that specific node index
   - Wait 30 minutes before processing the next node
3. Forge handles nonce management automatically

### Customizing the Delay

You can customize the delay by setting the `DELAY_SECONDS` environment variable:

```bash
export DELAY_SECONDS=3600  # 1 hour
./script/operator-management/sendWithDelays.sh
```

## How It Works

1. **Single Node Function**: The `runSingleNode(uint256 nodeIndex)` function in the Solidity script broadcasts the transaction for a specific node index.

2. **Bash Script**: The `sendWithDelays.sh` script:
   - Loops through each node index (0 to N-1)
   - Calls `forge script` with `--broadcast` for each node index
   - Forge handles transaction signing, nonce management, and broadcasting
   - Sleeps for the configured delay before processing the next node

## Requirements

- `forge` (Foundry)
- `jq` (for JSON parsing)
- `bash` (version 4+)

## Configuration

Edit `sendWithDelays.sh` to set:
- `RPC_URL`: Your Ethereum RPC URL
- `PRIVATE_KEY`: Your private key for signing transactions

Or set via environment variable:
- `DELAY_SECONDS`: Delay between transactions in seconds (default: 1800 = 30 minutes)

## Safety Features

- **Nonce Management**: The script automatically manages nonces, incrementing after each successful transaction
- **Transaction Confirmation**: Waits for each transaction to be confirmed before proceeding
- **Error Handling**: Stops execution if any step fails
- **Progress Logging**: Shows timestamps and progress for each transaction

## Example Output

```
Sender address: 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F
Starting nonce: 12345

Total nodes to process: 5
Delay between transactions: 1800 seconds (30 minutes)
==========================================

[2024-01-15 10:00:00] Processing node index 0...
  Target: 0x...
  Value: 1000000000000000 wei
  Calldata: 0x1234...
  Sending transaction with nonce 12345...
  Transaction sent: 0xabc123...
  Waiting for confirmation...
  [2024-01-15 10:05:00] Waiting 1800 seconds before next transaction...
```

## Troubleshooting

### Script fails to run
- Ensure `forge script` is working correctly
- Check that the JSON file exists and is valid
- Verify RPC URL and private key are set correctly in the script

### Transaction fails
- Check that the account has sufficient balance for fees and value
- Verify the rate limiter has sufficient capacity
- Forge handles nonce management automatically, but ensure no other process is sending transactions from the same account

### Script stops unexpectedly
- Check network connectivity
- Verify RPC URL is correct and accessible
- Ensure private key has proper permissions
- Check forge script output for specific error messages


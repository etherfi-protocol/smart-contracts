#!/usr/bin/env python3
"""
simulate.py - Transaction simulation tool with Tenderly Virtual Testnet support

This script simulates timelock-gated transactions by:
1. Running schedule transactions
2. Warping time to simulate timelock delay
3. Running execute transactions

Supports two modes:
- Forge simulation (local fork with vm.warp)
- Tenderly Virtual Testnet (persistent simulation environment)

Usage:
    # Simple simulation (no timelock)
    python simulate.py --txns consolidation.json

    # Schedule + Execute with timelock (8 hour delay)
    python simulate.py --schedule link-schedule.json --execute link-execute.json --delay 8h

    # Full auto-compound workflow with multiple consolidation transactions
    python simulate.py \\
        --schedule link-schedule.json \\
        --execute link-execute.json \\
        --then consolidation.json \\
        --delay 8h

    # Tenderly simulation (creates new VNet)
    python simulate.py --tenderly \\
        --schedule link-schedule.json \\
        --execute link-execute.json \\
        --vnet-name "AutoCompound-Test"

    # Tenderly simulation (use existing VNet)
    python simulate.py --tenderly \\
        --vnet-id "7113fe5d-bc69-475c-bfd5-a2a720c14d56" \\
        --schedule schedule.json \\
        --execute execute.json

    # List existing Tenderly VNets
    python simulate.py --tenderly --list-vnets

Environment Variables:
    MAINNET_RPC_URL: RPC URL for mainnet fork
    TENDERLY_API_ACCESS_TOKEN: Tenderly API access token
    TENDERLY_API_URL: Tenderly API URL (contains account/project slugs)
    SAFE_ADDRESS: Gnosis Safe address (default: EtherFi Operating Admin)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Load .env file if python-dotenv is available
try:
    from dotenv import load_dotenv
    # Try loading from current directory, then from script's parent directories
    env_path = Path('.env')
    if not env_path.exists():
        script_dir = Path(__file__).resolve().parent
        for _ in range(5):
            script_dir = script_dir.parent
            candidate = script_dir / '.env'
            if candidate.exists():
                env_path = candidate
                break
    load_dotenv(dotenv_path=env_path)
except ImportError:
    pass  # dotenv is optional

try:
    import requests
except ImportError:
    requests = None

# Default addresses
DEFAULT_SAFE_ADDRESS = "0x2aCA71020De61bb532008049e1Bd41E451aE8AdC"  # EtherFi Operating Admin


def get_project_root() -> Path:
    """Find the project root (where foundry.toml is)."""
    current = Path(__file__).resolve().parent
    while current != current.parent:
        if (current / 'foundry.toml').exists():
            return current
        current = current.parent
    return Path.cwd()


def parse_delay(delay_str: str) -> int:
    """Parse delay string like '8h', '72h', '1d', '28800' into seconds."""
    delay_str = delay_str.strip().lower()
    
    if delay_str.endswith('h'):
        return int(delay_str[:-1]) * 3600
    elif delay_str.endswith('d'):
        return int(delay_str[:-1]) * 86400
    elif delay_str.endswith('m'):
        return int(delay_str[:-1]) * 60
    elif delay_str.endswith('s'):
        return int(delay_str[:-1])
    else:
        return int(delay_str)


def resolve_file_path(project_root: Path, file_name: str) -> Path:
    """Resolve transaction file path."""
    # Check if it's an absolute path
    if file_name.startswith('/'):
        return Path(file_name)
    
    # Check if it exists relative to cwd
    cwd_path = Path.cwd() / file_name
    if cwd_path.exists():
        return cwd_path
    
    # Check if it exists relative to project root
    root_path = project_root / file_name
    if root_path.exists():
        return root_path
    
    # Default: look in auto-compound directory
    auto_compound_path = project_root / 'script' / 'operations' / 'auto-compound' / file_name
    if auto_compound_path.exists():
        return auto_compound_path
    
    # Return the original path (will fail with helpful error)
    return Path(file_name)


def load_transactions_from_file(file_path: Path) -> Tuple[List[Dict], str]:
    """Load transactions from a Gnosis Safe JSON file.

    Supports both formats:
    1. Single transaction batch: {"transactions": [...], "safeAddress": "..."}
    2. Multiple transaction batches: [{"transactions": [...], "safeAddress": "..."}, ...]

    Used for auto-compound consolidation files that may contain multiple transactions
    grouped by EigenPod (withdrawal credentials).
    """
    with open(file_path, 'r') as f:
        data = json.load(f)

    # Handle new format: array of transaction batches
    if isinstance(data, list):
        if len(data) == 0:
            return [], DEFAULT_SAFE_ADDRESS

        # Use the first batch's safe/from address and collect all transactions
        safe_address = data[0].get('safeAddress', data[0].get('from', DEFAULT_SAFE_ADDRESS))
        all_transactions = []
        for batch in data:
            batch_transactions = batch.get('transactions', [])
            all_transactions.extend(batch_transactions)
        return all_transactions, safe_address

    # Handle old format: single transaction batch, or raw EOA format with "from"
    else:
        transactions = data.get('transactions', [])
        safe_address = data.get('safeAddress', data.get('from', DEFAULT_SAFE_ADDRESS))
        return transactions, safe_address


# ==============================================================================
# Tenderly API Functions
# ==============================================================================

def get_tenderly_credentials() -> Tuple[str, str, str]:
    """Get Tenderly credentials from environment variables.
    
    Supports two formats:
    1. Separate variables: TENDERLY_ACCOUNT_SLUG, TENDERLY_PROJECT_SLUG
    2. Combined URL: TENDERLY_API_URL (e.g., https://api.tenderly.co/api/v1/account/{slug}/project/{slug}/)
    """
    access_token = os.environ.get('TENDERLY_API_ACCESS_TOKEN')
    account_slug = os.environ.get('TENDERLY_ACCOUNT_SLUG')
    project_slug = os.environ.get('TENDERLY_PROJECT_SLUG')
    
    # Try to extract from TENDERLY_API_URL if slugs not provided
    if not account_slug or not project_slug:
        api_url = os.environ.get('TENDERLY_API_URL', '')
        # Parse URL like: https://api.tenderly.co/api/v1/account/{account}/project/{project}/
        match = re.search(r'/account/([^/]+)/project/([^/]+)', api_url)
        if match:
            if not account_slug:
                account_slug = match.group(1)
            if not project_slug:
                project_slug = match.group(2)
    
    if not access_token:
        raise ValueError("TENDERLY_API_ACCESS_TOKEN not set")
    if not account_slug or not project_slug:
        raise ValueError("Could not determine Tenderly account/project slugs. Set TENDERLY_ACCOUNT_SLUG and TENDERLY_PROJECT_SLUG, or TENDERLY_API_URL")
    
    return access_token, account_slug, project_slug


def list_virtual_testnets(verbose: bool = True) -> List[Dict]:
    """List all Virtual Testnets in the project."""
    if not requests:
        raise ImportError("requests library required for Tenderly. Run: pip install requests")
    
    access_token, account_slug, project_slug = get_tenderly_credentials()
    
    url = f"https://api.tenderly.co/api/v1/account/{account_slug}/project/{project_slug}/vnets"
    headers = {
        "X-Access-Key": access_token,
        "Content-Type": "application/json"
    }
    
    response = requests.get(url, headers=headers)
    response.raise_for_status()
    
    data = response.json()
    
    # Handle both response formats: list directly or dict with 'vnets' key
    if isinstance(data, list):
        vnets = data
    elif isinstance(data, dict):
        vnets = data.get('vnets', [])
    else:
        vnets = []
    
    if verbose:
        print(f"\n{'='*60}")
        print("Tenderly Virtual Testnets")
        print(f"{'='*60}")
        
        if not vnets:
            print("No virtual testnets found.")
        else:
            for vnet in vnets:
                status = vnet.get('status', 'unknown')
                status_emoji = "🟢" if status == 'running' else "🔴"
                print(f"\n{status_emoji} {vnet.get('display_name', 'Unnamed')}")
                print(f"   ID: {vnet.get('id')}")
                print(f"   Slug: {vnet.get('slug')}")
                print(f"   Status: {status}")
                
                fork_config = vnet.get('fork_config', {})
                print(f"   Network: {fork_config.get('network_id', 'N/A')}")
                print(f"   Fork Block: {fork_config.get('block_number', 'N/A')}")
                
                # Print Admin RPC URL
                rpcs = vnet.get('rpcs', [])
                admin_rpc = next((r['url'] for r in rpcs if r.get('name') == 'Admin RPC'), None)
                if admin_rpc:
                    print(f"   Admin RPC: {admin_rpc}")
        
        print(f"\n{'='*60}\n")
    
    return vnets


def create_virtual_testnet(name: str, chain_id: int = 1, verbose: bool = True) -> Dict:
    """Create a new Virtual Testnet."""
    if not requests:
        raise ImportError("requests library required for Tenderly. Run: pip install requests")
    
    access_token, account_slug, project_slug = get_tenderly_credentials()
    
    url = f"https://api.tenderly.co/api/v1/account/{account_slug}/project/{project_slug}/vnets"
    headers = {
        "X-Access-Key": access_token,
        "Content-Type": "application/json"
    }
    
    # Generate unique slug
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    slug = f"{name.lower().replace(' ', '-')}-{timestamp}"
    
    # Get latest block from mainnet
    block_number = None
    rpc_url = os.environ.get('MAINNET_RPC_URL')
    if rpc_url:
        try:
            resp = requests.post(rpc_url, json={
                "jsonrpc": "2.0",
                "method": "eth_blockNumber",
                "params": [],
                "id": 1
            }, timeout=10)
            block_number = int(resp.json()['result'], 16)
        except:
            pass
    
    payload = {
        "slug": slug,
        "display_name": name,
        "fork_config": {
            "network_id": chain_id
        },
        "virtual_network_config": {
            "chain_config": {
                "chain_id": chain_id
            }
        },
        "sync_state_config": {
            "enabled": False
        },
        "explorer_page_config": {
            "enabled": True,
            "verification_visibility": "bytecode"
        }
    }
    
    if block_number:
        payload["fork_config"]["block_number"] = block_number
    
    if verbose:
        print(f"Creating Virtual Testnet: {name}")
        print(f"  Slug: {slug}")
        if block_number:
            print(f"  Fork Block: {block_number}")
    
    response = requests.post(url, headers=headers, json=payload)
    response.raise_for_status()
    
    result = response.json()
    
    if verbose:
        print(f"  ID: {result.get('id')}")
        rpcs = result.get('rpcs', [])
        admin_rpc = next((r['url'] for r in rpcs if r.get('name') == 'Admin RPC'), None)
        if admin_rpc:
            print(f"  Admin RPC: {admin_rpc}")
        print(f"  ✅ Created successfully!")
    
    return result


def get_vnet_by_id(vnet_id: str) -> Optional[Dict]:
    """Get a virtual testnet by ID."""
    if not requests:
        raise ImportError("requests library required for Tenderly. Run: pip install requests")
    
    access_token, account_slug, project_slug = get_tenderly_credentials()
    
    url = f"https://api.tenderly.co/api/v1/account/{account_slug}/project/{project_slug}/vnets/{vnet_id}"
    headers = {
        "X-Access-Key": access_token,
        "Content-Type": "application/json"
    }
    
    try:
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError:
        return None


def get_admin_rpc_url(vnet_data: Dict) -> str:
    """Extract Admin RPC URL from VNet data."""
    rpcs = vnet_data.get('rpcs', [])
    for rpc in rpcs:
        if rpc.get('name') == 'Admin RPC':
            return rpc.get('url')
    raise ValueError("No Admin RPC URL found in VNet data")


def rpc_request(rpc_url: str, method: str, params: List = None) -> Any:
    """Make a JSON-RPC request to a VNet RPC endpoint."""
    if not requests:
        raise ImportError("requests library required for Tenderly")
    
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params or [],
        "id": 1
    }
    
    response = requests.post(rpc_url, json=payload, timeout=60)
    response.raise_for_status()
    
    result = response.json()
    if 'error' in result:
        raise RuntimeError(f"RPC error: {result['error']}")
    return result.get('result')


def warp_time_on_vnet(rpc_url: str, delay_seconds: int, verbose: bool = True) -> int:
    """Warp time on a Tenderly VNet using evm_setNextBlockTimestamp and mine a block."""
    # Get current block timestamp
    block = rpc_request(rpc_url, "eth_getBlockByNumber", ["latest", False])
    current_timestamp = int(block.get('timestamp', '0x0'), 16)
    
    new_timestamp = current_timestamp + delay_seconds
    
    if verbose:
        print(f"  Current timestamp: {current_timestamp} ({datetime.fromtimestamp(current_timestamp)})")
        print(f"  Warping by: {delay_seconds}s ({delay_seconds / 3600:.1f}h)")
        print(f"  New timestamp: {new_timestamp} ({datetime.fromtimestamp(new_timestamp)})")
    
    # Set the next block timestamp
    rpc_request(rpc_url, "evm_setNextBlockTimestamp", [new_timestamp])
    
    # Mine a block to apply the timestamp
    rpc_request(rpc_url, "evm_mine", [])
    
    if verbose:
        print(f"  ✅ Time warp complete, mined new block")
    
    return new_timestamp


def submit_tx_via_rpc(
    rpc_url: str,
    from_addr: str,
    to_addr: str,
    data: str,
    value: str = "0x0",
    verbose: bool = True
) -> Dict:
    """Submit a transaction via Admin RPC using eth_sendTransaction."""
    if not requests:
        raise ImportError("requests library required for Tenderly")

    if verbose:
        print(f"  Submitting transaction...")
        print(f"    From: {from_addr}")
        print(f"    To: {to_addr}")
        data_preview = f"{data[:66]}..." if len(data) > 66 else data
        print(f"    Data: {data_preview}")

    # Use eth_sendTransaction
    payload = {
        "jsonrpc": "2.0",
        "method": "eth_sendTransaction",
        "params": [{
            "from": from_addr,
            "to": to_addr,
            "value": value,
            "data": data,
            "gas": "0x7a1200"  # 8M gas
        }],
        "id": 1
    }

    response = requests.post(rpc_url, json=payload, timeout=60)
    response.raise_for_status()
    result = response.json()

    if 'error' in result:
        if verbose:
            print(f"    ❌ Error: {result['error']}")
        return {"status": "failed", "error": result['error']}

    tx_hash = result.get('result')
    if verbose:
        print(f"    ✅ Tx submitted: {tx_hash}")

    # Wait for transaction to be mined and check receipt
    if tx_hash:
        receipt = wait_for_tx_receipt(rpc_url, tx_hash, verbose=verbose)

        # Check if receipt is empty (timeout)
        if not receipt:
            if verbose:
                print(f"    ❌ Tx failed - Timeout waiting for receipt")
            return {"status": "failed", "error": "Timeout waiting for transaction receipt", "tx_hash": tx_hash, "receipt": receipt}

        # Extract gas usage from receipt
        gas_used_hex = receipt.get('gasUsed', '0x0')
        gas_used = int(gas_used_hex, 16)

        # Check for excessive gas usage
        GAS_LIMIT_MAX = 10_000_000  # 10 million gas limit
        if gas_used > GAS_LIMIT_MAX:
            if verbose:
                print(f"    ❌ Tx failed - Gas used: {gas_used:,} (exceeds limit of {GAS_LIMIT_MAX:,})")
            return {"status": "failed", "error": f"Gas usage {gas_used:,} exceeds limit of {GAS_LIMIT_MAX:,}", "tx_hash": tx_hash, "receipt": receipt, "gas_used": gas_used}

        if receipt.get('status') == '0x1':
            if verbose:
                print(f"    ✅ Tx successful - Gas used: {gas_used:,}")
            return {"status": "success", "tx_hash": tx_hash, "receipt": receipt, "gas_used": gas_used}
        elif receipt.get('status') == '0x0':
            # Transaction reverted
            if verbose:
                print(f"    ❌ Tx reverted - Gas used: {gas_used:,}")
            return {"status": "failed", "error": "Transaction reverted", "tx_hash": tx_hash, "receipt": receipt, "gas_used": gas_used}
        else:
            # Unknown status
            if verbose:
                print(f"    ❌ Tx failed - Unknown status: {receipt.get('status')}")
            return {"status": "failed", "error": f"Unknown transaction status: {receipt.get('status')}", "tx_hash": tx_hash, "receipt": receipt, "gas_used": gas_used}

    # If no transaction hash was returned, submission failed
    if verbose:
        print(f"    ❌ Tx submission failed - No transaction hash returned")
    return {"status": "failed", "error": "Transaction submission failed - no hash returned", "tx_hash": None}


def wait_for_tx_receipt(rpc_url: str, tx_hash: str, timeout: int = 30, verbose: bool = True) -> Dict:
    """Wait for transaction receipt and return it."""
    start_time = time.time()

    while time.time() - start_time < timeout:
        try:
            receipt = rpc_request(rpc_url, "eth_getTransactionReceipt", [tx_hash])
            if receipt:
                return receipt
        except:
            pass
        time.sleep(1)

    if verbose:
        print(f"    ⚠️  Timeout waiting for receipt")
    return {}


# ==============================================================================
# Simulation Functions
# ==============================================================================

def run_tenderly_simulation(args) -> int:
    """Run simulation using Tenderly Virtual Testnet."""
    project_root = get_project_root()

    print("=" * 60)
    print("TENDERLY VIRTUAL TESTNET SIMULATION")
    print("=" * 60)
    print(f"Timestamp: {datetime.now().isoformat()}")
    print("")

    try:
        access_token, account_slug, project_slug = get_tenderly_credentials()
        print(f"Account: {account_slug}")
        print(f"Project: {project_slug}")
    except ValueError as e:
        print(f"Error: {e}")
        return 1

    # Get or create Virtual Testnet
    vnet_id = args.vnet_id
    vnet_data = None

    if vnet_id:
        print(f"\nUsing existing VNet: {vnet_id}")
        vnet_data = get_vnet_by_id(vnet_id)
        if not vnet_data:
            print(f"Error: VNet not found: {vnet_id}")
            return 1
    else:
        vnet_name = args.vnet_name or f"Simulation-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
        print("")
        try:
            vnet_data = create_virtual_testnet(vnet_name)
            vnet_id = vnet_data.get('id')
        except Exception as e:
            print(f"Failed to create Virtual Testnet: {e}")
            return 1

    # Get Admin RPC URL
    try:
        admin_rpc = get_admin_rpc_url(vnet_data)
    except ValueError as e:
        print(f"Error: {e}")
        return 1

    print(f"\nVNet ID: {vnet_id}")
    print(f"Admin RPC: {admin_rpc}")

    # Determine safe address
    safe_address = args.safe_address or os.environ.get('SAFE_ADDRESS', DEFAULT_SAFE_ADDRESS)
    print(f"Safe Address: {safe_address}")

    all_success = True
    total_gas_used = 0
    
    # Simple mode (--txns)
    if args.txns:
        print(f"\n{'='*40}")
        print("SIMPLE MODE (No Timelock)")
        print(f"{'='*40}")

        # Handle comma-separated list of files
        txn_files = [f.strip() for f in args.txns.split(',')]
        all_transactions = []
        file_safe = None

        for i, txn_file in enumerate(txn_files):
            file_path = resolve_file_path(project_root, txn_file)
            print(f"Loading file {i+1}/{len(txn_files)}: {file_path}")

            if not file_path.exists():
                print(f"Error: File not found: {file_path}")
                return 1

            transactions, current_safe = load_transactions_from_file(file_path)
            if file_safe is None:
                file_safe = current_safe
            elif file_safe != current_safe and current_safe is not None:
                print(f"Warning: File {file_path} has different safe address ({current_safe}) than previous files ({file_safe})")

            all_transactions.extend(transactions)

        safe = args.safe_address or file_safe
        transactions = all_transactions
        print(f"Transactions: {len(transactions)}")
        
        phase_gas_used = 0
        for i, tx in enumerate(transactions):
            print(f"\n--- Transaction {i+1}/{len(transactions)} ---")
            value = tx.get('value', '0')
            if not str(value).startswith('0x'):
                value = hex(int(value))

            result = submit_tx_via_rpc(
                admin_rpc,
                safe,
                tx['to'],
                tx['data'],
                value
            )
            if result.get('status') != 'success':
                all_success = False
                if result.get('tx_hash'):
                    print(f"    🔗 Tx Link: https://dashboard.tenderly.co/{account_slug}/{project_slug}/testnet/{vnet_id}/tx/{result['tx_hash']}")
            # Accumulate gas usage
            if 'gas_used' in result:
                phase_gas_used += result['gas_used']
                total_gas_used += result['gas_used']

        print(f"\n📊 Phase Summary: {len(transactions)} transactions, {phase_gas_used:,} gas used")
    
    # Timelock mode (--schedule + --execute)
    elif args.schedule and args.execute:
        # Phase 1: Schedule
        print(f"\n{'='*40}")
        print("PHASE 1: SCHEDULE")
        print(f"{'='*40}")
        
        schedule_path = resolve_file_path(project_root, args.schedule)
        print(f"Loading: {schedule_path}")
        
        if not schedule_path.exists():
            print(f"Error: File not found: {schedule_path}")
            return 1
        
        transactions, file_safe = load_transactions_from_file(schedule_path)
        safe = args.safe_address or file_safe
        print(f"Transactions: {len(transactions)}")
        
        phase_gas_used = 0
        for i, tx in enumerate(transactions):
            print(f"\n--- Schedule Transaction {i+1}/{len(transactions)} ---")
            value = tx.get('value', '0')
            if not str(value).startswith('0x'):
                value = hex(int(value))

            result = submit_tx_via_rpc(
                admin_rpc,
                safe,
                tx['to'],
                tx['data'],
                value
            )
            if result.get('status') != 'success':
                all_success = False
                if result.get('tx_hash'):
                    print(f"    🔗 Tx Link: https://dashboard.tenderly.co/{account_slug}/{project_slug}/testnet/{vnet_id}/tx/{result['tx_hash']}")
            # Accumulate gas usage
            if 'gas_used' in result:
                phase_gas_used += result['gas_used']
                total_gas_used += result['gas_used']

        print(f"\n📊 Schedule Phase Summary: {len(transactions)} transactions, {phase_gas_used:,} gas used")

        # Time Warp
        delay_seconds = parse_delay(args.delay) if args.delay else 28800
        print(f"\n{'='*40}")
        print("TIME WARP")
        print(f"{'='*40}")
        warp_time_on_vnet(admin_rpc, delay_seconds)
        
        # Phase 2: Execute
        print(f"\n{'='*40}")
        print("PHASE 2: EXECUTE")
        print(f"{'='*40}")
        
        execute_path = resolve_file_path(project_root, args.execute)
        print(f"Loading: {execute_path}")
        
        if not execute_path.exists():
            print(f"Error: File not found: {execute_path}")
            return 1
        
        transactions, _ = load_transactions_from_file(execute_path)
        print(f"Transactions: {len(transactions)}")
        
        phase_gas_used = 0
        for i, tx in enumerate(transactions):
            print(f"\n--- Execute Transaction {i+1}/{len(transactions)} ---")
            value = tx.get('value', '0')
            if not str(value).startswith('0x'):
                value = hex(int(value))

            result = submit_tx_via_rpc(
                admin_rpc,
                safe,
                tx['to'],
                tx['data'],
                value
            )
            if result.get('status') != 'success':
                all_success = False
                if result.get('tx_hash'):
                    print(f"    🔗 Tx Link: https://dashboard.tenderly.co/{account_slug}/{project_slug}/testnet/{vnet_id}/tx/{result['tx_hash']}")
            # Accumulate gas usage
            if 'gas_used' in result:
                phase_gas_used += result['gas_used']
                total_gas_used += result['gas_used']

        print(f"\n📊 Execute Phase Summary: {len(transactions)} transactions, {phase_gas_used:,} gas used")

        # Phase 3: Follow-up (optional --then)
        if args.then:
            print(f"\n{'='*40}")
            print("PHASE 3: FOLLOW-UP")
            print(f"{'='*40}")

            # Handle comma-separated list of then files
            then_files = [f.strip() for f in args.then.split(',')]
            all_then_transactions = []

            for j, then_file in enumerate(then_files):
                then_path = resolve_file_path(project_root, then_file)
                print(f"Loading follow-up file {j+1}/{len(then_files)}: {then_path}")

                if not then_path.exists():
                    print(f"Error: File not found: {then_path}")
                    return 1

                then_transactions, _ = load_transactions_from_file(then_path)
                all_then_transactions.extend(then_transactions)

            transactions = all_then_transactions
            print(f"Total follow-up transactions: {len(transactions)}")

            phase_gas_used = 0
            for i, tx in enumerate(transactions):
                print(f"\n--- Follow-up Transaction {i+1}/{len(transactions)} ---")
                value = tx.get('value', '0')
                if not str(value).startswith('0x'):
                    value = hex(int(value))

                result = submit_tx_via_rpc(
                    admin_rpc,
                    safe,
                    tx['to'],
                    tx['data'],
                    value
                )
                if result.get('status') != 'success':
                    all_success = False
                    if result.get('tx_hash'):
                        print(f"    🔗 Tx Link: https://dashboard.tenderly.co/{account_slug}/{project_slug}/testnet/{vnet_id}/tx/{result['tx_hash']}")
                # Accumulate gas usage
                if 'gas_used' in result:
                    phase_gas_used += result['gas_used']
                    total_gas_used += result['gas_used']

            print(f"\n📊 Follow-up Phase Summary: {len(transactions)} transactions, {phase_gas_used:,} gas used")

    # Summary
    print(f"\n{'='*60}")
    print("SIMULATION COMPLETE")
    print(f"{'='*60}")
    print(f"VNet ID: {vnet_id}")
    print(f"View in Tenderly: https://dashboard.tenderly.co/{account_slug}/{project_slug}/testnet/{vnet_id}")
    print(f"Result: {'✅ SUCCESS' if all_success else '❌ FAILED'}")
    print(f"Total Gas Used: {total_gas_used:,}")

    return 0 if all_success else 1


def run_forge_simulation(args) -> int:
    """Run simulation using Forge script."""
    print("=" * 60)
    print("FORGE SIMULATION")
    print("=" * 60)
    print("")
    
    rpc_url = args.rpc_url or os.environ.get('MAINNET_RPC_URL')
    if not rpc_url:
        print("Error: MAINNET_RPC_URL not set")
        return 1
    
    # Build forge command
    cmd = [
        'forge', 'script',
        'script/operations/utils/SimulateTransactions.s.sol:SimulateTransactions',
        '--fork-url', rpc_url,
        '-vvvv'
    ]
    
    # Set environment variables for the script
    env = os.environ.copy()
    
    if args.txns:
        env['TXNS'] = args.txns
        env['DELAY_AFTER_FILE'] = '0'  # No delay in simple mode
    elif args.schedule and args.execute:
        # Compose TXNS from schedule, execute, and optionally then files
        txns_list = [args.schedule, args.execute]
        if args.then:
            # Handle comma-separated then files
            then_files = [f.strip() for f in args.then.split(',')]
            txns_list.extend(then_files)
        env['TXNS'] = ','.join(txns_list)
        # Only apply delay after file index 0 (between schedule and execute)
        # No delay between execute and then files (index 1→...)
        env['DELAY_AFTER_FILE'] = '0'  # Only delay after first file
    
    # Also set individual file vars for reference
    if args.schedule:
        env['SCHEDULE_FILE'] = args.schedule
    if args.execute:
        env['EXECUTE_FILE'] = args.execute
    if args.then:
        env['THEN_FILE'] = args.then
    
    delay_seconds = parse_delay(args.delay) if args.delay else 28800
    env['DELAY'] = str(delay_seconds)
    
    if args.safe_address:
        env['SAFE_ADDRESS'] = args.safe_address
    
    # Run forge
    print(f"Running: {' '.join(cmd)}")
    print("")
    
    result = subprocess.run(cmd, env=env)
    
    return result.returncode


def main():
    parser = argparse.ArgumentParser(
        description='Simulate timelock-gated transactions',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Simple simulation (Forge)
  python simulate.py --txns consolidation.json

  # Timelock workflow (Forge)
  python simulate.py --schedule schedule.json --execute execute.json --delay 8h

  # Full auto-compound workflow (Forge)
  python simulate.py \\
      --schedule auto-compound-txns-link-schedule.json \\
      --execute auto-compound-txns-link-execute.json \\
      --then auto-compound-txns-consolidation.json

  # List Tenderly VNets
  python simulate.py --tenderly --list-vnets

  # Tenderly simulation (creates new VNet)
  python simulate.py --tenderly \\
      --schedule auto-compound-txns-link-schedule.json \\
      --execute auto-compound-txns-link-execute.json \\
      --vnet-name "AutoCompound-Test"

  # Tenderly simulation (use existing VNet)
  python simulate.py --tenderly \\
      --vnet-id "7113fe5d-bc69-475c-bfd5-a2a720c14d56" \\
      --schedule schedule.json \\
      --execute execute.json
        """
    )
    
    # Mode selection
    parser.add_argument(
        '--tenderly',
        action='store_true',
        help='Use Tenderly Virtual Testnet instead of Forge fork'
    )
    parser.add_argument(
        '--list-vnets',
        action='store_true',
        help='List existing Tenderly Virtual Testnets and exit'
    )
    
    # Tenderly-specific options
    parser.add_argument(
        '--vnet-id',
        help='Use existing Tenderly VNet by ID'
    )
    parser.add_argument(
        '--vnet-name',
        help='Display name for new Tenderly VNet'
    )
    
    # Transaction files
    parser.add_argument(
        '--txns', '-t',
        help='Simple transaction file(s) (no timelock). Can be comma-separated for multiple files'
    )
    parser.add_argument(
        '--schedule', '-s',
        help='Schedule transaction file (phase 1)'
    )
    parser.add_argument(
        '--execute', '-e',
        help='Execute transaction file (phase 2, after timelock)'
    )
    parser.add_argument(
        '--then',
        help='Follow-up transaction file(s) (phase 3, optional). Can be comma-separated for multiple files'
    )
    
    # Options
    parser.add_argument(
        '--delay', '-d',
        default='8h',
        help='Timelock delay (e.g., 8h, 72h, 1d, 28800). Default: 8h'
    )
    parser.add_argument(
        '--rpc-url', '-r',
        help='RPC URL for fork. Default: $MAINNET_RPC_URL'
    )
    parser.add_argument(
        '--safe-address',
        help='Gnosis Safe address. Default: EtherFi Operating Admin'
    )
    
    args = parser.parse_args()
    
    # Handle --list-vnets
    if args.list_vnets:
        if not args.tenderly:
            print("Note: --list-vnets implies --tenderly")
        
        try:
            list_virtual_testnets(verbose=True)
            return 0
        except Exception as e:
            print(f"Error listing Virtual Testnets: {e}")
            return 1
    
    # Validate arguments
    if args.txns and (args.schedule or args.execute):
        parser.error("Cannot use --txns with --schedule/--execute")

    if not args.txns and not (args.schedule and args.execute):
        parser.error("Must provide either --txns or both --schedule and --execute")
    
    if (args.schedule and not args.execute) or (args.execute and not args.schedule):
        parser.error("--schedule and --execute must be used together")
    
    if args.txns and args.then:
        parser.error("--then cannot be used with --txns. Use --schedule/--execute for multi-phase workflows")
    
    # Run simulation
    try:
        if args.tenderly:
            return run_tenderly_simulation(args)
        else:
            return run_forge_simulation(args)
    except Exception as e:
        print(f"Error: {e}")
        return 1


if __name__ == '__main__':
    sys.exit(main())

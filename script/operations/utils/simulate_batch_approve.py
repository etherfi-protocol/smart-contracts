#!/usr/bin/env python3
"""
Simulate batchApproveRegistration on Tenderly Virtual Testnet.

Usage:
    python3 script/operations/utils/simulate_batch_approve.py \
        --json validators.json \
        --vnet-name "BatchApprove-Test"

    # Or use existing VNet
    python3 script/operations/utils/simulate_batch_approve.py \
        --json validators.json \
        --vnet-id "existing-vnet-id"

JSON Format:
    [
      {"validator_id": 31225, "pubkey": "0xb4d601...", "eigenpod": "0x9ad4d1..."},
      {"validator_id": 31226, "pubkey": "0xa5eefc...", "eigenpod": "0x9ad4d1..."}
    ]
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    from eth_abi import encode
    HAS_ETH_ABI = True
except ImportError:
    HAS_ETH_ABI = False

try:
    import requests
except ImportError:
    print("Error: requests library required. Install with: pip install requests")
    sys.exit(1)

def load_env_file():
    """Load .env file from project root (where foundry.toml exists)."""
    # Start from script directory and walk up to find foundry.toml (project root)
    current = Path(__file__).resolve().parent
    for _ in range(10):
        foundry_file = current / 'foundry.toml'
        if foundry_file.exists():
            env_file = current / '.env'
            if env_file.exists():
                with open(env_file, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith('#'):
                            continue
                        if '=' in line:
                            key, value = line.split('=', 1)
                            key = key.strip()
                            value = value.strip().strip('"').strip("'")
                            os.environ[key] = value
            return
        if current.parent == current:
            break
        current = current.parent

load_env_file()

# Mainnet addresses
LIQUIDITY_POOL = "0x308861A430be4cce5502d0A12724771Fc6DaF216"
NODES_MANAGER = "0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F"
ETHERFI_ADMIN = "0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705"

TENDERLY_API_BASE = "https://api.tenderly.co/api/v1"


def get_tenderly_credentials() -> Tuple[str, str, str]:
    """Get Tenderly credentials from environment."""
    import re
    
    access_token = os.environ.get('TENDERLY_API_ACCESS_TOKEN')
    account_slug = os.environ.get('TENDERLY_ACCOUNT_SLUG')
    project_slug = os.environ.get('TENDERLY_PROJECT_SLUG')
    
    # Try to extract from TENDERLY_API_URL
    if not account_slug or not project_slug:
        api_url = os.environ.get('TENDERLY_API_URL', '')
        match = re.search(r'/account/([^/]+)/project/([^/]+)', api_url)
        if match:
            if not account_slug:
                account_slug = match.group(1)
            if not project_slug:
                project_slug = match.group(2)
    
    if not access_token or not account_slug or not project_slug:
        print("Error: Missing Tenderly credentials")
        print("  Set: TENDERLY_API_ACCESS_TOKEN, TENDERLY_ACCOUNT_SLUG, TENDERLY_PROJECT_SLUG")
        print("  Or: TENDERLY_API_ACCESS_TOKEN, TENDERLY_API_URL")
        sys.exit(1)
    
    return access_token, account_slug, project_slug


def tenderly_request(method: str, endpoint: str, data: Optional[Dict] = None) -> Dict:
    """Make a request to Tenderly API."""
    access_token, _, _ = get_tenderly_credentials()
    
    url = f"{TENDERLY_API_BASE}{endpoint}"
    headers = {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-Access-Key': access_token
    }
    
    response = requests.request(method, url, headers=headers, json=data, timeout=60)
    
    if not response.ok:
        print(f"Tenderly API error ({response.status_code}): {response.text}")
        sys.exit(1)
    
    return response.json()


def create_virtual_testnet(display_name: str) -> Dict:
    """Create a new Tenderly Virtual Testnet."""
    _, account_slug, project_slug = get_tenderly_credentials()
    
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    slug = f"{display_name.lower().replace(' ', '-')}-{timestamp}"
    
    payload = {
        "slug": slug,
        "display_name": display_name,
        "fork_config": {"network_id": 1},
        "virtual_network_config": {"chain_config": {"chain_id": 1}},
        "sync_state_config": {"enabled": True, "commitment_level": "latest"},
        "explorer_page_config": {"enabled": True, "verification_visibility": "src"}
    }
    
    print(f"Creating Virtual Testnet: {display_name}")
    endpoint = f"/account/{account_slug}/project/{project_slug}/vnets"
    result = tenderly_request('POST', endpoint, data=payload)
    
    print(f"  ID: {result.get('id')}")
    rpcs = result.get('rpcs', [])
    admin_rpc = next((r['url'] for r in rpcs if r.get('name') == 'Admin RPC'), None)
    if admin_rpc:
        print(f"  Admin RPC: {admin_rpc}")
    
    return result


def get_vnet_by_id(vnet_id: str) -> Optional[Dict]:
    """Get a virtual testnet by ID."""
    _, account_slug, project_slug = get_tenderly_credentials()
    endpoint = f"/account/{account_slug}/project/{project_slug}/vnets"
    vnets = tenderly_request('GET', endpoint)
    
    if isinstance(vnets, list):
        for vnet in vnets:
            if vnet.get('id') == vnet_id:
                return vnet
    return None


def get_admin_rpc_url(vnet_data: Dict) -> str:
    """Extract Admin RPC URL from VNet data."""
    rpcs = vnet_data.get('rpcs', [])
    for rpc in rpcs:
        if rpc.get('name') == 'Admin RPC':
            return rpc.get('url')
    raise ValueError("No Admin RPC URL found")


def rpc_call(rpc_url: str, method: str, params: List = None) -> any:
    """Make a JSON-RPC call."""
    payload = {"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}
    response = requests.post(rpc_url, json=payload, timeout=60)
    result = response.json()
    if 'error' in result:
        raise RuntimeError(f"RPC error: {result['error']}")
    return result.get('result')


def encode_batch_approve_calldata(validator_ids: List[int], pubkeys: List[bytes]) -> str:
    """Encode batchApproveRegistration calldata."""
    # Function selector: batchApproveRegistration(uint256[],bytes[],bytes[])
    # keccak256("batchApproveRegistration(uint256[],bytes[],bytes[])")[:4]
    selector = "0x84b0196e"  # We'll compute it properly
    
    # Actually compute the selector
    import hashlib
    sig = "batchApproveRegistration(uint256[],bytes[],bytes[])"
    selector = "0x" + hashlib.sha3_256(sig.encode()).hexdigest()[:8]
    # Use keccak256 instead
    from eth_hash.auto import keccak
    selector = "0x" + keccak(sig.encode()).hex()[:8]
    
    # Create dummy signatures (96 bytes each)
    signatures = [b'\x00' * 96 for _ in validator_ids]
    
    if HAS_ETH_ABI:
        # Use eth_abi for proper encoding
        encoded = encode(
            ['uint256[]', 'bytes[]', 'bytes[]'],
            [validator_ids, pubkeys, signatures]
        )
        return selector + encoded.hex()
    else:
        # Manual encoding fallback (simplified)
        print("Warning: eth_abi not installed, using simplified encoding")
        # This is a simplified version - for production use eth_abi
        return selector + "..." 


def load_validators(json_path: str) -> Tuple[List[int], List[bytes]]:
    """Load validators from JSON file."""
    with open(json_path, 'r') as f:
        data = json.load(f)
    
    validator_ids = []
    pubkeys = []
    
    for item in data:
        validator_ids.append(item['validator_id'])
        pubkey = item['pubkey']
        if pubkey.startswith('0x'):
            pubkey = pubkey[2:]
        pubkeys.append(bytes.fromhex(pubkey))
    
    return validator_ids, pubkeys


def analyze_validators(rpc_url: str, validator_ids: List[int]) -> Dict[str, List[int]]:
    """Analyze which validators belong to which nodes."""
    nodes = {}
    
    for vid in validator_ids:
        # Call etherfiNodeAddress(uint256)
        from eth_hash.auto import keccak
        selector = keccak(b"etherfiNodeAddress(uint256)").hex()[:8]
        data = "0x" + selector + hex(vid)[2:].zfill(64)
        
        result = rpc_call(rpc_url, "eth_call", [{
            "to": NODES_MANAGER,
            "data": data
        }, "latest"])
        
        # Extract address from result (last 20 bytes of 32-byte response)
        node_addr = "0x" + result[-40:]
        
        if node_addr not in nodes:
            nodes[node_addr] = []
        nodes[node_addr].append(vid)
    
    return nodes


def submit_transaction(rpc_url: str, from_addr: str, to_addr: str, data: str, value: str = "0x0") -> Dict:
    """Submit a transaction via eth_sendTransaction."""
    print(f"  Submitting transaction...")
    print(f"    From: {from_addr}")
    print(f"    To: {to_addr}")
    print(f"    Data: {data[:66]}..." if len(data) > 66 else f"    Data: {data}")
    
    result = rpc_call(rpc_url, "eth_sendTransaction", [{
        "from": from_addr,
        "to": to_addr,
        "value": value,
        "data": data,
        "gas": "0x7a1200"  # 8M gas
    }])
    
    print(f"    Tx Hash: {result}")
    
    # Get transaction receipt
    receipt = rpc_call(rpc_url, "eth_getTransactionReceipt", [result])
    
    status = int(receipt.get('status', '0x0'), 16)
    if status == 1:
        print(f"    ✅ Status: SUCCESS")
    else:
        print(f"    ❌ Status: REVERTED")
    
    return {"tx_hash": result, "status": "success" if status == 1 else "failed", "receipt": receipt}


def main():
    parser = argparse.ArgumentParser(
        description='Simulate batchApproveRegistration on Tenderly Virtual Testnet',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument('--json', '-j', required=True, help='JSON file with validator data')
    parser.add_argument('--vnet-id', help='Use existing VNet by ID')
    parser.add_argument('--vnet-name', default='BatchApprove-Sim', help='Name for new VNet')
    parser.add_argument('--analyze-only', action='store_true', help='Only analyze node distribution')
    
    args = parser.parse_args()
    
    # Resolve JSON path
    json_path = args.json
    if not os.path.isabs(json_path):
        # Try relative to current dir, then project root
        if not os.path.exists(json_path):
            project_root = Path(__file__).resolve().parent.parent.parent.parent
            json_path = project_root / json_path
    
    if not os.path.exists(json_path):
        print(f"Error: JSON file not found: {args.json}")
        sys.exit(1)
    
    print("=" * 60)
    print("BATCH APPROVE SIMULATION (Tenderly)")
    print("=" * 60)
    print(f"JSON file: {json_path}")
    print("")
    
    # Load validators
    validator_ids, pubkeys = load_validators(json_path)
    print(f"Validators loaded: {len(validator_ids)}")
    print(f"  First: {validator_ids[0]}")
    print(f"  Last: {validator_ids[-1]}")
    print("")
    
    # Get or create VNet
    if args.vnet_id:
        print(f"Using existing VNet: {args.vnet_id}")
        vnet_data = get_vnet_by_id(args.vnet_id)
        if not vnet_data:
            print(f"Error: VNet not found: {args.vnet_id}")
            sys.exit(1)
    else:
        vnet_data = create_virtual_testnet(args.vnet_name)
    
    admin_rpc = get_admin_rpc_url(vnet_data)
    print(f"Admin RPC: {admin_rpc}")
    print("")
    
    # Analyze node distribution
    print("=" * 40)
    print("NODE ANALYSIS")
    print("=" * 40)
    
    nodes = analyze_validators(admin_rpc, validator_ids)
    
    print(f"Unique nodes: {len(nodes)}")
    for node_addr, vids in nodes.items():
        print(f"  {node_addr}: {len(vids)} validators")
        if len(vids) <= 5:
            print(f"    IDs: {vids}")
        else:
            print(f"    IDs: {vids[:3]} ... {vids[-2:]}")
    
    if len(nodes) > 1:
        print("")
        print("⚠️  WARNING: Validators span multiple nodes!")
        print("   batchApproveRegistration will FAIL with InvalidEtherFiNode()")
        print("   Split into separate batches by node.")
    
    if args.analyze_only:
        print("")
        print("Analysis complete (--analyze-only)")
        return 0
    
    print("")
    print("=" * 40)
    print("SIMULATING batchApproveRegistration")
    print("=" * 40)
    print(f"Caller: EtherFiAdmin ({ETHERFI_ADMIN})")
    print(f"Target: LiquidityPool ({LIQUIDITY_POOL})")
    print(f"Validators: {len(validator_ids)}")
    print("")
    
    # Encode calldata
    try:
        calldata = encode_batch_approve_calldata(validator_ids, pubkeys)
    except Exception as e:
        print(f"Error encoding calldata: {e}")
        print("Install eth_abi: pip install eth_abi")
        sys.exit(1)
    
    # Submit transaction
    result = submit_transaction(
        admin_rpc,
        ETHERFI_ADMIN,
        LIQUIDITY_POOL,
        calldata
    )
    
    print("")
    print("=" * 60)
    print("SIMULATION COMPLETE")
    print("=" * 60)
    print(f"VNet ID: {vnet_data.get('id')}")
    print(f"Result: {result['status'].upper()}")
    
    if result['status'] == 'failed' and len(nodes) > 1:
        print("")
        print("Expected failure: validators from different nodes.")
        print("Solution: Split into separate calls per node.")
    
    return 0 if result['status'] == 'success' else 1


if __name__ == '__main__':
    sys.exit(main())


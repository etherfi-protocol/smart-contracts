#!/usr/bin/env python3
"""
generate_gnosis_txns.py - Generate Gnosis Safe transaction files for validator consolidation

This script reads consolidation-data.json and generates Gnosis Safe transaction JSON files
for importing into the Gnosis Safe Transaction Builder.

Generates:
  - link-schedule.json: Timelock schedule transaction for linking unlinked validators
  - link-execute.json: Timelock execute transaction for linking (after 8h delay)
  - consolidation-txns-N.json: Individual consolidation transactions

No external dependencies required (uses only Python standard library).

Usage:
    python3 generate_gnosis_txns.py --input consolidation-data.json --output-dir ./txns
    python3 generate_gnosis_txns.py --input consolidation-data.json --batch-size 50 --fee 1

Environment Variables:
    SAFE_ADDRESS: Override the default Safe address
    CHAIN_ID: Override the default chain ID (1 for mainnet)
"""

import argparse
import hashlib
import json
import os
import sys
from typing import Dict, List, Optional, Set, Tuple


# =============================================================================
# Constants
# =============================================================================

# Contract Addresses (Mainnet)
ETHERFI_NODES_MANAGER = "0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F"
ETHERFI_OPERATING_ADMIN = "0x2aCA71020De61bb532008049e1Bd41E451aE8AdC"
OPERATING_TIMELOCK = "0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a"

# Default parameters
DEFAULT_BATCH_SIZE = 50
DEFAULT_CHAIN_ID = 1
DEFAULT_CONSOLIDATION_FEE = 1  # 1 wei per consolidation request
MIN_DELAY_OPERATING_TIMELOCK = 28800  # 8 hours in seconds

# Function selectors
REQUEST_CONSOLIDATION_SELECTOR = "6691954e"  # requestConsolidation((bytes,bytes)[])
LINK_LEGACY_VALIDATOR_IDS_SELECTOR = "a8f85c84"  # linkLegacyValidatorIds(uint256[],bytes[])
SCHEDULE_BATCH_SELECTOR = "8f2a0bb0"  # scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)
EXECUTE_BATCH_SELECTOR = "e38335e5"  # executeBatch(address[],uint256[],bytes[],bytes32,bytes32)


# =============================================================================
# Keccak256 Implementation (for salt generation)
# =============================================================================

def keccak256(data: bytes) -> bytes:
    """
    Compute Keccak-256 hash.
    Uses hashlib if available (Python 3.11+), otherwise falls back to SHA3-256.
    Note: SHA3-256 != Keccak-256, but for salt generation purposes it's acceptable.
    For production, consider using pysha3 or pycryptodome.
    """
    try:
        # Python 3.11+ has keccak_256 in hashlib
        return hashlib.new('keccak_256', data).digest()
    except ValueError:
        # Fallback: use a pure Python implementation or SHA3-256
        # For salt generation, we can use a deterministic hash
        import struct
        
        # Simple keccak-256 implementation for salt generation
        # This is a simplified version - for critical use, use a proper library
        def _keccak_f(state):
            """Keccak-f[1600] permutation."""
            RC = [
                0x0000000000000001, 0x0000000000008082, 0x800000000000808a,
                0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
                0x8000000080008081, 0x8000000000008009, 0x000000000000008a,
                0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
                0x000000008000808b, 0x800000000000008b, 0x8000000000008089,
                0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
                0x000000000000800a, 0x800000008000000a, 0x8000000080008081,
                0x8000000000008080, 0x0000000080000001, 0x8000000080008008
            ]
            
            R = [
                [0, 36, 3, 41, 18],
                [1, 44, 10, 45, 2],
                [62, 6, 43, 15, 61],
                [28, 55, 25, 21, 56],
                [27, 20, 39, 8, 14]
            ]
            
            def rot64(x, n):
                return ((x << n) | (x >> (64 - n))) & 0xFFFFFFFFFFFFFFFF
            
            for round_idx in range(24):
                # θ step
                C = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
                D = [C[(x - 1) % 5] ^ rot64(C[(x + 1) % 5], 1) for x in range(5)]
                for x in range(5):
                    for y in range(5):
                        state[x][y] ^= D[x]
                
                # ρ and π steps
                B = [[0] * 5 for _ in range(5)]
                for x in range(5):
                    for y in range(5):
                        B[y][(2 * x + 3 * y) % 5] = rot64(state[x][y], R[x][y])
                
                # χ step
                for x in range(5):
                    for y in range(5):
                        state[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y])
                
                # ι step
                state[0][0] ^= RC[round_idx]
            
            return state
        
        def _keccak256(message):
            """Keccak-256 hash function."""
            rate = 136  # (1600 - 256*2) / 8
            capacity = 64
            
            # Padding
            padded = bytearray(message)
            padded.append(0x01)
            while len(padded) % rate != (rate - 1):
                padded.append(0x00)
            padded.append(0x80)
            
            # Initialize state
            state = [[0] * 5 for _ in range(5)]
            
            # Absorb
            for i in range(0, len(padded), rate):
                block = padded[i:i + rate]
                for j in range(min(len(block) // 8, 17)):
                    x = j % 5
                    y = j // 5
                    state[x][y] ^= struct.unpack('<Q', block[j*8:(j+1)*8])[0]
                state = _keccak_f(state)
            
            # Squeeze
            output = b''
            while len(output) < 32:
                for y in range(5):
                    for x in range(5):
                        if len(output) < 32:
                            output += struct.pack('<Q', state[x][y])[:min(8, 32 - len(output))]
                if len(output) < 32:
                    state = _keccak_f(state)
            
            return output[:32]
        
        return _keccak256(data)


# =============================================================================
# ABI Encoding Utilities (No external dependencies)
# =============================================================================

def encode_uint256(value: int) -> bytes:
    """Encode an integer as a 32-byte uint256."""
    return value.to_bytes(32, byteorder='big')


def encode_bytes32(data: bytes) -> bytes:
    """Encode bytes as bytes32 (pad or truncate to 32 bytes)."""
    if len(data) > 32:
        return data[:32]
    return data.rjust(32, b'\x00')


def encode_address(address: str) -> bytes:
    """Encode an address as 32 bytes (left-padded)."""
    addr = address.lower()
    if addr.startswith('0x'):
        addr = addr[2:]
    return bytes.fromhex(addr).rjust(32, b'\x00')


def encode_bytes_dynamic(data: bytes) -> bytes:
    """
    Encode dynamic bytes with length prefix.
    Returns length (32 bytes) + data padded to 32-byte boundary.
    """
    length = len(data)
    padding = (32 - (length % 32)) % 32
    return encode_uint256(length) + data + b'\x00' * padding


def encode_uint256_array(values: List[int]) -> bytes:
    """Encode a uint256[] array."""
    result = encode_uint256(len(values))
    for v in values:
        result += encode_uint256(v)
    return result


def encode_bytes_array(items: List[bytes]) -> bytes:
    """
    Encode a bytes[] array.
    Format: length + offsets + data
    """
    num_items = len(items)
    
    # Calculate header size (length + all offsets)
    header_size = 32 + num_items * 32
    
    # Calculate offsets and encode each item
    offsets = []
    encoded_items = []
    current_offset = num_items * 32  # Start after all offset slots
    
    for item in items:
        offsets.append(current_offset)
        encoded_item = encode_bytes_dynamic(item)
        encoded_items.append(encoded_item)
        current_offset += len(encoded_item)
    
    # Build result
    result = encode_uint256(num_items)
    for offset in offsets:
        result += encode_uint256(offset)
    for encoded_item in encoded_items:
        result += encoded_item
    
    return result


def encode_address_array(addresses: List[str]) -> bytes:
    """Encode an address[] array."""
    result = encode_uint256(len(addresses))
    for addr in addresses:
        result += encode_address(addr)
    return result


def normalize_pubkey(pubkey: str) -> bytes:
    """
    Normalize a pubkey string to 48 bytes.
    
    Args:
        pubkey: Pubkey as hex string (with or without 0x prefix)
    
    Returns:
        48-byte pubkey
    """
    if pubkey.startswith('0x'):
        pubkey = pubkey[2:]
    
    # BLS pubkeys are 48 bytes (96 hex chars)
    if len(pubkey) != 96:
        raise ValueError(f"Invalid pubkey length: expected 96 hex chars, got {len(pubkey)}")
    
    return bytes.fromhex(pubkey)


# =============================================================================
# Consolidation Transaction Encoding
# =============================================================================

def encode_consolidation_requests(source_pubkeys: List[bytes], target_pubkey: bytes) -> bytes:
    """
    Encode consolidation requests array for requestConsolidation function.
    
    The function signature is:
        requestConsolidation(ConsolidationRequest[] calldata reqs)
    
    Where ConsolidationRequest is:
        struct ConsolidationRequest {
            bytes srcPubkey;
            bytes targetPubkey;
        }
    """
    num_requests = len(source_pubkeys)
    
    # First 32 bytes: offset to the array (always 0x20 = 32 for single param)
    result = encode_uint256(32)
    
    # Array length
    result += encode_uint256(num_requests)
    
    # Calculate offsets for each tuple element
    tuple_offsets = []
    current_offset = num_requests * 32  # Start after all offsets
    
    # Pre-calculate all tuple data and their offsets
    tuple_data_list = []
    
    for src_pubkey in source_pubkeys:
        src_encoded = encode_bytes_dynamic(src_pubkey)
        target_encoded = encode_bytes_dynamic(target_pubkey)
        
        # Offsets are relative to start of tuple data
        src_offset = 64  # After two offset words
        target_offset = 64 + len(src_encoded)
        
        tuple_data = (
            encode_uint256(src_offset) +
            encode_uint256(target_offset) +
            src_encoded +
            target_encoded
        )
        
        tuple_offsets.append(current_offset)
        tuple_data_list.append(tuple_data)
        current_offset += len(tuple_data)
    
    # Add all offsets
    for offset in tuple_offsets:
        result += encode_uint256(offset)
    
    # Add all tuple data
    for tuple_data in tuple_data_list:
        result += tuple_data
    
    return result


def generate_consolidation_calldata(source_pubkeys: List[str], target_pubkey: str) -> str:
    """
    Generate the full calldata for requestConsolidation function.
    """
    target_bytes = normalize_pubkey(target_pubkey)
    source_bytes_list = [normalize_pubkey(pk) for pk in source_pubkeys]
    
    encoded_params = encode_consolidation_requests(source_bytes_list, target_bytes)
    selector = bytes.fromhex(REQUEST_CONSOLIDATION_SELECTOR)
    calldata = selector + encoded_params
    
    return "0x" + calldata.hex()


# =============================================================================
# Linking Transaction Encoding
# =============================================================================

def encode_link_legacy_validators(validator_ids: List[int], pubkeys: List[bytes]) -> bytes:
    """
    Encode linkLegacyValidatorIds calldata.
    
    Function signature:
        linkLegacyValidatorIds(uint256[] ids, bytes[] pubkeys)
    """
    selector = bytes.fromhex(LINK_LEGACY_VALIDATOR_IDS_SELECTOR)
    
    # Encode parameters
    # For functions with multiple dynamic params, we need offsets
    # Offset to ids array, offset to pubkeys array, ids data, pubkeys data
    
    ids_encoded = encode_uint256_array(validator_ids)
    pubkeys_encoded = encode_bytes_array(pubkeys)
    
    # Offsets (relative to start of params)
    ids_offset = 64  # After two offset words
    pubkeys_offset = 64 + len(ids_encoded)
    
    params = (
        encode_uint256(ids_offset) +
        encode_uint256(pubkeys_offset) +
        ids_encoded +
        pubkeys_encoded
    )
    
    return selector + params


def encode_timelock_schedule_batch(
    targets: List[str],
    values: List[int],
    payloads: List[bytes],
    predecessor: bytes,
    salt: bytes,
    delay: int
) -> bytes:
    """
    Encode TimelockController.scheduleBatch calldata.
    
    Function signature:
        scheduleBatch(address[] targets, uint256[] values, bytes[] payloads, 
                      bytes32 predecessor, bytes32 salt, uint256 delay)
    """
    selector = bytes.fromhex(SCHEDULE_BATCH_SELECTOR)
    
    # Encode all arrays
    targets_encoded = encode_address_array(targets)
    values_encoded = encode_uint256_array(values)
    payloads_encoded = encode_bytes_array(payloads)
    
    # Calculate offsets for dynamic params (first 3 are dynamic, last 3 are static)
    # Layout: offset_targets, offset_values, offset_payloads, predecessor, salt, delay, [data...]
    static_params_size = 6 * 32  # 6 parameters, each 32 bytes
    
    offset_targets = static_params_size
    offset_values = offset_targets + len(targets_encoded)
    offset_payloads = offset_values + len(values_encoded)
    
    params = (
        encode_uint256(offset_targets) +
        encode_uint256(offset_values) +
        encode_uint256(offset_payloads) +
        encode_bytes32(predecessor) +
        encode_bytes32(salt) +
        encode_uint256(delay) +
        targets_encoded +
        values_encoded +
        payloads_encoded
    )
    
    return selector + params


def encode_timelock_execute_batch(
    targets: List[str],
    values: List[int],
    payloads: List[bytes],
    predecessor: bytes,
    salt: bytes
) -> bytes:
    """
    Encode TimelockController.executeBatch calldata.
    
    Function signature:
        executeBatch(address[] targets, uint256[] values, bytes[] payloads,
                     bytes32 predecessor, bytes32 salt)
    """
    selector = bytes.fromhex(EXECUTE_BATCH_SELECTOR)
    
    # Encode all arrays
    targets_encoded = encode_address_array(targets)
    values_encoded = encode_uint256_array(values)
    payloads_encoded = encode_bytes_array(payloads)
    
    # Calculate offsets for dynamic params
    static_params_size = 5 * 32  # 5 parameters
    
    offset_targets = static_params_size
    offset_values = offset_targets + len(targets_encoded)
    offset_payloads = offset_values + len(values_encoded)
    
    params = (
        encode_uint256(offset_targets) +
        encode_uint256(offset_values) +
        encode_uint256(offset_payloads) +
        encode_bytes32(predecessor) +
        encode_bytes32(salt) +
        targets_encoded +
        values_encoded +
        payloads_encoded
    )
    
    return selector + params


def generate_linking_salt(validator_ids: List[int], pubkeys: List[bytes]) -> bytes:
    """Generate deterministic salt for linking transaction."""
    # Replicate Solidity: keccak256(abi.encode(ids, pubkeys, "link-legacy-validators-consolidation"))
    salt_input = json.dumps({
        'ids': validator_ids,
        'pubkeys': [pk.hex() for pk in pubkeys],
        'tag': 'link-legacy-validators-consolidation'
    }).encode()
    return keccak256(salt_input)


# =============================================================================
# Gnosis Safe JSON Generation
# =============================================================================

def generate_gnosis_tx_json(
    transactions: List[Dict],
    chain_id: int,
    safe_address: str,
    meta_name: str = None,
    meta_description: str = None
) -> str:
    """Generate Gnosis Safe Transaction Builder JSON format."""
    meta = {
        "txBuilderVersion": "1.16.5"
    }
    
    if meta_name:
        meta["name"] = meta_name
    if meta_description:
        meta["description"] = meta_description
    
    output = {
        "chainId": str(chain_id),
        "safeAddress": safe_address,
        "meta": meta,
        "transactions": transactions
    }
    
    return json.dumps(output, indent=2)


# =============================================================================
# Transaction Generation
# =============================================================================

def generate_consolidation_tx(
    source_pubkeys: List[str],
    target_pubkey: str,
    fee_per_request: int,
    nodes_manager_address: str = ETHERFI_NODES_MANAGER
) -> Dict:
    """Generate a single consolidation transaction."""
    calldata = generate_consolidation_calldata(source_pubkeys, target_pubkey)
    total_value = fee_per_request * len(source_pubkeys)
    
    return {
        "to": nodes_manager_address,
        "value": str(total_value),
        "data": calldata
    }


def collect_validators_needing_linking(
    consolidation_data: Dict,
    batch_size: int
) -> Tuple[List[int], List[bytes]]:
    """
    Collect validators that need linking.
    
    For consolidation to work, we need to link:
    1. Each target validator (if it has an 'id' field, it may need linking)
    2. The first validator of each batch (head of batch needs to be linked)
    
    Returns:
        Tuple of (validator_ids, pubkeys) for validators needing linking
    """
    unlinked_ids: List[int] = []
    unlinked_pubkeys: List[bytes] = []
    seen_ids: Set[int] = set()
    
    consolidations = consolidation_data.get('consolidations', [])
    
    for consolidation in consolidations:
        target = consolidation.get('target', {})
        sources = consolidation.get('sources', [])
        
        # Check target
        target_id = target.get('id')
        target_pubkey = target.get('pubkey', '')
        
        if target_id is not None and target_id not in seen_ids and target_pubkey:
            seen_ids.add(target_id)
            unlinked_ids.append(target_id)
            unlinked_pubkeys.append(normalize_pubkey(target_pubkey))
        
        # Check first source of each batch
        source_pubkeys = [s for s in sources if s.get('pubkey')]
        num_batches = (len(source_pubkeys) + batch_size - 1) // batch_size
        
        for batch_idx in range(num_batches):
            first_idx = batch_idx * batch_size
            if first_idx < len(source_pubkeys):
                source = source_pubkeys[first_idx]
                source_id = source.get('id')
                source_pubkey = source.get('pubkey', '')
                
                if source_id is not None and source_id not in seen_ids and source_pubkey:
                    seen_ids.add(source_id)
                    unlinked_ids.append(source_id)
                    unlinked_pubkeys.append(normalize_pubkey(source_pubkey))
    
    return unlinked_ids, unlinked_pubkeys


def generate_linking_transactions(
    validator_ids: List[int],
    pubkeys: List[bytes],
    chain_id: int,
    safe_address: str,
    output_dir: str
) -> Tuple[Optional[str], Optional[str]]:
    """
    Generate timelock schedule and execute transactions for linking validators.
    
    Returns:
        Tuple of (schedule_file_path, execute_file_path) or (None, None) if no linking needed
    """
    if not validator_ids or not pubkeys:
        return None, None
    
    print(f"\n  Generating linking transactions for {len(validator_ids)} validators...")
    
    # Build linkLegacyValidatorIds calldata
    link_calldata = encode_link_legacy_validators(validator_ids, pubkeys)
    
    # Build timelock batch parameters
    targets = [ETHERFI_NODES_MANAGER]
    values = [0]
    payloads = [link_calldata]
    predecessor = bytes(32)  # bytes32(0)
    
    # Generate salt
    salt = generate_linking_salt(validator_ids, pubkeys)
    
    # Generate schedule calldata
    schedule_calldata = encode_timelock_schedule_batch(
        targets, values, payloads, predecessor, salt, MIN_DELAY_OPERATING_TIMELOCK
    )
    
    # Generate execute calldata
    execute_calldata = encode_timelock_execute_batch(
        targets, values, payloads, predecessor, salt
    )
    
    # Write schedule transaction
    schedule_tx = {
        "to": OPERATING_TIMELOCK,
        "value": "0",
        "data": "0x" + schedule_calldata.hex()
    }
    schedule_json = generate_gnosis_tx_json(
        [schedule_tx], chain_id, safe_address,
        meta_name="Link Validators - Schedule",
        meta_description=f"Schedule linking of {len(validator_ids)} validators via timelock"
    )
    schedule_file = os.path.join(output_dir, "link-schedule.json")
    with open(schedule_file, 'w') as f:
        f.write(schedule_json)
    print(f"  ✓ Written: link-schedule.json")
    
    # Write execute transaction
    execute_tx = {
        "to": OPERATING_TIMELOCK,
        "value": "0",
        "data": "0x" + execute_calldata.hex()
    }
    execute_json = generate_gnosis_tx_json(
        [execute_tx], chain_id, safe_address,
        meta_name="Link Validators - Execute",
        meta_description=f"Execute linking of {len(validator_ids)} validators (after {MIN_DELAY_OPERATING_TIMELOCK // 3600}h delay)"
    )
    execute_file = os.path.join(output_dir, "link-execute.json")
    with open(execute_file, 'w') as f:
        f.write(execute_json)
    print(f"  ✓ Written: link-execute.json")
    
    return schedule_file, execute_file


def process_consolidation_data(
    consolidation_data: Dict,
    batch_size: int,
    fee_per_request: int
) -> List[Dict]:
    """Process consolidation data and generate transaction batches."""
    all_transactions = []
    consolidations = consolidation_data.get('consolidations', [])
    
    for consolidation in consolidations:
        target = consolidation.get('target', {})
        sources = consolidation.get('sources', [])
        
        target_pubkey = target.get('pubkey', '')
        if not target_pubkey:
            print(f"Warning: Skipping consolidation with missing target pubkey")
            continue
        
        # Extract source pubkeys
        source_pubkeys = [s.get('pubkey', '') for s in sources if s.get('pubkey')]
        
        if not source_pubkeys:
            print(f"Warning: Skipping consolidation with no source pubkeys")
            continue
        
        # Split into batches
        for batch_start in range(0, len(source_pubkeys), batch_size):
            batch_end = min(batch_start + batch_size, len(source_pubkeys))
            batch_pubkeys = source_pubkeys[batch_start:batch_end]
            
            tx = generate_consolidation_tx(
                batch_pubkeys,
                target_pubkey,
                fee_per_request
            )
            all_transactions.append(tx)
    
    return all_transactions


def write_transaction_files(
    transactions: List[Dict],
    output_dir: str,
    chain_id: int,
    safe_address: str
) -> List[str]:
    """Write each transaction to a separate JSON file."""
    os.makedirs(output_dir, exist_ok=True)
    written_files = []
    
    for i, tx in enumerate(transactions, start=1):
        tx_list = [tx]
        json_content = generate_gnosis_tx_json(
            tx_list,
            chain_id,
            safe_address
        )
        
        filename = f"consolidation-txns-{i}.json"
        filepath = os.path.join(output_dir, filename)
        
        with open(filepath, 'w') as f:
            f.write(json_content)
        
        written_files.append(filepath)
        print(f"  ✓ Written: {filename}")
    
    return written_files


# =============================================================================
# Main Entry Point
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Generate Gnosis Safe transaction files for validator consolidation',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Generate transactions from consolidation data
    python3 generate_gnosis_txns.py --input consolidation-data.json

    # Specify output directory and batch size
    python3 generate_gnosis_txns.py --input consolidation-data.json --output-dir ./txns --batch-size 50

    # Skip linking transaction generation
    python3 generate_gnosis_txns.py --input consolidation-data.json --skip-linking

    # Use custom fee per request
    python3 generate_gnosis_txns.py --input consolidation-data.json --fee 2
        """
    )
    
    parser.add_argument(
        '--input', '-i',
        required=True,
        help='Path to consolidation-data.json file'
    )
    parser.add_argument(
        '--output-dir', '-o',
        help='Output directory for transaction files (default: same as input file)'
    )
    parser.add_argument(
        '--batch-size',
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f'Number of sources per transaction (default: {DEFAULT_BATCH_SIZE})'
    )
    parser.add_argument(
        '--fee',
        type=int,
        default=DEFAULT_CONSOLIDATION_FEE,
        help=f'Fee per consolidation request in wei (default: {DEFAULT_CONSOLIDATION_FEE})'
    )
    parser.add_argument(
        '--chain-id',
        type=int,
        default=DEFAULT_CHAIN_ID,
        help=f'Chain ID (default: {DEFAULT_CHAIN_ID})'
    )
    parser.add_argument(
        '--safe-address',
        default=ETHERFI_OPERATING_ADMIN,
        help=f'Gnosis Safe address (default: {ETHERFI_OPERATING_ADMIN})'
    )
    parser.add_argument(
        '--skip-linking',
        action='store_true',
        help='Skip generating linking transactions'
    )
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Show verbose output'
    )
    
    args = parser.parse_args()
    
    # Validate input file
    if not os.path.exists(args.input):
        print(f"Error: Input file not found: {args.input}")
        sys.exit(1)
    
    # Set output directory
    output_dir = args.output_dir
    if not output_dir:
        output_dir = os.path.dirname(os.path.abspath(args.input))
    
    # Override from environment if set
    chain_id = int(os.environ.get('CHAIN_ID', args.chain_id))
    safe_address = os.environ.get('SAFE_ADDRESS', args.safe_address)
    
    print("=" * 60)
    print("GNOSIS TRANSACTION GENERATOR")
    print("=" * 60)
    print(f"Input file:    {args.input}")
    print(f"Output dir:    {output_dir}")
    print(f"Batch size:    {args.batch_size}")
    print(f"Fee/request:   {args.fee} wei")
    print(f"Chain ID:      {chain_id}")
    print(f"Safe address:  {safe_address}")
    print(f"Skip linking:  {args.skip_linking}")
    print("")
    
    # Load consolidation data
    print("Loading consolidation data...")
    with open(args.input, 'r') as f:
        consolidation_data = json.load(f)
    
    consolidations = consolidation_data.get('consolidations', [])
    total_targets = len(consolidations)
    total_sources = sum(len(c.get('sources', [])) for c in consolidations)
    
    print(f"  Consolidation targets: {total_targets}")
    print(f"  Total sources: {total_sources}")
    print("")
    
    if total_targets == 0:
        print("No consolidations to process")
        sys.exit(0)
    
    os.makedirs(output_dir, exist_ok=True)
    
    # Generate linking transactions if needed
    needs_linking = False
    if not args.skip_linking:
        print("Checking for validators that need linking...")
        unlinked_ids, unlinked_pubkeys = collect_validators_needing_linking(
            consolidation_data, args.batch_size
        )
        
        if unlinked_ids:
            print(f"  Found {len(unlinked_ids)} validators that may need linking")
            schedule_file, execute_file = generate_linking_transactions(
                unlinked_ids,
                unlinked_pubkeys,
                chain_id,
                safe_address,
                output_dir
            )
            needs_linking = schedule_file is not None
        else:
            print("  No validators need linking")
    else:
        print("Skipping linking transaction generation (--skip-linking)")
    
    print("")
    
    # Process and generate consolidation transactions
    print("Generating consolidation transactions...")
    transactions = process_consolidation_data(
        consolidation_data,
        args.batch_size,
        args.fee
    )
    
    print(f"  Generated {len(transactions)} transactions")
    print("")
    
    # Write transaction files
    print("Writing consolidation transaction files...")
    written_files = write_transaction_files(
        transactions,
        output_dir,
        chain_id,
        safe_address
    )
    
    # Summary
    print("")
    print("=" * 60)
    print("GENERATION COMPLETE")
    print("=" * 60)
    print(f"Total consolidation transactions: {len(written_files)}")
    print(f"Output directory: {output_dir}")
    print("")
    
    print("Files generated:")
    if needs_linking:
        print(f"  - link-schedule.json (timelock schedule)")
        print(f"  - link-execute.json (timelock execute)")
    for f in written_files:
        print(f"  - {os.path.basename(f)}")
    
    print("")
    print("Execution order:")
    if needs_linking:
        print("  1. Import and execute link-schedule.json in Gnosis Safe")
        print(f"  2. Wait {MIN_DELAY_OPERATING_TIMELOCK // 3600} hours for timelock delay")
        print("  3. Import and execute link-execute.json in Gnosis Safe")
        print("  4. Import and execute each consolidation-txns-*.json file")
    else:
        print("  1. Import and execute each consolidation-txns-*.json file in Gnosis Safe")
    
    print("")
    print(f"⚠ Each consolidation request requires {args.fee} wei fee.")
    print(f"  Total ETH needed for consolidations: {args.fee * total_sources / 1e18:.18f} ETH")


if __name__ == '__main__':
    main()

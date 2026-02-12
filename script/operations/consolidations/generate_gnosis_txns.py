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
import json
import os
import sys
from typing import Dict, List, Optional, Set, Tuple


# =============================================================================
# Constants
# =============================================================================

# Contract Addresses (Mainnet)
ETHERFI_NODES_MANAGER = "0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F"
ADMIN_EOA = "0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F"

# Default parameters
DEFAULT_BATCH_SIZE = 50
DEFAULT_CHAIN_ID = 1
DEFAULT_CONSOLIDATION_FEE = 1  # 1 wei per consolidation request

# Function selectors
REQUEST_CONSOLIDATION_SELECTOR = "6691954e"  # requestConsolidation((bytes,bytes)[])
LINK_LEGACY_VALIDATOR_IDS_SELECTOR = "83294396"  # linkLegacyValidatorIds(uint256[],bytes[])


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


def generate_linking_transaction(
    validator_ids: List[int],
    pubkeys: List[bytes],
    chain_id: int,
    admin_address: str,
    output_dir: str
) -> Optional[str]:
    """
    Generate direct linking transaction (no timelock).

    Returns:
        Path to link-validators.json or None if no linking needed
    """
    if not validator_ids or not pubkeys:
        return None

    print(f"\n  Generating linking transaction for {len(validator_ids)} validators...")

    # Build direct linkLegacyValidatorIds calldata
    link_calldata = encode_link_legacy_validators(validator_ids, pubkeys)

    # Write direct linking transaction (to EtherFiNodesManager)
    link_tx = {
        "to": ETHERFI_NODES_MANAGER,
        "value": "0",
        "data": "0x" + link_calldata.hex()
    }
    link_json = generate_gnosis_tx_json(
        [link_tx], chain_id, admin_address,
        meta_name="Link Validators",
        meta_description=f"Link {len(validator_ids)} validators directly via ADMIN_EOA"
    )
    link_file = os.path.join(output_dir, "link-validators.json")
    with open(link_file, 'w') as f:
        f.write(link_json)
    print(f"  ✓ Written: link-validators.json")

    return link_file


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
        '--admin-address',
        default=ADMIN_EOA,
        help=f'Admin address for transactions (default: {ADMIN_EOA})'
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
    admin_address = os.environ.get('ADMIN_ADDRESS', args.admin_address)

    print("=" * 60)
    print("GNOSIS TRANSACTION GENERATOR")
    print("=" * 60)
    print(f"Input file:    {args.input}")
    print(f"Output dir:    {output_dir}")
    print(f"Batch size:    {args.batch_size}")
    print(f"Fee/request:   {args.fee} wei")
    print(f"Chain ID:      {chain_id}")
    print(f"Admin address: {admin_address}")
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
    
    # Generate linking transaction if needed
    needs_linking = False
    if not args.skip_linking:
        print("Checking for validators that need linking...")
        unlinked_ids, unlinked_pubkeys = collect_validators_needing_linking(
            consolidation_data, args.batch_size
        )

        if unlinked_ids:
            print(f"  Found {len(unlinked_ids)} validators that may need linking")
            link_file = generate_linking_transaction(
                unlinked_ids,
                unlinked_pubkeys,
                chain_id,
                admin_address,
                output_dir
            )
            needs_linking = link_file is not None
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
        admin_address
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
        print(f"  - link-validators.json (direct linking via ADMIN_EOA)")
    for f in written_files:
        print(f"  - {os.path.basename(f)}")

    print("")
    print("Execution order:")
    if needs_linking:
        print("  1. Execute link-validators.json from ADMIN_EOA")
        print("  2. Execute each consolidation-txns-*.json file from ADMIN_EOA")
    else:
        print("  1. Execute each consolidation-txns-*.json file from ADMIN_EOA")

    print("")
    print(f"⚠ Each consolidation request requires {args.fee} wei fee.")
    print(f"  Total ETH needed for consolidations: {args.fee * total_sources / 1e18:.18f} ETH")


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
Export Database Data to JSON

This script exports operator and EtherFi node data from the PostgreSQL database
to JSON files that can be consumed by Solidity scripts (via DataLoader.sol).

Usage:
    # Export both operators and etherfi-nodes
    python export_data.py
    
    # Export only operators
    python export_data.py --operators-only
    
    # Export only etherfi-nodes
    python export_data.py --nodes-only
    
    # Custom output directory
    python export_data.py --output-dir /path/to/output

Configuration:
    Set VALIDATOR_DB environment variable to the PostgreSQL connection string.
"""

import os
import sys
import json
import argparse
from pathlib import Path
from typing import List, Dict
import psycopg2


def get_db_connection() -> psycopg2.extensions.connection:
    """Get PostgreSQL connection from VALIDATOR_DB environment variable."""
    db_url = os.getenv('VALIDATOR_DB')
    if not db_url:
        raise ValueError("VALIDATOR_DB environment variable not set")
    
    return psycopg2.connect(db_url)


def export_operators(conn: psycopg2.extensions.connection, output_path: Path) -> int:
    """
    Export operators from OperatorMetadata table to JSON.
    
    Args:
        conn: PostgreSQL connection
        output_path: Path to output JSON file
    
    Returns:
        Number of operators exported
    """
    with conn.cursor() as cur:
        cur.execute('''
            SELECT "operatorAdress", "operatorName" 
            FROM "OperatorMetadata" 
            ORDER BY "operatorName"
        ''')
        rows = cur.fetchall()
    
    operators = []
    for addr, name in rows:
        operators.append({
            "name": name,
            "address": addr.lower()
        })
    
    data = {"operators": operators}
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(data, f, indent=2)
    
    return len(operators)


def export_etherfi_nodes(conn: psycopg2.extensions.connection, output_path: Path) -> int:
    """
    Export EtherFi node contract addresses from MainnetValidators table to JSON.
    
    Args:
        conn: PostgreSQL connection
        output_path: Path to output JSON file
    
    Returns:
        Number of node addresses exported
    """
    with conn.cursor() as cur:
        cur.execute('''
            SELECT DISTINCT etherfi_node_contract 
            FROM "MainnetValidators" 
            WHERE etherfi_node_contract IS NOT NULL
            ORDER BY etherfi_node_contract
        ''')
        rows = cur.fetchall()
    
    # Preserve original checksum format from DB
    addresses = [row[0] for row in rows]
    
    data = {
        "description": "EtherFi node addresses exported from database",
        "count": len(addresses),
        "addresses": addresses
    }
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(data, f, indent=2)
    
    return len(addresses)


def main():
    parser = argparse.ArgumentParser(
        description='Export database data to JSON for Solidity scripts',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    
    parser.add_argument(
        '--output-dir',
        type=Path,
        default=Path(__file__).parent.parent / 'data',
        help='Output directory for JSON files (default: script/data/)'
    )
    
    parser.add_argument(
        '--operators-only',
        action='store_true',
        help='Export only operators.json'
    )
    
    parser.add_argument(
        '--nodes-only',
        action='store_true',
        help='Export only etherfi-nodes.json'
    )
    
    parser.add_argument(
        '--db-url',
        help='Override VALIDATOR_DB environment variable'
    )
    
    args = parser.parse_args()
    
    # Determine what to export
    export_ops = not args.nodes_only
    export_nodes = not args.operators_only
    
    # Connect to database
    try:
        if args.db_url:
            os.environ['VALIDATOR_DB'] = args.db_url
        conn = get_db_connection()
        print("Connected to database")
    except Exception as e:
        print(f"Database connection error: {e}", file=sys.stderr)
        print("Set VALIDATOR_DB environment variable or use --db-url", file=sys.stderr)
        sys.exit(1)
    
    try:
        # Export operators
        if export_ops:
            operators_path = args.output_dir / 'operators.json'
            count = export_operators(conn, operators_path)
            print(f"Exported {count} operators to {operators_path}")
        
        # Export EtherFi nodes
        if export_nodes:
            nodes_path = args.output_dir / 'etherfi-nodes.json'
            count = export_etherfi_nodes(conn, nodes_path)
            print(f"Exported {count} EtherFi node addresses to {nodes_path}")
        
        print("\nDone! JSON files are ready for Solidity scripts.")
        
    except Exception as e:
        print(f"Export error: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        conn.close()


if __name__ == '__main__':
    main()


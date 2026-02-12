#!/usr/bin/env python3
"""
export_db_data.py - Export operator and node data from database to JSON

This script exports data from the EtherFi validator database
to JSON files that can be consumed by Solidity scripts.

Usage:
    python export_db_data.py
    python export_db_data.py --operators-only
    python export_db_data.py --nodes-only
    python export_db_data.py --output-dir ./data

Environment Variables:
    VALIDATOR_DB: PostgreSQL connection string for validator database

Output:
    - operators.json: Operator name to address mapping
    - etherfi-nodes.json: EtherFi node contract addresses
"""

import argparse
import json
import os
import sys
from pathlib import Path

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
    import psycopg2
except ImportError:
    print("Error: psycopg2 not installed. Run: pip install psycopg2-binary")
    sys.exit(1)


def get_db_connection():
    """Get database connection from environment variable."""
    db_url = os.environ.get('VALIDATOR_DB')
    if not db_url:
        raise ValueError("VALIDATOR_DB environment variable not set")
    return psycopg2.connect(db_url)


def export_operators(conn, output_dir: Path):
    """Export operator data to JSON."""
    operators = {}
    
    with conn.cursor() as cur:
        cur.execute('SELECT "operatorAdress", "operatorName" FROM "OperatorMetadata"')
        for addr, name in cur.fetchall():
            operators[name] = addr.lower()
    
    output_file = output_dir / 'operators.json'
    with open(output_file, 'w') as f:
        json.dump(operators, f, indent=2)
    
    print(f"Exported {len(operators)} operators to {output_file}")


def export_etherfi_nodes(conn, output_dir: Path):
    """Export EtherFi node addresses to JSON."""
    nodes = []
    
    with conn.cursor() as cur:
        cur.execute('''
            SELECT DISTINCT etherfi_node_contract 
            FROM "MainnetValidators" 
            WHERE etherfi_node_contract IS NOT NULL
            ORDER BY etherfi_node_contract
        ''')
        for (node,) in cur.fetchall():
            if node:
                nodes.append(node.lower())
    
    output_file = output_dir / 'etherfi-nodes.json'
    with open(output_file, 'w') as f:
        json.dump(nodes, f, indent=2)
    
    print(f"Exported {len(nodes)} EtherFi nodes to {output_file}")


def main():
    parser = argparse.ArgumentParser(
        description='Export operator and EtherFi node data from database to JSON files.'
    )
    parser.add_argument(
        '--operators-only',
        action='store_true',
        help='Export only operator data'
    )
    parser.add_argument(
        '--nodes-only',
        action='store_true',
        help='Export only EtherFi node data'
    )
    parser.add_argument(
        '--output-dir',
        type=Path,
        default=Path(__file__).parent.parent / 'data',
        help='Output directory for JSON files (default: script/operations/data)'
    )
    
    args = parser.parse_args()
    
    # Create output directory if it doesn't exist
    args.output_dir.mkdir(parents=True, exist_ok=True)
    
    try:
        conn = get_db_connection()
    except ValueError as e:
        print(f"Error: {e}")
        print("Set VALIDATOR_DB environment variable to your PostgreSQL connection string")
        sys.exit(1)
    except Exception as e:
        print(f"Database connection error: {e}")
        sys.exit(1)
    
    try:
        if args.operators_only:
            export_operators(conn, args.output_dir)
        elif args.nodes_only:
            export_etherfi_nodes(conn, args.output_dir)
        else:
            export_operators(conn, args.output_dir)
            export_etherfi_nodes(conn, args.output_dir)
        
        print("\nDone! JSON files are ready for Solidity scripts.")
    finally:
        conn.close()


if __name__ == '__main__':
    main()


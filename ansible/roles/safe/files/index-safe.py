#!/usr/bin/env python3
"""
Manually index a Safe when automatic indexing fails.
This is a workaround for ProxyCreation event parsing issues.
"""

import argparse
import os
import re
import sys
from datetime import datetime

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.production')

import django
django.setup()

from django.db import connection
from web3 import Web3


def validate_hex(value: str, name: str, expected_length: int) -> str:
    """Validate and normalize hex value, preventing injection attacks."""
    # Remove 0x prefix if present
    clean = value.lower()
    if clean.startswith('0x'):
        clean = clean[2:]

    # Validate it's pure hex of expected length
    if not re.match(r'^[0-9a-f]+$', clean):
        raise ValueError(f"Invalid hex value for {name}: {value}")

    if len(clean) != expected_length:
        raise ValueError(f"Invalid length for {name}: expected {expected_length} hex chars, got {len(clean)}")

    return clean


def index_safe(safe_address: str, tx_hash: str, block_number: int):
    """Index a Safe by inserting records directly into the database."""

    # Validate inputs to prevent SQL injection
    safe_address = validate_hex(safe_address, "safe_address", 40)  # 20 bytes = 40 hex chars
    tx_hash = validate_hex(tx_hash, "tx_hash", 64)  # 32 bytes = 64 hex chars

    if not isinstance(block_number, int) or block_number < 0:
        raise ValueError(f"Invalid block number: {block_number}")

    with connection.cursor() as cursor:
        # Check if SafeContract already exists
        cursor.execute(
            "SELECT 1 FROM history_safecontract WHERE address = decode(%s, 'hex')",
            [safe_address]
        )
        if cursor.fetchone():
            print(f"Safe {safe_address} already indexed")
            return False

        # Check if EthereumTx exists
        cursor.execute(
            "SELECT 1 FROM history_ethereumtx WHERE tx_hash = decode(%s, 'hex')",
            [tx_hash]
        )
        if not cursor.fetchone():
            # Insert EthereumTx
            cursor.execute("""
                INSERT INTO history_ethereumtx (
                    created, modified, tx_hash, gas_used, status, transaction_index,
                    _from, gas, gas_price, data, nonce, "to", value, block_id, type
                )
                VALUES (
                    %s, %s,
                    decode(%s, 'hex'),
                    500000, 1, 0,
                    decode(%s, 'hex'),
                    500000, 25000000000, '', 0,
                    NULL,
                    0, %s, 0
                )
            """, [datetime.now(), datetime.now(), tx_hash, safe_address, block_number])
            print(f"Created EthereumTx {tx_hash}")

        # Insert SafeContract
        cursor.execute("""
            INSERT INTO history_safecontract (address, ethereum_tx_id, banned)
            VALUES (decode(%s, 'hex'), decode(%s, 'hex'), false)
        """, [safe_address, tx_hash])
        print(f"Indexed Safe 0x{safe_address}")
        return True


def main():
    parser = argparse.ArgumentParser(description='Manually index a Safe')
    parser.add_argument('--address', required=True, help='Safe address')
    parser.add_argument('--tx-hash', required=True, help='Creation transaction hash')
    parser.add_argument('--block', type=int, required=True, help='Block number')

    args = parser.parse_args()

    success = index_safe(args.address, args.tx_hash, args.block)
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())

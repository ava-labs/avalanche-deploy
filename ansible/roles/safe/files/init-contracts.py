#!/usr/bin/env python3
"""
Initialize Safe contracts in the Transaction Service database.
This script registers the pre-deployed Safe v1.4.1 contracts for the custom chain.
"""

import argparse
import os
import sys

# Django setup
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.production')

import django
django.setup()

from safe_transaction_service.contracts.models import Contract


def create_contract(address: str, name: str, chain_id: int) -> bool:
    """Create a contract entry if it doesn't exist."""
    contract, created = Contract.objects.get_or_create(
        address=address.lower(),
        defaults={
            'name': name,
            'display_name': name,
        }
    )
    if created:
        print(f"Created: {name} at {address}")
    else:
        print(f"Exists:  {name} at {address}")
    return created


def main():
    parser = argparse.ArgumentParser(description='Initialize Safe contracts')
    parser.add_argument('--chain-id', type=int, required=True, help='EVM Chain ID')
    parser.add_argument('--safe-singleton', required=True, help='Safe L2 Singleton address')
    parser.add_argument('--proxy-factory', required=True, help='Proxy Factory address')
    parser.add_argument('--multi-send', required=True, help='MultiSend address')
    parser.add_argument('--multi-send-call-only', required=True, help='MultiSendCallOnly address')
    parser.add_argument('--fallback-handler', required=True, help='Fallback Handler address')
    parser.add_argument('--create-call', required=True, help='CreateCall address')
    parser.add_argument('--sign-message-lib', required=True, help='SignMessageLib address')
    parser.add_argument('--simulate-tx-accessor', required=True, help='SimulateTxAccessor address')

    args = parser.parse_args()

    print(f"\nInitializing Safe contracts for chain {args.chain_id}...\n")

    contracts = [
        (args.safe_singleton, 'Safe L2 Singleton v1.4.1'),
        (args.proxy_factory, 'Safe Proxy Factory v1.4.1'),
        (args.multi_send, 'MultiSend v1.4.1'),
        (args.multi_send_call_only, 'MultiSendCallOnly v1.4.1'),
        (args.fallback_handler, 'Compatibility Fallback Handler v1.4.1'),
        (args.create_call, 'CreateCall v1.4.1'),
        (args.sign_message_lib, 'SignMessageLib v1.4.1'),
        (args.simulate_tx_accessor, 'SimulateTxAccessor v1.4.1'),
    ]

    created_count = 0
    for address, name in contracts:
        if create_contract(address, name, args.chain_id):
            created_count += 1

    print(f"\nDone. Created {created_count} new contract entries.")
    return 0


if __name__ == '__main__':
    sys.exit(main())

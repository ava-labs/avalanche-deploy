#!/usr/bin/env python3
"""
Initialize Safe contracts in the Transaction Service database.
This script registers the pre-deployed Safe v1.4.1 contracts for the custom chain.
Registers Contract entries, SafeMasterCopy entries, and ProxyFactory.

NOTE: This script should be run via `docker exec safe-txs-web python manage.py shell`
to inherit the proper Django environment. It's designed to be executed during
ansible deployment using a heredoc-style approach.

Example usage in ansible:
  docker exec safe-txs-web python manage.py shell -c '
    exec(open("/init/init-contracts.py").read())
    main("0x29fc...", "0x4e1D...", ...)
  '
"""

# When run via manage.py shell, Django is already setup
# These imports work in the shell context
import re


def validate_ethereum_address(address: str, name: str) -> str:
    """Validate Ethereum address format (0x + 40 hex chars)."""
    if not re.match(r'^0x[0-9a-fA-F]{40}$', address):
        raise ValueError(f"Invalid Ethereum address for {name}: {address}")
    return address.lower()


try:
    from safe_transaction_service.contracts.models import Contract
    from safe_transaction_service.history.models import SafeMasterCopy, ProxyFactory
except ImportError:
    # Fallback for standalone execution (not recommended)
    import os
    import sys
    os.chdir('/app')
    sys.path.insert(0, '/app')
    sys.path.insert(0, '/app/safe_transaction_service')
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.production')
    import django
    django.setup()
    from safe_transaction_service.contracts.models import Contract
    from safe_transaction_service.history.models import SafeMasterCopy, ProxyFactory


def create_contract(address, name):
    """Create a contract entry if it doesn't exist."""
    contract, created = Contract.objects.get_or_create(
        address=address.lower(),
        defaults={
            'name': name,
            'display_name': name,
        }
    )
    status = "Created" if created else "Exists"
    print(name + ": " + status)
    return created


def create_master_copy(address, version, l2=True):
    """Create a SafeMasterCopy entry if it doesn't exist."""
    mc, created = SafeMasterCopy.objects.get_or_create(
        address=address.lower(),
        defaults={
            "version": version,
            "l2": l2,
            "deployer": "Safe Team",
        }
    )
    status = "Created" if created else "Exists"
    safe_type = "L2" if l2 else "L1"
    print("MasterCopy " + safe_type + " v" + version + ": " + status)
    return created


def create_proxy_factory(address):
    """Create a ProxyFactory entry if it doesn't exist."""
    pf, created = ProxyFactory.objects.get_or_create(address=address.lower())
    status = "Created" if created else "Exists"
    print("ProxyFactory: " + status)
    return created


def main(safe_singleton, proxy_factory, multi_send, multi_send_call_only,
         fallback_handler, create_call, sign_message_lib, simulate_tx_accessor,
         l2=True):
    """Register all Safe v1.4.1 contracts."""
    # Validate all addresses first
    safe_singleton = validate_ethereum_address(safe_singleton, "safe_singleton")
    proxy_factory = validate_ethereum_address(proxy_factory, "proxy_factory")
    multi_send = validate_ethereum_address(multi_send, "multi_send")
    multi_send_call_only = validate_ethereum_address(multi_send_call_only, "multi_send_call_only")
    fallback_handler = validate_ethereum_address(fallback_handler, "fallback_handler")
    create_call = validate_ethereum_address(create_call, "create_call")
    sign_message_lib = validate_ethereum_address(sign_message_lib, "sign_message_lib")
    simulate_tx_accessor = validate_ethereum_address(simulate_tx_accessor, "simulate_tx_accessor")

    safe_type = "L2" if l2 else "Non-L2"
    print("Registering Safe v1.4.1 contracts (" + safe_type + ")...")
    print("")

    # Register contracts for display/indexing
    contracts = [
        (safe_singleton, "Safe Singleton v1.4.1 (" + safe_type + ")"),
        (proxy_factory, "Safe Proxy Factory v1.4.1"),
        (multi_send, "MultiSend v1.4.1"),
        (multi_send_call_only, "MultiSendCallOnly v1.4.1"),
        (fallback_handler, "Fallback Handler v1.4.1"),
        (create_call, "CreateCall v1.4.1"),
        (sign_message_lib, "SignMessageLib v1.4.1"),
        (simulate_tx_accessor, "SimulateTxAccessor v1.4.1"),
    ]

    for address, name in contracts:
        create_contract(address, name)

    print("")

    # Register SafeMasterCopy (required for Safe creation/detection)
    create_master_copy(safe_singleton, "1.4.1", l2=l2)

    # Register ProxyFactory (required for indexing Safe creation events)
    create_proxy_factory(proxy_factory)

    print("")
    print("Done!")


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Initialize Safe contracts')
    parser.add_argument('--safe-singleton', required=True)
    parser.add_argument('--proxy-factory', required=True)
    parser.add_argument('--multi-send', required=True)
    parser.add_argument('--multi-send-call-only', required=True)
    parser.add_argument('--fallback-handler', required=True)
    parser.add_argument('--create-call', required=True)
    parser.add_argument('--sign-message-lib', required=True)
    parser.add_argument('--simulate-tx-accessor', required=True)
    parser.add_argument('--l2', type=lambda x: x.lower() == 'true', default=True)
    args = parser.parse_args()

    main(
        args.safe_singleton, args.proxy_factory, args.multi_send,
        args.multi_send_call_only, args.fallback_handler, args.create_call,
        args.sign_message_lib, args.simulate_tx_accessor, args.l2
    )

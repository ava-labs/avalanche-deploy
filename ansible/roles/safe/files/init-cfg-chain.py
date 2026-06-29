#!/usr/bin/env python3
"""
Initialize chain configuration in the Safe Config Service database.
This script registers the custom L1 chain so the Client Gateway can find it.
"""

import argparse
import os
import sys
import base64
from io import BytesIO

# Change to app directory
os.chdir('/app/src')
sys.path.insert(0, '/app/src')

# Django setup - Config Service uses this settings module
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')

import django
django.setup()

from django.core.files.base import ContentFile
from chains.models import Chain, Feature, Wallet, GasPrice
from safe_apps.models import SafeApp


def create_placeholder_image(color: str = "#E84142") -> ContentFile:
    """Create a simple colored square PNG as placeholder."""
    # 1x1 red PNG (AVAX color)
    png_data = bytes([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  # PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  # IHDR chunk
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  # 1x1 px
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,  # IDAT chunk
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE,
        0xD4, 0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,  # IEND chunk
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])
    return ContentFile(png_data)


def set_contract_addresses(chain, args):
    """Set contract addresses on chain if the model supports them (CFG v2.92+)."""
    updated = False
    # Map of Chain model field -> CLI arg attribute
    field_map = {
        'safe_singleton_address': 'safe_singleton',
        'safe_proxy_factory_address': 'proxy_factory',
        'multi_send_address': 'multi_send',
        'multi_send_call_only_address': 'multi_send_call_only',
        'fallback_handler_address': 'fallback_handler',
        'create_call_address': 'create_call',
        'sign_message_lib_address': 'sign_message_lib',
        'simulate_tx_accessor_address': 'simulate_tx_accessor',
    }
    for field_name, arg_name in field_map.items():
        value = getattr(args, arg_name.replace('-', '_'), '')
        if value and hasattr(chain, field_name):
            setattr(chain, field_name, value)
            updated = True
    return updated


def main():
    parser = argparse.ArgumentParser(description='Initialize chain in Config Service')
    parser.add_argument('--chain-id', type=int, required=True, help='EVM Chain ID')
    parser.add_argument('--chain-name', default='Avalanche L1', help='Chain display name')
    parser.add_argument('--short-name', default='avax-l1', help='Chain short name')
    parser.add_argument('--rpc-url', required=True, help='RPC endpoint URL')
    parser.add_argument('--block-explorer-url', default='', help='Block explorer URL')
    parser.add_argument('--currency-name', default='AVAX', help='Native currency name')
    parser.add_argument('--currency-symbol', default='AVAX', help='Native currency symbol')
    parser.add_argument('--currency-decimals', type=int, default=18, help='Currency decimals')
    parser.add_argument('--txs-url', required=True, help='Transaction Service URL')
    parser.add_argument('--l2', type=lambda x: x.lower() == 'true', default=False, help='Is L2 chain (true/false)')
    parser.add_argument('--gas-price', type=int, default=25000000000, help='Gas price in wei (default: 25 gwei)')

    # Contract addresses (CFG v2.92+ has these fields on the Chain model)
    parser.add_argument('--safe-singleton', default='', help='Safe singleton address')
    parser.add_argument('--proxy-factory', default='', help='Proxy factory address')
    parser.add_argument('--multi-send', default='', help='MultiSend address')
    parser.add_argument('--multi-send-call-only', default='', help='MultiSendCallOnly address')
    parser.add_argument('--fallback-handler', default='', help='Fallback handler address')
    parser.add_argument('--create-call', default='', help='CreateCall address')
    parser.add_argument('--sign-message-lib', default='', help='SignMessageLib address')
    parser.add_argument('--simulate-tx-accessor', default='', help='SimulateTxAccessor address')

    args = parser.parse_args()

    print(f"\nInitializing chain {args.chain_id} in Config Service...\n")

    # Check if chain already exists
    try:
        chain = Chain.objects.get(id=args.chain_id)
        print(f"Chain {args.chain_id} already exists: {chain.name}")
        # Update contract addresses if provided and the model supports them
        updated = set_contract_addresses(chain, args)
        if updated:
            chain.save()
            print("  Updated contract addresses")
        # Re-seed Safe Apps so existing deployments pick up Tx Builder without
        # requiring a full chain re-init. idempotent via update_or_create.
        seed_default_apps(args.chain_id)
        return 0
    except Chain.DoesNotExist:
        pass

    # Create the chain - only include fields that exist in this version
    chain = Chain(
        id=args.chain_id,
        name=args.chain_name,
        short_name=args.short_name,
        description=f"{args.chain_name} - Custom Avalanche L1",
        l2=args.l2,  # True for L2 Safe singleton (recommended for Avalanche L1s)
        rpc_uri=args.rpc_url,
        safe_apps_rpc_uri=args.rpc_url,
        public_rpc_uri=args.rpc_url,
        block_explorer_uri_address_template=f"{args.block_explorer_url}/address/{{{{address}}}}" if args.block_explorer_url else "",
        block_explorer_uri_tx_hash_template=f"{args.block_explorer_url}/tx/{{{{txHash}}}}" if args.block_explorer_url else "",
        currency_name=args.currency_name,
        currency_symbol=args.currency_symbol,
        currency_decimals=args.currency_decimals,
        currency_logo_uri="",
        transaction_service_uri=args.txs_url,
        vpc_transaction_service_uri=args.txs_url,
        theme_text_color="#FFFFFF",
        theme_background_color="#E84142",
        ens_registry_address=None,
        recommended_master_copy_version="1.4.1",
    )

    # Save chain logo and currency logo as placeholders
    chain.chain_logo_uri.save('chain_logo.png', create_placeholder_image(), save=False)
    chain.currency_logo_uri.save('currency_logo.png', create_placeholder_image(), save=False)

    # Fix RPC authentication types (CGW expects these to be set)
    chain.rpc_authentication = Chain.RpcAuthentication.NO_AUTHENTICATION
    chain.safe_apps_rpc_authentication = Chain.RpcAuthentication.NO_AUTHENTICATION
    chain.public_rpc_authentication = Chain.RpcAuthentication.NO_AUTHENTICATION

    chain.save()

    # Set contract addresses (CFG v2.92+ only)
    if set_contract_addresses(chain, args):
        chain.save()
        print("  Contract addresses configured")

    print(f"Created chain: {chain.name} (ID: {chain.id})")
    print(f"  RPC URL: {chain.rpc_uri}")
    print(f"  TXS URL: {chain.transaction_service_uri}")

    # Create EIP-1559 gas price config
    try:
        gas_price_gwei = args.gas_price / 1e9
        GasPrice.objects.create(
            chain=chain,
            oracle_uri=None,
            oracle_parameter="",
            gwei_factor=1000000000,
            fixed_wei_value=None,
            rank=0,
            max_fee_per_gas=args.gas_price,
            max_priority_fee_per_gas=1000000000,
        )
        print(f"  Created gas price config (max fee: {gas_price_gwei:.1f} gwei)")
    except Exception as e:
        print(f"  Warning: Could not create gas price config: {e}")

    # Add chain to default features (and create if missing)
    # SAFE_141: Required for v1.4.1 contract support - without this, the UI may
    #   fall back to v1.3.0 contract addresses which are NOT deployed on the chain.
    # SAFE_TX_GAS_OPTIONAL: Required for L2/custom chains - allows safeTxGas=0
    #   in transactions, which is the correct behavior for chains with instant finality.
    # NATIVE_WALLETCONNECT: Enables native WalletConnect v2 support in the UI.
    # Do NOT add COUNTERFACTUAL without a relay service (Gelato) - it causes the UI
    #   to POST /relay which will 422 without proper Gelato integration.
    default_features = [
        'CONTRACT_INTERACTION', 'DEFAULT_TOKENLIST',
        'DOMAIN_LOOKUP', 'EIP_1559', 'ERC721', 'ERC1155',
        'NATIVE_WALLETCONNECT', 'SAFE_141',
        'SAFE_APPS', 'SAFE_TX_GAS_OPTIONAL', 'SPENDING_LIMIT',
    ]
    added = 0
    for key in default_features:
        try:
            feature, _ = Feature.objects.get_or_create(
                key=key, defaults={'description': key}
            )
            chain.feature_set.add(feature)
            added += 1
        except Exception as e:
            print(f"  WARNING: Could not add feature {key}: {e}")
    print(f"  Enabled {added}/{len(default_features)} features")

    # Seed default Safe Apps (Transaction Builder, Drain Account, CSV Airdrop).
    # The SAFE_APPS feature flag only controls whether the UI renders the Apps tab;
    # the actual list comes from safe_apps_safeapp rows joined by chain_id.
    # Without these records the tab is empty and Tx Builder is unreachable.
    seed_default_apps(args.chain_id)

    print("\nDone.")
    return 0


def seed_default_apps(chain_id: int) -> None:
    """Register hosted Safe Apps so they appear in the UI for this chain.

    Apps are hosted on apps-portal.safe.global — we only register URL metadata,
    no self-hosting required. update_or_create by URL keeps this idempotent and
    adds the new chain_id to any existing app record.
    """
    default_apps = [
        {
            'url': 'https://apps-portal.safe.global/tx-builder',
            'name': 'Transaction Builder',
            'description': 'Compose custom contract interactions and batch them into a single transaction',
        },
        {
            'url': 'https://apps-portal.safe.global/drain-safe',
            'name': 'Drain Account',
            'description': 'Transfer all assets from a Safe to another wallet',
        },
        {
            'url': 'https://apps-portal.safe.global/csv-airdrop',
            'name': 'CSV Airdrop',
            'description': 'Send ERC20 or native token transfers to many recipients at once',
        },
    ]
    seeded = 0
    for spec in default_apps:
        try:
            app, created = SafeApp.objects.get_or_create(
                url=spec['url'],
                defaults={
                    'name': spec['name'],
                    'description': spec['description'],
                    'chain_ids': [chain_id],
                    'listed': True,
                },
            )
            if not created and chain_id not in (app.chain_ids or []):
                app.chain_ids = list(app.chain_ids or []) + [chain_id]
                app.save(update_fields=['chain_ids'])
            seeded += 1
        except Exception as e:
            print(f"  WARNING: Could not register Safe App {spec['name']}: {e}")
    print(f"  Registered {seeded}/{len(default_apps)} Safe Apps for chain {chain_id}")


if __name__ == '__main__':
    sys.exit(main())

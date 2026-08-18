#!/usr/bin/env python3
"""Derive a canonical finalized scanner lower bound from manager init txs."""

import argparse
import json
import sys
import urllib.request


def rpc_call(rpc_url, method, params):
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    ).encode("utf-8")
    request = urllib.request.Request(
        rpc_url, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.load(response)
    if payload.get("error") is not None:
        raise RuntimeError(f"{method}: {payload['error']}")
    return payload.get("result")


def derive_start(anchors, expected_addresses, call):
    if not anchors:
        return {"derived": False, "startBlock": 0, "reason": "no initialization transactions"}
    expected = {address.lower() for address in expected_addresses}
    if not expected:
        return {"derived": False, "startBlock": 0, "reason": "no expected manager addresses"}
    try:
        finalized = call("eth_getBlockByNumber", ["finalized", False])
        if not isinstance(finalized, dict) or not finalized.get("number"):
            raise RuntimeError("finalized block is unavailable")
        finalized_number = int(finalized["number"], 16)
        blocks = []
        transaction_hashes = []
        for anchor in anchors:
            tx_hash = anchor["txHash"]
            selector = anchor["selector"].lower()
            transaction = call("eth_getTransactionByHash", [tx_hash])
            if not isinstance(transaction, dict) or (transaction.get("to") or "").lower() not in expected:
                raise RuntimeError(f"initialization transaction {tx_hash} does not target the configured manager")
            transaction_input = (transaction.get("input") or "").lower()
            if len(selector) != 10 or not transaction_input.startswith(selector):
                raise RuntimeError(
                    f"initialization transaction {tx_hash} does not call the expected function"
                )
            receipt = call("eth_getTransactionReceipt", [tx_hash])
            if not isinstance(receipt, dict):
                raise RuntimeError(f"initialization receipt {tx_hash} is unavailable")
            if receipt.get("status") != "0x1":
                raise RuntimeError(f"initialization receipt {tx_hash} did not succeed")
            if not receipt.get("blockNumber") or not receipt.get("blockHash"):
                raise RuntimeError(f"initialization receipt {tx_hash} has no block identity")
            log_addresses = {
                (entry.get("address") or "").lower()
                for entry in receipt.get("logs", [])
                if isinstance(entry, dict)
            }
            if not (log_addresses & expected):
                raise RuntimeError(f"initialization receipt {tx_hash} has no configured-manager log")
            block_number = int(receipt["blockNumber"], 16)
            if block_number > finalized_number:
                raise RuntimeError(f"initialization receipt {tx_hash} is not finalized")
            canonical = call("eth_getBlockByNumber", [receipt["blockNumber"], False])
            if not isinstance(canonical, dict) or canonical.get("hash") != receipt["blockHash"]:
                raise RuntimeError(f"initialization receipt {tx_hash} is not canonical")
            blocks.append(block_number)
            transaction_hashes.append(tx_hash)
        return {
            "derived": True,
            "startBlock": min(blocks),
            "finalizedHead": finalized_number,
            "transactions": transaction_hashes,
        }
    except (OSError, ValueError, RuntimeError) as error:
        return {"derived": False, "startBlock": 0, "reason": str(error)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--anchor", action="append", nargs=2, metavar=("TX_HASH", "SELECTOR"), default=[])
    parser.add_argument("--expected-address", action="append", default=[])
    args = parser.parse_args()
    result = derive_start(
        [
            {"txHash": tx_hash, "selector": selector}
            for tx_hash, selector in args.anchor
        ],
        args.expected_address,
        lambda method, params: rpc_call(args.rpc_url, method, params),
    )
    json.dump(result, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

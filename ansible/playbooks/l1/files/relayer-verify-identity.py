#!/usr/bin/env python3
"""Verify that Relayer identity metadata is derived from its TLS certificate."""

import argparse
import hashlib
import json
import pathlib
import re
import ssl


def fail(message):
    raise SystemExit(message)


def cb58_encode(payload):
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    checked = payload + hashlib.sha256(payload).digest()[-4:]
    leading_zeroes = len(checked) - len(checked.lstrip(b"\0"))
    value = int.from_bytes(checked, "big")
    encoded = ""
    while value:
        value, remainder = divmod(value, 58)
        encoded = alphabet[remainder] + encoded
    return ("1" * leading_zeroes) + encoded


def read_bytes(path, label):
    try:
        return pathlib.Path(path).read_bytes()
    except OSError as error:
        fail(f"cannot read {label}: {error}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--identity", required=True)
    parser.add_argument("--certificate", required=True)
    args = parser.parse_args()

    identity_bytes = read_bytes(args.identity, "identity metadata")
    certificate_pem = read_bytes(args.certificate, "TLS certificate")
    try:
        identity = json.loads(identity_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"identity metadata is invalid JSON: {error}")
    if not isinstance(identity, dict):
        fail("identity metadata must be a JSON object")

    node_id = identity.get("p2pNodeId")
    certificate_sha = identity.get("tlsCertificateSha256")
    if identity.get("schemaVersion") != 1:
        fail("identity metadata has an unsupported schema version")
    if not isinstance(node_id, str) or not node_id.startswith("NodeID-"):
        fail("identity metadata has an invalid P2P NodeID")
    if not isinstance(certificate_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", certificate_sha):
        fail("identity metadata has an invalid TLS certificate SHA-256")

    actual_certificate_sha = hashlib.sha256(certificate_pem).hexdigest()
    if certificate_sha != actual_certificate_sha:
        fail("identity metadata does not match the TLS certificate checksum")
    try:
        certificate_der = ssl.PEM_cert_to_DER_cert(certificate_pem.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as error:
        fail(f"TLS certificate is invalid: {error}")
    derived_payload = hashlib.new("ripemd160", hashlib.sha256(certificate_der).digest()).digest()
    derived_node_id = "NodeID-" + cb58_encode(derived_payload)
    if derived_node_id != node_id:
        fail("TLS certificate does not derive the recorded P2P NodeID")

    print(
        json.dumps(
            {
                "schemaVersion": 1,
                "p2pNodeId": node_id,
                "tlsCertificateSha256": certificate_sha,
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()

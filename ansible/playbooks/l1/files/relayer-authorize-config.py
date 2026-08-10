#!/usr/bin/env python3
"""Inspect, update, or roll back one validator's Relayer allowlist."""

import argparse
import base64
import grp
import json
import os
import pathlib
import pwd
import re
import shutil
import stat
import tempfile
from datetime import datetime, timezone


NODE_CONFIG_PATH = pathlib.Path("/etc/avalanchego/node.json")
DEFAULT_SUBNET_CONFIG_DIR = pathlib.Path("/home/avalanche/.avalanchego/configs/subnets")
MANIFEST_DIR = pathlib.Path("/etc/avalanchego/relayer-authorization")


def fail(message):
    raise SystemExit(message)


def read_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON from {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{path} must contain a JSON object")
    return value


def validate_regular_path(path, allow_absent=False):
    try:
        details = path.lstat()
    except FileNotFoundError:
        if allow_absent:
            return None
        fail(f"required file is absent: {path}")
    if not stat.S_ISREG(details.st_mode):
        fail(f"refusing non-regular file: {path}")
    return details


def decode_inline_configs(encoded):
    try:
        decoded = base64.b64decode(encoded, validate=True)
        value = json.loads(decoded.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"subnet-config-content is invalid: {error}")
    if not isinstance(value, dict):
        fail("subnet-config-content must encode a subnet-ID map")
    return value


def load_state(subnet_id, required_nodes):
    validate_regular_path(NODE_CONFIG_PATH)
    node_config = read_json(NODE_CONFIG_PATH)
    encoded = node_config.get("subnet-config-content", "")
    if encoded:
        if not isinstance(encoded, str):
            fail("subnet-config-content must be a base64 string")
        source_mode = "content"
        source_path = NODE_CONFIG_PATH
        inline_configs = decode_inline_configs(encoded)
        subnet_config = inline_configs.get(subnet_id, {})
    else:
        source_mode = "file"
        configured_dir = node_config.get("subnet-config-dir", str(DEFAULT_SUBNET_CONFIG_DIR))
        if not isinstance(configured_dir, str) or not configured_dir.startswith("/"):
            fail("subnet-config-dir must be an absolute path")
        source_path = pathlib.Path(configured_dir) / f"{subnet_id}.json"
        validate_regular_path(source_path, allow_absent=True)
        inline_configs = None
        subnet_config = read_json(source_path) if source_path.exists() else {}

    if not isinstance(subnet_config, dict):
        fail(f"the subnet configuration for {subnet_id} must be a JSON object")
    validator_only = subnet_config.get("validatorOnly", False)
    if not isinstance(validator_only, bool):
        fail("validatorOnly must be a boolean")
    allowed_nodes = subnet_config.get("allowedNodes", [])
    if not isinstance(allowed_nodes, list) or any(not isinstance(value, str) for value in allowed_nodes):
        fail("allowedNodes must be a string list")

    manifest_path = MANIFEST_DIR / f"{subnet_id}.json"
    validate_regular_path(manifest_path, allow_absent=True)
    manifest = read_json(manifest_path) if manifest_path.exists() else {}
    if manifest:
        if manifest.get("schemaVersion") != 1 or manifest.get("subnetId") != subnet_id:
            fail(f"managed authorization manifest is incompatible: {manifest_path}")
        managed_nodes = manifest.get("managedNodeIds", [])
        if not isinstance(managed_nodes, list) or any(not isinstance(value, str) for value in managed_nodes):
            fail(f"managedNodeIds must be a string list in {manifest_path}")
    else:
        managed_nodes = []

    required_ids = []
    for item in required_nodes:
        if not isinstance(item, dict) or not isinstance(item.get("nodeId"), str):
            fail("each required node must contain a NodeID string")
        node_id = item["nodeId"]
        if not node_id.startswith("NodeID-"):
            fail(f"invalid required NodeID: {node_id}")
        if node_id not in required_ids:
            required_ids.append(node_id)

    original_allowed = list(allowed_nodes)
    stale_managed = set(managed_nodes) - set(required_ids)
    final_allowed = []
    for node_id in original_allowed:
        if node_id not in stale_managed and node_id not in final_allowed:
            final_allowed.append(node_id)
    for node_id in required_ids:
        if node_id not in final_allowed:
            final_allowed.append(node_id)

    final_managed = []
    for node_id in managed_nodes:
        if node_id in required_ids and node_id not in final_managed:
            final_managed.append(node_id)
    for node_id in required_ids:
        if node_id not in original_allowed and node_id not in final_managed:
            final_managed.append(node_id)

    return {
        "nodeConfig": node_config,
        "inlineConfigs": inline_configs,
        "subnetConfig": subnet_config,
        "sourceMode": source_mode,
        "sourcePath": source_path,
        "manifestPath": manifest_path,
        "validatorOnly": validator_only,
        "allowedNodes": original_allowed,
        "finalAllowedNodes": final_allowed,
        "managedNodeIds": managed_nodes,
        "finalManagedNodeIds": final_managed,
        "missingRequiredNodeIds": [node_id for node_id in required_ids if node_id not in original_allowed],
        "configChanged": original_allowed != final_allowed,
        "manifestChanged": managed_nodes != final_managed,
    }


def atomic_write(path, data, details=None, owner=None, group=None, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        if details is not None:
            os.chown(temporary_path, details.st_uid, details.st_gid)
            os.chmod(temporary_path, stat.S_IMODE(details.st_mode))
        else:
            uid = pwd.getpwnam(owner).pw_uid if owner else 0
            gid = grp.getgrnam(group).gr_gid if group else 0
            os.chown(temporary_path, uid, gid)
            os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def backup_file(path, backup_dir, label):
    details = validate_regular_path(path, allow_absent=True)
    record = {
        "path": str(path),
        "existed": details is not None,
        "backup": "",
        "uid": details.st_uid if details else 0,
        "gid": details.st_gid if details else 0,
        "mode": stat.S_IMODE(details.st_mode) if details else 0,
    }
    if details:
        backup_path = backup_dir / label
        shutil.copyfile(path, backup_path)
        os.chmod(backup_path, 0o600)
        record["backup"] = str(backup_path)
    return record


def inspect_result(state):
    return {
        "sourceMode": state["sourceMode"],
        "sourcePath": str(state["sourcePath"]),
        "validatorOnly": state["validatorOnly"],
        "allowedNodes": state["allowedNodes"],
        "managedNodeIds": state["managedNodeIds"],
        "missingRequiredNodeIds": state["missingRequiredNodeIds"],
        "configChanged": state["configChanged"],
        "manifestChanged": state["manifestChanged"],
    }


def apply_state(args, state):
    if not state["validatorOnly"]:
        fail("validatorOnly is false; authorization never enables protocol privacy")
    changed = state["configChanged"] or state["manifestChanged"]
    result = inspect_result(state)
    result.update({"changed": changed, "backupDir": ""})
    if not changed:
        return result

    backup_dir = pathlib.Path(args.backup_root) / args.subnet_id / args.run_id / args.host_name
    backup_dir.mkdir(parents=True, exist_ok=False, mode=0o700)
    source_record = backup_file(state["sourcePath"], backup_dir, "source.json")
    manifest_record = backup_file(state["manifestPath"], backup_dir, "manifest.json")
    rollback = {"schemaVersion": 1, "source": source_record, "manifest": manifest_record}
    atomic_write(backup_dir / "rollback.json", json_bytes(rollback), mode=0o600)

    try:
        subnet_config = dict(state["subnetConfig"])
        subnet_config["allowedNodes"] = state["finalAllowedNodes"]
        source_details = validate_regular_path(state["sourcePath"], allow_absent=True)
        if state["sourceMode"] == "content":
            inline_configs = dict(state["inlineConfigs"])
            inline_configs[args.subnet_id] = subnet_config
            node_config = dict(state["nodeConfig"])
            node_config["subnet-config-content"] = base64.b64encode(json_bytes(inline_configs)).decode("ascii")
            atomic_write(state["sourcePath"], json_bytes(node_config), details=source_details)
        else:
            atomic_write(
                state["sourcePath"],
                json_bytes(subnet_config),
                details=source_details,
                owner="avalanche",
                group="avalanche",
                mode=0o644,
            )

        manifest = {
            "schemaVersion": 1,
            "subnetId": args.subnet_id,
            "managedNodeIds": state["finalManagedNodeIds"],
            "updatedAt": datetime.now(timezone.utc).isoformat(),
        }
        manifest_details = validate_regular_path(state["manifestPath"], allow_absent=True)
        atomic_write(state["manifestPath"], json_bytes(manifest), details=manifest_details, mode=0o644)
    except BaseException as write_error:
        try:
            restore_record(source_record)
            restore_record(manifest_record)
        except BaseException as rollback_error:
            fail(
                f"authorization write failed ({write_error}); automatic rollback also failed "
                f"({rollback_error}); recover from {backup_dir}"
            )
        raise
    result.update(
        {
            "changed": True,
            "backupDir": str(backup_dir),
            "allowedNodes": state["finalAllowedNodes"],
            "managedNodeIds": state["finalManagedNodeIds"],
        }
    )
    return result


def restore_record(record):
    path = pathlib.Path(record["path"])
    if record["existed"]:
        backup = pathlib.Path(record["backup"])
        details = validate_regular_path(backup)
        atomic_write(path, backup.read_bytes(), details=details)
        os.chown(path, int(record["uid"]), int(record["gid"]))
        os.chmod(path, int(record["mode"]))
    else:
        path.unlink(missing_ok=True)


def rollback(args):
    backup_dir = pathlib.Path(args.backup_dir)
    rollback_path = backup_dir / "rollback.json"
    rollback_state = read_json(rollback_path)
    if rollback_state.get("schemaVersion") != 1:
        fail(f"unsupported rollback metadata: {rollback_path}")
    restore_record(rollback_state["source"])
    restore_record(rollback_state["manifest"])
    return {"rolledBack": True, "backupDir": str(backup_dir)}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("inspect", "apply", "rollback"), required=True)
    parser.add_argument("--subnet-id")
    parser.add_argument("--required-nodes-json", default="[]")
    parser.add_argument("--run-id")
    parser.add_argument("--host-name")
    parser.add_argument("--backup-root", default="/var/backups/avalanchego/relayer-authorize")
    parser.add_argument("--backup-dir")
    args = parser.parse_args()
    if args.mode == "rollback":
        if not args.backup_dir:
            parser.error("--backup-dir is required for rollback")
        return args
    if not args.subnet_id or not args.run_id or not args.host_name:
        parser.error("--subnet-id, --run-id, and --host-name are required")
    if not re.fullmatch(r"[A-Za-z0-9]+", args.subnet_id):
        parser.error("--subnet-id must contain only letters and digits")
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", args.run_id):
        parser.error("--run-id must be a UTC basic timestamp")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.host_name):
        parser.error("--host-name contains unsupported characters")
    try:
        args.required_nodes = json.loads(args.required_nodes_json)
    except json.JSONDecodeError as error:
        parser.error(f"--required-nodes-json is invalid: {error}")
    if not isinstance(args.required_nodes, list) or not args.required_nodes:
        parser.error("--required-nodes-json must be a non-empty list")
    return args


def main():
    args = parse_args()
    if args.mode == "rollback":
        result = rollback(args)
    else:
        state = load_state(args.subnet_id, args.required_nodes)
        result = inspect_result(state) if args.mode == "inspect" else apply_state(args, state)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()

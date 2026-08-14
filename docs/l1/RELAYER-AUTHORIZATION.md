# Authorize the Relayer on a protocol-private L1

Use this runbook only when every L1 validator has `validatorOnly: true`.
Network-private L1s that enforce privacy only with firewalls do not require a
NodeID allowlist.

Run the Avalanche Deploy commands from the repository root. They discover the
active Terraform state, Ansible inventory, L1 metadata, validators, and RPC
nodes. Do not copy a validator staking certificate into the Relayer.

## 1. Prepare the permanent identity

```bash
make relayer-prepare
```

Confirm identity creation when prompted. Record the printed permanent Relayer
NodeID. Also record every managed RPC NodeID and every validator config path.
The command stages the Relayer TLS certificate and key on `rpc[0]`; it does not
install or start the runtime.

Run `make relayer-prepare` again at any time to confirm that it reuses the same
NodeID. A restart, reapply, upgrade, normal removal, or backup restore preserves
this identity. `make relayer-remove PURGE=true` deletes it and the next prepare
creates a different NodeID.

## 2. Choose one authorization method

Use managed authorization when every validator is present in Avalanche
Deploy's active Terraform state and Ansible inventory. Use manual or external
authorization when the L1 owner applies validator configuration through a
different system. Do not run both methods for the same identity rollout.

### Managed authorization

```bash
make relayer-authorize
```

Review and approve the printed plan. The command merges missing Relayer and RPC
NodeIDs into every validator's existing `allowedNodes` list. It preserves
unrelated entries and does not enable `validatorOnly`.

The command restarts changed validators one at a time. It waits for the local
Info API and the L1 to bootstrap after each restart. If a validator fails, it
restores that validator's exact prior configuration, restarts it, verifies
recovery, and stops before changing a later validator.

After the validator rollout, the command checks every managed RPC node. A
validator restart can leave an RPC with stale P2P sessions even when the
allowlist is correct. The command restarts only an RPC that cannot see every
validator, then verifies the RPC's NodeID, L1 bootstrap, and peer visibility.

Rerun `make relayer-authorize` to test idempotence. It must report that every
required NodeID is authorized and make no changes.

### Manual or external authorization

Use the L1 owner's normal configuration-management process. Do not run
`make relayer-authorize`.

For every validator:

1. Back up the effective subnet configuration path printed by
   `make relayer-prepare`.
2. Confirm that `validatorOnly` is `true`.
3. Merge the printed Relayer NodeID and every non-validator RPC NodeID into the
   existing `allowedNodes` array. Do not replace unrelated entries.
4. Validate the JSON and preserve the file's owner and permissions.
5. Restart AvalancheGo on one validator.
6. Verify the same validator NodeID returns from `info.getNodeID` and the L1
   returns `isBootstrapped: true`.
7. Complete those checks before changing the next validator.

After every validator is complete, query `info.peers` on every RPC node. If an
RPC cannot see every L1 validator, restart AvalancheGo on that RPC. Verify that
its NodeID did not change, the L1 is bootstrapped, and all validator NodeIDs are
visible before continuing.

The minimum subnet configuration shape is:

```json
{
  "validatorOnly": true,
  "allowedNodes": [
    "NodeID-RELAYER",
    "NodeID-RPC-1",
    "NodeID-RPC-2"
  ]
}
```

This example is not a complete replacement file. Preserve existing validator
and owner-managed entries. See the
[AvalancheGo field reference](https://build.avax.network/docs/nodes/chain-configs/avalanche-l1s/avalanche-l1-configs#allowednodes-string-list).

## 3. Verify and install

Whether authorization was managed or manual, run:

```bash
make relayer-doctor
make relayer
make relayer-status
```

`VM.PROTOCOL.PRIVACY` and `VM.PEERS.VISIBLE` must pass before installation.
`make relayer` verifies the loaded configuration and peer visibility; a file
edit without the required restart does not pass.

After installation, fund both public addresses printed by
`make relayer-status`. Then run:

```bash
make relayer-doctor
make relayer-backup
make relayer-access
```

Keep the access command running and open `http://127.0.0.1:3080`.

## Recovery rules

- If a managed validator update fails, use the backup path printed by the
  failed command. Do not continue to another validator.
- If a manual validator update fails, restore that validator's backup, restart
  AvalancheGo, and verify its prior NodeID and L1 bootstrap.
- If an RPC does not reconnect, restart only that RPC and repeat the peer
  checks. Do not change validator allowlists again when the correct entries are
  already loaded.
- Do not start the Relayer when any existing validator or required RPC NodeID
  is missing from an allowlist.
- Never reuse one Relayer TLS identity on two running Relayers.

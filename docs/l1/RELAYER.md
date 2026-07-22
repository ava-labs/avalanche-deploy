# Managed validator-lifecycle Relayer

This is the canonical operator runbook for the Avalanche Deploy-managed
validator-lifecycle Relayer for L1s created by this repository through the
Terraform/Ansible workflow. External and hand-built infrastructure are not
supported installation targets.

Run every command in this guide from the Avalanche Deploy repository. You do not
clone or build the separate Relayer repository: Avalanche Deploy discovers the
managed L1 and downloads one pinned, checksum-verified release.

## What it does

An official PoAManager validator change crosses the L1 and the P-Chain. The
Relayer validates initiated operations, gathers Warp signatures, submits the
corresponding P-Chain transaction, waits for acceptance, gathers the return
message, and completes the operation on the L1. It persists in-flight work so a
restart does not blindly repeat P-Chain spending.

This is not the ICM Relayer. The ICM Relayer delivers application messages
between chains; this Relayer drives PoAManager validator registration, weight
changes, and removals.

Only the official Avalanche Deploy PoAManager wrapping an initialized
ValidatorManager is supported. The manager owner may be an EOA or a compatible
Safe. Custom manager wrappers and bare ValidatorManagers are rejected by
preflight.

## Security and authorization

Use the same authorized operator that deployed the L1:

- Terraform/Ansible: a deployment administrator who can read the selected
  Terraform backend/state and matching inventory, SSH to `rpc[0]`, and use the
  existing passwordless `sudo` path.

`doctor` checks effective access one capability at a time; an administrator
title is not trusted. The prerequisite commands install local software only.
They never create cloud credentials, SSH access, or network infrastructure.

The workflow installs one native daemon and one digest-pinned console on
`rpc[0]`, never on validators. Ports 8080 and 3080 bind to loopback, are not
opened by Terraform, and are reached only through the local access tunnel.

Private keys, keystore passwords, session secrets, Terraform state, and
passwords are never printed by the lifecycle scripts or doctor. Normal removal
preserves encrypted keys, state, TLS identity, configuration, and backups.

## Terraform and Ansible workflow

Prerequisites:

1. Create and configure exactly one AWS, GCP, or Azure L1 in this checkout.
2. Initialize the official PoAManager topology and keep the generated `l1.env`.
3. Use the matching deployment administrator, Terraform backend, inventory,
   SSH key, and `sudo` access.

Run:

```bash
make relayer-prereqs
make relayer-doctor
make relayer
make relayer-status
make relayer-access
```

`make relayer` reruns the same read-only doctor before its two application
prompts: target confirmation and an optional console password. A rerun reapplies
the workload while retaining the existing encrypted keys, state, and TLS
identity.

`rpc[0]` must be AMD64 or ARM64 with at least 2 GiB memory and 10 GiB free on
the root filesystem. The installer downloads the native daemon and offline
restore utility for that architecture, verifies the release checksum, and uses
the published immutable console digest.

## What doctor checks

Each independent result has a stable identifier and a `PASS`, `WARN`, `FAIL`,
or `SKIP` level, followed by an exact remediation. Exit status 0 means ready, 1
means blockers, and 2 means invalid usage or an internal error. Warnings do not
change a ready exit status.

Doctor is read-only. It may fetch release metadata and checksums, open temporary
local tunnels, and perform read-only API/database/keystore integrity checks. It
does not install packages, pull images, restart workloads, create resources, or
change infrastructure.

The VM doctor verifies local software and Terraform version, `l1.env`, exactly
one cloud state, matching inventory, backend access, SSH and `sudo`, target
architecture/capacity, release availability, RPC and peer health, the official
manager topology, EOA/Safe ownership, installation state, loopback listeners,
service readiness, encrypted-key and bbolt integrity, public funding status,
retained backup integrity/freshness, and installed artifact drift.

Doctor adapts its result to a fresh target, a healthy installation, a normally
removed workload with retained recovery state, or a partial/inconsistent
installation. Partial state is a blocker; restore matching recovery material or
use the separately confirmed purge only when permanent deletion is intended.

## Metadata and funding

No command asks you to re-enter deployed values. Discovery uses:

- Terraform state/backend outputs and the matching Ansible inventory;
- generated `l1.env`;
- AvalancheGo RPCs and validator peer identities; and
- the official PoAManager, ValidatorManager, owner EOA/Safe, and optional Safe
  services discovered on-chain and in the deployment.

The daemon generates dedicated public P-Chain float and L1 EVM gas addresses.
Fund both addresses before validator operations. `doctor` reports a blocker when
either balance is below the runtime threshold. These are Relayer hot keys; they
are not validator staking keys or the manager owner key.

## Day-two commands

| Command | Result |
|---|---|
| `make relayer-doctor` | Comprehensive read-only readiness check |
| `make relayer-access` | Local console and L1 RPC tunnels |
| `make relayer-status` | Lightweight runtime snapshot |
| `make relayer-logs` | Follow runtime logs |
| `make relayer-backup` | Drain and create a retained consistent backup |
| `make relayer-upgrade RELAYER_VERSION=vX.Y.Z` | Backup, immutable upgrade, readiness check, automatic rollback |
| `make relayer-remove` | Remove workload and retain recovery material |
| `make relayer-remove PURGE=true` | Separately confirm permanent deletion |

`status` is intentionally quick. Use `doctor` for a comprehensive point-in-time
assessment.

## Backup and restore

Backups drain the daemon and console before taking a consistent archive. The
archive includes bbolt state, the encrypted keystore and matching credential,
TLS identity, and runtime configuration. A non-secret sidecar manifest records
the release version, network and chain identity, manager addresses, public
funding addresses, creation time, archive name, and checksum.

VM backups are retained on `rpc[0]` and fetched to the root-only local
`backups/relayer` directory. Restore requires the absolute path to the fetched
archive and its adjacent manifest:

```bash
make relayer-restore BACKUP=/absolute/path/to/relayer-YYYYMMDDTHHMMSS.tar.gz
```

Restore confirms the exact target, validates the sidecar checksum and current
L1 compatibility, rejects unsafe archive members, drains an installed workload,
retains an automatic pre-restore archive, uses `relayer-restore` to replace
bbolt state offline, restores the matching encrypted keys/TLS material, and
checks readiness. A failed readiness check automatically reapplies the
pre-restore state. If the workload was normally removed, restore leaves it
removed and ready for an idempotent reinstall.

## Removal and purge

Normal removal is reversible:

```bash
make relayer-remove
```

Permanent deletion is a different operation with a second destructive
confirmation:

```bash
make relayer-remove PURGE=true
```

Create and retain a validated backup before purge. Purge deletes keys, state,
TLS identity, configuration, and backups.

## Release and repository contract

The separate `ava-labs/validator-manager-relayer` repository owns daemon behavior, release
artifacts, configuration, APIs, security, and runtime semantics. A tagged
release publishes `relayerd`, `relayer-setup`, and `relayer-restore` for
Darwin/Linux on AMD64/ARM64, `checksums.txt`, SBOMs and attestations, and
multi-architecture daemon/console images with immutable digest assets.

Avalanche Deploy owns discovery, authorization, placement, and lifecycle
commands. VM installs use the checksum-verified native daemon and a digest-pinned
console. Installed release metadata lets doctor detect checksum, digest, and
version drift.

The production version pin intentionally remains a transfer sentinel until all
of these release gates pass:

1. the repository is transferred to public `ava-labs/validator-manager-relayer`;
2. OCI packages are public under `ghcr.io/ava-labs`;
3. a tagged release is published after transfer; and
4. anonymous archive downloads and image pulls pass for the VM workflow.

Repository redirects do not move granular GHCR packages to the new owner, so
production images must be published after transfer. Maintainers may use an
authenticated repository override only for pre-transfer development by setting
`RELAYER_DEVELOPMENT=true`; that override is not part of the supported operator
flow.

For runtime details, see the [Relayer technical documentation](https://github.com/ava-labs/validator-manager-relayer/tree/main/docs).

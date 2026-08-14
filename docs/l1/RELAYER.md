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
`rpc[0]`, never on validators. Ports 8081 and 3080 bind to loopback, are not
opened by Terraform, and are reached only through the local access tunnel.
Port 8081 keeps the daemon API clear of 8080, which Safe's Nginx redirect and
the ICM Relayer bind when co-located on `rpc[0]`.

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

### Permanent NodeID and protocol-private L1s

Every Relayer gets a permanent P2P TLS certificate and derived NodeID by
default. The identity is created by `relayer-setup`, staged on `rpc[0]` before
the runtime is installed, and reused across restarts, upgrades, normal removal,
and reinstallation. The daemon refuses to silently generate a replacement.

Discovery reads the effective Subnet config from every existing validator. If
`validatorOnly` is disabled everywhere, including a network-private deployment
whose P2P ports are protected only by firewalls, no protocol allowlist is
required and installation continues normally.

If `validatorOnly` is enabled, every managed RPC node must also be present in
`allowedNodes` on every validator. RPC nodes are not L1 validators, so
`validatorOnly` otherwise prevents them from exchanging this L1's messages and
the Relayer cannot use them to verify topology or gather Warp signatures.

For a fresh protocol-private installation, use this sequence:

```bash
make relayer-prepare
# Terraform/Ansible-managed validators:
make relayer-authorize
# Or skip that command and follow RELAYER-AUTHORIZATION.md when the L1 owner
# manages validator configuration manually or with an external system.
make relayer
```

`make relayer-prepare` creates and stages the permanent Relayer identity. It
does not install or start the Relayer. It prints the permanent Relayer NodeID,
all managed RPC NodeIDs, every missing validator entry, and the effective
configuration source on each validator.

The chain owner can merge the printed NodeIDs into `allowedNodes` by using the
owner's normal process. Each NodeID must be present on **every existing L1
validator**. Restart each affected AvalancheGo node. Updating only `rpc[0]` or
one validator is insufficient. Follow the dedicated
[Relayer authorization runbook](RELAYER-AUTHORIZATION.md) and the
[AvalancheGo `allowedNodes` documentation](https://build.avax.network/docs/nodes/chain-configs/avalanche-l1s/avalanche-l1-configs#allowednodes-string-list).

When every validator is present in the active Terraform state and Ansible
inventory, Avalanche Deploy operators can run:

```bash
make relayer-authorize
```

This optional command audits every validator before it makes a change. It
merges only the missing managed NodeIDs and preserves unrelated entries. It
does not enable `validatorOnly`; the chain owner controls that policy. It then
restarts one affected validator at a time. After each restart, it waits for the
local Info API and L1 bootstrap. If a validator fails, the command restores that
validator's exact previous configuration, restarts it, checks recovery, and
stops before it changes a later validator. Validators that completed earlier
keep the safe allowlist superset. After the validator rollout, the command
checks every managed RPC node. It restarts only an RPC whose validator sessions
did not reconnect, then verifies the RPC's NodeID, L1 bootstrap, and complete
validator peer visibility.

If the owner completed authorization manually or through another configuration
system, skip
`make relayer-authorize` and run `make relayer`. The installer verifies the
effective configuration, confirms that the running AvalancheGo process started
after that configuration was written, and checks RPC peer visibility. A config
edit without a validator restart is not accepted. If authorization or a restart
is incomplete, `make relayer` offers to run the managed authorization command
in the same invocation. If the operator accepts, all readiness checks run again
before installation continues.

Authorization discovery does not depend on a working L1 RPC connection. This
lets the managed command restore RPC access after `validatorOnly` excludes an
RPC node. Full RPC, contract topology, Safe, release, and installation checks
still run before the Relayer starts.

#### Relayers outside Avalanche Deploy

An external Relayer operator must perform the same sequence with the operator's
own configuration system:

1. Run `relayer-setup` before the service starts. Retain its TLS certificate,
   TLS key, and generated configuration as one permanent identity.
2. Read `p2pNodeId` from the JSON setup result.
3. Give the Relayer NodeID and every non-validator peer NodeID to the L1 owner.
4. Merge all of those NodeIDs into `allowedNodes` on every validator that uses
   `validatorOnly: true`.
5. Restart the affected AvalancheGo validators one at a time and verify their
   local Info API and L1 bootstrap after each restart.
6. Check every non-validator RPC peer after the validator rollout. Restart only
   an RPC whose validator sessions did not reconnect, then verify its stable
   NodeID, L1 bootstrap, and complete validator peer visibility.
7. Start `relayerd --config-file=<generated-config>` only after the effective
   configuration is complete.

`make relayer-authorize` applies only to validators in the active Avalanche
Deploy Terraform and Ansible inventory. The Relayer binary cannot edit an
external owner's validators. External operators must use the owner's normal
configuration management, but they do not need a different Relayer release.

The workflow also blocks a mixed validator set where only some validators have
`validatorOnly` enabled. Apply one protocol-privacy policy consistently before
continuing. A backup retains the identity. An explicit `PURGE=true` deletes it,
so the next fresh setup creates a different NodeID that must be allowlisted
again on every protocol-private validator.

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
manager topology, EOA/Safe ownership, all-validator protocol privacy and
NodeID allowlisting, installation state, loopback listeners, service readiness,
encrypted-key and bbolt integrity, public funding status, retained backup
integrity/freshness, and installed artifact drift.

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

## Operating validators

Before starting a registration, weight update, or removal:

1. Run `make relayer-doctor` and resolve every blocker.
2. Run `make relayer-status` and confirm that the daemon and console are
   healthy and that the expected public funding addresses are present.
3. Run `make relayer-access` and keep the SSH tunnel open.
4. Open the console at `http://127.0.0.1:3080`.

The console prepares the L1 call and then hands the **executed L1 transaction**
to the Relayer. The owner type changes who executes that first call:

- An EOA owner signs and broadcasts the L1 transaction directly from the
  connected wallet. The confirmed wallet transaction hash can flow directly
  into the Relayer step.
- A Safe owner does not broadcast the L1 call when the console creates the
  proposal. The Safe owners must approve and execute it separately before the
  Relayer can start.

### Safe-backed operation ceremony

When the PoAManager owner is a Safe:

1. Complete the validator-operation form in the console and create the Safe
   proposal.
2. Open the Safe UI at `https://127.0.0.1:3081` through the same
   `make relayer-access` tunnel. Accept the self-signed certificate warning
   when using the default deployment.
3. Find the proposal and collect the configured approval threshold. An approval
   alone does not change the L1.
4. Execute the approved proposal in the Safe UI and wait for its L1 receipt to
   confirm.
5. Copy the hash of that **executed L1 transaction** from the execution receipt.
6. Return to the console Relayer step and paste that hash when it is not
   already populated.
7. Keep the console open to follow the persisted operation timeline. The
   Relayer now validates the receipt, gathers Warp signatures, submits the
   P-Chain transaction, waits for acceptance, and completes the return leg on
   the L1.

The Relayer does not approve or execute Safe proposals and must not receive the
Safe proposal hash. If the proposal is only approved, or if its proposal
identifier is pasted into the Relayer step, there is no executed L1 receipt for
the daemon to process.

### Do not mix up these identifiers

| Identifier | Where it comes from | How it is used |
|---|---|---|
| Safe proposal hash | Safe Transaction Service before execution | Tracks approvals; never submit it to the Relayer |
| Executed L1 transaction hash | Wallet or Safe execution receipt after the L1 transaction confirms | The hash submitted to the Relayer |
| P-Chain transaction ID | Relayer after Warp aggregation and P-Chain submission | Tracks the validator-set mutation on the P-Chain |
| Validation ID | Registration result and subsequent validator records | Stable validator identity for weight updates and removal |

Keep the executed L1 transaction hash and validation ID in the operation
record. The P-Chain transaction ID is useful when diagnosing an operation that
has left the L1 but has not completed its return leg.

### Inputs by operation

- Registration requires the validator NodeID and its 144-byte BLS
  proof-of-possession payload in addition to the normal registration fields.
  Use the values belonging to the validator being registered; the Relayer
  verifies that the proof matches the BLS public key in the initiated event.
- Weight update requires the existing validation ID and the new weight.
- Removal requires the existing validation ID. If this Relayer did not perform
  the original registration, also provide the original executed registration
  transaction hash when the console asks for it. That receipt supplies the
  registration message needed to justify removal.

Do not guess a registration transaction hash or substitute the P-Chain
transaction ID. If the original receipt is unavailable, stop and recover the
original registration record before attempting removal.

### Timing, retries, and recovery

A complete lifecycle can take several minutes. Warp signature collection,
P-Chain acceptance, and the return message are separate asynchronous stages.
Do not start a second operation merely because the UI remains on one stage for
a few minutes.

The daemon persists operation progress and deduplicates the executed L1
transaction hash. If the browser or console restarts, reopen the same operation
and reconcile it against the console timeline before submitting another hash.
Use:

```bash
make relayer-status
make relayer-logs
```

`status` confirms workload health and public funding metadata; `logs` shows the
daemon's current stage and any actionable failure. Reusing the same executed L1
transaction hash is the safe retry. Do not create and execute a second Safe
proposal unless the first proposal was never executed and the console has
confirmed that no operation was persisted.

## Day-two commands

| Command | Result |
|---|---|
| `make relayer-doctor` | Comprehensive read-only readiness check |
| `make relayer-prepare` | Create or reuse the permanent NodeID without installing the runtime |
| `make relayer-authorize` | Optionally update every managed validator and restart only affected nodes |
| `make relayer-access` | Local console and L1 RPC tunnels |
| `make relayer-status` | Lightweight runtime snapshot |
| `make relayer-logs` | Follow runtime logs |
| `make relayer-backup` | Drain and create a retained consistent backup |
| `make relayer-upgrade [RELAYER_VERSION=vX.Y.Z]` | Backup, upgrade to the latest official stable or an exact override, readiness check, automatic rollback |
| `make relayer-remove` | Remove workload and retain recovery material |
| `make relayer-remove PURGE=true` | Separately confirm permanent deletion |

`status` is intentionally quick. Use `doctor` for a comprehensive point-in-time
assessment.

## Backup and restore

Backups drain the daemon and console before taking a consistent archive. The
archive includes bbolt state, the encrypted keystore and matching credential,
TLS identity, and runtime configuration. A non-secret sidecar manifest records
the release version, network and chain identity, manager addresses, public
funding addresses, permanent P2P NodeID and certificate fingerprint, creation
time, archive name, and checksum.

VM backups are retained on `rpc[0]` and fetched to the root-only local
`backups/relayer` directory. Restore requires the absolute path to the fetched
archive and its adjacent manifest:

```bash
make relayer-restore BACKUP=/absolute/path/to/relayer-YYYYMMDDTHHMMSS.tar.gz
```

Restore confirms the exact target, validates the sidecar checksum and current
L1 compatibility, rejects unsafe or duplicate archive members, and derives the
NodeID from the archived TLS certificate. The manifest, `identity.json`, and
certificate must all describe the same permanent identity. The VM repeats that
binding check before it stops services. Restore then retains an automatic
pre-restore archive, uses `relayer-restore` to replace bbolt state offline,
restores the matching encrypted keys/TLS material, and checks readiness. A
failed readiness check automatically reapplies the pre-restore state. If the
workload was normally removed, restore leaves it removed and ready for an
idempotent reinstall. On a protocol-private L1, managed restore temporarily
authorizes both the current NodeID and the validated backup NodeID when the
owner has not already done so. After every successful restore, including one
that the owner pre-authorized, it removes only obsolete NodeID entries recorded
in its managed manifest. After a failed restore, it removes the temporary
backup NodeID only when discovery confirms that the original identity was
restored. If identity recovery cannot be confirmed, both NodeIDs remain
authorized and the command stops for operator recovery instead of risking a
P2P lockout.

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

The separate `ava-labs/avalanche-vmc-relayer` repository owns daemon behavior, release
artifacts, configuration, APIs, security, and runtime semantics. A tagged
release publishes `relayerd`, `relayer-setup`, and `relayer-restore` for
Darwin/Linux on AMD64/ARM64, `checksums.txt`, SBOMs and attestations, and
multi-architecture daemon/console images with immutable digest assets.

Avalanche Deploy owns discovery, authorization, placement, and lifecycle
commands. VM installs use the checksum-verified native daemon and a digest-pinned
console. Installed release metadata lets doctor detect checksum, digest, and
version drift.

For release-dependent commands, the VM workflow resolves `official-latest` to
GitHub's newest non-draft, non-prerelease release from
`ava-labs/avalanche-vmc-relayer`. It then uses that immutable tag for release
availability, checksum, image-digest, install, restore, and integrity checks.
While the official repository has no production release, the reviewed fallback
is `v0.1.0-rc.8`. The prerelease is ready for managed testing only after all of
these publication gates pass:

1. `v0.1.0-rc.8` is published from `ava-labs/avalanche-vmc-relayer`;
2. its OCI packages are readable under `ghcr.io/ava-labs`;
3. archive checksums and immutable image-digest assets are present; and
4. the authenticated private-repository flow or the anonymous public flow
   passes end to end.

This selector does not upgrade a running Relayer in the background. Once a
production release exists, `make relayer-doctor` selects it and reports whether
the installed immutable version differs. The operator must still run
`make relayer-upgrade` to perform a backup and upgrade. Set
`RELAYER_VERSION=vX.Y.Z` to test or retain one exact release explicitly.

While the Ava Labs repository is private, an authorized maintainer can read its
release archives with an explicit development token:

```bash
RELAYER_DEVELOPMENT=true \
RELAYER_DEVELOPMENT_TOKEN="$(gh auth token)" \
make relayer
```

The VM still needs anonymous read access to the immutable `ghcr.io/ava-labs`
console image because the managed install does not configure registry
credentials. Make that package public before the end-to-end test. Repository
overrides remain an explicit development-only escape hatch and are not part of
the supported operator flow.

For runtime details, see the [Relayer technical documentation](https://github.com/ava-labs/avalanche-vmc-relayer/tree/main/docs).

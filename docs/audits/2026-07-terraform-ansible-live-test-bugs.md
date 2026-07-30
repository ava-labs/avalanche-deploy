# Terraform/Ansible Fuji Live-Test Bug Register

This register records defects and documentation ambiguities found while
following the supported Avalanche Deploy Terraform/Ansible workflow on Fuji.
It is an implementation backlog, not an operator troubleshooting log.

Last updated: 2026-07-23

## Inclusion rules

Add an entry when a problem is reproducible in an advertised repository
workflow and at least one of the following is true:

- Repository code fails with otherwise valid inputs.
- Repository setup does not install or verify a declared prerequisite.
- A command performs a partial mutation and cannot safely resume.
- Documentation omits or misstates a decision required by repository code.
- Two supported repository components conflict with each other.

Do not add failures caused only by cloud-account policy, expired credentials,
incorrect operator input, unavailable test funds, or an unsupported deviation
from the documented workflow.

Use these statuses:

- `OPEN`: confirmed and not fixed.
- `PARTIAL`: immediate failure fixed, root issue remains.
- `FIXED-WORKTREE`: fixed and verified locally but not committed.
- `RESOLVED`: merged and verified from the published workflow.

For every new confirmed defect, update this register in the same working
session as the fix or investigation.

## Summary

| ID | Status | Area | Defect |
|---|---|---|---|
| AD-TF-001 | OPEN | Setup | macOS setup installs Terraform from a removed Homebrew formula |
| AD-TF-002 | OPEN | Setup | Ansible collection installation failures are discarded |
| AD-TF-003 | FIXED-WORKTREE | Validator Manager | Inventory validators were used instead of the accepted conversion |
| AD-TF-004 | FIXED-WORKTREE | Validator Manager | Glacier signature route was obsolete |
| AD-TF-005 | FIXED-WORKTREE | Validator Manager | Foundry warnings broke successful deployment parsing |
| AD-TF-006 | PARTIAL | Genesis/ownership | Genesis ProxyAdmin owner differs from the documented runtime deployer |
| AD-TF-007 | FIXED-WORKTREE | Validator Manager | JSON mode emitted progress text on stdout |
| AD-TF-008 | FIXED-WORKTREE | Safe | Safe deployer required Bash 4 on supported macOS |
| AD-TF-009 | OPEN | Safe documentation | Factory and inventory prerequisites are described without discovery context |
| AD-TF-010 | FIXED-WORKTREE | Safe | Fresh deployment treated Django's startup banner as a Safe address |
| AD-TF-011 | OPEN | Safe architecture | Playbook deploys independent stateful Safe stacks on every RPC host |
| AD-TF-012 | FIXED-WORKTREE | Safe access | Late failure prevented the pending Nginx configuration from loading |
| AD-TF-013 | FIXED-WORKTREE | Safe access | Empty WalletConnect project ID disabled every wallet connection |
| AD-TF-014 | OPEN | Safe access | Default self-signed RPC URL causes Safe creation to fail |
| AD-TF-015 | OPEN | Ownership documentation | ProxyAdmin handoff procedure is omitted |
| AD-TF-016 | OPEN | Relayer installation | Optional console password is accepted without confirmation |
| AD-TF-017 | FIXED-WORKTREE | Relayer networking | Doctor passed although no Primary bootstrap peer was available |
| AD-TF-018 | FIXED-WORKTREE | Relayer diagnostics | Doctor treated a locked live bbolt database as corrupt |
| AD-TF-019 | OPEN | Relayer documentation | Runbook omits the Safe-backed validator-operation ceremony |

## AD-TF-001: macOS setup installs Terraform from a removed Homebrew formula

Status: `OPEN`

Affected paths:

- `Makefile` (`setup`)
- `scripts/shared/relayer-prereqs.sh`

Supported reproduction:

```bash
make setup
```

Observed result:

```text
Warning: No available formula with the name "terraform".
make: *** [setup] Error 1
```

Expected result:

`make setup` installs the Terraform CLI on a supported macOS operator machine.

Root cause:

Both setup paths call `brew install terraform` without first configuring the
official HashiCorp tap. Terraform is no longer available from the Homebrew core
formula used by that command.

Impact:

The documented first-time setup stops before Terraform, Ansible collections,
and later prerequisites are ready.

Current workaround:

Configure HashiCorp's official Homebrew tap and install its Terraform formula
before rerunning setup.

Required repository fix:

- Use the official HashiCorp tap/formula in both macOS setup paths.
- Make the operation idempotent.
- Verify the installed Terraform version before reporting success.
- Add a macOS setup smoke test or command-rendering fixture.

## AD-TF-002: Ansible collection installation failures are discarded

Status: `OPEN`

Affected path:

- `Makefile` (`setup`)
- `ansible/requirements.yml`

Supported reproduction:

Run `make setup` with a missing, incompatible, or failed Ansible Galaxy
collection installation, then run `make deploy`.

Observed behavior:

The setup command executes:

```make
ansible-galaxy collection install -r ansible/requirements.yml || true
```

Any installation failure is converted into success. During the live test, the
NVMe formatting task later failed while resolving
`community.general.filesystem`, reporting that its normal `dev` and `fstype`
parameters were unsupported. The exact collection state at the time was not
preserved, but setup would have hidden a failed collection installation.

Expected result:

Setup fails immediately with the collection name and an exact remediation.
Deployment begins only after required modules can be resolved.

Impact:

Operators can receive a successful setup message and discover the broken
dependency only after infrastructure has been created and Ansible has started
mutating remote hosts.

Required repository fix:

- Remove `|| true`.
- Pin a tested compatible range for Ansible Core and each collection.
- Verify `community.general.filesystem` and `ansible.posix.mount` resolution.
- Add a clean-machine Ansible syntax/module-resolution check.

## AD-TF-003: inventory validators were used instead of the accepted conversion

Status: `FIXED-WORKTREE`

Affected paths:

- `tools/initialize-validator-manager/`
- `ansible/playbooks/l1/initialize-validator-manager.yml`

Supported reproduction:

1. Provision two validator instances.
2. Convert the Subnet to an L1 with only the first validator.
3. Reserve the second instance for validator-lifecycle testing.
4. Run `make initialize-validator-manager`.

Previous behavior:

The initializer constructed the initial validator set from every validator in
the Ansible/Terraform inventory. That did not match the validator set committed
by the accepted `ConvertSubnetToL1Tx`.

Expected behavior:

The accepted P-Chain conversion transaction is the only authority for subnet,
blockchain, manager address, initial NodeIDs, BLS keys, weights, and conversion
ID.

Impact:

Initialization either fails with a conversion mismatch or risks constructing
state from stale deployment inventory.

Worktree fix:

- Fetch and decode the accepted conversion transaction.
- Validate subnet, chain, manager topology, NodeIDs, BLS keys, and weights.
- Derive and validate the real conversion ID.
- Ignore inventory validators as conversion authority.
- Add conversion fixtures and mismatch tests.

Verification:

The SafeTF conversion containing one initial validator passed the read-only
local-signature preflight while the inventory still contained two validators.

## AD-TF-004: Glacier signature route was obsolete

Status: `FIXED-WORKTREE`

Affected path:

- `tools/initialize-validator-manager/glacier.go`

Previous behavior:

The initializer called an obsolete Glacier signature-aggregation URL that
returned HTTP 404.

Expected behavior:

Use the current aggregate-signatures route, authenticate via header, distinguish
retryable responses, and return sanitized errors.

Worktree fix:

- Use `/v1/signatureAggregator/{network}/aggregateSignatures/{txHash}`.
- Send the API key through `x-glacier-api-key`, never argv.
- Add response parsing, bounded retries, and route tests.

Scope note:

Hosted aggregation being unable to reach a private/custom L1 is not itself a
repository defect. The supported private-L1 path is a local
`icm-services/signature-aggregator` peered with that L1's validators.

## AD-TF-005: Foundry warnings broke successful deployment parsing

Status: `FIXED-WORKTREE`

Affected path:

- `tools/initialize-validator-manager/main.go`

Supported reproduction:

Run initialization with Foundry 1.7.1 and the selected `icm-contracts`
`foundry.toml`.

Observed result:

Foundry successfully deployed `ValidatorMessages`, but emitted warnings about
the `number_underscores` formatting key before its JSON result. The initializer
attempted to decode the entire combined output as JSON and returned:

```text
failed to parse output
```

Impact:

An on-chain deployment succeeded, but the command reported failure and had no
resume input. A blind retry would deploy duplicate contracts and waste gas.

Worktree fix:

- Extract the JSON object containing `deployedTo` from warning-prefixed output.
- Add `--validator-messages-library` to reuse an already deployed library.
- Validate that a supplied address contains contract code.
- Add warning-prefixed parser regression tests.

## AD-TF-006: genesis ProxyAdmin owner differs from the runtime deployer

Status: `PARTIAL`

Affected paths:

- `configs/l1/genesis/genesis.json`
- `tools/initialize-validator-manager/main.go`
- `ansible/playbooks/l1/initialize-validator-manager.yml`
- `docs/l1/DEPLOYMENT.md`

Supported reproduction:

1. Create an L1 from the repository's sample genesis.
2. Fund and export a separate `l1-deployer` key.
3. Run Validator Manager initialization.

Observed result:

The sample genesis assigns the predeployed ProxyAdmin to the public EWOQ test
account. The documented runtime deployer therefore cannot upgrade the genesis
proxy:

```text
Ownable: caller is not the owner
```

Why this is a repository defect:

The documentation previously presented one deployment key without explaining
that the genesis ProxyAdmin has a separate upgrade owner. The initializer also
deployed contracts before checking that it possessed the upgrade authority.

Worktree mitigation:

- Read the EIP-1967 ProxyAdmin slot and `owner()` before deployments.
- Support a separate `GENESIS_PROXY_ADMIN_PRIVATE_KEY` environment variable.
- Keep the runtime deployer as the initial ValidatorManager/PoAManager owner.
- Add `--validator-manager-implementation` for safe interrupted-run recovery.
- Document ProxyAdmin versus PoAManager ownership.

Remaining root fix:

- Make L1 creation personalize or explicitly require the genesis ProxyAdmin
  owner before `CreateChainTx`.
- Treat the public EWOQ-owned sample genesis as disposable development-only
  configuration.
- Provide a supported path to transfer both upgrade authority and
  validator-lifecycle authority to the intended Safe.

## AD-TF-007: JSON mode emitted progress text on stdout

Status: `FIXED-WORKTREE`

Affected paths:

- `tools/initialize-validator-manager/init_validator_set.go`
- `ansible/playbooks/l1/initialize-validator-manager.yml`

Observed result:

Validator Manager initialization completed successfully, wrote
`validator-manager.json`, upgraded the proxy, transferred ownership, and
initialized the validator set. Ansible then failed locally:

```text
from_json failed: Expecting value
```

Root cause:

The local signature-aggregation helper printed progress messages to stdout
before the tool's final JSON document. Ansible correctly expected stdout to be
a single JSON value.

Impact:

The command reported failure after every required on-chain mutation had already
succeeded. A retry would be unsafe.

Worktree fix:

- Send signature-aggregation progress to stderr.
- Reserve stdout for the JSON result when `--json` is active.
- Restore `VALIDATOR_MANAGER_PROXY` and `POA_MANAGER` metadata after the live
  run's reporting-only failure.

Verification:

A live read-only `--preflight-only --json` invocation pipes directly through
`jq` and returns success.

## AD-TF-008: Safe deployer required Bash 4 on supported macOS

Status: `FIXED-WORKTREE`

Affected paths:

- `scripts/l1/safe/deploy-contracts.sh`
- `tests/safe-deploy-contracts.sh`

Supported reproduction:

On macOS using the system Bash 3.2:

```bash
make safe
```

Observed result:

```text
deploy-contracts.sh: line 19: SafeL2: unbound variable
```

Classification:

This is a code defect, not a missing operator prerequisite. The repository's
supported macOS flow invokes `#!/usr/bin/env bash`; it did not state or install
Bash 4.

Root cause:

The script used Bash 4 associative arrays (`declare -A`). Bash 3.2 interpreted
the string key as an indexed-array arithmetic expression. With `set -u`,
`SafeL2` became an unbound variable.

Impact:

`make safe` stopped before deploying any Safe contracts.

Worktree fix:

- Replace associative arrays with Bash-3-compatible parallel indexed arrays.
- Verify equal name, address, and gas-limit counts before processing.
- Add a non-mutating compatibility test that exercises all eight mappings under
  strict mode.
- Verify every required initcode asset is present.

Verification:

`bash -n`, ShellCheck, and `tests/safe-deploy-contracts.sh` pass with the macOS
system Bash.

## AD-TF-009: Safe prerequisites lack discovery context

Status: `OPEN`

Affected path:

- `docs/l1/SAFE.md`

Current ambiguity:

The guide lists the Singleton Factory and an Ansible `rpc` group as manual
prerequisites without explaining what they are, how to verify them, or that the
standard repository genesis and Terraform inventory normally provide them.
It also does not emphasize that `hosts: rpc` installs the full Safe service
stack on every RPC host in that group.

Live-test state:

- The Singleton Factory was already present at its canonical address with 69
  bytes of code from genesis.
- The generated inventory's `rpc` parent group contained both
  `rpc-archive-1` and `rpc-pruned-1`.
- Port 8080 was free on both hosts.
- The eight Safe v1.4.1 contracts had not yet been deployed.

Required documentation fix:

- Explain that the factory is a deterministic deployer, not the Safe wallet.
- Show a read-only factory-code verification command.
- Explain the generated `rpc` group and show `ansible-inventory --graph`.
- State that `make safe` installs services on every host in the group.
- State that `make safe` deploys infrastructure and canonical contracts but
  does not create the operator's multisig wallet.
- Document the subsequent owner/threshold selection and ownership transfers.

## AD-TF-010: fresh deployment treated Django's startup banner as a Safe address

Status: `FIXED-WORKTREE`

Affected path:

- `ansible/roles/safe/tasks/main.yml`

Supported reproduction:

Run `make safe` against a newly deployed Safe Transaction Service with no Safe
wallets indexed yet.

Observed result:

The late `SafeLastStatus` repair task captured all stdout from Django's
`manage.py shell`. Django printed:

```text
43 objects imported automatically (use -v 2 for details).
```

The actual missing-address query returned an empty line, but the task treated
the startup banner as its space-separated address list. It passed words from
the banner to `reindex_master_copies --addresses`, which failed with:

```text
unrecognized arguments: for details).
```

Expected behavior:

A fresh deployment with no indexed Safes is a clean no-op. Only validated
20-byte EVM addresses may be passed to the repair command.

Impact:

All eight canonical Safe contracts and the service stack deployed
successfully, but Ansible reported the complete `make safe` workflow as failed
during a post-deployment repair step.

Worktree fix:

- Run Django shell with verbosity zero.
- Prefix the query result with a unique `SAFE_MISSING=` marker.
- Extract only the marked result rather than arbitrary command stdout.
- Reject every non-empty token that is not a `0x`-prefixed 20-byte EVM
  address before invoking any repair command.

Verification:

The marked query returned `SAFE_MISSING=` on both live RPC hosts, confirming
that the correct behavior for the fresh deployment is a no-op. All eight
canonical Safe contracts were independently confirmed on-chain.

## AD-TF-011: playbook deploys independent stateful Safe stacks on every RPC host

Status: `OPEN`

Affected paths:

- `ansible/playbooks/l1/deploy-safe.yml`
- `ansible/roles/safe/templates/docker-compose.yml.j2`
- `ansible/roles/safe/templates/txs.env.j2`
- `ansible/roles/safe/defaults/main.yml`
- `docs/l1/SAFE.md`

Supported reproduction:

1. Generate the standard Terraform inventory with one archive and one pruned
   RPC node.
2. Run `make safe`.
3. Observe the completion output.

Observed result:

The play targets `hosts: rpc`, whose generated parent group contains both
`rpc-archive-1` and `rpc-pruned-1`. It therefore publishes two UI URLs and
installs a full Safe stack on both machines.

This is not an HA deployment. Each host has independent local PostgreSQL
databases for Transaction Service, Config Service, and Client Gateway, plus
independent Redis, RabbitMQ, secrets, workers, and persistent data directories.
There is no shared database, replication, load balancer, or single canonical
service endpoint.

Impact:

- Off-chain Safe proposals and collected signatures submitted to one
  Transaction Service may not exist on the other.
- Operators can switch between visually identical UIs and observe inconsistent
  pending state.
- Both stacks independently index the same chain and consume resources.
- The pruned-node stack may be less suitable for historical indexing than the
  archive-node stack.
- Documentation presents a singular architecture while the default playbook
  creates two independent control planes.

Current live-test workaround:

Use only the archive-node UI (`rpc-archive-1`) and do not alternate between the
two URLs. Do not present the pruned-node UI as an equivalent endpoint.

Required repository decision and fix:

- Default to one explicit Safe application host, preferably the archive RPC
  host, and publish one canonical URL; or
- Implement actual HA with shared/replicated state and a supported load
  balancer.

The playbook must fail on ambiguous placement rather than silently deploying
multiple independent stateful stacks. Doctor/status checks should verify the
selected placement and canonical endpoint.

## AD-TF-012: late failure prevented the pending Nginx configuration from loading

Status: `FIXED-WORKTREE`

Affected paths:

- `ansible/roles/safe/tasks/main.yml`
- `ansible/playbooks/l1/deploy-safe.yml`

Supported reproduction:

1. Run `make safe` on fresh RPC hosts.
2. Let the role template and enable the Safe Nginx site.
3. Trigger a later role failure before Ansible reaches the end-of-play handler
   flush.
4. Open the reported HTTPS URL.

Observed result:

Nginx itself was active and `nginx -t` accepted the generated configuration,
but the running master process had never reloaded it. Nothing listened on ports
443, 4443, or 8080, and browsers reported that the site could not be reached.
Internal Transaction, Config, and Client Gateway health checks still passed,
making the completion state misleading.

Root cause:

The site template, symlink, and default-site removal only notified the
`Reload nginx` handler. That handler was deferred until the end of the play.
The later `SafeLastStatus` task failure prevented the pending handler from
running. The playbook also verified only internal application ports, not the
published HTTPS ingress.

Impact:

The Safe contracts and all backend services can be healthy while the operator
cannot reach the UI or HTTPS RPC endpoint.

Live recovery:

Validate the Nginx configuration, reload the service, and verify
`https://127.0.0.1/health` locally before testing the public endpoint. Both
SafeTF hosts returned external HTTP 200 after reload.

Worktree fix:

- Flush pending Nginx handlers immediately after installing/enabling the Safe
  site and removing the default site.
- Add an explicit self-signed-certificate-aware HTTPS ingress health check to
  the playbook's post-deployment validation.

## AD-TF-013: empty WalletConnect project ID disabled every wallet connection

Status: `FIXED-WORKTREE`

Affected paths:

- `ansible/roles/safe/defaults/main.yml`
- `ansible/roles/safe/templates/ui.env.j2`
- `ansible/roles/safe/tasks/main.yml`
- `docs/l1/SAFE.md`

Supported reproduction:

1. Run `make safe` with the repository defaults.
2. Open the published Safe UI over HTTPS.
3. Click the wallet connection control.

Observed result:

No wallet chooser or extension prompt opened. The live static UI contained
`projectId:""` in two compiled files.

Root cause:

The UI environment template deliberately left `NEXT_PUBLIC_WC_PROJECT_ID`
empty, and the separate build-time `.env.production` did not define it at all.
Safe Wallet Web v1.32.1 therefore supplied an invalid empty WalletConnect
module to web3-onboard. Initialization failed before the chooser could offer
even injected Core or MetaMask wallets.

This is the same failure previously observed on the POAS Safe test stack. Its
live workaround replaced the empty value with a 32-character placeholder,
which restored injected-wallet connections but did not provide functional
WalletConnect QR sessions.

Impact:

The Safe UI and backend services appeared healthy, but operators could not
connect a signing wallet and therefore could not create or operate a Safe.

Worktree fix:

- Compile a valid-format placeholder by default so injected browser wallets
  remain usable without an external account.
- Allow operators to override `safe_walletconnect_project_id` with a public
  Reown/WalletConnect Cloud project ID for QR/mobile connections.
- Force a UI image rebuild when the compiled bundle still contains an empty or
  stale project ID.
- Fail the build if the requested value was not compiled into the static UI.
- Document the build-time override and the difference between injected and
  WalletConnect-based connections.

## AD-TF-014: default self-signed RPC URL causes Safe creation to fail

Status: `OPEN`

Affected paths:

- `ansible/roles/safe/tasks/main.yml`
- `ansible/roles/safe/templates/ui.env.j2`
- `ansible/roles/safe/files/init-cfg-chain.py`
- `docs/l1/SAFE.md`

Supported reproduction:

1. Deploy the Safe stack with its default self-signed certificate.
2. Connect an injected wallet through the published Safe UI.
3. Configure or auto-add the SafeTF network using the advertised
   `https://<rpc-node-ip>/rpc` endpoint.
4. Review a valid funded 2-of-3 Safe creation and submit it.

Observed result:

The UI reports `Error creating the Safe Account. Please try again later.`
despite a funded creator and deployed Safe singleton and Proxy Factory.

Root cause:

The default UI bundle and Config Service records advertise the Nginx HTTPS RPC
proxy. Its certificate is self-signed when `safe_use_letsencrypt` is false.
The browser can display the UI after an operator accepts its warning, but
wallet extensions use a separate network client and silently reject the
untrusted RPC certificate.

Live-test evidence:

- Chain ID `99999` was reachable through the direct RPC.
- The connected deployer held more than 9 native tokens.
- The canonical Proxy Factory and SafeL2 singleton both had deployed bytecode.
- The direct RPC returned a valid gas price.

Current workaround:

Configure the wallet network with the direct AvalancheGo HTTP endpoint:

```text
http://<rpc-node-ip>:9650/ext/bc/<CHAIN_ID>/rpc
```

Do not use `https://<rpc-node-ip>/rpc` with the default self-signed
certificate.

Required repository fix:

The default deployment must not advertise an RPC URL that its supported wallet
clients reject. Use a trusted TLS domain for the wallet-facing endpoint, or
separate the browser-facing and wallet-facing RPC metadata and verify the
wallet endpoint during deployment. The UI should surface the underlying wallet
RPC error rather than replacing it with a generic creation failure.

## AD-TF-015: ownership-handoff documentation omits the ProxyAdmin procedure

Status: `OPEN`

Affected paths:

- `docs/l1/DEPLOYMENT.md`
- `docs/l1/SAFE.md`

Supported reproduction:

1. Initialize the official ValidatorManager and PoAManager topology.
2. Deploy a Safe.
3. Follow the documented instruction to transfer both control authorities to
   the Safe.

Observed result:

`DEPLOYMENT.md` correctly states that both ProxyAdmin ownership (upgrade
authority) and PoAManager ownership (validator-lifecycle authority) must move
to the Safe. `SAFE.md` provides an exact `cast send` and verification command
for PoAManager, but neither document provides the corresponding ProxyAdmin
transfer command, identifies the `0xdad...` predeploy in the handoff section,
or shows the final two-owner verification.

Impact:

An operator can transfer only PoAManager ownership and incorrectly conclude
that the Safe controls the complete ValidatorManager topology. The genesis
ProxyAdmin owner would retain unilateral implementation-upgrade authority.

Required documentation fix:

- Provide separate commands for the two current owners:
  `AVALANCHE_PRIVATE_KEY` for PoAManager and
  `GENESIS_PROXY_ADMIN_PRIVATE_KEY` for ProxyAdmin.
- State that `cast` requires a raw 32-byte hex private key and show how to
  convert an Avalanche `PrivateKey-...` CB58 key through Platform CLI without
  changing the underlying keypair.
- Verify each key's derived address against the current on-chain owner before
  sending.
- Transfer each contract with `transferOwnership(address)`.
- Read both `owner()` values afterward and require the intended Safe address.
- Explain that the transfers are independent and that success of one does not
  imply success of the other.

## AD-TF-016: optional console password is accepted without confirmation

Status: `OPEN`

Affected path:

- `scripts/l1/relayer.sh`

Supported reproduction:

1. Run `make relayer`.
2. Confirm the discovered installation target.
3. Enter a non-empty console password with a typo.

Observed result:

The installer reads the hidden password once and immediately passes it to
`relayer-setup`. The operator cannot detect a typo until attempting to access
the installed console.

Required fix:

- Keep Enter as the explicit choice for no console password.
- For a non-empty password, prompt for the password a second time.
- If the values differ, clear both variables, print a non-secret mismatch
  message, and repeat password entry until they match or input is cancelled.
- Never echo either value or expose it in process arguments, logs, temporary
  metadata, or Ansible output.
- Treat confirmation and any mismatch retries as one password-entry
  interaction; the application decisions remain target confirmation and the
  optional console-password choice.
- Add non-interactive shell tests for empty, matching, mismatched-then-matching,
  and interrupted input.

## AD-TF-017: doctor passed although relayerd had no Primary Network bootstrap peer

Status: `FIXED-WORKTREE`

Affected paths:

- `scripts/l1/relayer.sh`
- `ansible/playbooks/l1/discover-relayer.yml`
- Relayer's vendored `icm-services/peers` startup dependency

Supported reproduction:

1. Deploy the managed Fuji L1 and confirm `rpc[0]` sees both L1 validators.
2. Ensure those L1 validators are not current Fuji Primary Network validators.
3. Run `make relayer-doctor`; observe `PASS VM.PEERS.VISIBLE`.
4. Run `make relayer`.

Observed result:

Doctor reported no blockers. The installed daemon then exited four times and
systemd entered the failed state. Every start logged:

```text
Failed to connect to enough bootstrap nodes
targetBootstrapNodes=5 numAvailablePeers=2 connectedBootstrapNodes=0
failed to connect to any bootstrap nodes
```

The readiness endpoint never listened, so the Ansible readiness task continued
retrying even though systemd had already exhausted its restart limit.

The failure also exposed a repair deadlock: `make relayer` invoked the
operations-oriented doctor before reapplying. Once the daemon was installed
but failed readiness, doctor returned a blocker and the install command exited
before it could render corrected configuration. An unfunded but otherwise
healthy installation caused the same reapply blockage.

Root cause:

The generated Relayer configuration uses the local managed AvalancheGo node for
`info-rpc-url`. Its `info.peers` response contained exactly the two SafeTF L1
validators. The Relayer networking dependency intersects those peers with
`platform.getCurrentValidators` for the Primary Network and requires at least
one intersection member before starting network dispatch. Both SafeTF
validators were absent from the current Primary validator set, so the
intersection was empty.

Doctor checked that every managed L1 validator was visible, but did not check
the separate Primary bootstrap requirement. Installation was therefore
guaranteed to fail despite a clean doctor result.

Required fix:

- Add a read-only doctor result that intersects the selected Info API's peers
  with the current Primary validator set and blocks installation when empty.
- Generate an Info API/bootstrap configuration that can supply reachable
  Primary validator peers. A network-specific public Info API is a candidate
  for Fuji/mainnet while retaining local P-Chain and EVM RPCs, but it must be
  tested end-to-end before becoming the managed default.
- Keep the explicit private L1 validators as manually tracked peers for Warp
  requests; Primary bootstrap peers and L1 request peers are separate
  requirements.
- Fail the Ansible readiness task immediately when `relayerd.service` is in a
  terminal failed state rather than consuming every remaining HTTP retry.
- Keep standalone doctor strict for validator operations, but treat runtime,
  funding, bootstrap-configuration drift, and verified-release drift as
  repairable warnings inside `make relayer`. Key, database, topology, access,
  listener, and partial-install failures remain blockers.
- Add fixtures for visible L1 peers with zero Primary intersection and for a
  healthy mixed peer set.

Worktree fix:

- Select `https://api.avax-test.network` for Fuji and
  `https://api.avax.network` for Mainnet while retaining the local P-Chain and
  EVM RPCs.
- Query the selected Info API and the local current Primary validator set
  during discovery, persist their intersection count, and report the stable
  `VM.PEERS.BOOTSTRAP` doctor result.
- Keep every deployed private L1 validator as a separate manual peer.
- Make installation preflight enforce a non-empty bootstrap intersection.
- Stop the Ansible readiness loop immediately when systemd reports a terminal
  service failure and include recent service logs in that failure.
- Allow the install command to repair runtime/configuration/release drift and
  defer funding without weakening standalone doctor.

Live verification:

- The patched SafeTF doctor found 66 Info API peers, 88 current Fuji Primary
  validators, and 59 eligible bootstrap peers.
- The manually repaired daemon reached `ready` using the same managed Fuji
  Info API while retaining both private SafeTF validators as manual peers.
- The final managed `make relayer` reapply completed on `rpc-archive-1` with
  `failed=0`, preserved the existing installation, and reported both retained
  funding addresses.

## AD-TF-018: doctor treats the running bbolt database lock as corruption

Status: `FIXED-WORKTREE`

Affected path:

- `scripts/l1/relayer.sh`

Supported reproduction:

1. Install the Relayer and wait for `http://127.0.0.1:8081/ready`.
2. Run `make relayer-doctor`.

Observed result:

Doctor ran:

```text
relayer-restore --check-db /var/lib/relayerd/relayer.db
```

against the live database while `relayerd` held bbolt's process lock. The
restore utility returned:

```text
relayer-restore: open backup "/var/lib/relayerd/relayer.db": timeout
```

Doctor discarded that specific error and incorrectly reported
`FAIL VM.STATE.INTEGRITY`, implying database corruption and recommending a
restore.

Root cause:

`relayer-restore --check-db` validates an offline bbolt file. Read-only bbolt
opens still honor the file lock, so the command cannot inspect the daemon's
live database. The configured daemon already writes a consistent rolling
snapshot at `/var/backups/relayerd/relayer.db.bak` every five minutes using a
read transaction.

Worktree fix:

- When the daemon is ready, validate the rolling hot backup instead of the
  locked live database.
- Warn during the initial five-minute interval before the first hot backup
  exists.
- If the daemon is active but not ready, report that the lock prevents an
  independent check rather than claiming corruption.
- Validate the live database directly only when the daemon is stopped.

Live verification:

The live database check reproduced the lock timeout. The corresponding rolling
hot backup passed `relayer-restore --check-db` and reported
`database integrity verified`.

## AD-TF-019: runbook omits the Safe-backed validator-operation ceremony

Status: `OPEN`

Affected paths:

- `docs/l1/RELAYER.md`
- Relayer `console/README.md`

Supported reproduction:

1. Complete `make relayer`.
2. Follow the managed Relayer runbook to begin the first validator registration
   with a Safe-owned PoAManager.

Observed result:

The runbook ends with funding and `make relayer-access`. It lists registration,
weight change, and removal as supported, but does not provide the actual
operator sequence in the console. In particular, it does not explain that:

- the connected wallet must be a Safe owner on the managed L1;
- the console initially creates and signs a Safe proposal, not an executed L1
  transaction;
- the Safe must reach its threshold and execute the proposal in the Safe UI;
- the Relayer requires the executed L1 transaction hash, not the Safe
  transaction hash or proposal identifier;
- the operator returns to the console's Relayer step, pastes that executed
  hash, and waits through the durable cross-chain timeline; and
- registration additionally requires the validator NodeID and 144-byte BLS
  proof of possession, while removal of a validator not registered by this
  Relayer may require the original registration transaction hash.

Impact:

An operator can submit the wrong hash, expect the Relayer to execute the Safe
proposal, or conclude that the flow is stuck between the initiate and Relayer
steps.

Required documentation fix:

- Add one concise EOA/Safe operation walkthrough covering registration, weight
  change, and removal.
- Clearly distinguish proposal hash, executed L1 transaction hash, P-Chain
  transaction ID, and validation ID.
- Document required validator inputs, funding gates, expected multi-minute
  stages, restart-safe polling, error recovery, and the manual justification
  escape hatch for removals.
- Link the Avalanche Deploy operator runbook to the exact Relayer console
  runtime section rather than only its technical index.

## AD-TF-020: L1 configuration replaces Primary Network bootstrap peers and leaves the P-Chain stale

Status: `OPEN`

Affected paths:

- `ansible/playbooks/l1/configure.yml`
- `ansible/roles/avalanchego/tasks/main.yml`
- `ansible/roles/avalanchego/templates/node-config.json.j2`
- `scripts/l1/relayer.sh`

Supported reproduction:

1. Deploy Fuji nodes and wait for `P:OK`.
2. Run `make configure-l1 SUBNET_ID=... CHAIN_ID=...`.
3. Fund the managed Relayer P-Chain float address through a current Fuji
   endpoint.
4. Compare `platform.getHeight`, `platform.getTimestamp`,
   `platform.getTxStatus`, and `platform.getBalance` through the current Fuji
   endpoint and the managed `rpc[0]` endpoint.
5. Query the Relayer's loopback-only `GET /keys` endpoint.

Observed live result:

- The public Fuji endpoint reported height `289679`, timestamp
  `2026-07-24T00:45:12Z`, the funding transaction as `Committed`, and
  `200000000` nAVAX unlocked.
- Every managed node remained at height `289627` with P-Chain timestamp
  `2026-07-23T16:55:32Z`.
- `rpc[0]` reported the committed funding transaction as `Unknown` and the
  address balance as zero.
- `rpc[0]` had only the two managed L1 validators as peers.
- `/etc/avalanchego/node.json` contained global `bootstrap-ids` and
  `bootstrap-ips` values made exclusively from those L1 validators.
- Relayer `GET /keys` consequently reported
  `pchainFloatBalanceNAvax: "0"` and `fundedFloat: false`.

Root cause:

The L1 configuration playbook writes the managed L1 validators into the
node-wide `bootstrap-ids` and `bootstrap-ips` settings. This replaces the
network's normal bootstrap configuration instead of only adding the
connectivity needed for the managed L1. The resulting peer set can remain
internally connected and continue to report a previously completed bootstrap
while no longer learning current Fuji P-Chain blocks.

Impact:

- `make status` and the existing doctor checks can describe the Primary
  Network as ready even though its accepted P-Chain state is hours stale.
- The Relayer console incorrectly appears unfunded because the daemon reads
  the isolated local P-Chain RPC.
- Registration, weight, removal, and balance transactions must not be attempted
  because the Relayer cannot safely build or observe current P-Chain
  transactions.

Live recovery validation:

- Backed up each deployed `/etc/avalanchego/node.json`.
- Replaced the L1-only bootstrap set with the 21 Fuji bootstrappers embedded in
  the deployed AvalancheGo v1.14.1 release plus both managed L1 nodes.
- Restarted AvalancheGo on both validators and both RPC nodes.
- All four nodes returned HTTP 200 health, P-Chain height `289679`, EVM chain
  ID `99999`, and 64-66 connected peers.
- The Relayer recovered without a release change and reported
  `400000000` nAVAX, `fundedFloat: true`, `fundedGas: true`, and HTTP 200
  readiness.
- A post-recovery doctor run passed every blocker check. This was a live
  recovery only; the playbook remains unfixed and will recreate the problem on
  the next `configure-l1` reapply.

Required fix:

- Preserve the configured network bootstrap connectivity while adding the
  managed L1 peer/discovery configuration; do not replace the node-wide
  bootstrap set with only the L1 validators.
- Add a test proving that `configure-l1` retains Primary Network connectivity
  and still establishes the required L1 peers.
- Make doctor fail when the local P-Chain height/timestamp is materially stale
  relative to a current network reference, and report the exact peer/config
  remediation.
- Make the lightweight status output distinguish historical bootstrap success
  from current P-Chain progress.
- After correcting the configuration, restart the managed nodes, wait for
  P-Chain catch-up, and verify the committed funding transaction and
  `fundedFloat: true` through `rpc[0]` before any lifecycle operation.

## AD-TF-021: Safe-backed Relayer install omits the Safe transaction-service environment

Status: `OPEN`

Affected paths:

- `ansible/playbooks/l1/discover-relayer.yml`
- `ansible/roles/acp_relayer/templates/console.env.j2`
- `scripts/l1/relayer.sh`

Supported reproduction:

1. Deploy the managed Safe stack.
2. Confirm `safe.service` is `active (exited)` and its transaction-service
   health endpoint returns HTTP 200.
3. Install or reapply the managed Relayer.
4. Begin a Safe-backed validator operation in the Relayer console.

Observed result:

The console failed with:

```text
Invalid Safe contract at address 0x9980429B52D94d4B0F8717B8f1146F5353B8dF14:
Safe transaction service not configured (SAFE_TX_SERVICE_URL)
```

The Safe transaction service was healthy at
`http://127.0.0.1:8001/api/v1/about/`, but the rendered console environment and
running container contained no `SAFE_*` variables.

Root cause:

`safe.service` is deliberately a systemd `Type=oneshot` unit with
`RemainAfterExit=yes`. Its healthy state is `active (exited)`, while Ansible
`service_facts` reports its state as `stopped`. Relayer discovery requires
`ansible_facts.services['safe.service'].state == 'running'`, records
`safeServicesDetected: false`, and therefore omits `SAFE_TX_SERVICE_URL`,
`SAFE_UI_URL`, and `SAFE_ADDRESS`.

Live workaround:

Added the following non-secret values to
`/etc/relayerd/secrets/console.env` on `rpc[0]`:

```text
SAFE_TX_SERVICE_URL=http://127.0.0.1:8001
SAFE_UI_URL=https://127.0.0.1:3081
SAFE_ADDRESS=0x9980429B52D94d4B0F8717B8f1146F5353B8dF14
```

Only `relayer-console.service` needs a restart. AvalancheGo, `relayerd`, and
the Safe services remain running. A future `make relayer` reapply can remove
the workaround until discovery is fixed.

Required fix:

- Detect the active oneshot unit with `systemctl is-active safe.service`
  instead of requiring the `service_facts` state `running`.
- Verify the loopback Safe transaction-service health endpoint before enabling
  the integration.
- Make doctor fail when the manager owner is a Safe but the console environment
  lacks the three required Safe variables or the transaction service is
  unreachable.
- Add an Ansible fixture for an `active (exited)` Safe unit and verify that a
  rendered/running console receives the expected non-secret integration
  metadata.

## AD-TF-022: Safe UI does not display an indexed Safe owned by the connected wallet

Status: `CONFIRMED-LIVE`

Affected paths:

- `ansible/roles/safe/templates/nginx.conf.j2`
- `ansible/roles/safe/files/patch-safe-ui.sh`
- `ansible/roles/safe/tasks/main.yml`

Supported reproduction:

1. Deploy a Safe on the managed SafeTF L1.
2. Connect Safe Wallet Web with an address that is an on-chain owner.
3. Open `/welcome/accounts?chain=SafeTF`.

Observed result:

The connected owner `0x6DF540BF2A9908Be2bA712F52129d8001f5a71Da`
was shown in the header, but **My accounts** said:

```text
You don't have any Safe Accounts yet
```

The deployed gateway returned HTTP 200 for the same owner and included the
Safe:

```json
{
  "safes": [
    "0x9980429B52D94d4B0F8717B8f1146F5353B8dF14"
  ]
}
```

The Safe was therefore deployed and indexed; the empty account list was a
front-end discovery, caching, or response-integration failure.

Live workaround:

Use **Watchlist -> Add**, enter the existing Safe address, and open it while an
owner wallet is connected. The Watchlist label does not change the on-chain
owner permissions.

Required fix:

- Add a browser test that loads the accounts page with a mocked/healthy owner
  discovery response and verifies the indexed Safe appears under **My
  accounts**.
- Inspect the patched v1.32.1 UI's owner-discovery request and response mapping
  against the deployed CGW endpoint.
- Ensure a successfully indexed Safe can be opened directly or added as an
  existing Safe without requiring a previously exported browser-data file.
- Document **Watchlist -> Add** as the recovery workaround until automatic
  discovery is reliable.

## Release follow-up: replace the transfer sentinel with the tested production release

Status: `REQUIRED-BEFORE-PRODUCTION`

Affected paths:

- `Makefile`
- `scripts/l1/relayer.sh`
- `docs/l1/RELAYER.md`

Current development behavior:

Avalanche Deploy deliberately defaults to `v0.0.0-transfer-required` and the
future `ava-labs/validator-lifecycle-relayer` repository. Testing the
pre-transfer `anishnar/validator-lifecycle-relayer` RC therefore requires all
three explicit overrides:

```bash
RELAYER_DEVELOPMENT=true \
RELAYER_DEVELOPMENT_REPOSITORY=anishnar/validator-lifecycle-relayer \
make relayer-doctor RELAYER_VERSION=v0.1.0-rc.2
```

Required production change:

After the repository is transferred and both the GitHub repository and GHCR
packages are public:

- Pin the one tested production tag in both the Makefile and installer.
- Keep the default repository under `ava-labs`.
- Verify anonymous archive, checksum, and immutable image access.
- Run both doctor and installation without development variables or
  authentication:

```bash
make relayer-doctor
make relayer
```

- Keep `RELAYER_VERSION` only as an explicit advanced upgrade override.
- Do not make the personal-namespace RC or development flags part of the
  normal end-user instructions.

## Deliberately excluded incidents

The following occurred during the same session but are not entries in this
repository bug register:

- AWS Organizations SCP denials for EC2, S3, KMS, and IAM.
- Expired AWS SSO sessions.
- An invalid placeholder/truncated SSH public key in operator `tfvars`.
- Choosing local Terraform state instead of the optional S3 backend.
- Platform CLI keystore password entry and Fuji funding operations.
- Running a root Make target from a nested Terraform directory.
- eRPC returning HTTP 502 before its root cause is reproduced and isolated.

If later evidence ties an excluded symptom to repository code or documentation,
promote it into a numbered entry with a reproduction and evidence.

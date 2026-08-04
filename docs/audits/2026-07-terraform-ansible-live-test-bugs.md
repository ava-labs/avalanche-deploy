# Terraform/Ansible Fuji Live-Test Bug Register

This register records defects and documentation ambiguities found while
following the supported Avalanche Deploy Terraform/Ansible workflow on Fuji,
plus defects confirmed by review of the code behind that same workflow.
It is an implementation backlog, not an operator troubleshooting log.

Last updated: 2026-08-04

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
| AD-TF-016 | FIXED-WORKTREE | Relayer installation | Optional console password is accepted without confirmation |
| AD-TF-017 | FIXED-WORKTREE | Relayer networking | Doctor passed although no Primary bootstrap peer was available |
| AD-TF-018 | FIXED-WORKTREE | Relayer diagnostics | Doctor treated a locked live bbolt database as corrupt |
| AD-TF-019 | FIXED-WORKTREE | Relayer documentation | Runbook omits the Safe-backed validator-operation ceremony |
| AD-TF-020 | OPEN | L1 configuration | L1 configuration replaces Primary bootstrap peers and leaves the P-Chain stale |
| AD-TF-021 | FIXED-WORKTREE | Relayer Safe integration | Safe-backed Relayer install omitted the Safe transaction-service environment |
| AD-TF-022 | OPEN | Safe access | Safe UI does not display an indexed Safe owned by the connected wallet |
| AD-TF-023 | OPEN | Relayer diagnostics | Doctor and install abort on a Linux control host |
| AD-TF-024 | OPEN | Relayer diagnostics | Funding readiness passes on an unfunded P-Chain float |
| AD-TF-025 | OPEN | Validator Manager | Initialization ignores the repository network knob |
| AD-TF-026 | OPEN | Relayer installation | Relayer role installs a conflicting Docker package set |
| AD-TF-027 | OPEN | Setup | Linux prerequisites skip the Terraform repository when Terraform exists |
| AD-TF-028 | OPEN | Relayer restore | Restore cannot recover a rebuilt or partially installed host |
| AD-TF-029 | OPEN | Relayer restore | Restore can destroy the only copy of the Relayer identity |
| AD-TF-030 | OPEN | Validator Manager | Glacier signature fetch treats an unindexed transaction as terminal |
| AD-TF-031 | OPEN | Relayer backup | Fetched backups land inside the repository worktree |
| AD-TF-032 | OPEN | Relayer diagnostics | Several verification steps cannot fail |
| AD-TF-033 | OPEN | Relayer installation | Reapply installs without rollback and can drop the console password |
| AD-TF-034 | OPEN | Relayer access | Operator tunnels disable host-key verification |
| AD-TF-035 | OPEN | Validator Manager | Churn settings use the wrong bounds and are applied after the upgrade |
| AD-TF-036 | OPEN | Validator Manager | Successful initializer work is lost or reported as skipped |
| AD-TF-037 | OPEN | Validator Manager | P-Chain conversion fetch has no timeout |
| AD-TF-038 | OPEN | Relayer installation | Installation readiness wait cannot time out |
| AD-TF-039 | OPEN | Relayer runtime | relayerd and its console stay dead after a reboot |
| AD-TF-040 | OPEN | Relayer backup | Backup half-completes on an unhealthy or uninstalled host |
| AD-TF-041 | OPEN | Validator Manager | l1.env persistence fails after the irreversible initialization |
| AD-TF-042 | OPEN | Relayer installation | Release checksum marker strip is a no-op |
| AD-TF-043 | OPEN | Safe architecture | Safe Nginx and the ICM Relayer both bind port 8080 |

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

Status: `FIXED-WORKTREE`

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

Worktree fix:

- Read the console password twice and re-prompt until the two entries match.
- Keep Enter as the explicit no-password choice, and return a non-zero status
  without a stored value when input is cancelled.
- Clear both values on every exit path and pass the accepted value to
  `relayer-setup` through the environment, never argv.

Verification:

`tests/relayer-doctor-fixtures.sh` covers empty, matching,
mismatched-then-matching, and interrupted input, and asserts that no entered
value appears in the prompt output.

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

Status: `FIXED-WORKTREE`

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

Worktree fix:

- Add the Safe-backed operation ceremony and the EOA/Safe execution split to
  `docs/l1/RELAYER.md`.
- Add an identifier table separating the Safe proposal hash, the executed L1
  transaction hash, the P-Chain transaction ID, and the validation ID.
- Document the per-operation inputs, including NodeID and the 144-byte
  proof-of-possession, and the original registration receipt required to justify
  an unrelated removal.
- Document the expected multi-minute stages, restart-safe retry with the same
  executed hash, and the recovery commands.

Scope note:

The deep link into the Relayer console's runtime section still depends on the
pending repository transfer tracked by the release follow-up entry.

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

Status: `FIXED-WORKTREE`

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

Worktree fix:

- Detect the oneshot unit with `systemctl is-active safe.service` and verify the
  loopback Transaction Service before enabling the integration.
- Persist the unit state, the `service_facts` state, the Transaction Service
  status, and console-environment completeness in the discovery document.
- Report `VM.SAFE.DISCOVERY` and `VM.SAFE.CONSOLE_ENV`, blocking the standalone
  doctor when a Safe-owned console lacks the three required keys and warning
  during an install that will re-render them.

Verification:

`tests/relayer-doctor-fixtures.sh` covers an `active (exited)` Safe unit whose
`service_facts` state is `stopped`, a healthy Safe service with an incomplete
console environment in both doctor scopes, and an unhealthy Safe service.

## AD-TF-022: Safe UI does not display an indexed Safe owned by the connected wallet

Status: `OPEN`

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

## AD-TF-023: doctor and install abort on a Linux control host

Status: `OPEN`

Affected path:

- `scripts/l1/relayer.sh`

Observed behavior:

The `l1.env` age check runs `stat -f %m` first and falls back to `stat -c %Y`.
On GNU coreutils `-f` selects the file-system report, which is printed to stdout
before the command fails, so the fallback appends the real mtime to that report.
The resulting multi-line value fails the day arithmetic and `set -u` aborts
`make relayer-doctor` and `make relayer` before either can do any work.

Impact:

Every supported Linux operator machine loses both the read-only readiness check
and the installer. macOS is unaffected, and the doctor fixture suite cannot see
the failure because the fixture path short-circuits before the check.

Required fix:

- Probe the GNU format first and keep the BSD form as the fallback.
- Require a numeric mtime before computing the age, matching the other numeric
  guards in the script.
- Cover the age check with a fixture that exercises the real code path.

## AD-TF-024: funding readiness passes on an unfunded P-Chain float

Status: `OPEN`

Affected path:

- `scripts/l1/relayer.sh`

Observed behavior:

The `VM.FUNDING.READY` check greps the daemon's `/keys` payload for
`fundedFloat.*true` and `fundedGas.*true`. The Ansible `uri` module returns that
payload on a single line, so both patterns match
`"fundedFloat":false,...,"fundedGas":true`. Doctor reports that both funding
thresholds are met for a Relayer whose P-Chain float cannot pay for a
transaction.

Required fix:

- Evaluate the payload with `jq -e '.fundedFloat == true and .fundedGas == true'`
  instead of substring matching.
- Add a fixture with one funded and one unfunded address.

## AD-TF-025: validator-manager initialization ignores the repository network knob

Status: `OPEN`

Affected paths:

- `Makefile` (`initialize-validator-manager`)
- `ansible/playbooks/l1/initialize-validator-manager.yml`

Observed behavior:

`NETWORK` is the repository-wide network selector and other targets forward it as
`-e network=$(NETWORK)`. The initialization target forwards every other variable
but not `network`, so the playbook always falls back to `fuji`. On Mainnet the
accepted conversion is read from the real P-Chain and the signature aggregation
request is then sent to the Fuji route, which returns HTTP 404 and is treated as
terminal. There is no make-level override.

Required fix:

- Forward `-e "network=$(NETWORK)"` from the target.
- Cross-check the resolved network against `info.getNetworkID` before any
  aggregation request.

## AD-TF-026: Relayer role installs a conflicting Docker package set

Status: `OPEN`

Affected paths:

- `ansible/roles/acp_relayer/tasks/main.yml`
- `ansible/roles/safe/tasks/main.yml`

Observed behavior:

The Relayer role installs `docker.io` while `icm_relayer`, `graph_node`,
`blockscout`, `faucet`, and `erpc` all install `docker-ce`, `docker-ce-cli`, and
`containerd.io` on the same `rpc[0]` host. `docker-ce` declares
`Conflicts: docker.io`, so apt removes `docker-ce` and `containerd.io` to satisfy
the Relayer task and stops every container already running on that host. The Safe
role has the same defect.

Required fix:

- Install the same `docker-ce` package set and repository configuration the
  sibling roles use, or factor the shared setup into one role.
- Add a static check that no two roles targeting the same host request
  conflicting container runtimes.

## AD-TF-027: Linux prerequisites skip the Terraform repository when Terraform exists

Status: `OPEN`

Affected path:

- `scripts/shared/relayer-prereqs.sh`

Observed behavior:

The apt path configures the HashiCorp repository only when `terraform` is not
already on `PATH`, but then always runs `apt-get install -y terraform ansible`.
An operator whose Terraform comes from tfenv, asdf, or a manually installed
binary gets `Unable to locate package terraform`, and because the script runs
under `set -e`, Ansible and the Galaxy collections are never installed.

Required fix:

- Configure the HashiCorp repository whenever the apt path will request
  `terraform`, or request only the packages that are actually missing.
- Install Ansible independently of Terraform so one unavailable package cannot
  stop the rest of the bootstrap.

## AD-TF-028: restore cannot recover a rebuilt or partially installed host

Status: `OPEN`

Affected paths:

- `ansible/playbooks/l1/restore-relayer.yml`
- `ansible/playbooks/l1/discover-relayer.yml`
- `scripts/l1/relayer.sh`

Observed behavior:

Restore begins by archiving `etc/relayerd` and `var/lib/relayerd` with a bare
`tar` that has no existence guard, so the play aborts on a host where either
directory is absent and nothing later creates them. Discovery additionally
asserts that keystore, keystore password, funding, and configuration material is
either all present or all absent, and its failure message tells the operator to
run the restore that the same assert blocks.

Impact:

Both cases restore exists for fail before any restore work begins: a Terraform
rebuild or purge of `rpc[0]`, and an interrupted first install.

Required fix:

- Archive only the paths that exist and skip the rollback archive when neither
  does.
- Create `/etc/relayerd` and `/var/lib/relayerd` with their intended ownership
  and modes before the restore copies.
- Allow incomplete existing state when the run is a restore, keeping the
  L1-identity checks that prove the archive belongs to this deployment.

## AD-TF-029: restore can destroy the only copy of the Relayer identity

Status: `OPEN`

Affected path:

- `ansible/playbooks/l1/restore-relayer.yml`

Observed behavior:

The rescue path removes `/etc/relayerd` and `/var/lib/relayerd` and only then
extracts the pre-restore archive over `/`. Between those two tasks the host holds
no copy of the encrypted keystore, its password, the console session secret, or
the staker identity outside that single tarball, and a failed extraction skips
every remaining rescue task. That archive is created by a bare `tar` under the
root umask, so it is mode 0644 where the sibling backup path explicitly chmods
0600, and the extracted staging copy of the same secrets under
`/var/backups/relayerd/restore-*` is never removed. Stopping the services, the
rollback archive, the staging extract, and the completeness assert all run
outside the `block`/`rescue` pair, and the play has no `always`.

Required fix:

- Rename existing state aside, verify the extraction, then swap and delete; never
  remove the only copy first.
- Create the rollback archive with mode 0600.
- Remove the restore staging directory in an `always` section.
- Move the pre-restore tasks inside the protected block so a failure restarts the
  services it stopped and reports that the host is down.

## AD-TF-030: Glacier signature fetch treats an unindexed transaction as terminal

Status: `OPEN`

Affected paths:

- `tools/initialize-validator-manager/glacier.go`
- `tools/initialize-validator-manager/glacier_test.go`

Observed behavior:

The bounded retry loop only retries transport errors, HTTP 429, and HTTP 5xx.
Glacier answers HTTP 404 for a P-Chain transaction it has not indexed yet, and a
2xx response without a signed message is also treated as final, so running
`make initialize-validator-manager` shortly after `make create-l1` fails on the
first of thirty attempts. The repository's earlier initializer retries this case,
and the current test pins 404 as terminal.

Required fix:

- Retry HTTP 404 and a 2xx response with no signed message; keep 400, 401, and
  403 terminal.
- Add a test that succeeds after an initial 404.

## AD-TF-031: fetched backups land inside the repository worktree

Status: `OPEN`

Affected paths:

- `scripts/l1/relayer.sh`
- `.gitignore`

Observed behavior:

Backups default to `backups/relayer` inside the checkout and `.gitignore` has no
rule for that directory. The archive contains
`etc/relayerd/secrets/keystore-password` in plaintext, so one `git add -A` stages
the Relayer's signing credential. The `chmod 0600` that hardens the fetched
archive also runs only when the playbook exited zero, and the post-backup service
restart legitimately fails on an unhealthy host, leaving the archive at the
operator's default umask.

Required fix:

- Default the fetch destination outside the repository and ignore the directory
  regardless.
- Set `umask 0077` before the playbook runs, or apply the mode on both the
  success and failure paths.

## AD-TF-032: several verification steps cannot fail

Status: `OPEN`

Affected paths:

- `scripts/l1/relayer.sh`
- `ansible/playbooks/l1/discover-relayer.yml`
- `ansible/roles/safe/tasks/main.yml`
- `tests/relayer-doctor-fixtures.sh`

Observed behavior:

- `VM.LISTENERS.LOOPBACK` ends its remote `ss` pipeline with `|| true` and reads
  empty output as loopback-only, so it passes on a host without `iproute2` while
  the daemon and console are bound to every interface.
- Discovery reports `ownerType: eoa` for every result other than a non-empty
  `eth_getCode`, including a JSON-RPC error and a renounced or zero owner, and
  doctor then passes the manager-ownership check for an L1 with no authority.
- The Safe wallet-connector guards grep for the bare project ID, whose default is
  thirty-two zeros, so any long zero run in the bundle satisfies them.
- Most doctor fixture cases inject a pre-rendered result line that short-circuits
  the real doctor, so names such as `unfunded` and `ssh-denial` assert nothing
  about the checks they describe.

Required fix:

- Emit and require an explicit sentinel from the listener probe.
- Distinguish a failed ownership query from an EOA owner and reject a zero owner.
- Anchor the connector guard to the rendered assignment and use a non-degenerate
  placeholder.
- Exercise the real check functions against discovery fixtures instead of
  replaying their output.

## AD-TF-033: reapply installs without rollback and can drop the console password

Status: `OPEN`

Affected paths:

- `scripts/l1/relayer.sh`
- `ansible/roles/acp_relayer/tasks/main.yml`

Observed behavior:

`make relayer` always passes `operation=install`, but every rollback affordance in
the role is gated on `upgrade`: the pre-change copies of the runtime material and
the whole rescue path are skipped. A reapply over an existing installation can
therefore replace the daemon binary and overwrite `config.json` with no backup and
no rollback. The reapply password prompt has the same shape problem: pressing
Enter means "no console password", so the role deletes `console-password-hash` and
drops the hash from `console.env`, silently leaving the validator-lifecycle
console unauthenticated.

Required fix:

- Take the pre-change copies and enable the rescue path for a reapply over an
  existing installation, not only for an explicit upgrade.
- On a reapply, treat empty input as keeping the current console password and
  require an explicit choice to remove it.

## AD-TF-034: operator tunnels disable host-key verification

Status: `OPEN`

Affected path:

- `scripts/l1/relayer.sh`

Observed behavior:

The console/RPC/Safe tunnel and `relayer-logs` both pass
`-o StrictHostKeyChecking=no`, which silently accepts a changed host key rather
than only an unknown one. Those forwarded ports carry the validator-lifecycle
console, the L1 RPC, and the Safe UI, and a stale inventory after a cloud IP
reassignment is the realistic case.

Required fix:

- Use `-o StrictHostKeyChecking=accept-new` and let a changed key fail.
- State the expected remediation when the recorded key no longer matches.

## AD-TF-035: churn settings use the wrong bounds and are applied after the upgrade

Status: `OPEN`

Affected path:

- `tools/initialize-validator-manager/main.go`

Observed behavior:

The maximum churn percentage is accepted up to 100 and the churn period is
unbounded, while the contract rejects zero and anything above its churn
percentage limit of 20. Settings are initialized after the proxy upgrade, so an
out-of-range value reverts with the proxy already upgraded and the implementation
uninitialized.

Required fix:

- Validate both settings against the contract limits before sending any
  transaction.
- State in the failure that the proxy upgrade already succeeded and how to
  resume.

## AD-TF-036: successful initializer work is lost or reported as skipped

Status: `OPEN`

Affected path:

- `tools/initialize-validator-manager/main.go`

Observed behavior:

On any failure after the first step the partially populated result is discarded
and a fresh unsuccessful document is emitted, so the addresses just deployed never
reach the operator and the `--validator-messages-library` and
`--validator-manager-implementation` resume flags have no input. The
human-readable fallback prints are suppressed because the playbook always passes
`--json`. Separately, the `cast send` helper discards its JSON decode error and
returns an empty hash, so any Foundry warning on the stream makes the playbook
summary report a skipped settings transaction for a run that sent it.

Required fix:

- Emit the partial result with every address discovered so far on failure.
- Return the decode error and extract the JSON object from warning-prefixed
  `cast` output, as the deployment path already does.

## AD-TF-037: P-Chain conversion fetch has no timeout

Status: `OPEN`

Affected paths:

- `tools/initialize-validator-manager/conversion.go`
- `tools/initialize-validator-manager/main.go`
- `ansible/playbooks/l1/initialize-validator-manager.yml`

Observed behavior:

The conversion lookup uses avalanchego's P-Chain client on the default HTTP
client, which has no timeout, and is called with a bare background context. A
bootstrapping node that completes the TCP handshake but never answers blocks the
tool indefinitely, and the wrapping Ansible task sets no timeout either. Every
other HTTP path in the tool bounds itself.

Required fix:

- Bound the conversion lookup with a context deadline and a client timeout.
- Give the Ansible task a timeout and report which endpoint stalled.

## AD-TF-038: installation readiness wait cannot time out

Status: `OPEN`

Affected path:

- `ansible/roles/acp_relayer/tasks/main.yml`

Observed behavior:

The readiness probe curls the daemon without `--max-time`, and the terminal
failure escape checks `systemctl is-failed`, which is false for a daemon that is
running but hung. A daemon that accepts the connection and never answers blocks
`make relayer` instead of consuming a retry and reaching the intended failure.

Required fix:

- Give the probe an explicit `--max-time` shorter than the retry delay.
- Treat a running but unresponsive daemon as a consumed retry and fail with
  recent service logs once the retries are exhausted.

## AD-TF-039: relayerd and its console stay dead after a reboot

Status: `OPEN`

Affected paths:

- `ansible/roles/acp_relayer/templates/relayerd.service.j2`
- `ansible/roles/acp_relayer/templates/relayer-console.service.j2`
- `ansible/roles/acp_relayer/tasks/main.yml`

Observed behavior:

`StartLimitBurst=5` with `RestartSec=5s` tolerates about twenty-five seconds of
restarts, far less than an AvalancheGo bootstrap after a reboot. Systemd parks
`relayerd` in the failed state, and because `relayer-console` declares
`Requires=relayerd.service` the console is stopped as a dependency. A dependency
stop is not a failure, so the console's own `Restart=on-failure` never fires and
both units stay down until an operator intervenes.

Required fix:

- Disable the start-rate limit and restart the daemon unconditionally, matching
  the AvalancheGo unit.
- Make the console want, not require, the daemon.
- Reset the failed state before the reapply drain.

## AD-TF-040: backup half-completes on an unhealthy or uninstalled host

Status: `OPEN`

Affected path:

- `ansible/playbooks/l1/manage-relayer.yml`

Observed behavior:

The backup `always` section restarts the daemon, then the console, then reports
the archive path. Ansible skips the rest of an `always` section after a failure
inside it, so the common case of backing up a crash-looping host leaves the
console stopped and never prints the archive it just created. Backup also has no
installed-guard, so `make relayer-backup` or `make relayer-upgrade` against a
never-installed or purged host fails with a raw ownership error.

Required fix:

- Make each restart and the path report independently non-fatal so the section
  always completes.
- Assert that the workload is installed before starting a backup and name the
  install command in the failure.

## AD-TF-041: l1.env persistence fails after the irreversible initialization

Status: `OPEN`

Affected path:

- `ansible/playbooks/l1/initialize-validator-manager.yml`

Observed behavior:

The two tasks that record the manager addresses in `l1.env` use `lineinfile` with
`create: false`, which fails when the destination does not exist. They run after
the on-chain initialization, so an L1 created outside this repository, for example
with avalanche-cli, gets a failed play for a fully successful and unrepeatable
deployment.

Required fix:

- Create the file when it is absent, or skip persistence and print the values to
  record.
- Keep the on-chain result reported as successful independently of local
  bookkeeping.

## AD-TF-042: release checksum marker strip is a no-op

Status: `OPEN`

Affected path:

- `scripts/l1/relayer.sh`

Observed behavior:

The awk that reads `checksums.txt` strips the binary-mode marker with
`sub(/^\\*/, "", file)`. In an extended regular expression that pattern means zero
or more literal backslashes, matches the empty string, and removes nothing, so a
binary-mode checksum file yields an empty expected hash and every install or
upgrade stops at the missing-entry error. The published release asset does not
exist yet, so the failure is latent.

Required fix:

- Strip the marker with `sub(/^\*/, "", file)`.
- Add a fixture for both text-mode and binary-mode checksum files.

## AD-TF-043: Safe Nginx and the ICM Relayer both bind port 8080

Status: `OPEN`

Affected paths:

- `ansible/roles/safe/defaults/main.yml`
- `ansible/roles/icm_relayer/defaults/main.yml`
- `tests/relayer-static.sh`

Observed behavior:

`safe_http_port` and `icm_relayer_api_port` both default to 8080 on `rpc[0]`, and
the ICM Relayer container runs with host networking. Running `make icm-relayer`
and then `make safe` leaves Nginx logging `bind() ... Address already in use`
while the play still reports success. Moving the Relayer daemon API off 8080
avoided a third listener but did not remove the existing collision.

Required fix:

- Give the two components distinct default host ports on a shared host.
- Extend the static port check to fail on any duplicate host port across roles
  that target the same group.

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

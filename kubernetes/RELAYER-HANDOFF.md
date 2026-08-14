# Kubernetes Relayer — status and handoff

This branch adds the validator-lifecycle Relayer to the Kubernetes deployment path. It is
**stacked on `feat/terraform-relayer-service` (PR #24)**, which is the finished Terraform/Ansible
implementation and the authoritative spec for everything here. Nothing under `scripts/l1/`,
`ansible/`, `terraform/`, `tools/` or `docs/l1/` is modified by this branch.

Read this file before picking the work up. It records what is verified, what is written but
unproven, and what is deliberately out of scope.

## What this branch contains

| Area | Files |
|---|---|
| Helm chart | `kubernetes/helm/relayerd/` — StatefulSet, ConfigMap, RBAC, NetworkPolicy, ServiceAccount, helpers, `values.yaml`, `values-kind.yaml`, `values-example.yaml` |
| Lifecycle driver | `kubernetes/scripts/relayer.sh` — ten verbs, 28 `K8S.*` doctor checks |
| Operator commands | ten `k8s-relayer-*` targets in `Makefile`, plus `k8s-help`, `k8s-help-l1` and `help-all` entries |
| Prerequisites | `scripts/shared/relayer-prereqs.sh` gains a `k8s` mode (kubectl + Helm); every VM branch is preserved verbatim under a mode guard |
| Tests | `tests/relayer-k8s-doctor-fixtures.sh`, `tests/relayer-k8s-discovery-smoke.sh`, `tests/relayer-k8s-restore-smoke.sh`, plus the Kubernetes half of `tests/relayer-static.sh` |
| CI | `.github/workflows/relayer-k8s.yml`; `incremental.yml` gains a pinned Helm install because `relayer-static.sh` now renders the chart |
| Also | three `kubernetes/helm/avalanche-rpc` correctness fixes carried over: a network-validation `fail` guard, a ReadWriteOnce-vs-replicas `fail` guard with `strategy: Recreate`, and `l1_rpc_replicas` 2 → 1 for persistent mode |

`make k8s-relayer-prereqs | doctor | (install) | access | status | logs | backup |
restore BACKUP=… | upgrade RELAYER_VERSION=… | remove [PURGE=true]` mirrors the VM contract
one-for-one.

## Verified

Everything below was proven by a command on this tree, not argued:

- **Release contract** is a faithful port of `scripts/l1/relayer/prerequisites.sh` —
  `OFFICIAL_RELAYER_REPOSITORY` (`ava-labs/avalanche-vmc-relayer`), `official_latest_release_tag`,
  `resolve_release_version`, `validate_release_source`, the `RELAYER_DEVELOPMENT` /
  `RELAYER_DEVELOPMENT_TOKEN` override rules, and every `die()` text. Both release bases derive from
  `$RELAYER_REPOSITORY`.
- **Daemon API is on loopback 8081**, matching the VM path, propagated through `.Values.ports.api`.
  The Safe UI Service reference stays on 8080 — it is a different service, do not "fix" it.
- **PoAManager owner classification** handles all four cases: a zero-address (renounced) owner dies,
  an `eth_getCode` JSON-RPC error dies, a missing result dies, a Safe with threshold > 0 classifies
  as Safe, a plain EOA stays EOA.
- **Doctor is scope-aware** (`install` | `operations`) mirroring `doctor_vm`, so `make k8s-relayer`
  can reapply over an unready, drifted or underfunded install instead of refusing with a remediation
  that tells you to reapply.
- **Restore rolls back on every failure path**, stage cleanup is unconditional via the trap, and the
  post-restore gate consults only conditions that mean *this restore* failed — not external health.
- Chart lints and renders; a bare render still fails closed on required values, deliberately.
- `shellcheck -x -S warning` and `bash -n` clean; all four suites pass; all ten `make -n` targets
  pass; both VM harnesses still pass and `tests/relayer-doctor-fixtures.sh` is byte-identical to the
  base commit.

## Not supported on this path

**Protocol-private L1s.** The permanent-identity staging and `allowedNodes` authorization that PR #24
added for the VM path (`relayer-prepare`, `relayer-authorize`, `VM.PROTOCOL.PRIVACY`) are roughly
3,400 lines built on Ansible facts and SSH config rewrites. The Kubernetes equivalent is a different
mechanism — patching `avalanche-validator` ConfigMaps and orchestrating rolling restarts — and is not
implemented here.

The path **fails closed with a truthful message** rather than pretending: `discover_validator_peers`
detects `validatorOnly` best-effort and directs the operator to `make relayer` on the
Terraform/Ansible path. It does not silently misreport it as a peering delay. This is accuracy only;
no protocol-private support exists.

## Open before merge

1. **Confirm `wget` exists in `ghcr.io/ava-labs/relayerd`.** The relayerd container's probes exec
   `wget` against loopback `:8081`. `httpGet` is not an option — the daemon binds `127.0.0.1` and
   kubelet dials `httpGet` from the node, not the pod netns. The evidence for a busybox userland is
   that the merged doctor already execs `sh -ec … sha256sum … ls -t … head … cut` in that same
   container, so a POSIX shell plus busybox/coreutils is already load-bearing — and busybox ships
   `wget`. But if the image is coreutils-only the probe fails permanently and the pod never becomes
   Ready. Somebody with the image must check. One-line fix if wrong: swap to `curl -fsS`.
2. **The doctor cannot run while the release repository is private and no token is set.** `main()`
   resolves `official-latest` before dispatch, and `resolve_release_version` dies when the releases
   query fails. This is inherited from the VM path (`scripts/l1/relayer.sh`), not k8s drift, so it is
   PR #24's accepted contract — but on this path it also gates the restore decision. Export
   `RELAYER_DEVELOPMENT=true RELAYER_DEVELOPMENT_TOKEN=…` (and `RELAYER_DEVELOPMENT_REPOSITORY` for
   the mirror) until the repository is public.

## One verification pass was cut for time

The review that produced the fixes above worked by mutation: revert a fix in a throwaway copy of the
tree, then check whether the suite catches it. That method found the three vacuous assertions and the
unwired fixture suite, and it is the only thing that establishes the tests can actually see these
fixes.

A final replay of all 21 mutations against the fixed tree **was not run.** Every suite is green and
the three known-vacuous assertions were rewritten to iterate RBAC rules against an exact whitelist
and to pin the chmod target rather than the surrounding words — but "green" here has not been
re-earned by the same adversarial standard the earlier round was held to.

If you pick this up, run that pass first; it is cheap relative to live testing and it tells you
whether the rest of the suite is worth trusting. The mutations to replay: a second unrestricted
`configmaps` RBAC rule; a second `pods` rule granting `watch`; retargeting both archive chmods to the
directory; deleting the fixture suite; hollowing out `K8S.PEERS.BOOTSTRAP`, `K8S.SAFE.CONSOLE_ENV`,
`K8S.BACKUPS.INTEGRITY` and `K8S.STATE.INTEGRITY` to always pass; flipping a `WARN` to `PASS` with
the message unchanged; moving a probe between containers; removing the
`RELAYER_PRERELEASE_FALLBACK` forwarding; reverting the `--slurpfile` fix to `--argjson`; removing the
pre-restore reapply from the bbolt failure path; and removing the doctor scope parameter.

## Never validated against a cluster

There is no live Kubernetes validation behind any of this. Every claim above rests on static
analysis, chart rendering, and driving real functions with stubbed `kubectl`/`helm`/`curl`. Not
observed in a real kubelet or against a real L1:

- that a daemon-only liveness failure restarts the relayerd container and leaves the console alive
- the install, upgrade, backup, restore and remove verbs end to end
- the busybox pod bodies (`tar`, `rm -rf`, `relayer-restore --check-db`)
- funding, RPC health, peer visibility and manager topology against a real bootstrapped node
- anything Safe-owned, against a real Safe

PR #24's own release gates require live Fuji EOA **and** Safe validation of the full lifecycle. None
of that has been done for Kubernetes. **Do not present this path as production ready.**

## Picking the work up

Suggested order:

1. **Live-validate on kind, then a real cluster.** Start with item 1 above (the `wget` question),
   since a wrong answer there blocks every other test. `values-example.yaml` renders the chart
   standalone for review; the installer generates the real values.
2. **Run the lifecycle against a Fuji L1 with an EOA owner**, then against a Safe-owned L1. Work
   through the same defect classes PR #24's live testing surfaced — its findings are the best
   available map of what breaks.
3. **Decide on protocol-private.** Either implement the Kubernetes mechanism (~1.5–2 weeks) or keep
   the fail-closed refusal and document the boundary as permanent. The refusal is honest today; the
   only thing wrong with it is that it is a boundary rather than a feature.

Doctor coverage gaps against the VM path, if you want parity: no `K8S` analogue of
`VM.PROTOCOL.PRIVACY`, `VM.L1_ENV.AGE`, `VM.LISTENERS.LOOPBACK` or `VM.TARGET.ARCHITECTURE`. Two
checks measure a weaker property than their VM counterpart under a same-shaped ID —
`K8S.CONFIG.BOOTSTRAP` compares against the in-cluster RPC Service rather than the public managed
Info API, and `K8S.PEERS.BOOTSTRAP` computes bootstrap eligibility through the partial-sync L1 RPC
node rather than a full Primary Network node. Both are noted in the code.

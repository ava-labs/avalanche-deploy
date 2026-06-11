# Hardening Audit — 2026-06-10

Full-repo review (5 parallel deep audits: ansible, terraform, Go tools, kubernetes/helm, DX/docs)
plus a same-day live deployment exercise (Fuji L1 + Safe stack, PR #17) that surfaced four real
bugs while CI was green. Load-bearing claims below were independently spot-verified against source.

**Verdict:** the repo is a competent first-generation stack with real care in places (the safe
role, `make help-*`/`doctor`, clean ansible-lint production profile, CI + pre-commit). It is not
yet remediation-grade: **the three tools an operator reaches for in a crisis — key backup, reset,
restore — are exactly the broken ones**, and every post-conversion path in the Go tools is broken.
CI certifies that the repo parses, not that it deploys.

---

## P0 — fix before calling this a source of truth

| # | Area | Finding | Impact |
|---|------|---------|--------|
| 1 | ansible | **L1 staking-key backups are empty.** Node config sets `db-dir` but not `data-dir`/staking paths, so keys live in `/home/avalanche/.avalanchego/staking`; `deploy-nodes.yml:108` tars the empty `/var/lib/avalanchego/staking` and reports success. (Verified live.) | Silent key loss on instance failure |
| 2 | ansible | `reset.yml` operates entirely on `/opt/avalanche/*` — a path that doesn't exist. Wipes nothing, restarts, prints success. | Remediation tool is a no-op |
| 3 | ansible | `restore-snapshot.yml` / `prepare-migration.yml` / `create-snapshot.yml` use `hosts: all` with destructive bodies (stop avalanchego, delete DB). Forgetting `--limit` hits every node incl. active validators. | Fleet-wide outage from one typo |
| 4 | ansible | `migrate-validator.yml` never disables/de-keys the source node after migration; reboot/auto-recovery resurrects a duplicate NodeID against the live validator. | Uptime/rewards damage |
| 5 | ansible | `blockscout`/`graph_node` passwords use lazy `lookup('password','/dev/null')` — regenerated per reference and per run; creds drift from the persisted postgres volume on every re-run. | Re-runs break running stacks |
| 6 | go-tools | **Every post-conversion path is broken** (6 implementations, 6 bug sets): dead Glacier GET endpoint, local sig-agg stub, `CalculateConversionID` always errors (`ids.ToID` copies, doesn't hash), hand-rolled warp message missing codec/typeID/length prefixes, invalid `cast --access-list` format (and predicate truncated to 32 bytes via `BytesToHash`), hardcoded weight 1000 vs actual Schmeckle weights. The one correct implementation (`init_validator_set.go`) is dead code with zero callers. | `initializeValidatorSet` cannot succeed via any tool path |
| 7 | terraform | No remote state backend — local `terraform.tfstate` only. (Bit us same-day: stale state from a March-destroyed deployment.) | State loss/drift, no locking, no team use |
| 8 | terraform | Port 4443 (Blockscout HTTPS) was added to the SG by hand in the console and never landed in code; any re-apply removes it. | Silent breakage on apply; console drift |
| 9 | k8s | Node charts never set `--http-allowed-hosts`; avalanchego rejects in-cluster clients using service DNS. Invisible under port-forward testing. Every add-on chart affected. | K8s add-ons can't talk to nodes |
| 10 | k8s | Blockscout frontend bakes internal cluster DNS into browser-resolved `NEXT_PUBLIC_*` vars — explorer broken for external users despite ingress. | Aspirational, not usable |
| 11 | k8s | `init-validator-manager.sh` feeds unreachable pod IPs to the Go tool; error handling is dead code under `set -e`. | Step cannot succeed on K8s |
| 12 | dx | `make primary-status` reads the L1 inventory (`aws_hosts`) instead of `aws_primary_hosts`; primary-network quickstart dead-ends at step 3 with a misleading error. | First-run failure on primary path |
| 13 | dx | `platform-cli` required at the key-import step of the L1 guide; no install instructions exist anywhere in the repo. | Hard onboarding dead end |

## P1 highlights (full lists in per-area sections)

- **ansible:** stop→tar→start sequences have no `block/always` (failed tar leaves validator down);
  avalanchego binary re-downloaded every run, unchecksummed, with no restart notify (running
  process diverges from disk); fstab by raw NVMe device name without `nofail`; env/compose
  template changes never `notify` restarts in faucet/graph_node/erpc/icm_relayer; final readiness
  checks `ignore_errors: true` (deploys exit green with dead services); `:latest` images +
  `compose pull` on re-run (silent major upgrades); Grafana admin/admin on 0.0.0.0; Glacier API
  key on the command line; restore-snapshot checksum verification silently degrades to unverified.
- **terraform:** GCP monitoring functionally broken (firewall + missing `private_ip` hostvars);
  gcp/azure a generation behind aws (no Safe ports, no key backup, no `owner_tag`, no
  archive/pruned split — `CLOUD=gcp|azure` overpromises); S3 bucket name collision for any second
  account; `enable_public_{grafana,blockscout,safe}` default to 0.0.0.0/0; GCP nodes get
  near-Editor `cloud-platform` scope; `operator_ip` auto-detect unvalidated.
- **go-tools:** private keys on `forge`/`cast` argv (visible in `ps`); `--json` mode pollutes
  stdout with progress (breaks `| jq`) and exits 0 on partial failure with no status field;
  no resume after partial failure (orphaned subnets cost real AVAX); `castSend` ignores parse
  errors and never checks receipt status; no contexts/timeouts/signal handling (Ctrl-C leaks the
  sig-agg child process).
- **k8s:** `randAlphaNum` secret fallbacks regenerate on every `helm upgrade` (postgres auth
  breakage); Safe combo (CGW v1.102/TXS v5.42.1, tag-pinned) diverges from ansible's
  digest-pinned validated set; monitoring chart deps not vendored (`helm template` fails as
  checked in); no startupProbe on validators (crash-loop risk on long DB replay).
- **dx:** `ICM_SERVICES_PATH` (create-l1) vs `ICM_CONTRACTS_PATH` (IVM + all docs) — same concept,
  two names; SAFE.md's `make safe -e "..."` examples silently do nothing (make eats `-e`);
  TROUBLESHOOTING.md recommends `durangoTimestamp: 0` — exactly the genesis bug previously
  debugged (0 = "use primary network default", never what you want stated this way); broken
  doc links; `GENESIS.md` referenced but doesn't exist; full e2e contains bugs that guarantee
  failure (L1 e2e invokes a primary-only target), so it hasn't run green recently.

## Cross-cutting themes

1. **Success theater.** `ignore_errors`/`failed_when: false` on the checks that matter, empty
   backups reporting success, dead error-handling blocks, green CI over broken behavior. The
   repo's default failure mode is *looking* fine.
2. **The safe role is the gold standard; nothing else follows it.** Secret persistence to
   dotfiles, digest pinning, systemd down/up handlers (avoiding the `compose restart` env trap)
   — all solved there, all unreplicated in blockscout/graph_node/faucet/erpc/grafana.
3. **Knowledge exists but didn't land.** The warp gotchas (predicate packing, DynamicFeeTx,
   justification, NodeID sort) are documented in memory/notes and even in dead code, while all
   executed paths have them wrong. TROUBLESHOOTING contradicts hard-won genesis lessons.
4. **Two-headed truth.** ansible vs helm diverge on versions, behavior, and capability; aws vs
   gcp/azure diverge on everything. Each fork ages independently.
5. **CI green ≠ deploys.** Lint/syntax/build only. Four real bugs shipped under green CI today;
   the only behavioral test (full e2e) is broken and manual.

## Recommended plan

**Wave 1 — stop the bleeding (≈1 day, do immediately):**
P0 #1 (backup path + assert archive contains `staker.key`), #2 (reset.yml real paths), #3
(`hosts: all` → required `target_host`), #5 (persist secrets via safe-role pattern), #8 (4443 SG
rule), #12 (primary-status inventory), and the doc one-liners (#13 install snippet,
ICM_* env unification, durangoTimestamp correction, SAFE.md `-e` examples, dead links).

**Wave 2 — make the dangerous paths safe (≈2-3 days):**
P0 #4 (migration end-state: disable unit, rename keys, assert source down), block/always around
every stop-work-start, binary checksums + notify, readiness checks that fail, image pinning
sweep, Grafana credentials, key-material umask/cleanup, remote state backends (S3/GCS/azurerm)
+ `terraform plan` drift check in CI.

**Wave 3 — Go tools rebuild of the post-conversion path (≈2 days):**
One shared warp package (promote the dead-but-correct code), Glacier POST + local sig-agg both
implemented (selection must respect genesis `requirePrimaryNetworkSigners`), real
validators/weights from the conversion tx, native libevm tx-sending (kills argv key exposure and
cast access-list bugs together), resume flags, status fields in JSON output, unit tests against
known-good vectors from a successful deployment.

**Wave 4 — converge the forks (≈3-4 days, can trail):**
helm/ansible parity (one blessed digest-pinned Safe combo, `http-allowed-hosts`, blockscout
external URLs, secret-regeneration fixes), then either bring gcp/azure to parity or explicitly
mark them experimental in README/Makefile (recommend: mark experimental now, parity later).

**Wave 5 — make CI mean something (≈2 days):**
Fix the e2e scripts' own bugs, then add a scheduled (weekly) real-Fuji e2e: deploy 1 validator +
RPC → create L1 → initialize validator manager → deploy Safe + blockscout → execute a Safe tx →
assert single transfer row → destroy. Cost ≈ a few dollars/run; it would have caught all four of
today's bugs plus the empty-backup P0. Add `gofmt`/`go vet` gates and helm-template-with-defaults
to incremental CI.

## Per-area maturity (agents' verdicts)

| Area | Verdict |
|------|---------|
| ansible | Happy path works; remediation/recovery paths broken exactly where needed in a crisis |
| terraform | l1/aws ~80% production-shaped; multi-cloud claim ~40%; local state is systemic risk |
| go tools | Wallet-SDK happy path solid; everything post-conversion demo-grade/broken |
| k8s | safe chart battle-tested (ahead of ansible); nodes ~80% with 2 showstoppers; blockscout/monitoring aspirational |
| dx/docs | ~85%; strong skeleton, dead ends concentrated at new-user critical steps |

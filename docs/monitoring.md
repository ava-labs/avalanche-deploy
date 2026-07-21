# Monitoring & availability

Running a remote signer puts a **second process on your validator's signing
path**. A stock validator has one thing to watch (the node); with a remote
signer you have two, and a new silent failure mode: the node stays up and
looks healthy while the signer is down, unreachable, or producing signatures
the network rejects — so the validator quietly stops contributing signatures.

On mainnet that means missed uptime (and lost staking rewards), and for
L1/subnet validators, broken ICM. `systemctl is-active avalanchego` will say
everything is fine through all of it. This page is what to watch instead.

> The signer is deliberately a **thin gRPC service that implements
> avalanchego's own [`signer.proto`](../spec/signer/)** — it has no dedicated
> health RPC. Liveness and correctness are observed the same way you already
> observe the node: process state, a cheap gRPC probe, and the node's own
> health endpoint.

---

## The one failure mode that matters most

**The node is up but not signing.** This is the case basic monitoring misses,
because the node process is alive and its API answers. It happens when:

- the signer process is down or its port is closed → the node cannot sign at
  all (peer handshakes and warp/ICM signatures fail);
- the signer is up but returns signatures the network rejects — classically a
  **domain-separation-tag mismatch**, where proofs of possession and validator
  registration still work but *every* warp/ICM signature is silently rejected
  (see [architecture.md](architecture.md#domain-separation-tags)). The signer
  logs nothing; only the network says no.

Alert on **signing health**, not just process liveness.

---

## What to watch (layered, cheapest first)

### 1. Signer process liveness

The example systemd units use `Restart=always` (see
[aws-nitro.md](aws-nitro.md#systemd-units) and the per-backend guides), so a
**crash self-heals**. Note the unit name differs by guide: the Nitro guide
uses `remote-signer.service`; the cloud-KMS/Vault guides use
`avalanche-remote-signer.service` — adjust the checks below to yours.
What that does **not** cover is a deliberate `systemctl stop` that is never
undone — systemd treats a clean stop as intentional and leaves it down. Watch
for that:

```bash
systemctl is-active remote-signer   # expect: active
```

### 2. Signer reachability + key correctness (gRPC probe)

The cheapest signer-specific check is to call `PublicKey` over gRPC and confirm
it returns the key your validator is registered with on the P-Chain. This
proves the signer is reachable **and** serving the right identity — it would
have caught a signer accidentally started against the wrong key blob:

```bash
# grpcurl example — PublicKey takes no arguments and has no side effects.
# The server does not expose gRPC reflection, so point grpcurl at the proto
# (copy spec/signer/signer.proto to the box, or run from a repo checkout):
grpcurl -import-path spec/signer -proto signer.proto \
  -plaintext -d '{}' 127.0.0.1:50051 signer.Signer/PublicKey \
  | jq -r '.publicKey'          # base64; compare against your known key
```

If you don't want a gRPC client on the box, a plain TCP check that the port is
open (`nc -z 127.0.0.1 50051`) is a weaker fallback — it catches "signer down"
but not "signer serving the wrong key."

### 3. Node-level signing health (the real signal)

AvalancheGo's health endpoint is the authoritative "is this validator actually
working" check — its `bls`, `validation`, and `network` sub-checks reflect the
signing path end to end:

```bash
curl -sf -m 10 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"health.health"}' \
  http://127.0.0.1:9650/ext/health | jq '.result.healthy'   # expect: true
```

For the silent DST-rejection case specifically, watch the aggregator/relayer
side of your deployment for `invalid signature response` or "failed to collect
a threshold of signatures" — those are what a wrong-DST signer looks like from
the network, since the signer and node themselves report success.

---

## Alerting

Wire the checks above into whatever alerting you already run for validators
(CloudWatch alarm, Prometheus + Alertmanager, PagerDuty, a Slack webhook —
this repo is unopinionated). The minimum that would catch the common failures:

- `health.health != true` for more than a few consecutive checks → page.
- `remote-signer` not `active` → page.

**Where the check runs matters.** A cron or agent *on the validator host* dies
with the host — it cannot tell you the instance itself went down. Treat an
on-host check as the fast inner loop and pair it with an **external** probe
(an uptime pinger, or a metric pushed to CloudWatch/Prometheus and alarmed
off-box) so a dead host still pages you. The on-host check alone is enough to
catch "signer stopped, node still up"; it is *not* enough to catch "host gone."

---

## systemd hardening

The example units already do the right things — reproduced here as the
availability checklist:

- **`Restart=always` + `RestartSec`** on every unit → crashes self-heal.
- **`enable`d** → a reboot brings the whole chain back in order
  (vsock-proxy → signer → node).
- **`Wants=remote-signer.service`** on the node unit (soft dependency, not
  `Requires=`), as shown in the Nitro guide — apply the same to your
  avalanchego unit whichever backend you run: the node starts the signer if it
  isn't up, but a signer *restart* does not bounce the node — avalanchego's
  gRPC client reconnects on its own. Using `Requires=` instead would
  needlessly restart the node every time the signer cycles.

A deliberate `systemctl stop` is the one thing systemd will not auto-recover;
that is what monitoring (section 1) is for.

---

## Availability characteristics by backend

The backend changes what a signing request depends on at runtime:

| Backend | Runtime dependency for each signature | Notes |
|---|---|---|
| `aws-kms`, `gcp-kms`, `azure-kv` | **None** beyond the signer process | KMS is called **once at startup** to decrypt the blob; signing is local thereafter, so a cloud-KMS outage does not stop a *running* signer (only a restart during the outage). |
| `vault` | **Vault must be reachable for every signature** | Signing happens inside the Vault plugin; Vault availability is directly on the signing path. Also watch token expiry — the signer renews/re-logs in automatically (see [`api/vault`](../api/vault/)), but a misconfigured non-renewable token will lapse. |
| `aws-nitro` | The enclave (local, on the same host) | The signer reconnects to an already-running enclave across restarts; the enclave holds the key for its lifetime. vsock-proxy must be up for the enclave's *startup* KMS decrypt, not for steady-state signing. |

---

## Related

- [architecture.md](architecture.md) — key lifecycle, the DST failure mode, availability coupling.
- [aws-nitro.md](aws-nitro.md#systemd-units) — the production systemd units.
- [e2e.md](e2e.md) — the end-to-end suite that verifies signing against a live node (the same signals, exercised in a test harness).

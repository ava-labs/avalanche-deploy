# Operations & Maintenance Guide

Day-2 operations for your Avalanche infrastructure.

For deployment guides, see [L1 Deployment](l1/DEPLOYMENT.md) or [Primary Network](primary-network/DEPLOYMENT.md).
For command-focused CLI help, use `make help-l1`, `make help-primary`, `make k8s-help`, or `make help-all`.

## Health Checks

```bash
# Comprehensive health checks on all nodes
make health-checks

# Include L1 chain status
make health-checks CHAIN_ID=$CHAIN_ID
```

The check prints a full per-node report, then **exits nonzero** if any node
is broken: service not running, API unreachable, or `/ext/health` failing on
a node that has finished bootstrapping. Nodes that are still bootstrapping
(service up, API responding) are reported as syncing but do not fail the run,
so this is safe to use in CI/cron.

## Rolling Restart

Restart nodes one at a time with health checks (zero downtime):

```bash
make rolling-restart
```

## Upgrading Avalanchego

Zero-downtime version upgrades:

```bash
make upgrade VERSION=1.14.2
```

> **Note:** avalanchego release tarballs do **not** bundle subnet-evm (only the docker
> images do). The upgrade installs the standalone subnet-evm release alongside
> avalanchego, verified against the `checksums.txt` that subnet-evm releases publish.

The upgrade is rolling (`serial: 1`): each node downloads and SHA256-verifies
the release tarball **while still running**, atomically swaps the binary,
restarts only if the binary actually changed, and must pass health +
bootstrap + running-version checks before the next node is touched. Nodes
already on the target version are skipped. A checksum mismatch or failed
health check aborts the upgrade before any further node is modified.

**Checksums:** avalanchego GitHub releases do not publish a checksum
manifest, so known-good SHA256 values are pinned in
`ansible/roles/avalanchego/defaults/main.yml` (`avalanchego_checksums`).
For a version that is not pinned yet, compute the checksum on a trusted
machine and pass it through:

```bash
curl -fsSL https://github.com/ava-labs/avalanchego/releases/download/v1.15.0/avalanchego-linux-amd64-v1.15.0.tar.gz | shasum -a 256

cd ansible && ansible-playbook -i inventory/aws_hosts playbooks/shared/upgrade-nodes.yml \
  -e avalanchego_version=1.15.0 \
  -e avalanchego_checksum_sha256=<sha256>
```

(or add the value to `avalanchego_checksums` in the role defaults — preferred,
since it also covers fresh deploys). Unverified downloads are refused unless
you explicitly set `-e avalanchego_allow_unverified_download=true`.

## Monitoring

Deploy Prometheus + Grafana:

```bash
make monitoring
# Access: http://<monitoring-ip>:3000
```

Grafana's `admin` password is generated on first deploy and stored on the
monitoring host at `/etc/grafana/.admin_password` (mode 0600). Retrieve it with:

```bash
ssh -i ~/.ssh/avalanche-deploy ubuntu@<monitoring-ip> sudo cat /etc/grafana/.admin_password
```

To manage the credential externally instead, deploy with
`-e grafana_admin_password=...` (the override is persisted to the same file).

Pre-configured dashboards include:
- Node health and sync status
- P2P network metrics
- Chain-specific metrics
- Resource utilization

## Viewing Logs

```bash
make logs
```

Or SSH directly:
```bash
ssh -i ~/.ssh/avalanche-deploy ubuntu@<node-ip> \
  "sudo journalctl -u avalanchego -f --no-pager -n 50"
```

## Reset L1 Chain Data

Wipe L1 chain data for redeployment (keeps staking keys):

```bash
make reset-l1
```

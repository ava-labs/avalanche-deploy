# Troubleshooting

Common issues and solutions.

## Connection Issues

### Ansible can't connect to nodes

**Symptom:** SSH connection timeouts or permission denied

**Solutions:**
1. Check SSH key path in `ansible/inventory/<cloud>_hosts` (for example, `ansible/inventory/aws_hosts`)
2. Verify security group allows SSH (port 22) from your IP
3. Check that the instance is running: `make status`

```bash
# Test SSH manually
ssh -i ~/.ssh/avalanche-deploy ubuntu@<node-ip>
```

### Nodes not syncing

**Symptom:** P-Chain stays at "NOT_BOOTSTRAPPED"

**Solutions:**
1. Check logs for errors: `make logs`
2. Verify P2P port (9651) is open in security group
3. Ensure nodes can reach Primary Network bootstrap nodes

```bash
# Check connectivity
ssh ubuntu@<node-ip> "curl -s localhost:9650/ext/health"
```

## Infrastructure Issues

### Stale terraform state / inventory after manual teardown

**Symptom:** `terraform plan` shows resources that no longer exist (e.g., instances terminated manually in the AWS console), or the IPs in `ansible/inventory/<cloud>_hosts` are unreachable.

**Explanation:** Terraform state and the generated Ansible inventory only reflect the last `terraform apply`. Manual changes (console teardown, expired accounts) leave both pointing at dead resources.

**Solutions:**
1. Reconcile state with reality: `terraform apply -refresh-only` (or `terraform refresh`), then review `terraform plan`
2. Re-run `terraform apply` to recreate missing resources — this also regenerates the Ansible inventory with the new IPs
3. If a resource was deleted outside Terraform and you don't want it back, remove it from state: `terraform state rm <address>`
4. Long-term: use remote state (S3 backend with state locking) so state survives laptops and is shared across operators — each AWS terraform root ships a `backend.tf.example` with setup instructions (see "Remote State" in [docs/l1/DEPLOYMENT.md](l1/DEPLOYMENT.md))

## L1 Creation Issues

### "insufficient funds"

**Symptom:** create-l1 tool fails with insufficient funds

**Solution:** Fund your P-Chain address on Fuji:
1. Get test AVAX from [Builder Hub Faucet](https://build.avax.network/tools/faucet)
2. Use Core Wallet to cross-chain transfer to P-Chain

### "illegal name character"

**Symptom:** Chain creation fails with illegal name character

**Solution:** Chain names must be alphanumeric only (no hyphens, underscores, or special characters).

```bash
# Bad
--chain-name=my-chain

# Good
--chain-name=mychain
```

## RPC Access Issues

### Can't reach RPC endpoint

**Symptom:** Connection refused when accessing RPC

**Explanation:** Validators don't expose port 9650 publicly for security.

**Solutions:**
1. Use RPC nodes (they have 9650 open)
2. Use eRPC load balancer
3. SSH tunnel for development:
   ```bash
   ssh -i ~/.ssh/avalanche-deploy -L 9650:localhost:9650 ubuntu@<validator-ip>
   ```

## Genesis Configuration

### "warp cannot be activated before Durango"

**Symptom:** Chain fails to start with warp activation error

**Solution:** Add the network upgrade timestamps to your genesis file (default: `configs/l1/genesis/genesis.json`) using the **actual Fuji activation times**:
```json
{
  "config": {
    "subnetEVMTimestamp": 0,
    "durangoTimestamp": 1707840000,
    "etnaTimestamp": 1732550400
  }
}
```

> **Do not set upgrade timestamps to `0`.** In SubnetEVM, a `0` or missing upgrade timestamp does **not** mean "active at genesis" — it means "use the Primary Network's default activation time for this network." The one legitimate `0` is `subnetEVMTimestamp: 0` (SubnetEVM itself active from genesis). Setting `durangoTimestamp: 0` therefore doesn't activate Durango earlier than the values above, and it hides a related pitfall on fresh chains — see ["invalid opcode: PUSH0"](#invalid-opcode-push0--eth_estimategas-fails-on-a-fresh-l1) below.

### "invalid opcode: PUSH0" / eth_estimateGas fails on a fresh L1

**Symptom:** On a brand-new L1 (no blocks produced yet), `eth_estimateGas` or `eth_call` fails with `invalid opcode: PUSH0` for contracts compiled with Solidity 0.8.20+, even though Durango/Shanghai should be active.

**Explanation:** Upgrade activation is evaluated against the timestamp of the block being simulated on. Block 0 carries the genesis timestamp (commonly `0`), which is before every upgrade's activation time — so simulations on top of block 0 run pre-Shanghai rules where `PUSH0` is an invalid opcode. This persists until the chain produces its first block with a real wall-clock timestamp.

**Solution:** Send any one transaction (e.g., a simple self-transfer) to produce block 1. Once block 1 exists, simulations run against its timestamp and `PUSH0` works:
```bash
cast send --rpc-url <rpc-url> --private-key <funded-key> --value 0 <your-own-address>
```
Long-term, set a realistic `timestamp` in your genesis instead of `0`.

## Snapshot Issues

### Checksum verification failed

**Symptom:** Snapshot restore fails checksum verification

**Solutions:**
1. Re-download the snapshot
2. Try a different snapshot: `make list-snapshots`
3. Skip verification (not recommended): remove `-e verify_integrity=true`

### Snapshot too large for disk

**Symptom:** Not enough space during snapshot creation/restore

**Solutions:**
1. Use larger instance with more storage
2. Clean up old data: `sudo rm -rf /tmp/snapshot*`
3. For restore, verified mode needs 3x snapshot size (download + extract)

## Migration Issues

### Target node not fully synced

**Symptom:** Migration fails with sync check error

**Solution:** Wait for full sync before migration:
```bash
./scripts/primary-network/check-sync.sh <target-ip>
```

All chains must show `SYNCED`

### Source validator still running after migration

**Symptom:** Both old and new validators appear active

**Solution:** This is expected briefly. The old validator will be inactive after it misses its next validation slot. Verify migration success:
```bash
curl -s http://<new-ip>:9650/ext/info -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' | jq
```

## Add-on Issues

### Blockscout not indexing

**Symptom:** Block explorer shows no transactions

**Solutions:**
1. Wait for initial sync (can take hours for large chains)
2. Check Blockscout logs: `docker logs -f blockscout-backend`
3. Verify RPC connection: check `blockscout_rpc_url` setting

### Faucet not dispensing

**Symptom:** Faucet returns error or 0 balance

**Solutions:**
1. Fund the faucet wallet on your L1
2. Check faucet logs: `docker logs -f faucet`
3. Verify chain ID matches
4. Verify you're using the faucet endpoint on port `8010`

### eRPC returning errors

**Symptom:** 502 or 503 errors from eRPC

**Solutions:**
1. Check upstream RPC nodes are healthy
2. Verify eRPC config: `cat /etc/erpc/erpc.yaml`
3. Check eRPC logs: `docker logs -f erpc`

## Getting Help

- Check node logs: `make logs`
- Run health checks: `make health-checks`
- [Avalanche Discord](https://discord.gg/avalanche)
- [Open an issue](https://github.com/ava-labs/avalanche-deploy/issues)

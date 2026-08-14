# Avalanche Deploy documentation

Use this page as the documentation entry point. Commands are run from the
Avalanche Deploy repository unless a guide says otherwise.

## Deploy

- [Launch an L1](l1/DEPLOYMENT.md)
- [Run Primary Network validators](primary-network/DEPLOYMENT.md)
- [Deploy to Kubernetes](../kubernetes/README.md)

## L1 services and operations

- [Add-ons](l1/ADD-ONS.md)
- [Managed validator-lifecycle Relayer for Terraform/Ansible](l1/RELAYER.md)
- [Authorize a Relayer on a protocol-private L1](l1/RELAYER-AUTHORIZATION.md)
- [Operations](OPERATIONS.md)
- [Troubleshooting](TROUBLESHOOTING.md)

## Security

- [Repository security policy](../SECURITY.md)
- [Protocol-private Relayer authorization](l1/RELAYER-AUTHORIZATION.md)
- [Managed Relayer secrets and tunnel-only access](l1/RELAYER.md#security-and-authorization)

The validator-lifecycle Relayer is different from the ICM Relayer. Use the
[managed Relayer runbook](l1/RELAYER.md) for PoAManager validator registration,
weight, and removal operations. Use the [add-ons guide](l1/ADD-ONS.md#icm-relayer-cross-chain-messaging)
for application-message delivery.

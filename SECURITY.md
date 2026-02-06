# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please report security issues to: security@avalabs.org

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fixes (optional)

## Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Resolution**: Depends on severity, typically 30-90 days

## Scope

This security policy applies to:
- The `avalanche-deploy` repository
- Terraform modules in `terraform/`
- Ansible roles in `ansible/roles/`
- Go tools in `tools/`

## Security Best Practices

When using this project:

1. **Never commit secrets** - Use environment variables or secret managers
2. **Restrict SSH access** - Limit `operator_ip` in `terraform/<provider>/terraform.tfvars`
3. **Use private keys securely** - Store in secure locations, never commit
4. **Keep dependencies updated** - Run `go mod tidy` and update terraform providers
5. **Review `configs/l1/genesis/genesis.json`** - Ensure pre-funded addresses are intended

## Known Security Considerations

- Default Grafana credentials are `admin/admin` - change immediately
- SSH is allowed from your IP by default - restrict in production
- P-Chain private keys should be stored in hardware wallets for mainnet

## Acknowledgments

We appreciate security researchers who help keep Avalanche Deploy secure.

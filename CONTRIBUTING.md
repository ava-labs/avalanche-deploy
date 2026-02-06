# Contributing to Avalanche Deploy

Thank you for your interest in contributing to Avalanche Deploy!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/avalanche-deploy.git`
3. Create a feature branch: `git checkout -b feature/my-feature`
4. Make your changes
5. Test your changes locally
6. Commit with clear messages: `git commit -m "Add feature X"`
7. Push to your fork: `git push origin feature/my-feature`
8. Open a Pull Request

## Development Setup

### Prerequisites

- Go 1.24.13+
- Terraform 1.5+
- Ansible 2.15+
- AWS CLI (for AWS deployments)
- `jq`
- `shellcheck`

### Building

```bash
# Build the create-l1 tool
cd tools/create-l1
go build -o create-l1 .
```

### Configuration Layout

- L1 config: `configs/l1/`
- Primary Network config: `configs/primary-network/`
- Keep new config files under these folders instead of repo root.

### Testing Locally

```bash
# Prerequisites + config sanity
make doctor

# Full incremental suite (recommended before PR)
make test-incremental

# If your environment cannot reach registry.terraform.io:
make test-incremental SKIP_TERRAFORM_VALIDATE=true
```

### Pre-commit (Recommended)

```bash
pipx install pre-commit
pre-commit install
pre-commit run --all-files
```

## Code Style

- Go: Follow standard Go formatting (`go fmt`)
- Terraform: Use `terraform fmt`
- YAML: 2-space indentation
- Shell scripts: Use shellcheck for linting
- Keep Terraform lockfiles (`.terraform.lock.hcl`) committed for reproducibility

## Pull Request Guidelines

- Keep PRs focused on a single change
- Update documentation if needed
- Add tests for new functionality
- Ensure CI passes before requesting review

## Reporting Issues

- Use GitHub Issues for bug reports and feature requests
- Include steps to reproduce for bugs
- For security issues, see [SECURITY.md](SECURITY.md)

## Questions?

Open a GitHub Discussion or reach out to the maintainers.

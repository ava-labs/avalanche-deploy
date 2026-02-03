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

- Go 1.21+
- Terraform 1.0+
- Ansible 2.10+
- AWS CLI (for AWS deployments)

### Building

```bash
# Build the create-l1 tool
cd tools/create-l1
go build -o create-l1 .
```

### Testing Locally

```bash
# Validate terraform
cd terraform/aws
terraform validate

# Check ansible syntax
cd ansible
ansible-playbook --syntax-check playbooks/*.yml
```

## Code Style

- Go: Follow standard Go formatting (`go fmt`)
- Terraform: Use `terraform fmt`
- YAML: 2-space indentation
- Shell scripts: Use shellcheck for linting

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

# Security Policy

## Supported version

Security fixes are applied to the latest version on the `main` branch.

## Reporting a vulnerability

Do not disclose vulnerabilities, credentials, tenant evidence, or customer data in a public issue.

Report a vulnerability through the repository's private security advisory feature:

1. Open the repository's **Security** tab.
2. Select **Advisories**.
3. Select **New draft security advisory**.
4. Include impact, affected files, reproduction steps, and a proposed mitigation if available.

## Sensitive assessment data

The collector output can contain tenant, identity, network, security, and workload information. The `output/` directory and local workload configuration files are excluded by `.gitignore`.

Before contributing, verify that commits contain no:

- Assessment output
- Subscription or tenant identifiers from real environments
- User or service principal data
- Access tokens or authorization headers
- Secret values or private keys
- Certificate bodies
- Customer resource names or network topology

See [Security and permissions](docs/SECURITY-AND-PERMISSIONS.md) for operational guidance.

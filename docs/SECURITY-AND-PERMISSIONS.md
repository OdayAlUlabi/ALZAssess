# Security and Permissions

## 1. Security model

The collector is read-only by design. It queries configuration and metadata, then writes evidence to the local output directory.

It does not:

- Modify Azure resources.
- Create role assignments or Policy assignments.
- Retrieve Key Vault secret values.
- Retrieve application password values.
- Persist access tokens.
- Export certificate bodies from application or service principal metadata.

## 2. Recommended Azure permissions

Grant access only to the approved assessment scope.

| Permission | Why it is needed | Required for |
|---|---|---|
| Reader | Read Azure resources and configuration | Baseline collection |
| Security Reader | Read Defender for Cloud posture and assessments | Complete security evidence |
| Cost Management Reader | Read budgets and cost-management configuration | Complete cost evidence |

Management-group visibility may require Reader at the management-group scope.

Resource Graph returns only objects the identity can read. Partial visibility can produce technically valid but incomplete output.

## 3. Microsoft Graph permissions

Directory collection depends on the signed-in identity and tenant consent. Typical read permissions include:

| Evidence | Relevant permission family |
|---|---|
| Directory roles and assignments | `RoleManagement.Read.Directory` or equivalent |
| PIM eligible assignments | `RoleEligibilitySchedule.Read.Directory` |
| Conditional Access | `Policy.Read.All` |
| Applications | `Application.Read.All` or equivalent |
| Service principals | `Application.Read.All` or equivalent |

Exact requirements vary by authentication method and tenant policy. Some delegated permissions require both admin consent and an appropriate Entra role.

If PIM permission is absent, the collector records a 403 error and continues with other evidence.

Use `-SkipDirectoryData` or the Fast profile when directory evidence is not approved.

## 4. Least-privilege recommendations

1. Use a dedicated assessment identity.
2. Prefer time-bound assignment through PIM.
3. Scope Azure roles to selected management groups or subscriptions.
4. Grant only required Microsoft Graph read permissions.
5. Remove or expire elevated access after collection.
6. Review sign-in and audit logs after the engagement.
7. Do not use Owner or Contributor merely to run this collector.

## 5. Credential metadata handling

Application and service principal evidence can contain credential metadata such as:

- Credential ID
- Display name
- Start and expiration date
- Credential type
- Certificate thumbprint/custom identifier

Credential-metadata collection removes certificate bodies and password values. In addition, the centralized evidence sanitizer recursively removes these prohibited fields, case-insensitively, before every JSON write:

- `secretText`
- `connectionString` and connection-string variants
- `sharedAccessKey`
- `accountKey` and primary/secondary key variants
- `clientSecret`
- `privateKey`
- `password`
- `accessToken`
- `authorization` and authorization-header variants
- SAS token and shared-access-signature variants

Non-secret credential metadata such as credential IDs, dates, and certificate thumbprints is retained. A generic field named `key` is not removed globally because Azure uses it for non-secret identifiers and metadata; certificate bodies are removed by the Microsoft Graph credential-metadata collector.

Persisted log and error text is also redacted when it contains bearer tokens, private-key blocks, connection strings, or assignments to prohibited names.

Stage 10 applies the sanitizer to existing JSON, CSV, log, text, Markdown, and HTML evidence before hashing. It then validates the entire evidence tree and stops index generation if a prohibited JSON property or recognizable secret signature remains. This provides defense in depth for resumed runs and evidence collected by an earlier version.

No credential value should appear in the output. Treat retained credential metadata as sensitive because it reveals identity inventory and expiration posture.

## 6. Other sensitive evidence

Outputs can expose:

- Tenant and subscription identifiers
- User, group, application, and service principal identifiers
- Role assignments
- Network address spaces and topology
- Public endpoints
- Security recommendations
- Resource names and tags
- Business ownership
- Workload criticality and recovery targets

Store the output in an approved restricted location. Do not publish it to a public repository or unsecured collaboration space.

## 7. Filesystem protection

Recommended controls:

- Use a dedicated encrypted workstation or approved jump host.
- Write evidence to an access-controlled directory.
- Limit access to the assessment team.
- Transfer through approved encrypted channels.
- Avoid consumer synchronization locations.
- Preserve SHA-256 hashes from the evidence index.
- Delete temporary local copies according to retention policy.

Example NTFS review:

```powershell
Get-Acl '.\output\assessment' | Format-List
```

## 8. Evidence retention

Define before collection:

- Evidence owner
- Approved repository
- Retention period
- Access reviewers
- Permitted recipients
- Secure deletion process
- Whether identifiers must be redacted in final reports

The collector does not enforce retention or deletion.

## 9. Log hygiene

Collection errors can include API response details. The collector redacts recognized secret assignments and signatures before persisting errors, but you should still review `_collection-errors.csv` before sharing it externally.

Do not add debug logging that prints:

- Access tokens
- Authorization headers
- Secret values
- Complete certificate data
- Environment variables containing credentials

## 10. Integrity

Stage 10 calculates SHA-256 for collected files. After copying evidence:

```powershell
Get-FileHash `
  -LiteralPath '.\output\assessment\02-resource-governance\resources.json' `
  -Algorithm SHA256
```

Compare the result with `10-evidence-index\evidence-index.csv`.

Stage 10 does not generate the index unless sensitive-data validation passes. The index proves file consistency from the time it was generated; it does not provide signer identity or nonrepudiation.

## 11. Incident handling

If sensitive values are found:

1. Stop distribution of the evidence.
2. Restrict access to the output directory.
3. Identify the affected files.
4. Follow the organization's incident process.
5. Rotate exposed credentials if applicable.
6. Remove the sensitive field at the source.
7. recollect into a new directory.
8. Do not overwrite the incident evidence unless directed by the response team.

## 12. Official references

- [Azure Resource Graph permissions](https://learn.microsoft.com/azure/governance/resource-graph/overview#permissions-in-azure-resource-graph)
- [Azure built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)
- [Microsoft identity platform access tokens](https://learn.microsoft.com/entra/identity-platform/access-tokens)

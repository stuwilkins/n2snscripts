# `azoidcapp`

Python utility that creates or reconciles an Azure Entra ID OIDC web
application and its service principal. Sets an owner on both objects,
ensures the standard OIDC delegated Microsoft Graph scopes (`openid`,
`email`, `profile`, `offline_access`) plus the delegated `User.Read`
scope, and grants tenant-wide admin consent for those delegated
permissions.

The script is **idempotent**: re-running with the same `--name` is safe.
Existing objects are reused; redirect URIs are unioned (never removed);
permissions and consent are reconciled to the desired state.

Authentication reuses the current `az` CLI session — no additional
credentials or Python packages are required.

## Requirements

- `az` (Azure CLI) logged in via `az login`
- `python3 >= 3.9` (stdlib only — no pip dependencies)

## Usage

```text
azoidcapp --name NAME --owner UPN --redirect-uri URI [options]
azoidcapp --help
```

| Option | Description |
| --- | --- |
| `-n`, `--name NAME` | Display name of the app registration (required) |
| `-o`, `--owner UPN` | Owner UPN/email resolved to an object ID (required) |
| `-r`, `--redirect-uri URI` | Web redirect URI; repeatable, minimum one required |
| `-t`, `--tenant TENANT` | Tenant ID or domain for the `az` token request (optional) |
| `--json` | Emit a JSON result instead of a human-readable summary |
| `-h`, `--help` | Show help and exit |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — all resources in desired state |
| `1` | Usage error |
| `2` | `az` CLI missing or not logged in |
| `3` | Owner UPN could not be resolved to an object ID |
| `4` | A Microsoft Graph call failed, or multiple apps share `--name` |

## Examples

```bash
# Minimal: single redirect URI
azoidcapp \
  --name "My OIDC App" \
  --owner alice@example.com \
  --redirect-uri https://app.example.com/callback

# Multiple redirect URIs
azoidcapp \
  --name "My OIDC App" \
  --owner alice@example.com \
  --redirect-uri https://app.example.com/callback \
  --redirect-uri https://app.example.com/silent-callback

# Emit JSON output (useful for scripting)
azoidcapp \
  --name "My OIDC App" \
  --owner alice@example.com \
  --redirect-uri https://app.example.com/callback \
  --json

# Specify tenant explicitly
azoidcapp \
  --name "My OIDC App" \
  --owner alice@example.com \
  --redirect-uri https://app.example.com/callback \
  --tenant contoso.onmicrosoft.com
```

## Caveats

- Only **delegated** Microsoft Graph scopes are configured — the script
  does not assign any application app-roles (e.g. `User.Read.All`). The
  resulting app is suitable for delegated (user-signed-in) OIDC flows,
  not app-only/daemon scenarios.
- Requires the `az` session to have sufficient Microsoft Graph permissions
  to create app registrations, service principals, and grant admin consent
  for delegated scopes. Typically this means a user with the **Application
  Administrator** or **Global Administrator** Entra ID role.
- `--name` is used as both the display name and the lookup key for
  idempotency. If multiple existing app registrations share the same
  display name, the script exits with code `4`.
- Re-running is safe: redirect URIs are **unioned** (existing URIs are
  never removed), and permissions are reconciled to the desired state
  rather than duplicated.

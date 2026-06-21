# Authentication reference

## Provider switch

Use an environment variable:

```text
AUTH_PROVIDER=github|google|entra|none
```

Default to `github`. If the value is missing, use GitHub. If auth is enabled and no users are allowlisted, deny everyone.

Common env vars:

```text
PUBLIC_BASE_URL=https://example.com
AUTH_PROVIDER=github
ALLOWED_USERS=alice,bob
SESSION_SECRET=<random 32+ byte secret>
```

Provider-specific env vars:

```text
GITHUB_CLIENT_ID=<id>
GITHUB_CLIENT_SECRET=<secret>
GITHUB_ALLOWED_EMAILS=<optional comma-separated verified emails>

GOOGLE_CLIENT_ID=<id>
GOOGLE_CLIENT_SECRET=<secret>

ENTRA_TENANT_ID=<tenant-id>
ENTRA_CLIENT_ID=<id>
ENTRA_CLIENT_SECRET=<secret>
```

## GitHub registration

Create a GitHub OAuth App manually in GitHub Developer settings:

```text
https://github.com/settings/developers
```

Click **OAuth Apps** > **New OAuth App** before collecting the client ID or secret from the user.

Use:

```text
Homepage URL: https://<host>
Authorization callback URL: https://<host>/oauth/github/callback
```

Scopes:

```text
read:user user:email
```

Authorize using GitHub handles in `ALLOWED_USERS`. Use `GITHUB_ALLOWED_EMAILS` only as optional defense-in-depth.

## Google registration

Create an OAuth client in Google Cloud Console before collecting the client ID or secret:

```text
https://console.cloud.google.com/apis/credentials
```

```text
Application type: Web application
Authorized JavaScript origins: https://<host>
Authorized redirect URI: https://<host>/oauth/google/callback
```

Authorize using email addresses in `ALLOWED_USERS`.

## Entra registration

Create an app registration in Microsoft Entra before collecting the client ID or secret:

```text
https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade
```

```text
Platform: Web
Redirect URI: https://<host>/oauth/entra/callback
Supported account types: single tenant unless user asks otherwise
```

Create a client secret and configure:

```text
ENTRA_TENANT_ID
ENTRA_CLIENT_ID
ENTRA_CLIENT_SECRET
```

Authorize using object IDs where possible. UPN/email can be allowed for convenience, but object IDs are more stable.

## No auth

Use `AUTH_PROVIDER=none` only when the user explicitly requests no authentication. Blob Storage should still remain private; ACA becomes the public serving endpoint.

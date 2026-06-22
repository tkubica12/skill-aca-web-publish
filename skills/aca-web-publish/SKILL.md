---
name: aca-web-publish
description: Deploy private static HTML, docs, media, or generated site content to Azure Container Apps with an authenticated proxy to private Azure Blob Storage. Use for ACA web publishing, Blob-backed static sites, GitHub/Google/Entra OAuth, GHCR or ACR container publishing, custom DNS, and day-2 content/user updates.
license: MIT
compatibility: Requires Azure CLI, gh CLI for GitHub operations, Azure subscription access, and permission to create ACA, Storage, RBAC, DNS, and optionally ACR resources.
---

# ACA Web Publish

Use this skill to deploy private static content on Azure without exposing Blob Storage publicly. The default pattern is policy-aligned private networking:

1. Static content is uploaded to private Azure Blob Storage and set to Cold tier.
2. A small Docker image runs in Azure Container Apps (ACA).
3. The container implements app-level authentication and streams Blob content through ACA.
4. ACA runs in a VNet-integrated Workload Profiles environment with the Consumption workload profile.
5. Blob Storage is reached through a Blob private endpoint and `privatelink.blob.core.windows.net` private DNS.
6. Storage final state is `publicNetworkAccess=Disabled`, firewall default action `Deny`, `allowBlobPublicAccess=false`, and `allowSharedKeyAccess=false`.
7. ACA uses a system-assigned managed identity with `Storage Blob Data Reader`.
8. Browser users never receive blob keys, SAS URLs, direct blob URLs, or storage account keys.
9. ACA Easy Auth is not used; authentication stays in the app.

## Mandatory interaction model

Unless the user has already provided all choices explicitly, use the `ask_user` tool before implementing. Gather:

| Decision | Recommended default |
|---|---|
| Auth provider | GitHub |
| Allowed users | No default; if empty, no one can sign in |
| Registry mode | GHCR public image if the repository can host a public package; ACR if the solution must be private/self-contained |
| Custom DNS | Prefer custom DNS if the user has an Azure DNS zone |
| Content directory | Ask for local path |
| Azure resource names | Generate safe defaults, but ask before changing existing infra |
| Storage networking | Private endpoint, not public RBAC |
| VNet CIDR | `10.42.0.0/24` |
| ACA subnet | `snet-aca-env`, `/27`, delegated to `Microsoft.App/environments` |
| Private endpoint subnet | `snet-storage-pe`, `/28` |
| Upload path | Temporary narrow public upload window by default; VNet-hosted runner for stricter environments |

Before asking for any OAuth client ID or secret, first determine whether the final public hostname is already known:

- With custom DNS, ask for the hostname and DNS zone first. Then give the user the provider portal link and exact redirect URLs for that custom hostname before collecting client IDs/secrets.
- With the ACA built-in hostname, do not ask for OAuth client IDs/secrets yet because the hostname is not known until ACA exists. First create a bootstrap ACA endpoint, capture its `https://<app>.<region>.azurecontainerapps.io` URL, then give the user the provider portal link and exact redirect URLs and collect client IDs/secrets.

Never ask the user to create an OAuth app from placeholder URLs. Collect client IDs/secrets with `ask_user`; never echo secrets in the final response and never commit them.

## Key defaults

- Auth provider defaults to `github`.
- Supported auth providers: `github`, `google`, `entra`, `none`.
- `none` is only for explicitly public or internal test deployments.
- If auth is enabled and no allowed users are configured, deny everyone.
- Use comma-separated allowed users:
  - GitHub: handles such as `tkubica12,octocat`.
  - Google: email addresses.
  - Entra: object IDs or UPN/email addresses, depending on implementation.
- Optional email allowlists may be used for GitHub as defense-in-depth, but handles are the primary GitHub identity.
- Storage networking defaults to `private-endpoint`. The old public endpoint + RBAC pattern is `public-rbac` fallback only.
- Storage final state for the default pattern must be `publicNetworkAccess=Disabled`, firewall default action `Deny`, `bypass=None`, `allowBlobPublicAccess=false`, and `allowSharedKeyAccess=false`.
- Use a Workload Profiles Container Apps environment with VNet infrastructure subnet and the Consumption workload profile. Do not use Flex as the default.
- ACA should be small: start at `0.25` CPU and `0.5Gi` memory.
- ACA should scale to zero with a 60-minute cooldown/idleness behavior where supported by the active ACA/KEDA CLI surface; otherwise use min replicas `0` and document the limitation.
- Existing non-VNet ACA environments should be treated as effectively immutable for VNet attachment. Migrate by creating a new VNet-integrated environment, deploying a replacement app, and cutting over the custom domain.

## Registry choices

### GHCR mode

Use GHCR when the image contains only proxy/auth code and no content. The image/package must be public so ACA can pull without credentials. Create a GitHub Actions workflow from `assets/publish-web-image.yml` to build and push the image.

### ACR mode

Use ACR when the user wants a fully private and self-contained Azure solution. Create an ACR, build or push the image there, and grant the ACA managed identity `AcrPull`.

For ACR, avoid creating ACA directly from the private image before `AcrPull` is configured. Create the app first with a public bootstrap image and system-assigned identity, grant that identity `AcrPull`, configure the registry with `--identity system`, then update the app to the ACR image.

When building with `az acr build` from Windows terminals, use `--no-logs` to avoid Azure CLI log streaming Unicode/console encoding failures; query the build result instead.

## Storage networking choices

### Default: private endpoint

Create VNet resources before locking Storage:

1. VNet, default `/24`.
2. ACA infrastructure subnet, minimum `/27`, delegated to `Microsoft.App/environments`.
3. Private endpoint subnet, default `/28`.
4. Private DNS zone `privatelink.blob.core.windows.net`.
5. VNet link for the private DNS zone.
6. Blob private endpoint for the Storage account target subresource `blob`.
7. Private DNS zone group on the private endpoint.
8. ACA Workload Profiles environment with `--enable-workload-profiles true` and `--infrastructure-subnet-resource-id`.
9. ACA proxy app in that environment with system-assigned identity.
10. `Storage Blob Data Reader` RBAC for the ACA identity.
11. Content upload.
12. Storage lock-down to `publicNetworkAccess=Disabled`, `defaultAction=Deny`, `bypass=None`.

Do not disable Storage public network access before the private endpoint and DNS path exist.

### Fallback: public RBAC

Use `public-rbac` only when private endpoints are intentionally out of scope. Blobs still must not be anonymous and shared keys still must stay disabled. Do not use policy exemptions as the normal path.

### Upload strategy

For the default private endpoint pattern, local uploads need either a VNet path or a temporary authenticated public network window. The pragmatic default is a narrow temporary window:

1. Enable Storage public network access.
2. Keep `allowBlobPublicAccess=false`.
3. Keep `allowSharedKeyAccess=false`.
4. Set firewall default action `Deny`.
5. Add only the current uploader public IP as a network rule.
6. Upload with Entra/RBAC using AzCopy when available.
7. Remove the IP rule in `finally`.
8. Disable Storage public network access again and keep default action `Deny`.

For stricter environments, use a VNet-hosted upload runner: a temporary VM/jumpbox, self-hosted runner, VPN/ExpressRoute client path, or temporary ACA Job in the VNet.

## OAuth hostname timing

OAuth app registration must use the final browser-visible host in the homepage/origin and callback URL.

### Custom DNS flow

1. Ask for the custom hostname and DNS zone.
2. Show the provider registration link and exact URLs, for example `https://site.example.com` and `https://site.example.com/oauth/github/callback`.
3. Collect the client ID and secret.
4. Deploy ACA, DNS, auth settings, content, and certificate binding.

### ACA built-in hostname flow

1. Deploy a bootstrap ACA endpoint first to discover the built-in hostname. Use the deployment script with `-BootstrapOnly` or create the ACA/container app shell manually.
2. Show the provider registration link and exact URLs using the discovered hostname, for example `https://<fqdn>` and `https://<fqdn>/oauth/github/callback`.
3. Collect the client ID and secret.
4. Complete the deployment by applying auth settings, uploading content, and switching to the proxy image if the app was bootstrapped.

## Required files to copy or adapt

Use these assets as implementation starting points:

- `assets/blob_proxy_app.py`: FastAPI app with Blob proxy and provider switch.
- `assets/requirements.txt`: Python runtime dependencies.
- `assets/Dockerfile`: Minimal image for ACA.
- `assets/deploy-aca-web.ps1`: Opinionated Azure deployment script.
- `assets/publish-web-image.yml`: GitHub Actions workflow for GHCR publishing.

Read these references when needed:

- `references/architecture.md`: Architecture, storage rules, and scaling notes.
- `references/auth.md`: OAuth registration steps and env variables.
- `references/day-2.md`: Adding users, rotating secrets, uploading content, and troubleshooting.

## Implementation checklist

1. Confirm content directory and generated site entry point.
2. Choose storage networking; default to `private-endpoint`, ask before using `public-rbac`.
3. Confirm or generate VNet CIDR, ACA subnet, private endpoint subnet, and private DNS zone values.
4. Choose custom DNS or ACA built-in hostname.
5. Choose auth provider.
6. If the hostname is known, give the user provider-specific app registration links and exact callback URLs; if using the ACA built-in hostname, bootstrap ACA first and then provide those URLs.
7. Collect app registration values.
8. Collect allowed users.
9. Choose GHCR or ACR.
10. Copy/adapt the sample app and Dockerfile into the target repository.
11. If GHCR mode, add the workflow and make the resulting package public.
12. Create Storage, VNet/subnets, private DNS, Blob private endpoint, and VNet-integrated ACA Workload Profiles environment.
13. Deploy ACA, RBAC, secrets, env vars, and optional DNS.
14. Upload content to Blob using VNet runner or temporary narrow public upload window.
15. Lock Storage to `publicNetworkAccess=Disabled`, `defaultAction=Deny`, `bypass=None`.
16. Smoke test:
    - unauthenticated request redirects to provider, unless `AUTH_PROVIDER=none`;
    - allowed user can load `index.html`;
    - non-allowed user gets `403`;
    - media range requests return `206 Partial Content`;
    - Blob direct anonymous access fails.
    - `/storage-health` works only for an authenticated session and reports Storage availability.

## Day-2 task handling

For "add user", update only `ALLOWED_USERS` or provider-specific allowlist env vars and restart/revise ACA.

For "upload new content", regenerate local static output, run Blob sync with delete enabled only if local output is authoritative, then set Cold tier. With private endpoint mode, upload from a VNet path or use the temporary narrow public upload window and always restore locked Storage state in `finally`.

Prefer AzCopy for large sites or many files. If AzCopy is unavailable and the site is small, Azure CLI `az storage blob upload-batch --auth-mode login` is an acceptable fallback; for large sites, install AzCopy first or use the deploy script with `-InstallAzCopy`.

For "switch auth provider", create the new provider registration first, set secrets/env vars, verify login, then remove obsolete provider secrets.

For "move from GHCR to ACR", deploy ACR, grant `AcrPull`, update the image reference, and keep Blob content unchanged.

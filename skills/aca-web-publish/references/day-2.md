# Day-2 operations

## Add users

Update the comma-separated allowlist and restart/create a new ACA revision:

```powershell
az containerapp update `
  --name <app> `
  --resource-group <rg> `
  --set-env-vars "ALLOWED_USERS=user1,user2,user3"
```

For GitHub optional email checks:

```powershell
az containerapp update `
  --name <app> `
  --resource-group <rg> `
  --set-env-vars "GITHUB_ALLOWED_EMAILS=user1@example.com,user2@example.com"
```

## Upload content

Use AzCopy with Entra auth:

```powershell
azcopy login --tenant-id <tenant-id>
azcopy sync <content-dir> https://<storage>.blob.core.windows.net/<container> --recursive=true --delete-destination=true
azcopy set-properties https://<storage>.blob.core.windows.net/<container> --block-blob-tier=Cold --recursive=true
```

Use `--delete-destination=true` only when the local directory is authoritative.

If AzCopy is missing, install it before large uploads or use the deploy script with `-InstallAzCopy`. For small sites, Azure CLI can be used as a fallback:

```powershell
az storage blob delete-batch --account-name <storage> --source <container> --auth-mode login
az storage blob upload-batch --account-name <storage> --destination <container> --source <content-dir> --auth-mode login --overwrite true --tier Cold
```

Prefer AzCopy for large sites because it handles high file counts and incremental sync more efficiently.

## Rotate OAuth secrets

1. Create a new provider secret in the provider portal.
2. Update the ACA secret.
3. Restart ACA revision or deploy a new revision.
4. Verify login.
5. Delete the old provider secret.

## Troubleshoot 500 after login

If logs show Blob `AuthorizationFailure`, check:

- ACA identity has `Storage Blob Data Reader`.
- Storage account has `publicNetworkAccess=Enabled` unless private endpoint/VNet routing exists.
- Blob public access is disabled.
- Shared keys are disabled.

## Direct blob access check

Anonymous direct Blob URLs should fail. Content should only be reachable through ACA.

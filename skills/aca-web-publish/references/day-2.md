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

The default architecture leaves Storage with `publicNetworkAccess=Disabled`. A local developer machine cannot upload to `https://<storage>.blob.core.windows.net/<container>` unless it has a private network path.

Preferred upload options:

1. Run upload from a VM, jumpbox, self-hosted runner, or temporary ACA Job inside the VNet.
2. Use VPN, ExpressRoute, or another private endpoint path from the operator network.
3. For simple operator workflows, briefly open an authenticated public network window with a narrow IP rule and automatic cleanup.

Temporary public upload window:

```powershell
$ip = (Invoke-RestMethod https://api.ipify.org).Trim()

try {
  az storage account update `
    --name <storage> `
    --resource-group <rg> `
    --public-network-access Enabled `
    --default-action Deny `
    --bypass None `
    --allow-blob-public-access false `
    --allow-shared-key-access false `
    --output none

  az storage account network-rule add `
    --account-name <storage> `
    --resource-group <rg> `
    --ip-address $ip `
    --output none

  azcopy login --tenant-id <tenant-id>
  azcopy sync <content-dir> https://<storage>.blob.core.windows.net/<container> --recursive=true --delete-destination=true
  azcopy set-properties https://<storage>.blob.core.windows.net/<container> --block-blob-tier=Cold --recursive=true
}
finally {
  az storage account network-rule remove `
    --account-name <storage> `
    --resource-group <rg> `
    --ip-address $ip `
    --output none

  az storage account update `
    --name <storage> `
    --resource-group <rg> `
    --public-network-access Disabled `
    --default-action Deny `
    --bypass None `
    --allow-blob-public-access false `
    --allow-shared-key-access false `
    --output none
}
```

This never enables anonymous Blob access and never enables shared keys. It only makes the public endpoint reachable for authenticated RBAC callers from the operator IP during upload.

If AzCopy is missing, install it before large uploads or use the deploy script with `-InstallAzCopy`. For small sites, Azure CLI can be used inside the same temporary network window:

```powershell
az storage blob delete-batch --account-name <storage> --source <container> --auth-mode login
az storage blob upload-batch --account-name <storage> --destination <container> --source <content-dir> --auth-mode login --overwrite true --tier Cold
```

Use `--delete-destination=true` only when the local directory is authoritative.

## Rotate OAuth secrets

1. Create a new provider secret in the provider portal.
2. Update the ACA secret.
3. Restart ACA revision or deploy a new revision.
4. Verify login.
5. Delete the old provider secret.

ACA secrets are write-only. For migrations to a replacement VNet-integrated environment, ask the user to provide the OAuth secret again or use Key Vault references.

## Troubleshoot storage errors

If the proxy shows Storage unavailable or logs show Blob `AuthorizationFailure`, check both identity and network:

- ACA identity has `Storage Blob Data Reader`.
- ACA environment is VNet-integrated with the intended delegated subnet.
- `privatelink.blob.core.windows.net` is linked to the ACA VNet.
- `<storage>.blob.core.windows.net` resolves to the private endpoint IP from inside the VNet.
- Blob private endpoint is approved and targets subresource `blob`.
- Storage final state is `publicNetworkAccess=Disabled`, `defaultAction=Deny`, and `bypass=None`.
- Blob public access is disabled.
- Shared keys are disabled.

If `publicNetworkAccess` was enabled and later changed to disabled, inspect the activity log:

```powershell
$storageId = az storage account show --name <storage> --resource-group <rg> --query id -o tsv
az monitor activity-log list --resource-id $storageId --offset 24h -o table
```

If a Microsoft first-party app or Defender/Security Center policy patched it, either:

1. Create a targeted policy exemption for this storage account, keeping blob public access and shared keys disabled.
2. Or move ACA to a VNet-integrated environment with a Blob private endpoint and keep `publicNetworkAccess=Disabled`.

## Direct blob access check

Anonymous direct Blob URLs should fail. Content should only be reachable through ACA.

## Custom domain migration

When moving to a new ACA environment, the ACA FQDN changes:

1. Update the CNAME to the new ACA FQDN.
2. Ensure `asuid.<record>` TXT uses the new app verification ID.
3. Add hostname to the new app.
4. Bind/create managed certificate in the new environment.
5. Wait/retry because certificate provisioning may stay pending.
6. Remove hostname from the old app before binding to the new app if needed.

Do not assume verification IDs remain the same across apps or environments.

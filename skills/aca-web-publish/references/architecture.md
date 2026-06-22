# Architecture reference

## Components

- Azure Blob Storage stores all static content and media.
- The Blob container is private.
- Blob public access is disabled.
- Shared-key access is disabled.
- Azure Container Apps hosts a small proxy/auth web app.
- ACA has a system-assigned managed identity.
- Managed identity has `Storage Blob Data Reader` on the storage account.
- Upload identity has `Storage Blob Data Contributor`.
- App code reads blobs with `DefaultAzureCredential`.

## Storage networking

Keep the storage account data plane reachable by ACA:

```text
publicNetworkAccess = Enabled
allowBlobPublicAccess = false
allowSharedKeyAccess = false
```

This does not make blobs public. Anonymous blob reads still fail. It only allows authenticated callers with RBAC to reach the Blob endpoint.

If the user requires `publicNetworkAccess=Disabled`, first integrate ACA with a VNet and configure a private endpoint/private DNS path for the storage account. Do not disable public network access before that path is working.

Defender for Cloud or Security Center policy may auto-patch storage accounts back to `publicNetworkAccess=Disabled`. For the simple ACA proxy architecture, create a narrow policy exemption on the storage account for the Security Center storage network/private-link recommendations. This is acceptable only when blob public access and shared keys remain disabled and all reads go through the ACA managed identity.

The fully policy-aligned alternative is:

1. Create a VNet with a delegated ACA infrastructure subnet.
2. Create a new VNet-integrated Container Apps environment.
3. Create a Blob private endpoint.
4. Link `privatelink.blob.core.windows.net` private DNS to the VNet.
5. Move/recreate the Container App in the VNet-integrated environment.
6. Set storage `publicNetworkAccess=Disabled`.

## Scale settings

Use small ACA resources:

```text
cpu = 0.25
memory = 0.5Gi
min replicas = 0
max replicas = 2
```

When the available ACA/KEDA CLI supports cooldown configuration, set idle/cooldown to 3600 seconds. If not supported, set min replicas to 0 and document that the platform default cooldown applies.

## Blob tier

Set uploaded blobs to Cold tier:

```powershell
azcopy set-properties https://<storage>.blob.core.windows.net/<container> --block-blob-tier=Cold --recursive=true
```

Cold is suitable for rarely accessed generated libraries. For frequently opened sites, warn the user that Cool or Hot can be cheaper overall due to retrieval costs.

# Architecture reference

## Components

- Azure Blob Storage stores all static content and media.
- The Blob container is private.
- Blob public access is disabled.
- Shared-key access is disabled.
- Storage public network access is disabled in the final state.
- Azure Container Apps hosts a small proxy/auth web app.
- ACA runs in a Workload Profiles environment with the Consumption workload profile.
- The ACA environment is VNet-integrated through a delegated infrastructure subnet.
- Blob Storage is reachable from ACA through a Blob private endpoint and private DNS.
- ACA has a system-assigned managed identity.
- Managed identity has `Storage Blob Data Reader` on the storage account.
- Upload identity has `Storage Blob Data Contributor`.
- App code reads blobs with `DefaultAzureCredential`.

## Storage networking

Default final Storage state:

```text
publicNetworkAccess = Disabled
networkRuleSet.defaultAction = Deny
networkRuleSet.bypass = None
allowBlobPublicAccess = false
allowSharedKeyAccess = false
```

Required private networking resources:

```text
VNet = e.g. 10.42.0.0/24
ACA subnet = /27 minimum, delegated to Microsoft.App/environments
Private endpoint subnet = e.g. /28
Private DNS zone = privatelink.blob.core.windows.net
Private DNS zone link = linked to ACA VNet
Blob private endpoint = Approved, groupId blob
Private DNS A record = <storage-account> -> private endpoint IP
```

Do not disable Storage public network access before the private endpoint and private DNS path are created. ACA must have both RBAC and a private network path; RBAC alone is not enough when `publicNetworkAccess=Disabled`.

The old public Storage endpoint + RBAC pattern is a fallback only. It keeps blobs private, but it is not the default because policy may block public Storage data-plane reachability.

## ACA environment

Use a Workload Profiles environment, not Flex, for the default private endpoint pattern:

```powershell
az containerapp env create `
  --name <env> `
  --resource-group <rg> `
  --location <location> `
  --enable-workload-profiles true `
  --infrastructure-subnet-resource-id <aca-subnet-id>
```

This supports custom VNet integration, Consumption workload profile behavior, and scale-to-zero. Flex is not the default because it is preview and does not align with the scale-to-zero goal.

Existing non-VNet ACA environments generally should be treated as immutable for VNet attachment. The practical migration path is a new VNet-integrated ACA environment, replacement app, OAuth secret re-entry or Key Vault references, and custom domain cutover.

## Deployment ordering

1. Create resource group.
2. Create Storage with `allowBlobPublicAccess=false`, `allowSharedKeyAccess=false`, and temporary public network reachability only as needed for deployment.
3. Create VNet and subnets.
4. Delegate ACA subnet to `Microsoft.App/environments`.
5. Create private DNS zone and VNet link.
6. Create Blob private endpoint and DNS zone group.
7. Create VNet-integrated ACA Workload Profiles environment.
8. Create ACA app with a public bootstrap image and system identity.
9. Grant ACA identity `Storage Blob Data Reader`.
10. If using ACR, grant `AcrPull`, configure registry identity, and switch to the proxy image.
11. Configure secrets and environment variables.
12. Upload content.
13. Lock Storage to the final private state.
14. Configure custom domain and managed certificate.
15. Verify browser auth, proxy access, and direct Blob denial.

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

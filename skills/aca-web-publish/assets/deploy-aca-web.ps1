param(
    [string]$ResourceGroup,
    [string]$Location = "westeurope",
    [string]$AppName,
    [string]$EnvironmentName,
    [string]$StorageAccountName,
    [string]$ContainerName = "site",
    [string]$ContentDir,
    [ValidateSet("ghcr", "acr")]
    [string]$RegistryMode = "ghcr",
    [string]$Image,
    [string]$AcrName = "",
    [ValidateSet("github", "google", "entra", "none")]
    [string]$AuthProvider = "github",
    [string]$AllowedUsers,
    [string]$PublicBaseUrl = "",
    [string]$CustomHostname = "",
    [string]$DnsZoneName = "",
    [string]$DnsZoneResourceGroup = "",
    [string]$SessionSecret = $env:SESSION_SECRET,
    [string]$GitHubClientId = $env:GITHUB_CLIENT_ID,
    [string]$GitHubClientSecret = $env:GITHUB_CLIENT_SECRET,
    [string]$GoogleClientId = $env:GOOGLE_CLIENT_ID,
    [string]$GoogleClientSecret = $env:GOOGLE_CLIENT_SECRET,
    [string]$EntraTenantId = $env:ENTRA_TENANT_ID,
    [string]$EntraClientId = $env:ENTRA_CLIENT_ID,
    [string]$EntraClientSecret = $env:ENTRA_CLIENT_SECRET,
    [ValidateSet("auto", "azcopy", "cli")]
    [string]$UploadMode = "auto",
    [switch]$InstallAzCopy,
    [switch]$BootstrapOnly,
    [ValidateSet("private-endpoint", "public-rbac")]
    [string]$StorageNetworkMode = "private-endpoint",
    [string]$VnetName = "",
    [string]$VnetAddressPrefix = "10.42.0.0/24",
    [string]$AcaSubnetName = "snet-aca-env",
    [string]$AcaSubnetPrefix = "10.42.0.0/27",
    [string]$PrivateEndpointSubnetName = "snet-storage-pe",
    [string]$PrivateEndpointSubnetPrefix = "10.42.0.32/28",
    [string]$PrivateDnsZoneName = "privatelink.blob.core.windows.net",
    [bool]$TemporaryPublicUpload = $true,
    [string]$UploaderIpAddress = ""
)

$ErrorActionPreference = "Stop"

function Install-AzCopyIfRequested {
    if (-not $InstallAzCopy) {
        return $null
    }
    $existing = Get-Command azcopy -ErrorAction SilentlyContinue
    if ($existing) {
        return $existing
    }

    $installRoot = Join-Path ([System.IO.Path]::GetTempPath()) "azcopy-install"
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $archive = Join-Path $installRoot "azcopy.zip"
        Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile $archive
        Expand-Archive -Force -Path $archive -DestinationPath $installRoot
        $azCopyPath = Get-ChildItem -Path $installRoot -Recurse -Filter azcopy.exe | Select-Object -First 1
    } else {
        $archive = Join-Path $installRoot "azcopy.tar.gz"
        Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-linux" -OutFile $archive
        tar -xzf $archive -C $installRoot
        $azCopyPath = Get-ChildItem -Path $installRoot -Recurse -Filter azcopy | Select-Object -First 1
    }
    if (-not $azCopyPath) {
        throw "AzCopy installation failed."
    }
    $env:PATH = "$($azCopyPath.Directory.FullName)$([System.IO.Path]::PathSeparator)$env:PATH"
    return Get-Command azcopy -ErrorAction Stop
}

function Invoke-ContentUpload {
    param(
        [string]$AccountName,
        [string]$Container,
        [string]$SourceDir
    )

    $azCopy = Get-Command azcopy -ErrorAction SilentlyContinue
    if (-not $azCopy) {
        $azCopy = Install-AzCopyIfRequested
    }
    if ($UploadMode -eq "azcopy" -and -not $azCopy) {
        throw "AzCopy is required when UploadMode=azcopy. Install AzCopy or pass -InstallAzCopy."
    }
    if ($UploadMode -ne "cli" -and $azCopy) {
        azcopy sync $SourceDir "https://$AccountName.blob.core.windows.net/$Container" --recursive=true --delete-destination=true
        azcopy set-properties "https://$AccountName.blob.core.windows.net/$Container" --block-blob-tier=Cold --recursive=true
    } else {
        Write-Warning "AzCopy is not available; using Azure CLI upload fallback. Prefer AzCopy for large sites or many files."
        az storage blob delete-batch --account-name $AccountName --source $Container --auth-mode login --output none
        az storage blob upload-batch --account-name $AccountName --destination $Container --source $SourceDir --auth-mode login --overwrite true --tier Cold --output none
    }
}

function Invoke-TemporaryPublicUpload {
    param(
        [string]$AccountName,
        [string]$StorageResourceGroup,
        [string]$Container,
        [string]$SourceDir
    )

    if (-not $TemporaryPublicUpload) {
        throw "Local upload requires public network reachability or a VNet-hosted runner when StorageNetworkMode=private-endpoint."
    }
    $ip = $UploaderIpAddress
    if (-not $ip) {
        $ip = (Invoke-RestMethod "https://api.ipify.org").Trim()
    }

    try {
        az storage account update `
            --name $AccountName `
            --resource-group $StorageResourceGroup `
            --public-network-access Enabled `
            --default-action Deny `
            --bypass None `
            --allow-blob-public-access false `
            --allow-shared-key-access false `
            --output none

        az storage account network-rule add `
            --account-name $AccountName `
            --resource-group $StorageResourceGroup `
            --ip-address $ip `
            --output none

        Invoke-ContentUpload -AccountName $AccountName -Container $Container -SourceDir $SourceDir
    } finally {
        az storage account network-rule remove `
            --account-name $AccountName `
            --resource-group $StorageResourceGroup `
            --ip-address $ip `
            --output none 2>$null

        az storage account update `
            --name $AccountName `
            --resource-group $StorageResourceGroup `
            --public-network-access Disabled `
            --default-action Deny `
            --bypass None `
            --allow-blob-public-access false `
            --allow-shared-key-access false `
            --output none
    }
}

if (-not $ResourceGroup -or -not $AppName -or -not $EnvironmentName -or -not $StorageAccountName -or -not $ContentDir) {
    throw "ResourceGroup, AppName, EnvironmentName, StorageAccountName, and ContentDir are required."
}
if (-not $BootstrapOnly -and $AuthProvider -ne "none" -and -not $AllowedUsers) {
    throw "AllowedUsers is required for authenticated deployments. Empty allowlists deny everyone."
}
if (-not $BootstrapOnly -and $AuthProvider -eq "github" -and (-not $GitHubClientId -or -not $GitHubClientSecret)) {
    throw "GitHubClientId and GitHubClientSecret are required when AuthProvider=github."
}
if (-not $BootstrapOnly -and $AuthProvider -eq "google" -and (-not $GoogleClientId -or -not $GoogleClientSecret)) {
    throw "GoogleClientId and GoogleClientSecret are required when AuthProvider=google."
}
if (-not $BootstrapOnly -and $AuthProvider -eq "entra" -and (-not $EntraTenantId -or -not $EntraClientId -or -not $EntraClientSecret)) {
    throw "EntraTenantId, EntraClientId, and EntraClientSecret are required when AuthProvider=entra."
}
if (-not $SessionSecret) {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $SessionSecret = [Convert]::ToBase64String($bytes)
}
if (-not $VnetName) {
    $VnetName = "$AppName-vnet"
}

az group create --name $ResourceGroup --location $Location --output none

az storage account create `
    --name $StorageAccountName `
    --resource-group $ResourceGroup `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --allow-blob-public-access false `
    --allow-shared-key-access false `
    --public-network-access Enabled `
    --default-action Deny `
    --bypass None `
    --output none 2>$null

az storage account update `
    --name $StorageAccountName `
    --resource-group $ResourceGroup `
    --allow-blob-public-access false `
    --allow-shared-key-access false `
    --public-network-access Enabled `
    --default-action Deny `
    --bypass None `
    --output none

az storage container-rm create `
    --resource-group $ResourceGroup `
    --storage-account $StorageAccountName `
    --name $ContainerName `
    --public-access off `
    --output none

$storageId = az storage account show --name $StorageAccountName --resource-group $ResourceGroup --query id -o tsv

if ($StorageNetworkMode -eq "private-endpoint") {
    az network vnet create `
        --resource-group $ResourceGroup `
        --location $Location `
        --name $VnetName `
        --address-prefixes $VnetAddressPrefix `
        --subnet-name $AcaSubnetName `
        --subnet-prefixes $AcaSubnetPrefix `
        --output none 2>$null

    az network vnet subnet update `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --name $AcaSubnetName `
        --delegations Microsoft.App/environments `
        --output none

    az network vnet subnet create `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --name $PrivateEndpointSubnetName `
        --address-prefixes $PrivateEndpointSubnetPrefix `
        --output none 2>$null

    az network vnet subnet update `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --name $PrivateEndpointSubnetName `
        --disable-private-endpoint-network-policies true `
        --output none

    az network private-dns zone create `
        --resource-group $ResourceGroup `
        --name $PrivateDnsZoneName `
        --output none 2>$null

    $vnetId = az network vnet show --resource-group $ResourceGroup --name $VnetName --query id -o tsv
    $acaSubnetId = az network vnet subnet show --resource-group $ResourceGroup --vnet-name $VnetName --name $AcaSubnetName --query id -o tsv
    $zoneId = az network private-dns zone show --resource-group $ResourceGroup --name $PrivateDnsZoneName --query id -o tsv

    az network private-dns link vnet create `
        --resource-group $ResourceGroup `
        --zone-name $PrivateDnsZoneName `
        --name "$VnetName-link" `
        --virtual-network $vnetId `
        --registration-enabled false `
        --output none 2>$null

    $privateEndpointName = "pe-$StorageAccountName-blob"
    az network private-endpoint create `
        --resource-group $ResourceGroup `
        --location $Location `
        --name $privateEndpointName `
        --vnet-name $VnetName `
        --subnet $PrivateEndpointSubnetName `
        --private-connection-resource-id $storageId `
        --group-id blob `
        --connection-name "$privateEndpointName-conn" `
        --output none 2>$null

    az network private-endpoint dns-zone-group create `
        --resource-group $ResourceGroup `
        --endpoint-name $privateEndpointName `
        --name "zg-blob" `
        --private-dns-zone $zoneId `
        --zone-name $PrivateDnsZoneName `
        --output none 2>$null
}

if ($RegistryMode -eq "acr") {
    if (-not $AcrName) {
        throw "AcrName is required when RegistryMode=acr."
    }
    az acr create --name $AcrName --resource-group $ResourceGroup --location $Location --sku Basic --admin-enabled false --output none 2>$null
    az acr build --registry $AcrName --image "aca-web-proxy:latest" --no-logs . --output none
    $loginServer = az acr show --name $AcrName --resource-group $ResourceGroup --query loginServer -o tsv
    $Image = "$loginServer/aca-web-proxy:latest"
    $registryId = az acr show --name $AcrName --resource-group $ResourceGroup --query id -o tsv
} elseif (-not $Image) {
    throw "Image is required when RegistryMode=ghcr. Use a public GHCR image such as ghcr.io/owner/repo/aca-web-proxy:latest."
}

if ($StorageNetworkMode -eq "private-endpoint") {
    az containerapp env create `
        --name $EnvironmentName `
        --resource-group $ResourceGroup `
        --location $Location `
        --enable-workload-profiles true `
        --infrastructure-subnet-resource-id $acaSubnetId `
        --output none 2>$null
} else {
    az containerapp env create --name $EnvironmentName --resource-group $ResourceGroup --location $Location --output none 2>$null
}

$initialImage = if ($registryId) { "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest" } else { $Image }
$initialTargetPort = if ($registryId) { 80 } else { 8000 }
$existingApp = az containerapp show --name $AppName --resource-group $ResourceGroup --query name -o tsv 2>$null
if (-not $existingApp) {
    az containerapp create `
        --name $AppName `
        --resource-group $ResourceGroup `
        --environment $EnvironmentName `
        --image $initialImage `
        --ingress external `
        --target-port $initialTargetPort `
        --min-replicas 0 `
        --max-replicas 2 `
        --cpu 0.25 `
        --memory 0.5Gi `
        --system-assigned `
        --output none
}

$principalId = az containerapp show --name $AppName --resource-group $ResourceGroup --query identity.principalId -o tsv
az role assignment create --assignee $principalId --role "Storage Blob Data Reader" --scope $storageId --output none 2>$null
if ($registryId) {
    az role assignment create --assignee $principalId --role AcrPull --scope $registryId --output none 2>$null
    Start-Sleep -Seconds 30
    az containerapp registry set --name $AppName --resource-group $ResourceGroup --server $loginServer --identity system --output none
}

$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv
if (-not $PublicBaseUrl) {
    $PublicBaseUrl = if ($CustomHostname) { "https://$CustomHostname" } else { "https://$fqdn" }
}
if ($BootstrapOnly) {
    Write-Host "BOOTSTRAP DONE"
    Write-Host "URL: $PublicBaseUrl"
    Write-Host "Use this URL for OAuth app registration, then rerun without -BootstrapOnly and provide the provider client ID/secret."
    return
}

$secrets = @("session-secret=$SessionSecret")
if ($AuthProvider -eq "github") { $secrets += "github-client-secret=$GitHubClientSecret" }
if ($AuthProvider -eq "google") { $secrets += "google-client-secret=$GoogleClientSecret" }
if ($AuthProvider -eq "entra") { $secrets += "entra-client-secret=$EntraClientSecret" }
az containerapp secret set --name $AppName --resource-group $ResourceGroup --secrets $secrets --output none

$envVars = @(
    "STORAGE_ACCOUNT_NAME=$StorageAccountName",
    "BLOB_CONTAINER_NAME=$ContainerName",
    "PUBLIC_BASE_URL=$PublicBaseUrl",
    "AUTH_PROVIDER=$AuthProvider",
    "ALLOWED_USERS=$AllowedUsers",
    "SESSION_SECRET=secretref:session-secret"
)
if ($AuthProvider -eq "github") {
    $envVars += "GITHUB_CLIENT_ID=$GitHubClientId"
    $envVars += "GITHUB_CLIENT_SECRET=secretref:github-client-secret"
}
if ($AuthProvider -eq "google") {
    $envVars += "GOOGLE_CLIENT_ID=$GoogleClientId"
    $envVars += "GOOGLE_CLIENT_SECRET=secretref:google-client-secret"
}
if ($AuthProvider -eq "entra") {
    $envVars += "ENTRA_TENANT_ID=$EntraTenantId"
    $envVars += "ENTRA_CLIENT_ID=$EntraClientId"
    $envVars += "ENTRA_CLIENT_SECRET=secretref:entra-client-secret"
}
az containerapp update --name $AppName --resource-group $ResourceGroup --set-env-vars $envVars --output none
if ($registryId) {
    az containerapp ingress update --name $AppName --resource-group $ResourceGroup --target-port 8000 --output none
    az containerapp update --name $AppName --resource-group $ResourceGroup --image $Image --output none
}

$signedInUserObjectId = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee $signedInUserObjectId --role "Storage Blob Data Contributor" --scope $storageId --output none 2>$null

if ($StorageNetworkMode -eq "private-endpoint") {
    Invoke-TemporaryPublicUpload -AccountName $StorageAccountName -StorageResourceGroup $ResourceGroup -Container $ContainerName -SourceDir $ContentDir
} else {
    az storage account update `
        --name $StorageAccountName `
        --resource-group $ResourceGroup `
        --public-network-access Enabled `
        --default-action Allow `
        --allow-blob-public-access false `
        --allow-shared-key-access false `
        --output none
    Invoke-ContentUpload -AccountName $StorageAccountName -Container $ContainerName -SourceDir $ContentDir
}

if ($CustomHostname) {
    if (-not $DnsZoneName -or -not $DnsZoneResourceGroup) {
        throw "DnsZoneName and DnsZoneResourceGroup are required with CustomHostname."
    }
    $recordName = $CustomHostname.Substring(0, $CustomHostname.Length - $DnsZoneName.Length - 1)
    $verificationId = az containerapp show --name $AppName --resource-group $ResourceGroup --query properties.customDomainVerificationId -o tsv
    az network dns record-set cname set-record --resource-group $DnsZoneResourceGroup --zone-name $DnsZoneName --record-set-name $recordName --cname $fqdn --ttl 300 --output none
    az network dns record-set txt create --resource-group $DnsZoneResourceGroup --zone-name $DnsZoneName --record-set-name "asuid.$recordName" --ttl 300 --output none 2>$null
    az network dns record-set txt add-record --resource-group $DnsZoneResourceGroup --zone-name $DnsZoneName --record-set-name "asuid.$recordName" --value $verificationId --output none 2>$null
    az containerapp hostname add --name $AppName --resource-group $ResourceGroup --hostname $CustomHostname --output none 2>$null
    az containerapp hostname bind --name $AppName --resource-group $ResourceGroup --hostname $CustomHostname --environment $EnvironmentName --validation-method CNAME --output none
}

if ($StorageNetworkMode -eq "private-endpoint") {
    az storage account update `
        --name $StorageAccountName `
        --resource-group $ResourceGroup `
        --public-network-access Disabled `
        --default-action Deny `
        --bypass None `
        --allow-blob-public-access false `
        --allow-shared-key-access false `
        --output none
}

Write-Host "DONE"
Write-Host "URL: $PublicBaseUrl"

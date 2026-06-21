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
    [switch]$BootstrapOnly
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
    --output none 2>$null

az storage account update `
    --name $StorageAccountName `
    --resource-group $ResourceGroup `
    --allow-blob-public-access false `
    --allow-shared-key-access false `
    --public-network-access Enabled `
    --output none

az storage container-rm create `
    --resource-group $ResourceGroup `
    --storage-account $StorageAccountName `
    --name $ContainerName `
    --public-access off `
    --output none

$storageId = az storage account show --name $StorageAccountName --resource-group $ResourceGroup --query id -o tsv

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

az containerapp env create --name $EnvironmentName --resource-group $ResourceGroup --location $Location --output none 2>$null

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

$signedInUserObjectId = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee $signedInUserObjectId --role "Storage Blob Data Contributor" --scope $storageId --output none 2>$null

$azCopy = Get-Command azcopy -ErrorAction SilentlyContinue
if (-not $azCopy) {
    $azCopy = Install-AzCopyIfRequested
}
if ($UploadMode -eq "azcopy" -and -not $azCopy) {
    throw "AzCopy is required when UploadMode=azcopy. Install AzCopy or pass -InstallAzCopy."
}
if ($UploadMode -ne "cli" -and $azCopy) {
    azcopy sync $ContentDir "https://$StorageAccountName.blob.core.windows.net/$ContainerName" --recursive=true --delete-destination=true
    azcopy set-properties "https://$StorageAccountName.blob.core.windows.net/$ContainerName" --block-blob-tier=Cold --recursive=true
} else {
    Write-Warning "AzCopy is not available; using Azure CLI upload fallback. Prefer AzCopy for large sites or many files."
    az storage blob delete-batch --account-name $StorageAccountName --source $ContainerName --auth-mode login --output none
    az storage blob upload-batch --account-name $StorageAccountName --destination $ContainerName --source $ContentDir --auth-mode login --overwrite true --tier Cold --output none
}

Write-Host "DONE"
Write-Host "URL: $PublicBaseUrl"

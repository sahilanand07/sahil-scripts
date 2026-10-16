# ============================================================================
# CREATE ADVANCED CATALOG TILE (DYNAMIC SIZING, TAGS, & METADATA)
# ============================================================================
# Working lab script. Only change from the original: URL/token from environment
# variables, SSL bypass is opt-in, and the catalog item name is a variable.
# Bash version: create-catalog-tile.sh

# Connection details come from the environment (never commit a real token):
#   $env:MORPHEUS_URL = 'https://vme-manager.example.local'
#   $env:MORPHEUS_TOKEN = '<api token>'
#   $env:MORPHEUS_SKIP_TLS_VERIFY = 'true'   # lab appliance with a self-signed certificate

# ----------------------------------------------------------------------------
# SSL / TLS certificate handling
# ----------------------------------------------------------------------------
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
if ($env:MORPHEUS_SKIP_TLS_VERIFY -match '^(1|true|yes)$') {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PowerShell 7: the ServicePointManager callback is ignored; use the cmdlet switch instead
        $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
    } else {
        # Windows PowerShell 5.1: bypass certificate validation for self-signed lab certificates
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    Write-Host 'SSL certificate errors are being ignored (lab mode).' -ForegroundColor Yellow
}

# Standard variables
$GroupId = 3
$CloudId = 1
$LayoutId = 32
$ImageId = 194
$NetworkId = 1
$ResourcePoolId = "pool-1"
$CatalogName = "Advanced VM (Self-Service)"

$Script:MorpheusBaseUrl = ([string]$env:MORPHEUS_URL).TrimEnd('/')
$Script:MorpheusToken   = $env:MORPHEUS_TOKEN
if (-not $Script:MorpheusBaseUrl -or -not $Script:MorpheusToken) { throw 'Set $env:MORPHEUS_URL and $env:MORPHEUS_TOKEN first.' }

function Invoke-MorpheusApi {
    param([string]$Method, [string]$Path, [hashtable]$Body)
    $uri = "$($Script:MorpheusBaseUrl)$Path"
    $headers = @{ Authorization = "Bearer $($Script:MorpheusToken)"; Accept = "application/json" }
    
    $json = if ($Body) { $Body | ConvertTo-Json -Depth 20 } else { $null }
    
    try {
        if ($json) {
            # Removed -SkipCertificateCheck for PS 5.1 compatibility
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body $json
        } else {
            # Removed -SkipCertificateCheck for PS 5.1 compatibility
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        }
    } catch {
        if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            Write-Error "API Error on $Path : $($reader.ReadToEnd())"
        } else {
            Write-Error "API Error on $Path : $($_.Exception.Message)"
        }
        throw
    }
}

Write-Host "Building Advanced Form Fields..." -ForegroundColor Cyan

# 1. VM Name
$nameRes = Invoke-MorpheusApi -Method Post -Path '/api/library/option-types' -Body @{ optionType = @{ name = "Cat - VM Name"; fieldName = "customVmName"; type = "text"; fieldLabel = "Server Name"; required = $true; exportMeta = $true } }
$nameId = $nameRes.optionType.id

# 2. Description (Text Area)
$descRes = Invoke-MorpheusApi -Method Post -Path '/api/library/option-types' -Body @{ optionType = @{ name = "Cat - Description"; fieldName = "customDesc"; type = "textarea"; fieldLabel = "Purpose / Description"; required = $false; exportMeta = $true } }
$descId = $descRes.optionType.id

# 3. Plan Selection
$planListRes = Invoke-MorpheusApi -Method Post -Path '/api/library/option-type-lists' -Body @{ optionTypeList = @{ name = "Plan Sizes"; type = "manual"; initialDataset = '[{"name":"Standard Sizing (Plan 25)","value":25},{"name":"Performance Sizing (Plan 26)","value":26}]' } }
$planRes = Invoke-MorpheusApi -Method Post -Path '/api/library/option-types' -Body @{ optionType = @{ name = "Cat - Plan"; fieldName = "customPlan"; type = "select"; fieldLabel = "Server Plan Size"; required = $true; exportMeta = $true; optionList = @{ id = $planListRes.optionTypeList.id } } }
$planId = $planRes.optionType.id

# 4. Disk Size
$diskRes = Invoke-MorpheusApi -Method Post -Path '/api/library/option-types' -Body @{ optionType = @{ name = "Cat - Disk"; fieldName = "customDiskSize"; type = "number"; fieldLabel = "Root Disk Size (GB)"; defaultValue = "40"; required = $true; exportMeta = $true } }
$diskId = $diskRes.optionType.id

# 5. Cost Center Tag
$costRes = Invoke-MorpheusApi -Method Post -Path '/api/library/option-types' -Body @{ optionType = @{ name = "Cat - Cost Center"; fieldName = "customCostCenter"; type = "text"; fieldLabel = "Cost Center Tag"; required = $true; exportMeta = $true } }
$costId = $costRes.optionType.id

# 6. Department Tag
$deptRes = Invoke-MorpheusApi -Method Post -Path '/api/library/option-types' -Body @{ optionType = @{ name = "Cat - Department"; fieldName = "customDept"; type = "text"; fieldLabel = "Department Tag"; required = $true; exportMeta = $true } }
$deptId = $deptRes.optionType.id

Write-Host "-> Success! Form Fields created." -ForegroundColor Green

# ----------------------------------------------------------------------------
# Create the Advanced Catalog Tile
# ----------------------------------------------------------------------------
Write-Host "`nCreating Advanced Catalog Item..." -ForegroundColor Cyan

$catalogBody = @{
    catalogItemType = @{
        name        = $CatalogName
        code        = "adv-vm-$((Get-Random -Maximum 9999))"
        description = "Provision a highly customizable VM with metadata and strict tagging."
        type        = "instance" 
        enabled     = $true
        featured    = $true
        
        # Attach all 6 form fields in the exact order you want them to appear in the UI
        optionTypes = @( $nameId, $descId, $planId, $diskId, $costId, $deptId )
        
        config = @{
            plan        = @{ id = "<%= customOptions.customPlan %>" }
            servicePlan = @{ id = "<%= customOptions.customPlan %>" }
            layout      = @{ id = $LayoutId }
            group       = @{ id = $GroupId }
            zoneId      = $CloudId

            instance = @{
                name         = "<%= customOptions.customVmName %>"
                description  = "<%= customOptions.customDesc %>"    
                type         = "mvm"
                site         = @{ id = $GroupId }
                layout       = @{ id = $LayoutId }
                plan         = @{ id = "<%= customOptions.customPlan %>" }
            }
            config = @{
                imageId          = $ImageId
                resourcePoolId   = $ResourcePoolId
                poolProviderType = "mvm"
                createUser       = $true
            }
            volumes = @(
                @{ id = -1; rootVolume = $true; name = "root"; size = "<%= customOptions.customDiskSize %>"; storageType = 1; datastoreId = 6 }
            )
            networkInterfaces = @(
                @{ network = @{ id = $NetworkId } }
            )
            tags = @(
                @{ name = 'CostCenter';  value = "<%= customOptions.customCostCenter %>" },
                @{ name = 'Department';  value = "<%= customOptions.customDept %>" },
                @{ name = 'Environment'; value = "Production" },     
                @{ name = 'ManagedBy';   value = "Self-Service" }
            )
        }
    }
}

$catalogResponse = Invoke-MorpheusApi -Method Post -Path '/api/catalog-item-types' -Body $catalogBody
$catalogItemId = $catalogResponse.catalogItemType.id

Write-Host "-> Success! Catalog Item created with ID: $catalogItemId" -ForegroundColor Magenta
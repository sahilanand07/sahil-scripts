#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a self-service VM catalog item (with its form inputs) on HPE Morpheus Enterprise /
    HPE VM Essentials (VME) Manager.

.DESCRIPTION
    Builds, in this order:

      1. Pre-checks every ID you pass (group, cloud, layout, image, network, resource pool,
         datastore, service plans) and prints what each one is - nothing is created if one is wrong.
      2. Option list  - a manual list of the service plans users may pick.
      3. Inputs       - VM name, description, plan (select), root disk size, cost center, department.
      4. Catalog item - an "instance" item whose provisioning config uses those inputs,
                        and tags the VM with CostCenter / Department plus any static tags.

    Every step is "get or create": re-running with the same names reuses what already exists.
    Use -Update to push changed settings (config, plan list) into an existing catalog item.

    Credentials are read from environment variables, never from the script:
      MORPHEUS_URL               e.g. https://vme-manager.example.local
      MORPHEUS_TOKEN             API access token
      MORPHEUS_SKIP_TLS_VERIFY   optional; true = ignore SSL certificate errors (lab appliances)

.EXAMPLE
    $env:MORPHEUS_URL = 'https://vme-manager.example.local'
    $env:MORPHEUS_TOKEN = '<token>'
    ./New-MorpheusCatalogItem.ps1 -Name 'Linux VM (Self-Service)' -GroupId 3 -CloudId 1 -LayoutId 32 `
        -ImageId 194 -NetworkId 1 -ResourcePoolId pool-1 -DatastoreId 6 -PlanIds 25,26 -SkipCertificateCheck -DryRun

.NOTES
    Runs on Windows PowerShell 5.1 and PowerShell 7+. Not an official HPE tool - test in a lab first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
    [ValidatePattern('^[a-z0-9-]*$')][string]$Code,
    [string]$Description = 'Provision a customizable VM with metadata and mandatory cost tagging.',
    [string]$Category,
    [ValidateSet('private', 'public')][string]$Visibility = 'private',
    [switch]$NotFeatured,

    [Parameter(Mandatory)][long]$GroupId,
    [Parameter(Mandatory)][long]$CloudId,
    [Parameter(Mandatory)][long]$LayoutId,
    [Parameter(Mandatory)][long]$ImageId,
    [Parameter(Mandatory)][long]$NetworkId,
    [Parameter(Mandatory)][ValidatePattern('^(pool-)?\d+$')][string]$ResourcePoolId,
    [Parameter(Mandatory)][ValidatePattern('^(\d+|auto|autoCluster)$')][string]$DatastoreId,
    [Parameter(Mandatory)][string[]]$PlanIds,
    [long]$StorageTypeId = 1,
    [string]$InstanceTypeCode = 'mvm',
    [string]$PoolProviderType = 'mvm',

    [ValidateRange(1, 65536)][int]$DefaultDiskSizeGB = 40,
    [hashtable]$Tags = @{ Environment = 'Production'; ManagedBy = 'Self-Service' },
    [string]$InputPrefix = 'Cat',
    [switch]$ExportInputsAsTags,

    [switch]$Update,
    [switch]$SkipCertificateCheck,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    [ok] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Warn([string]$Text) { Write-Host "    [warn] $Text" -ForegroundColor Yellow }
function Write-Done([string]$Done, [string]$Planned) {
    if ($DryRun) { Write-Host "    [plan] $Planned" -ForegroundColor DarkGray } else { Write-Ok $Done }
}
function Format-Id($Id) { if ($Id) { "ID $Id" } else { 'new' } }
function Hide-Secret([string]$Json) {
    return ($Json -replace '"password"\s*:\s*"(?:[^"\\]|\\.)*"', '"password":"********"')
}

# ---------------------------------------------------------------------------
# SSL / TLS certificate handling
# ---------------------------------------------------------------------------
# Lab appliances usually present a self-signed certificate, which makes every API call fail with
# "The SSL connection could not be established" / "Could not establish trust relationship".
# Certificate errors are ignored ONLY when you ask for it:
#   -SkipCertificateCheck                    on the command line, or
#   MORPHEUS_SKIP_TLS_VERIFY=true            in the environment / .env file.
# Windows PowerShell 5.1 and PowerShell 7 need different mechanisms, so both are handled here.
# Never use this against production appliances - it disables protection against impersonation.
$script:RestOptions = @{}

function Initialize-TlsSettings([bool]$IgnoreCertificateErrors) {
    if ($PSVersionTable.PSEdition -ne 'Core') {
        # Windows PowerShell 5.1 may default to TLS 1.0/1.1, which current appliances reject.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    if (-not $IgnoreCertificateErrors) { return }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PowerShell 7: per-request switch. ServicePointManager callbacks have no effect here.
        $script:RestOptions['SkipCertificateCheck'] = $true
    } else {
        # Windows PowerShell 5.1: process-wide policy. A compiled class is used instead of a
        # scriptblock callback, which can fail when .NET calls it on a background thread.
        if (-not ('MorpheusTrustAllCertsPolicy' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class MorpheusTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest request, int problem) { return true; }
}
'@
        }
        [Net.ServicePointManager]::CertificatePolicy = New-Object MorpheusTrustAllCertsPolicy
    }
    Write-Warn 'SSL certificate errors are being IGNORED (lab mode). Do not use this against production.'
}

# ---------------------------------------------------------------------------
# API helper
# ---------------------------------------------------------------------------
function ConvertTo-QueryString([hashtable]$Query) {
    if (-not $Query -or $Query.Count -eq 0) { return '' }
    $pairs = foreach ($key in ($Query.Keys | Sort-Object)) {
        '{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$Query[$key])
    }
    return '?' + ($pairs -join '&')
}

function Invoke-MorpheusApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [object]$Body
    )
    $uri  = $script:BaseUrl + $Path + (ConvertTo-QueryString $Query)
    $json = $null
    if ($null -ne $Body) { $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }

    if ($Method -ne 'GET' -and $DryRun) {
        Write-Host "    [dry-run] $Method $Path" -ForegroundColor DarkGray
        if ($json) { Write-Host "              $(Hide-Secret $json)" -ForegroundColor DarkGray }
        return $null
    }

    $request = @{ Method = $Method; Uri = $uri; Headers = $script:Headers; ErrorAction = 'Stop' }
    foreach ($key in $script:RestOptions.Keys) { $request[$key] = $script:RestOptions[$key] }
    if ($json) {
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }

    try {
        $response = Invoke-RestMethod @request
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        try { $detail = $detail | ConvertFrom-Json -ErrorAction Stop | ConvertTo-Json -Depth 10 -Compress } catch { }
        if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + '...' }
        if ($detail -match 'SSL|TLS|trust relationship|certificate') {
            $detail += ' -> If the appliance uses a self-signed certificate, add -SkipCertificateCheck or set MORPHEUS_SKIP_TLS_VERIFY=true.'
        }
        $statusText = ''
        if ($status) { $statusText = " (HTTP $status)" }
        throw "API $Method $Path failed${statusText}: $(Hide-Secret $detail)"
    }
    if ($response -and ($response.PSObject.Properties.Name -contains 'success') -and $response.success -eq $false) {
        throw "API $Method $Path was rejected: $(Hide-Secret ($response | ConvertTo-Json -Depth 10 -Compress))"
    }
    return $response
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
function Find-ByName($Items, [string]$Property, [string]$Value) {
    return @($Items) | Where-Object { $_ -and $_.$Property -and [string]$_.$Property -eq $Value } | Select-Object -First 1
}

function ConvertTo-IdList([string[]]$Values, [string]$ParamName) {
    $ids = foreach ($value in $Values) {
        foreach ($part in ($value -split '[,\s]+')) {
            if (-not $part) { continue }
            if ($part -notmatch '^\d+$') { throw "$ParamName must be numeric IDs separated by commas (got '$part')." }
            [long]$part
        }
    }
    return @($ids | Select-Object -Unique)
}

function Get-MorpheusObject([string]$Label, [string]$Path, [string]$Key) {
    $object = (Invoke-MorpheusApi -Method GET -Path $Path).$Key
    if (-not $object) { throw "$Label was not found ($Path)." }
    return $object
}

# get-or-create for an input (option type). Returns its ID (0 in a dry run when it would be created).
function Resolve-Input([hashtable]$Spec) {
    $existing = Find-ByName (Invoke-MorpheusApi -Method GET -Path '/api/library/option-types' -Query @{ name = $Spec.name; max = 1000 }).optionTypes 'name' $Spec.name
    if ($existing) {
        if ($existing.fieldName -ne $Spec.fieldName) {
            throw "Input '$($Spec.name)' already exists with field name '$($existing.fieldName)', but this catalog item needs '$($Spec.fieldName)'. Rename it or use -InputPrefix."
        }
        if ($existing.type -ne $Spec.type) { Write-Warn "Input '$($Spec.name)' is type '$($existing.type)', expected '$($Spec.type)'. Left unchanged." }
        Write-Ok "Input '$($Spec.name)' exists (ID $($existing.id))"
        return [long]$existing.id
    }
    $res = Invoke-MorpheusApi -Method POST -Path '/api/library/option-types' -Body @{ optionType = $Spec }
    $id = 0
    if ($res) { $id = [long]$res.optionType.id }
    Write-Done "Created input '$($Spec.name)' (ID $id)" "Would create input '$($Spec.name)' [$($Spec.type)]"
    return $id
}

$summary = [ordered]@{}

try {
    # -----------------------------------------------------------------------
    # Validate inputs and environment
    # -----------------------------------------------------------------------
    $script:BaseUrl = ([string]$env:MORPHEUS_URL).TrimEnd('/')
    if (-not $script:BaseUrl) { throw 'Set MORPHEUS_URL (e.g. https://vme-manager.example.local).' }
    if ($script:BaseUrl -notmatch '^https://') { Write-Warn 'MORPHEUS_URL is not https:// - the API token will be sent unencrypted.' }
    if (-not $env:MORPHEUS_TOKEN) { throw 'Set MORPHEUS_TOKEN to your Morpheus API access token.' }
    $script:Headers = @{ Authorization = "Bearer $($env:MORPHEUS_TOKEN)"; Accept = 'application/json' }

    $ignoreTls = $SkipCertificateCheck.IsPresent -or ([string]$env:MORPHEUS_SKIP_TLS_VERIFY -match '^(1|true|yes)$')
    Initialize-TlsSettings $ignoreTls

    if ($PSVersionTable.PSEdition -ne 'Core') {
        # Windows PowerShell 5.1 otherwise serializes some arrays as {"value":[...],"Count":n}
        Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
    }

    $planIdList = ConvertTo-IdList $PlanIds '-PlanIds'
    if ($planIdList.Count -eq 0) { throw '-PlanIds needs at least one service plan ID.' }
    if (-not $Code) { $Code = (($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) }
    if (-not $Code) { throw 'Could not derive a code from -Name; pass -Code.' }
    $poolNumber = [long]($ResourcePoolId -replace '^pool-', '')
    $poolRef = "pool-$poolNumber"

    if ($DryRun) { Write-Host "`nDRY RUN - lookups are real, nothing will be created or changed." -ForegroundColor Magenta }

    # -----------------------------------------------------------------------
    # 1. Check every referenced ID (read-only)
    # -----------------------------------------------------------------------
    Write-Step 'Checking the IDs this catalog item will use'
    $whoami = Invoke-MorpheusApi -Method GET -Path '/api/whoami'
    Write-Ok "Connected as '$($whoami.user.username)'"

    $cloud = Get-MorpheusObject "Cloud ID $CloudId" "/api/zones/$CloudId" 'zone'
    Write-Ok "Cloud        $CloudId = '$($cloud.name)'"

    $group = Get-MorpheusObject "Group ID $GroupId" "/api/groups/$GroupId" 'group'
    $groupCloudIds = @(@($group.zones) | Where-Object { $_ } | ForEach-Object { [long]$_.id })
    if ($groupCloudIds -notcontains $CloudId) { throw "Group '$($group.name)' does not contain cloud '$($cloud.name)'. Add the cloud to the group first." }
    Write-Ok "Group        $GroupId = '$($group.name)' (contains the cloud)"

    $layout = Get-MorpheusObject "Layout ID $LayoutId" "/api/library/layouts/$LayoutId" 'instanceTypeLayout'
    $layoutTypeCode = $null
    if ($layout.instanceType -and $layout.instanceType.code) { $layoutTypeCode = [string]$layout.instanceType.code }
    if ($layoutTypeCode -and $layoutTypeCode -ne $InstanceTypeCode) {
        Write-Warn "Layout belongs to instance type '$layoutTypeCode', but the config will use '$InstanceTypeCode'. Pass -InstanceTypeCode $layoutTypeCode if ordering fails."
    }
    Write-Ok "Layout       $LayoutId = '$($layout.name)' (instance type '$InstanceTypeCode')"

    $image = Get-MorpheusObject "Image ID $ImageId" "/api/virtual-images/$ImageId" 'virtualImage'
    Write-Ok "Image        $ImageId = '$($image.name)'"

    $network = Get-MorpheusObject "Network ID $NetworkId" "/api/networks/$NetworkId" 'network'
    Write-Ok "Network      $NetworkId = '$($network.name)'"

    $pool = Get-MorpheusObject "Resource pool $poolRef" "/api/zones/$CloudId/resource-pools/$poolNumber" 'resourcePool'
    Write-Ok "Pool         $poolRef = '$($pool.name)'"

    if ($DatastoreId -match '^\d+$') {
        $datastore = Get-MorpheusObject "Datastore ID $DatastoreId" "/api/zones/$CloudId/data-stores/$DatastoreId" 'datastore'
        Write-Ok "Datastore    $DatastoreId = '$($datastore.name)'"
    } else {
        Write-Ok "Datastore    $DatastoreId (selected automatically at provision time)"
    }

    $planChoices = foreach ($planId in $planIdList) {
        $plan = Get-MorpheusObject "Service plan ID $planId" "/api/service-plans/$planId" 'servicePlan'
        Write-Ok "Plan         $planId = '$($plan.name)'"
        [ordered]@{ name = [string]$plan.name; value = $planId }
    }

    # Inputs that already exist must use the field names the config refers to - check before creating anything.
    $inputFields = [ordered]@{ 'VM Name' = 'customVmName'; 'Description' = 'customDesc'; 'Plan' = 'customPlan'
                               'Disk' = 'customDiskSize'; 'Cost Center' = 'customCostCenter'; 'Department' = 'customDept' }
    foreach ($label in $inputFields.Keys) {
        $inputName = "$InputPrefix - $label"
        $found = Find-ByName (Invoke-MorpheusApi -Method GET -Path '/api/library/option-types' -Query @{ name = $inputName; max = 1000 }).optionTypes 'name' $inputName
        if ($found -and $found.fieldName -ne $inputFields[$label]) {
            throw "Input '$inputName' already exists with field name '$($found.fieldName)', but this catalog item needs '$($inputFields[$label])'. Rename it or use -InputPrefix."
        }
    }
    Write-Ok "Input names are free or compatible (prefix '$InputPrefix')"

    # -----------------------------------------------------------------------
    # 2. Option list with the allowed plans
    # -----------------------------------------------------------------------
    $listName = "$InputPrefix - Plan Sizes"
    Write-Step "Option list '$listName'"
    $dataset = ConvertTo-Json -InputObject @($planChoices) -Depth 5 -Compress
    $planList = Find-ByName (Invoke-MorpheusApi -Method GET -Path '/api/library/option-type-lists' -Query @{ name = $listName; max = 1000 }).optionTypeLists 'name' $listName
    if ($planList) {
        $planListId = [long]$planList.id
        if ($Update) {
            Invoke-MorpheusApi -Method PUT -Path "/api/library/option-type-lists/$planListId" -Body @{ optionTypeList = @{ initialDataset = $dataset } } | Out-Null
            Write-Done "Updated plan choices in option list (ID $planListId)" "Would update the plan choices in option list (ID $planListId)"
        } else {
            Write-Ok "Option list exists (ID $planListId) - plan choices left unchanged (use -Update to refresh them)"
        }
    } else {
        $res = Invoke-MorpheusApi -Method POST -Path '/api/library/option-type-lists' -Body @{ optionTypeList = @{
            name = $listName; description = 'Service plans offered in the self-service catalog'; type = 'manual'; initialDataset = $dataset
        } }
        $planListId = 0
        if ($res) { $planListId = [long]$res.optionTypeList.id }
        Write-Done "Created option list (ID $planListId)" "Would create option list with $($planIdList.Count) plan(s)"
    }

    # -----------------------------------------------------------------------
    # 3. Inputs (the order here is the order on the order form)
    # -----------------------------------------------------------------------
    Write-Step 'Form inputs'
    $exportMeta = $ExportInputsAsTags.IsPresent
    $inputSpecs = @(
        @{ name = "$InputPrefix - VM Name";     fieldName = 'customVmName';     type = 'text';     fieldLabel = 'Server Name';           required = $true;  exportMeta = $exportMeta
           verifyPattern = '^[a-zA-Z][a-zA-Z0-9-]{0,62}$'; placeHolder = 'e.g. app-web-01' },
        @{ name = "$InputPrefix - Description"; fieldName = 'customDesc';       type = 'textarea'; fieldLabel = 'Purpose / Description'; required = $false; exportMeta = $exportMeta },
        @{ name = "$InputPrefix - Plan";        fieldName = 'customPlan';       type = 'select';   fieldLabel = 'Server Plan Size';      required = $true;  exportMeta = $exportMeta
           optionList = @{ id = $planListId } },
        @{ name = "$InputPrefix - Disk";        fieldName = 'customDiskSize';   type = 'number';   fieldLabel = 'Root Disk Size (GB)';   required = $true;  exportMeta = $exportMeta
           defaultValue = [string]$DefaultDiskSizeGB },
        @{ name = "$InputPrefix - Cost Center"; fieldName = 'customCostCenter'; type = 'text';     fieldLabel = 'Cost Center Tag';       required = $true;  exportMeta = $exportMeta },
        @{ name = "$InputPrefix - Department";  fieldName = 'customDept';       type = 'text';     fieldLabel = 'Department Tag';        required = $true;  exportMeta = $exportMeta }
    )
    $inputIds = @(foreach ($spec in $inputSpecs) { Resolve-Input $spec })

    # -----------------------------------------------------------------------
    # 4. Catalog item
    # -----------------------------------------------------------------------
    Write-Step "Catalog item '$Name'"
    $tagList = @(
        @{ name = 'CostCenter'; value = '<%= customOptions.customCostCenter %>' },
        @{ name = 'Department'; value = '<%= customOptions.customDept %>' }
    )
    foreach ($key in ($Tags.Keys | Sort-Object)) { $tagList += @{ name = [string]$key; value = [string]$Tags[$key] } }

    $datastoreValue = $DatastoreId
    if ($DatastoreId -match '^\d+$') { $datastoreValue = [long]$DatastoreId }

    # Provisioning config - same structure as the lab script proven on a VME appliance
    # (examples/create-catalog-tile.ps1). <%= customOptions.<fieldName> %> is replaced with
    # what the user entered on the order form when the item is ordered.
    $config = [ordered]@{
        plan        = @{ id = '<%= customOptions.customPlan %>' }
        servicePlan = @{ id = '<%= customOptions.customPlan %>' }
        layout      = @{ id = $LayoutId }
        group       = @{ id = $GroupId }
        zoneId      = $CloudId
        instance    = [ordered]@{
            name        = '<%= customOptions.customVmName %>'
            description = '<%= customOptions.customDesc %>'
            type        = $InstanceTypeCode
            site        = @{ id = $GroupId }
            layout      = @{ id = $LayoutId }
            plan        = @{ id = '<%= customOptions.customPlan %>' }
        }
        config      = [ordered]@{ imageId = $ImageId; resourcePoolId = $poolRef; poolProviderType = $PoolProviderType; createUser = $true }
        volumes     = @( [ordered]@{ id = -1; rootVolume = $true; name = 'root'; size = '<%= customOptions.customDiskSize %>'; storageType = $StorageTypeId; datastoreId = $datastoreValue } )
        networkInterfaces = @( @{ network = @{ id = $NetworkId } } )
        tags        = $tagList
    }
    $itemBody = [ordered]@{
        name        = $Name
        code        = $Code
        description = $Description
        type        = 'instance'
        visibility  = $Visibility
        enabled     = $true
        featured    = (-not $NotFeatured.IsPresent)
        formType    = 'optionTypes'
        optionTypes = $inputIds
        config      = $config
    }
    if ($Category) { $itemBody.category = $Category }

    $existingItem = Find-ByName (Invoke-MorpheusApi -Method GET -Path '/api/catalog-item-types' -Query @{ name = $Name; max = 1000 }).catalogItemTypes 'name' $Name
    if ($existingItem) {
        $itemId = [long]$existingItem.id
        if ($Update) {
            Invoke-MorpheusApi -Method PUT -Path "/api/catalog-item-types/$itemId" -Body @{ catalogItemType = $itemBody } | Out-Null
            Write-Done "Updated catalog item (ID $itemId)" "Would update catalog item (ID $itemId) with the settings above"
        } else {
            Write-Ok "Catalog item exists (ID $itemId) - left unchanged (use -Update to apply new settings)"
        }
    } else {
        $res = Invoke-MorpheusApi -Method POST -Path '/api/catalog-item-types' -Body @{ catalogItemType = $itemBody }
        $itemId = 0
        if ($res) { $itemId = [long]$res.catalogItemType.id }
        Write-Done "Created catalog item (ID $itemId)" 'Would create the catalog item'
    }

    $summary['Catalog item'] = "$Name ($(Format-Id $itemId)), code '$Code'"
    $summary['Inputs']       = ($inputIds | ForEach-Object { Format-Id $_ }) -join ', '
    $summary['Plan list']    = "$listName ($(Format-Id $planListId))"
    $summary['Tags']         = ($tagList | ForEach-Object { $_.name }) -join ', '

    Write-Host "`n================================================================" -ForegroundColor Cyan
    if ($DryRun) { Write-Host ' DRY RUN COMPLETE - nothing was changed' -ForegroundColor Green }
    else { Write-Host ' CATALOG ITEM READY' -ForegroundColor Green }
    foreach ($key in $summary.Keys) { Write-Host (" {0,-13} {1}" -f "${key}:", $summary[$key]) }
    Write-Host ' Find it:      Library > Blueprints > Catalog Items; order it from Provisioning > Catalog'
    Write-Host '================================================================' -ForegroundColor Cyan
}
catch {
    Write-Host "`n[error] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '        Fix the cause and re-run with the same parameters; completed steps are reused.' -ForegroundColor Red
    exit 1
}

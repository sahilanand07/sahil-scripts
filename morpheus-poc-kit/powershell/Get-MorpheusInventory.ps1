#Requires -Version 7.0
<#
.SYNOPSIS
    Reads everything a PoC config refers to from an HPE Morpheus / VME Manager appliance and writes it
    to disk. Changes nothing on the appliance.

.DESCRIPTION
    Output, in a new folder under -OutDir (default .\inventory):

      summary.txt          tables: clouds with their resource pools, datastores and networks (with
                           visibility and which tenants they are shared with), tenants, groups, roles,
                           feature-permission codes, layouts, images, plans, policy types, and existing
                           option lists, inputs, catalog items, blueprints and policies
      inventory.json       the same data as JSON
      starter-config.json  a customer config pre-filled with real names from this appliance
      blueprints\NAME.json (with -ExportBlueprint NAME) a blueprint config usable as catalog.threeTier.templateFile

    Environment: MORPHEUS_URL, MORPHEUS_TOKEN (master-tenant admin), MORPHEUS_SKIP_TLS_VERIFY.

.EXAMPLE
    ./Get-MorpheusInventory.ps1 -SkipCertificateCheck
.EXAMPLE
    ./Get-MorpheusInventory.ps1 -ExportBlueprint '3-Tier Lab' -OutDir ./inventory
#>
[CmdletBinding()]
param(
    [string]$OutDir = './inventory',
    [string[]]$ExportBlueprint = @(),
    [string]$PermissionsFrom = 'Tenant Admin',
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorpheusPoc.psm1') -Force

function Get-AllItems([string]$Path, [string]$Key, [hashtable]$Query = @{}) {
    $q = @{ max = 1000 } + $Query
    $res = Invoke-MorpheusApi -Method GET -Path $Path -Query $q
    $items = @(Get-List $res $Key)
    $meta = Get-Prop $res 'meta'
    $total = Get-Prop $meta 'total'
    if ($total -and [long]$total -gt $items.Count) { Write-Warn "${Path}: only the first $($items.Count) of $total items were read." }
    return @{ Items = $items; Response = $res }
}

function Get-TenantNames($Object, $Map) {
    $names = @()
    foreach ($t in @(Get-Prop $Object 'tenants') + @(Get-Prop $Map ([string]$Object.id))) {
        if ($t) { $names += $(if (Get-Prop $t 'name') { [string]$t.name } else { [string]$t.id }) }
    }
    return @($names | Sort-Object -Unique)
}

# Format-Section TITLE HEADERS ITEMS PROJECTION -> aligned text lines (PROJECTION turns one item into its cells)
function Format-Section([string]$Title, [string[]]$Headers, $Items, [scriptblock]$Projection) {
    $rows = [System.Collections.Generic.List[string[]]]::new()
    $rows.Add($Headers)
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $rows.Add([string[]]@(& $Projection $item | ForEach-Object { [string]$_ }))
    }
    $widths = @(0) * $Headers.Count
    foreach ($r in $rows) { for ($i = 0; $i -lt $r.Count; $i++) { if ($r[$i].Length -gt $widths[$i]) { $widths[$i] = $r[$i].Length } } }
    $lines = @('', "## $Title")
    foreach ($r in $rows) {
        $line = ''
        for ($i = 0; $i -lt $r.Count; $i++) { $line += $r[$i].PadRight($widths[$i] + 2) }
        $lines += $line.TrimEnd()
    }
    return $lines
}

try {
    $baseUrl = Initialize-MorpheusSession -SkipCertificateCheck:$SkipCertificateCheck

    Write-Step "Reading from $baseUrl"
    $whoami = Invoke-MorpheusApi -Method GET -Path '/api/whoami'
    if (-not $whoami.isMasterAccount) { throw 'The token must belong to a master-tenant user (the inventory reads every tenant).' }
    Write-Ok "Connected as '$($whoami.user.username)'"

    $inv = [ordered]@{
        appliance    = $baseUrl
        readAt       = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        user         = $whoami.user.username
        masterTenant = $(if (Get-Prop $whoami.user 'account') { $whoami.user.account } else { @{ id = $whoami.user.accountId } })
    }

    $inv.tenants = @((Get-AllItems '/api/accounts' 'accounts').Items | ForEach-Object {
        $role = Get-Prop $_ 'role'
        [ordered]@{ id = $_.id; name = $_.name; subdomain = (Get-Prop $_ 'subdomain'); baseRole = $(if ($role) { (Get-Prop $role 'authority') ?? (Get-Prop $role 'name') } else { $null }) }
    })
    Write-Ok "Tenants: $($inv.tenants.Count)"

    $clouds = @()
    foreach ($z in (Get-AllItems '/api/zones' 'zones').Items) {
        $pools = Get-AllItems "/api/zones/$($z.id)/resource-pools" 'resourcePools'
        $dss = Get-AllItems "/api/zones/$($z.id)/data-stores" 'datastores'
        $nets = Get-AllItems '/api/networks' 'networks' @{ zoneId = $z.id }
        $poolMap = Get-Prop $pools.Response 'tenants'
        $dsMap = Get-Prop $dss.Response 'tenants'
        $zt = Get-Prop $z 'zoneType'
        $acct = Get-Prop $z 'account'
        $clouds += [ordered]@{
            id = $z.id; name = $z.name; type = $(if ($zt) { (Get-Prop $zt 'code') ?? (Get-Prop $zt 'name') } else { $null })
            visibility = (Get-Prop $z 'visibility')
            ownerTenant = $(if ($acct) { Get-Prop $acct 'name' } else { $null })
            ownerTenantId = (Get-OwnerId $z)
            resourcePools = @($pools.Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; poolRef = "pool-$($_.id)"; visibility = (Get-Prop $_ 'visibility'); sharedWith = @(Get-TenantNames $_ $poolMap) } })
            datastores    = @($dss.Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; visibility = (Get-Prop $_ 'visibility'); sharedWith = @(Get-TenantNames $_ $dsMap) } })
            networks      = @($nets.Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; visibility = (Get-Prop $_ 'visibility'); sharedWith = @(Get-TenantNames $_ $null) } })
        }
    }
    $inv.clouds = $clouds
    Write-Ok "Clouds: $($clouds.Count)"

    $inv.groups = @((Get-AllItems '/api/groups' 'groups').Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; clouds = @(@(Get-Prop $_ 'zones') | Where-Object { $_ } | ForEach-Object { $_.name }) } })

    $inv.tenantRoles = @((Get-AllItems '/api/roles' 'roles' @{ roleType = 'account' }).Items | ForEach-Object { [ordered]@{ id = $_.id; name = (Get-Prop $_ 'authority') ?? (Get-Prop $_ 'name') } })
    $userRoles = (Get-AllItems '/api/roles' 'roles' @{ roleType = 'user' }).Items
    $inv.userRoles = @($userRoles | ForEach-Object { [ordered]@{ id = $_.id; name = (Get-Prop $_ 'authority') ?? (Get-Prop $_ 'name'); multitenant = [bool](Get-Prop $_ 'multitenant') } })
    $permRole = $userRoles | Where-Object { ((Get-Prop $_ 'authority') ?? (Get-Prop $_ 'name')) -ieq $PermissionsFrom } | Select-Object -First 1
    if (-not $permRole) { $permRole = $userRoles | Select-Object -First 1 }
    if ($permRole) {
        $full = Invoke-MorpheusApi -Method GET -Path "/api/roles/$($permRole.id)"
        $inv.featurePermissions = [ordered]@{
            fromRole = (Get-Prop $full.role 'authority') ?? (Get-Prop $full.role 'name')
            codes    = @(@(Get-Prop $full 'featurePermissions') | Where-Object { $_ } | ForEach-Object { [ordered]@{ code = $_.code; name = $_.name; access = $_.access } })
        }
        $inv.personas = @(@(Get-Prop $full 'personaPermissions') | Where-Object { $_ } | ForEach-Object { [ordered]@{ code = $_.code; name = $_.name } })
    }
    Write-Ok "Roles: $($inv.tenantRoles.Count) tenant, $($inv.userRoles.Count) user"

    $inv.instanceTypes = @((Get-AllItems '/api/library/instance-types' 'instanceTypes').Items | ForEach-Object { [ordered]@{ id = $_.id; code = $_.code; name = $_.name } })
    $inv.layouts = @((Get-AllItems '/api/library/layouts' 'instanceTypeLayouts').Items | ForEach-Object {
        $it = Get-Prop $_ 'instanceType'
        [ordered]@{ id = $_.id; name = $_.name; code = (Get-Prop $_ 'code'); instanceType = $(if ($it) { Get-Prop $it 'code' } else { $null }) } })
    $inv.images = @((Get-AllItems '/api/virtual-images' 'virtualImages').Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; visibility = (Get-Prop $_ 'visibility'); imageType = (Get-Prop $_ 'imageType') } })
    $inv.plans = @((Get-AllItems '/api/service-plans' 'servicePlans').Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; code = (Get-Prop $_ 'code') } })
    Write-Ok "Layouts: $($inv.layouts.Count), images: $($inv.images.Count), plans: $($inv.plans.Count)"

    $inv.policyTypes = @(Get-List (Invoke-MorpheusApi -Method GET -Path '/api/policy-types') 'policyTypes' | ForEach-Object { [ordered]@{ code = $_.code; name = $_.name } })
    $inv.policies = @((Get-AllItems '/api/policies' 'policies').Items | ForEach-Object {
        [ordered]@{ id = $_.id; name = $_.name; type = $_.policyType.code; scope = (Get-Prop $_ 'refType') ?? 'global'; enabled = (Get-Prop $_ 'enabled') } })
    $inv.optionLists = @((Get-AllItems '/api/library/option-type-lists' 'optionTypeLists').Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; type = (Get-Prop $_ 'type') } })
    $inv.inputs = @((Get-AllItems '/api/library/option-types' 'optionTypes').Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; fieldName = (Get-Prop $_ 'fieldName'); type = (Get-Prop $_ 'type') } })
    $inv.catalogItems = @((Get-AllItems '/api/catalog-item-types' 'catalogItemTypes').Items | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; type = (Get-Prop $_ 'type') } })
    $blueprints = (Get-AllItems '/api/blueprints' 'blueprints').Items
    $inv.blueprints = @($blueprints | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; type = (Get-Prop $_ 'type') } })
    Write-Ok "Policy types available: $(($inv.policyTypes | ForEach-Object { $_.code }) -join ', ')"

    # -----------------------------------------------------------------------
    # Output
    # -----------------------------------------------------------------------
    $hostName = ($baseUrl -replace '^https?://', '' -replace '[:/].*$', '')
    $dest = Join-Path $OutDir "$hostName-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    ConvertTo-Json -InputObject $inv -Depth 20 | Set-Content -LiteralPath (Join-Path $dest 'inventory.json') -Encoding utf8NoBOM

    function Get-Shared($o) { $s = ($o.sharedWith -join ', '); if ($s) { $s } else { '-' } }
    function Get-Or($v) { if ($null -ne $v -and "$v" -ne '') { $v } else { '-' } }
    $lines = @("Morpheus inventory - $baseUrl - read $($inv.readAt) as $($inv.user)")
    $lines += Format-Section 'Tenants' @('ID', 'Name', 'Subdomain', 'Base role') $inv.tenants { @($args[0].id, $args[0].name, (Get-Or $args[0].subdomain), (Get-Or $args[0].baseRole)) }
    foreach ($c in $inv.clouds) {
        $items = @($c.resourcePools | ForEach-Object { @{ k = 'resourcePool'; o = $_ } }) + @($c.datastores | ForEach-Object { @{ k = 'datastore'; o = $_ } }) + @($c.networks | ForEach-Object { @{ k = 'network'; o = $_ } })
        $lines += Format-Section "Cloud $($c.name) (ID $($c.id), $(Get-Or $c.type), $($c.visibility), owner $(Get-Or $c.ownerTenant))" @('Kind', 'ID', 'Name', 'Visibility', 'Shared with') $items { @($args[0].k, $args[0].o.id, $args[0].o.name, (Get-Or $args[0].o.visibility), (Get-Shared $args[0].o)) }
    }
    $lines += Format-Section 'Groups (master tenant)' @('ID', 'Name', 'Clouds') $inv.groups { @($args[0].id, $args[0].name, ($args[0].clouds -join ', ')) }
    $lines += Format-Section 'Tenant roles (copy-from templates for tenant.role.copyFrom)' @('ID', 'Name') $inv.tenantRoles { @($args[0].id, $args[0].name) }
    $lines += Format-Section 'User roles' @('ID', 'Name', 'Multitenant') $inv.userRoles { @($args[0].id, $args[0].name, $args[0].multitenant.ToString().ToLowerInvariant()) }
    if ($inv.Contains('featurePermissions')) {
        $lines += Format-Section "Feature-permission codes (for roles[].features) - from role $($inv.featurePermissions.fromRole)" @('Code', 'Name', 'Access in that role') $inv.featurePermissions.codes { @($args[0].code, $args[0].name, $args[0].access) }
    }
    $lines += Format-Section 'Instance types' @('ID', 'Code', 'Name') $inv.instanceTypes { @($args[0].id, $args[0].code, $args[0].name) }
    $lines += Format-Section 'Layouts' @('ID', 'Name', 'Instance type') $inv.layouts { @($args[0].id, $args[0].name, (Get-Or $args[0].instanceType)) }
    $lines += Format-Section 'Virtual images' @('ID', 'Name', 'Visibility', 'Type') $inv.images { @($args[0].id, $args[0].name, (Get-Or $args[0].visibility), (Get-Or $args[0].imageType)) }
    $lines += Format-Section 'Service plans' @('ID', 'Name', 'Code') $inv.plans { @($args[0].id, $args[0].name, (Get-Or $args[0].code)) }
    $lines += Format-Section 'Policy types available on this appliance' @('Code', 'Name') $inv.policyTypes { @($args[0].code, $args[0].name) }
    $lines += Format-Section 'Existing policies (master tenant)' @('ID', 'Name', 'Type', 'Scope') $inv.policies { @($args[0].id, $args[0].name, $args[0].type, $args[0].scope) }
    $lines += Format-Section 'Existing option lists' @('ID', 'Name', 'Type') $inv.optionLists { @($args[0].id, $args[0].name, (Get-Or $args[0].type)) }
    $lines += Format-Section 'Existing inputs' @('ID', 'Name', 'Field name', 'Type') $inv.inputs { @($args[0].id, $args[0].name, (Get-Or $args[0].fieldName), (Get-Or $args[0].type)) }
    $lines += Format-Section 'Existing catalog items' @('ID', 'Name', 'Type') $inv.catalogItems { @($args[0].id, $args[0].name, (Get-Or $args[0].type)) }
    $lines += Format-Section 'Existing blueprints' @('ID', 'Name', 'Type') $inv.blueprints { @($args[0].id, $args[0].name, (Get-Or $args[0].type)) }
    $lines += @('', 'Note: lists show what the master tenant sees. Images or plans that are Private are not visible to', 'sub-tenants unless they are shared.')
    $lines | Set-Content -LiteralPath (Join-Path $dest 'summary.txt') -Encoding utf8NoBOM

    # Starter config with real names from this appliance
    function First($a, $default) { $x = @($a | Where-Object { $_ }); if ($x.Count) { $x[0] } else { $default } }
    $placeholder = @{ name = 'CHANGE-ME'; resourcePools = @(); datastores = @(); networks = @() }
    $cloud = First ($inv.clouds | Where-Object { [string]$_.type -match 'mvm|hvm|kvm' }) (First $inv.clouds $placeholder)
    $pool = (First $cloud.resourcePools @{ name = 'CHANGE-ME' }).name
    $ds = (First $cloud.datastores @{ name = 'CHANGE-ME' }).name
    $net = (First $cloud.networks @{ name = 'CHANGE-ME' }).name
    $layout = (First ($inv.layouts | Where-Object { $_.instanceType -eq 'mvm' }) (First $inv.layouts @{ name = 'CHANGE-ME' })).name
    $image = (First ($inv.images | Where-Object { $_.visibility -eq 'public' }) (First $inv.images @{ name = 'CHANGE-ME' })).name
    $plans = @($inv.plans | Select-Object -First 2 | ForEach-Object { $_.name })
    if (-not $plans) { $plans = @('CHANGE-ME') }
    $starter = [ordered]@{
        tenant  = [ordered]@{ name = 'Customer'; subdomain = 'customer'; description = 'Customer PoC'; currency = 'USD'
                              role = [ordered]@{ name = 'Customer Tenant Role'; copyFrom = (First $inv.tenantRoles @{ name = 'Tenant Admin' }).name } }
        cloud   = [ordered]@{ name = $cloud.name; mode = 'shared'; share = [ordered]@{ resourcePools = @($pool); datastores = @($ds); networks = @($net) } }
        admin   = [ordered]@{ username = 'customer_admin'; email = 'admin@customer.example'; firstName = 'Customer'; lastName = 'Admin'; role = 'Tenant Admin'; roleCopyFrom = 'Tenant Admin' }
        groups  = @('Customer-Dev')
        roles   = @(
            [ordered]@{ name = 'Customer Approver'; copyFrom = 'Tenant Admin'; groups = 'all'; defaultPersona = 'standard'; features = [ordered]@{ 'operations-approvals' = 'full' }; catalogItems = 'all' },
            [ordered]@{ name = 'Customer Requester'; groups = @('Customer-Dev'); defaultPersona = 'serviceCatalog'
                        features = [ordered]@{ 'service-catalog' = 'full'; 'service-catalog-dashboard' = 'full'; 'service-catalog-inventory' = 'full' }; catalogItems = @('Linux VM', '3-Tier App') })
        users   = @(
            [ordered]@{ username = 'customer_approver'; email = 'approver@customer.example'; role = 'Customer Approver' },
            [ordered]@{ username = 'customer_dev1'; email = 'dev1@customer.example'; role = 'Customer Requester' })
        tags    = @([ordered]@{ name = 'Application'; values = @('App-1', 'App-2') }, [ordered]@{ name = 'CostCenter'; label = 'Cost Center'; values = @('CC-1001', 'CC-2002') })
        catalog = [ordered]@{
            inputPrefix = 'Customer'
            vm = [ordered]@{ name = 'Linux VM'; group = 'Customer-Dev'; layout = $layout; image = $image; network = $net; resourcePool = $pool; datastore = $ds
                             plans = $plans; defaultDiskGB = 40; staticTags = [ordered]@{ Environment = 'PoC'; ManagedBy = 'Self-Service' } }
            threeTier = [ordered]@{ name = '3-Tier App'; group = 'Customer-Dev'; network = $net; resourcePool = $pool; datastore = $ds
                tiers = @(
                    [ordered]@{ name = 'Web'; linkTo = @('App'); layout = $layout; image = $image; plan = $plans[0]; diskGB = 40 },
                    [ordered]@{ name = 'App'; linkTo = @('DB'); layout = $layout; image = $image; plan = $plans[-1]; diskGB = 60 },
                    [ordered]@{ name = 'DB'; linkTo = @(); layout = $layout; image = $image; plan = $plans[-1]; diskGB = 100 })
                staticTags = [ordered]@{ Environment = 'PoC' } }
        }
        policies = [ordered]@{
            naming = [ordered]@{ pattern = 'cust-${sequence}'; enforcement = 'user'; autoResolveConflicts = $true; scope = 'global' }
            approval = [ordered]@{ scope = [ordered]@{ role = 'Customer Requester' }; eachUser = $true }
            tagEnforcement = [ordered]@{ strict = $true; scope = 'global' }
            quotas = @(
                [ordered]@{ name = 'Requester quota'; scope = [ordered]@{ role = 'Customer Requester' }; eachUser = $true; maxVms = 5; maxCores = 16; maxMemoryGB = 64; maxStorageGB = 500 },
                [ordered]@{ name = 'Dev group quota'; scope = [ordered]@{ group = 'Customer-Dev' }; maxVms = 20 })
        }
    }
    ConvertTo-Json -InputObject $starter -Depth 20 | Set-Content -LiteralPath (Join-Path $dest 'starter-config.json') -Encoding utf8NoBOM

    foreach ($name in $ExportBlueprint) {
        $bp = Find-ByName $blueprints 'name' $name
        if (-not $bp) { throw "Blueprint '$name' was not found. Existing: $(($blueprints | ForEach-Object { $_.name }) -join ', ')" }
        $full = (Invoke-MorpheusApi -Method GET -Path "/api/blueprints/$($bp.id)").blueprint
        $cfg = Get-Prop $full 'config'
        $tiers = if ($cfg -and (Get-Prop $cfg 'tiers')) { $cfg.tiers } else { Get-Prop $full 'tiers' }
        $bpDir = Join-Path $dest 'blueprints'
        New-Item -ItemType Directory -Path $bpDir -Force | Out-Null
        $file = Join-Path $bpDir "$(Get-Slug $name).json"
        ConvertTo-Json -InputObject ([ordered]@{ name = $full.name; type = $full.type; tiers = $tiers }) -Depth 50 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
        Write-Ok "Exported blueprint '$name' to $file"
    }

    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host ' INVENTORY SAVED  ' -ForegroundColor Green -NoNewline; Write-Host $dest
    Write-Host ' summary.txt          read this first'
    Write-Host ' inventory.json       the same data as JSON'
    Write-Host ' starter-config.json  copy to customers/<name>.json and edit'
    Write-Host '================================================================' -ForegroundColor Cyan
}
catch {
    Write-Host "`n[error] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

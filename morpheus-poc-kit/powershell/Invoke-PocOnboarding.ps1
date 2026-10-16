#Requires -Version 7.0
<#
.SYNOPSIS
    Builds a customer PoC on HPE Morpheus / VME Manager from one JSON config file.

.DESCRIPTION
    As the master tenant (MORPHEUS_TOKEN)           Inside the new tenant (signed in as its admin)
     1 pre-flight: every name in the config is       7 groups that contain the cloud
       looked up before anything is changed          8 roles mapped to groups, features and persona
     2 cloud made Public (shared) or assigned        9 users
       to the tenant (dedicated)                    10 tag dropdowns: option lists + select inputs
     3 tenant role with Full access to the cloud    11 VM catalog item: plan list, inputs, tags
     4 tenant                                       12 3-tier app blueprint + its catalog item
     5 resource pools / datastores / networks       13 role access to catalog items and blueprints
       shared with the tenant                       14 policies: naming, approval, tag enforcement,
     6 tenant admin role and admin user                quotas

    Every step is get-or-create: re-running finishes a partial run and skips what already exists.
    Each object is recorded in state/<tenant>.json; Remove-PocTenant.ps1 (or bash/poc-teardown.sh)
    uses that file to undo the run.

    Environment:
      MORPHEUS_URL, MORPHEUS_TOKEN (master-tenant admin)   required
      TENANT_ADMIN_PASSWORD   tenant admin password; generated and printed once if unset
      MORPHEUS_SKIP_TLS_VERIFY                             lab certificates

.EXAMPLE
    ./Invoke-PocOnboarding.ps1 -Config ../customers/acme.json -DryRun
.EXAMPLE
    ./Invoke-PocOnboarding.ps1 -Config ../customers/acme.json -Yes -SkipCertificateCheck
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Config,
    [string]$StateDir = (Join-Path $PSScriptRoot '..' 'state'),
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$ResetAdminPassword,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorpheusPoc.psm1') -Force

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
function P($Object, [string]$Path) {
    # P $cfg 'catalog.vm.name' -> value or $null (no error for missing parts)
    $v = $Object
    foreach ($part in $Path.Split('.')) { if ($null -eq $v) { return $null }; $v = Get-Prop $v $part }
    return $v
}
function Has($Object, [string]$Name) { $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name }
function OrDefault($Value, $Default) { if ($null -eq $Value) { $Default } else { $Value } }
function IsText($v) { $v -is [string] -and $v.Length -gt 0 }
function Add-Id([System.Collections.Generic.List[long]]$List, $Id) { $List.Add([long]$Id) }

function Test-PocConfig($c) {
    $errors = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $groups = @(if (Has $c 'groups') { @($c.groups | ForEach-Object { [string]$_ }) } else { @([string](P $c 'tenant.name')) })
    $roles = @(@($c.roles | Where-Object { $_ } | ForEach-Object { $_.name }) + @((OrDefault (P $c 'admin.role') 'Tenant Admin')))
    $users = @(@($c.users | Where-Object { $_ } | ForEach-Object { $_.username }) + @((P $c 'admin.username')))
    $items = @(@((P $c 'catalog.vm.name'), (P $c 'catalog.threeTier.name')) | Where-Object { $_ })
    function Check-Scope([string]$Where, $Scope) {
        if ($null -eq $Scope -or $Scope -eq 'global') { return }
        if ($Scope -isnot [pscustomobject]) { $errors.Add("${Where}: scope must be ""global"" or an object such as {""role"": ""NAME""}"); return }
        if (Has $Scope 'group') { if ($groups -notcontains $Scope.group) { $errors.Add("${Where}: group ""$($Scope.group)"" is not listed in groups") } }
        elseif (Has $Scope 'role') { if ($roles -notcontains $Scope.role) { $errors.Add("${Where}: role ""$($Scope.role)"" is not defined in roles (or admin.role)") } }
        elseif (Has $Scope 'user') { if ($users -notcontains $Scope.user) { $errors.Add("${Where}: user ""$($Scope.user)"" is not defined in users (or admin)") } }
        elseif (Has $Scope 'cloud') { }
        else { $errors.Add("${Where}: scope must have one of group, role, user, cloud") }
    }
    if (-not (IsText (P $c 'tenant.name'))) { $errors.Add('tenant.name is required') }
    if ([string](OrDefault (P $c 'tenant.subdomain') '') -notmatch '^[A-Za-z0-9-]*$') { $errors.Add('tenant.subdomain may only contain letters, digits and hyphens') }
    if ([string](OrDefault (P $c 'tenant.currency') 'USD') -cnotmatch '^[A-Z]{3}$') { $errors.Add('tenant.currency must be a 3-letter code such as INR') }
    if (-not (IsText (P $c 'admin.username'))) { $errors.Add('admin.username is required') }
    if ([string](OrDefault (P $c 'admin.email') '') -notmatch '^[^@\s]+@[^@\s]+$') { $errors.Add('admin.email must be an email address') }
    $mode = OrDefault (P $c 'cloud.mode') 'shared'
    if ($mode -notin 'shared', 'dedicated', 'none') { $errors.Add('cloud.mode must be shared, dedicated or none') }
    if ((Has $c 'cloud') -and $mode -ne 'none' -and $null -eq (OrDefault (P $c 'cloud.name') (P $c 'cloud.id'))) { $errors.Add('cloud.name is required') }
    $shareCount = 0; foreach ($k in 'resourcePools', 'datastores', 'networks') { $shareCount += @(P $c "cloud.share.$k" | Where-Object { $null -ne $_ }).Count }
    if ($mode -ne 'shared' -and $shareCount -gt 0) { $errors.Add('cloud.share only applies to cloud.mode shared') }
    if ((-not (Has $c 'cloud') -or (P $c 'cloud.mode') -eq 'none') -and (Has $c 'catalog')) { $errors.Add('catalog needs a cloud (cloud.mode shared or dedicated)') }
    if ($groups.Count -ne @($groups | Select-Object -Unique).Count) { $errors.Add('groups contains duplicates') }
    $roleNames = @($c.roles | Where-Object { $_ } | ForEach-Object { $_.name })
    if ($roleNames.Count -ne @($roleNames | Select-Object -Unique).Count) { $errors.Add('roles contains duplicate names') }
    foreach ($r in @($c.roles | Where-Object { $_ })) {
        if (-not (IsText $r.name)) { $errors.Add('every role needs a name') }
        $rg = $r.groups   # read directly: a one-element list must stay a list
        if ($null -ne $rg -and $rg -ne 'all') {
            if ($rg -is [array]) { foreach ($g in $rg) { if ($groups -notcontains $g) { $errors.Add("role ""$($r.name)"": group ""$g"" is not listed in groups") } } }
            else { $errors.Add("role ""$($r.name)"": groups must be ""all"" or a list") }
        }
        $dp = P $r 'defaultPersona'
        if ($null -ne $dp -and $dp -notin 'standard', 'serviceCatalog', 'vdi') { $errors.Add("role ""$($r.name)"": defaultPersona must be standard, serviceCatalog or vdi") }
        $ci = $r.catalogItems
        if ($null -ne $ci -and $ci -isnot [array] -and $ci -notin 'all', 'none') { $errors.Add("role ""$($r.name)"": catalogItems must be ""all"", ""none"" or a list") }
        if ($ci -is [array]) { foreach ($i in $ci) { if ($items -notcontains $i) { $notes.Add("role ""$($r.name)"": catalog item ""$i"" is not defined in catalog (it must already exist in the tenant)") } } }
    }
    foreach ($u in @($c.users | Where-Object { $_ })) {
        if (-not ((IsText $u.username) -and (IsText (P $u 'email')) -and (IsText (P $u 'role')))) { $errors.Add('every user needs username, email and role') }
    }
    $tagNames = @($c.tags | Where-Object { $_ } | ForEach-Object { $_.name })
    if ($tagNames.Count -ne @($tagNames | Select-Object -Unique).Count) { $errors.Add('tags contains duplicate names') }
    foreach ($t in @($c.tags | Where-Object { $_ })) { if (-not (IsText $t.name) -or @(P $t 'values').Count -eq 0) { $errors.Add('every tag needs a name and at least one value') } }
    $vm = P $c 'catalog.vm'
    if ($vm) {
        foreach ($k in 'name', 'group', 'layout', 'image', 'network', 'resourcePool', 'datastore') { if ([string](P $vm $k) -eq '') { $errors.Add("catalog.vm.$k is required") } }
        if (@(P $vm 'plans' | Where-Object { $null -ne $_ }).Count -eq 0) { $errors.Add('catalog.vm.plans needs at least one plan') }
        if ((P $vm 'group') -and $groups -notcontains $vm.group) { $errors.Add("catalog.vm.group ""$($vm.group)"" is not listed in groups") }
    }
    $tt = P $c 'catalog.threeTier'
    if ($tt) {
        foreach ($k in 'name', 'group', 'network', 'resourcePool', 'datastore') { if ([string](P $tt $k) -eq '') { $errors.Add("catalog.threeTier.$k is required") } }
        if ((P $tt 'group') -and $groups -notcontains $tt.group) { $errors.Add("catalog.threeTier.group ""$($tt.group)"" is not listed in groups") }
        $tiers = @(P $tt 'tiers' | Where-Object { $_ })
        if (-not (P $tt 'templateFile') -and $tiers.Count -eq 0) { $errors.Add('catalog.threeTier.tiers needs at least one tier (or set templateFile)') }
        foreach ($tier in $tiers) {
            foreach ($k in 'name', 'layout', 'image', 'plan') { if ([string](P $tier $k) -eq '') { $errors.Add("catalog.threeTier.tiers[$(OrDefault (P $tier 'name') '?')].$k is required") } }
        }
        $tierNames = @($tiers | ForEach-Object { $_.name })
        foreach ($tier in $tiers) { foreach ($l in @(P $tier 'linkTo' | Where-Object { $_ })) { if ($tierNames -notcontains $l) { $errors.Add("catalog.threeTier: linkTo ""$l"" is not a tier name") } } }
    }
    $naming = P $c 'policies.naming'
    if ($naming) {
        if (-not (IsText (P $naming 'pattern'))) { $errors.Add('policies.naming.pattern is required') }
        if ((OrDefault (P $naming 'enforcement') 'user') -notin 'user', 'fixed') { $errors.Add('policies.naming.enforcement must be user or fixed') }
    }
    Check-Scope 'policies.naming.scope' (P $c 'policies.naming.scope')
    Check-Scope 'policies.approval.scope' (P $c 'policies.approval.scope')
    Check-Scope 'policies.tagEnforcement.scope' (P $c 'policies.tagEnforcement.scope')
    foreach ($q in @(P $c 'policies.quotas' | Where-Object { $_ })) {
        if (-not (IsText (P $q 'name'))) { $errors.Add('every quota needs a name') }
        if (@('maxVms', 'maxCores', 'maxMemoryGB', 'maxStorageGB' | Where-Object { $null -ne (P $q $_) }).Count -eq 0) {
            $errors.Add("quota ""$($q.name)"": set at least one of maxVms, maxCores, maxMemoryGB, maxStorageGB")
        }
        Check-Scope "quota ""$($q.name)""" (P $q 'scope')
    }
    return @{ Errors = $errors; Notes = $notes }
}

$summary = [ordered]@{}
$newPasswords = [System.Collections.Generic.List[string[]]]::new()

try {
    if (-not (Test-Path -LiteralPath $Config)) { throw "Config file '$Config' not found." }
    try { $cfg = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json -Depth 50 } catch { throw "$Config is not valid JSON: $($_.Exception.Message)" }
    $check = Test-PocConfig $cfg
    if ($check.Errors.Count -gt 0) {
        Write-Host "[error] $Config has problems:" -ForegroundColor Red
        foreach ($e in $check.Errors) { Write-Host "        - $e" -ForegroundColor Red }
        exit 2
    }

    $tenantName = [string]$cfg.tenant.name
    $subdomain = [string](OrDefault (P $cfg 'tenant.subdomain') '')
    $tenantDesc = OrDefault (P $cfg 'tenant.description') "PoC tenant $tenantName"
    $currency = OrDefault (P $cfg 'tenant.currency') 'USD'
    $troleName = OrDefault (P $cfg 'tenant.role.name') "$tenantName Tenant Role"
    $troleTemplate = if (Has (P $cfg 'tenant.role') 'copyFrom') { [string]$cfg.tenant.role.copyFrom } else { 'Tenant Admin' }
    $cloudMode = if (-not (Has $cfg 'cloud')) { 'none' } else { OrDefault (P $cfg 'cloud.mode') 'shared' }
    $cloudRef = [string](OrDefault (P $cfg 'cloud.name') (P $cfg 'cloud.id'))
    $adminUser = [string]$cfg.admin.username
    $adminEmail = [string]$cfg.admin.email
    $adminFirst = OrDefault (P $cfg 'admin.firstName') 'Tenant'
    $adminLast = OrDefault (P $cfg 'admin.lastName') 'Admin'
    $adminRoleName = OrDefault (P $cfg 'admin.role') 'Tenant Admin'
    $adminRoleTemplate = if (Has $cfg.admin 'roleCopyFrom') { [string]$cfg.admin.roleCopyFrom } else { 'Tenant Admin' }
    $prefix = OrDefault (P $cfg 'catalog.inputPrefix') 'PoC'
    $groupsCfg = @(if (Has $cfg 'groups') { @($cfg.groups | ForEach-Object { [string]$_ }) } else { @($tenantName) })
    $rolesCfg = @($cfg.roles | Where-Object { $_ })
    $usersCfg = @($cfg.users | Where-Object { $_ })
    $tagsCfg = @($cfg.tags | Where-Object { $_ })
    $namingFixed = (P $cfg 'policies.naming.enforcement') -eq 'fixed'

    $groupIds = @{}; $roleIds = @{}; $userIds = @{}; $tagField = [ordered]@{}; $tagListId = @{}; $tagInputId = @{}
    $catalogIds = @{}; $blueprintOf = @{}

    $baseUrl = Initialize-MorpheusSession -SkipCertificateCheck:$SkipCertificateCheck -DryRun:$DryRun -Yes:$Yes
    $manifestFile = Join-Path $StateDir "$(Get-Slug $(if ($subdomain) { $subdomain } else { $tenantName })).json"
    Initialize-Manifest -Path $manifestFile -Appliance $baseUrl -TenantName $tenantName
    $script:Hint = "Fix the cause and re-run the same command; completed steps are reused. State: $manifestFile"

    if ($DryRun) { Write-Host "`nDRY RUN - lookups are real, nothing will be created or changed." -ForegroundColor Magenta }
    foreach ($n in $check.Notes) { Write-Warn $n }

    # -----------------------------------------------------------------------
    # Helpers used by the stages
    # -----------------------------------------------------------------------
    function Resolve-CopyFromRole([string]$Template, [string]$RoleType, [long]$OwnerTenantId) {
        if (-not $Template) { return $null }
        $options = Invoke-MorpheusApi -Method GET -Path '/api/options/copyFromRole' -Query ([ordered]@{ roleType = $RoleType; tenantId = $OwnerTenantId })
        $match = @(Get-List $options 'data') | Where-Object { [string]$_.name -ieq $Template } | Select-Object -First 1
        if (-not $match) { throw "Template role '$Template' ($RoleType role) was not found. Roles you can copy from: $((@(Get-List $options 'data') | ForEach-Object { $_.name } | Sort-Object -Unique) -join ', ')" }
        return [long]$match.value
    }

    function Get-TenantRoles {
        $res = Invoke-MorpheusApi -Method GET -Path '/api/roles' -Query ([ordered]@{ roleType = 'user'; max = 1000 })
        return @(Get-List $res 'roles' | ForEach-Object { $_ | Add-Member -NotePropertyName name -NotePropertyValue ((Get-Prop $_ 'authority') ?? (Get-Prop $_ 'name')) -Force -PassThru })
    }

    function ConvertTo-Dataset($Pairs) { ConvertTo-Json -InputObject @($Pairs) -Compress -Depth 5 }

    function Resolve-OptionList([string]$Name, [string]$Dataset) {
        $res = Invoke-MorpheusApi -Method GET -Path '/api/library/option-type-lists' -Query ([ordered]@{ name = $Name; max = 1000 })
        $existing = Find-ByName (Get-List $res 'optionTypeLists') 'name' $Name
        if ($existing) {
            $id = [long]$existing.id
            $current = ConvertTo-Json -InputObject @((OrDefault (Get-Prop $existing 'initialDataset') '[]') | ConvertFrom-Json) -Compress -Depth 5
            $wanted = ConvertTo-Json -InputObject @($Dataset | ConvertFrom-Json) -Compress -Depth 5
            if ($current -ne $wanted) {
                if ((Get-ManifestAction 'optionList' $id) -eq 'created') {
                    Invoke-MorpheusApi -Method PUT -Path "/api/library/option-type-lists/$id" -Body @{ optionTypeList = @{ initialDataset = $Dataset } } | Out-Null
                    Write-Done "Option list '$Name' updated with the values from the config" "Would update the values of option list '$Name'"
                } else {
                    Write-Warn "Option list '$Name' exists with different values and was not created by this kit - left unchanged."
                }
            } else { Write-Ok "Option list '$Name' exists (ID $id)" }
            Save-ObjectRecord optionList tenant $id $Name $false
            return $id
        }
        $res = Invoke-MorpheusApi -Method POST -Path '/api/library/option-type-lists' -Body @{ optionTypeList = [ordered]@{
            name = $Name; description = 'Created by morpheus-poc-kit'; type = 'manual'; initialDataset = $Dataset } }
        $id = [long](OrDefault (P $res 'optionTypeList.id') 0)
        Save-ObjectRecord optionList tenant $id $Name $true
        Write-Done "Created option list '$Name' (ID $id)" "Would create option list '$Name'"
        return $id
    }

    function Resolve-Input([System.Collections.IDictionary]$Spec) {
        $res = Invoke-MorpheusApi -Method GET -Path '/api/library/option-types' -Query ([ordered]@{ name = $Spec.name; max = 1000 })
        $existing = Find-ByName (Get-List $res 'optionTypes') 'name' $Spec.name
        if ($existing) {
            if ($existing.fieldName -ne $Spec.fieldName) {
                throw "Input '$($Spec.name)' already exists with field name '$($existing.fieldName)', but the kit needs '$($Spec.fieldName)'. Rename it, or set a different catalog.inputPrefix."
            }
            Write-Ok "Input '$($Spec.name)' exists (ID $($existing.id))"
            Save-ObjectRecord input tenant $existing.id $Spec.name $false
            return [long]$existing.id
        }
        $res = Invoke-MorpheusApi -Method POST -Path '/api/library/option-types' -Body @{ optionType = $Spec }
        $id = [long](OrDefault (P $res 'optionType.id') 0)
        Save-ObjectRecord input tenant $id $Spec.name $true
        Write-Done "Created input '$($Spec.name)' (ID $id)" "Would create input '$($Spec.name)' [$($Spec.type)]"
        return $id
    }

    function Resolve-CatalogItem([System.Collections.IDictionary]$Item) {
        $res = Invoke-MorpheusApi -Method GET -Path '/api/catalog-item-types' -Query ([ordered]@{ name = $Item.name; max = 1000 })
        $existing = Find-ByName (Get-List $res 'catalogItemTypes') 'name' $Item.name
        if ($existing) {
            Write-Ok "Catalog item '$($Item.name)' exists (ID $($existing.id)) - left unchanged"
            Save-ObjectRecord catalogItem tenant $existing.id $Item.name $false
            return [long]$existing.id
        }
        $res = Invoke-MorpheusApi -Method POST -Path '/api/catalog-item-types' -Body @{ catalogItemType = $Item }
        $id = [long](OrDefault (P $res 'catalogItemType.id') 0)
        Save-ObjectRecord catalogItem tenant $id $Item.name $true
        Write-Done "Created catalog item '$($Item.name)' (ID $id)" "Would create catalog item '$($Item.name)'"
        return $id
    }

    function Assert-TenantSees([string]$Kind, $Id, [string]$Label) {
        switch ($Kind) {
            'image'     { $l = Get-List (Invoke-MorpheusApi -Method GET -Path '/api/virtual-images' -Query @{ max = 1000 }) 'virtualImages'; $hint = 'Make the image Public, or share it with the tenant, then re-run.' }
            'plan'      { $l = Get-List (Invoke-MorpheusApi -Method GET -Path '/api/service-plans' -Query @{ max = 1000 }) 'servicePlans'; $hint = 'Make the plan available to the tenant, then re-run.' }
            'network'   { $l = Get-List (Invoke-MorpheusApi -Method GET -Path '/api/networks' -Query ([ordered]@{ zoneId = $cloudId; max = 1000 })) 'networks'; $hint = 'Add it to cloud.share.networks (or make it Public), then re-run.' }
            'pool'      { $l = Get-List (Invoke-MorpheusApi -Method GET -Path "/api/zones/$cloudId/resource-pools" -Query @{ max = 1000 }) 'resourcePools'; $hint = 'Add it to cloud.share.resourcePools (or make it Public), then re-run.' }
            'datastore' { if ([string]$Id -notmatch '^\d+$') { return }
                          $l = Get-List (Invoke-MorpheusApi -Method GET -Path "/api/zones/$cloudId/data-stores" -Query @{ max = 1000 }) 'datastores'; $hint = 'Add it to cloud.share.datastores (or make it Public), then re-run.' }
        }
        if (-not (@($l) | Where-Object { [long]$_.id -eq [long]$Id })) { throw "$Label is not visible to the tenant. $hint" }
    }

    function Get-ScopeFields($Scope) {
        if ($null -eq $Scope -or $Scope -eq 'global') { return [ordered]@{} }
        $kind = @($Scope.PSObject.Properties.Name)[0]; $name = [string]$Scope.$kind
        $id = switch ($kind) {
            'group' { $groupIds[$name] }
            'role'  { $(if ($roleIds[$name]) { $roleIds[$name] } else { (Find-ByName (Get-TenantRoles) 'name' $name).id }) }
            'user'  { $userIds[$name] }
            'cloud' { $cloudId }
        }
        if (-not $id) { return $null }
        $id = [long]$id
        switch ($kind) {
            'group' { [ordered]@{ refType = 'ComputeSite'; refId = $id; site = @{ id = $id } } }
            'cloud' { [ordered]@{ refType = 'ComputeZone'; refId = $id; zone = @{ id = $id } } }
            'user'  { [ordered]@{ refType = 'User'; refId = $id; user = @{ id = $id } } }
            'role'  { [ordered]@{ refType = 'Role'; refId = $id; role = @{ id = $id } } }
        }
    }

    function Resolve-Policy([string]$Name, [string]$Code, [System.Collections.IDictionary]$PolicyConfig, $Scope, [bool]$EachUser) {
        $res = Invoke-MorpheusApi -Method GET -Path '/api/policies' -Query ([ordered]@{ name = $Name; max = 1000 })
        $existing = Find-ByName (Get-List $res 'policies') 'name' $Name
        if ($existing) {
            Write-Ok "Policy '$Name' exists (ID $($existing.id)) - left unchanged"
            Save-ObjectRecord policy tenant $existing.id $Name $false
            return
        }
        $fields = Get-ScopeFields $Scope
        if ($null -eq $fields) { Write-Plan "Would create policy '$Name' (its scope is created earlier in a real run)"; return }
        $policy = [ordered]@{ name = $Name; description = 'Created by morpheus-poc-kit'; enabled = $true; policyType = @{ code = $Code }; config = $PolicyConfig }
        foreach ($k in $fields.Keys) { $policy[$k] = $fields[$k] }
        if ($fields.Contains('refType') -and $fields.refType -eq 'Role') { $policy.eachUser = $EachUser }
        $res = Invoke-MorpheusApi -Method POST -Path '/api/policies' -Body @{ policy = $policy }
        $id = [long](OrDefault (P $res 'policy.id') 0)
        Save-ObjectRecord policy tenant $id $Name $true
        Write-Done "Created policy '$Name' (ID $id)" "Would create policy '$Name' [$Code]"
    }

    # =======================================================================
    # 1. Pre-flight (read-only)
    # =======================================================================
    Write-Step 'Pre-flight checks'
    $whoami = Invoke-MorpheusApi -Method GET -Path '/api/whoami'
    if (-not $whoami.isMasterAccount) { throw 'MORPHEUS_TOKEN must belong to a user in the MASTER tenant.' }
    $masterId = Get-OwnerId $whoami.user
    if (-not $masterId) { throw 'Could not determine the master tenant ID from /api/whoami.' }
    Write-Ok "Connected as '$($whoami.user.username)' (master tenant ID $masterId)"

    $ptypes = @(Get-List (Invoke-MorpheusApi -Method GET -Path '/api/policy-types') 'policyTypes' | ForEach-Object { $_.code })
    $needed = [System.Collections.Generic.List[string]]::new()
    if (P $cfg 'policies.naming') { $needed.Add('naming') }
    if (P $cfg 'policies.approval') { $needed.Add('provisionApproval') }
    if ((P $cfg 'policies.tagEnforcement') -and $tagsCfg.Count -gt 0) { $needed.Add('tags') }
    foreach ($q in @(P $cfg 'policies.quotas' | Where-Object { $_ })) {
        if ($null -ne (P $q 'maxVms')) { $needed.Add('maxVms') }
        if ($null -ne (P $q 'maxCores')) { $needed.Add('maxCores') }
        if ($null -ne (P $q 'maxMemoryGB')) { $needed.Add('maxMemory') }
        if ($null -ne (P $q 'maxStorageGB')) { $needed.Add('maxStorage') }
    }
    $neededList = @($needed | Sort-Object -Unique)
    $missing = @($neededList | Where-Object { $ptypes -notcontains $_ })
    if ($missing.Count) {
        throw "This appliance does not offer these policy types: $($missing -join ', '). On HPE VM Essentials some governance features need a Morpheus Enterprise licence; remove them from 'policies' or check the licence."
    }
    Write-Ok "Policy types needed by the config are available: $(if ($neededList.Count) { $neededList -join ', ' } else { 'none' })"

    $tenant = Find-ByName (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/accounts' -Query ([ordered]@{ name = $tenantName; max = 1000 })) 'accounts') 'name' $tenantName
    $tenantId = 0
    if ($tenant) {
        $tenantId = [long]$tenant.id
        Write-Ok "Tenant '$tenantName' already exists (ID $tenantId) - this run will complete it"
        if (-not $subdomain) { $subdomain = [string](OrDefault (Get-Prop $tenant 'subdomain') '') }
    } elseif ($subdomain) {
        $clash = Get-List (Invoke-MorpheusApi -Method GET -Path '/api/accounts' -Query @{ max = 1000 }) 'accounts' | Where-Object { [string](Get-Prop $_ 'subdomain') -ieq $subdomain } | Select-Object -First 1
        if ($clash) { throw "Subdomain '$subdomain' is already used by tenant '$($clash.name)'." }
    }

    $cloudId = 0; $cloudName = ''; $cloudVis = ''; $cloudOwner = $null
    $sharePools = [System.Collections.Generic.List[long]]::new(); $shareDs = [System.Collections.Generic.List[long]]::new(); $shareNets = [System.Collections.Generic.List[long]]::new()
    $poolsList = @(); $dsList = @(); $netsList = @()
    if ($cloudMode -ne 'none') {
        $cloud = Select-MorpheusObject $cloudRef 'Cloud' (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/zones' -Query @{ max = 1000 }) 'zones')
        $cloudId = [long]$cloud.id; $cloudName = [string]$cloud.name
        $cloudVis = OrDefault (Get-Prop $cloud 'visibility') 'private'
        $cloudOwner = OrDefault (Get-OwnerId $cloud) $masterId
        Write-Ok "Cloud '$cloudName' (ID $cloudId) - visibility $cloudVis, owner tenant ID $cloudOwner"
        if ($cloudOwner -ne $masterId -and $cloudOwner -ne $tenantId) { throw "Cloud '$cloudName' is assigned to another tenant (ID $cloudOwner). Reassign it in the UI first." }
        if ($cloudMode -eq 'shared' -and $cloudOwner -ne $masterId) { throw "Cloud '$cloudName' is already dedicated to this tenant. Use cloud.mode dedicated, or reassign it to the master tenant first." }
        $poolsList = @(Get-List (Invoke-MorpheusApi -Method GET -Path "/api/zones/$cloudId/resource-pools" -Query @{ max = 1000 }) 'resourcePools')
        $dsList = @(Get-List (Invoke-MorpheusApi -Method GET -Path "/api/zones/$cloudId/data-stores" -Query @{ max = 1000 }) 'datastores')
        $netsList = @(Get-List (Invoke-MorpheusApi -Method GET -Path '/api/networks' -Query ([ordered]@{ zoneId = $cloudId; max = 1000 })) 'networks')
        foreach ($r in @(P $cfg 'cloud.share.resourcePools' | Where-Object { $null -ne $_ })) { Add-Id $sharePools (Select-MorpheusObject ([string]$r) 'Resource pool' $poolsList).id }
        foreach ($r in @(P $cfg 'cloud.share.datastores' | Where-Object { $null -ne $_ })) { Add-Id $shareDs (Select-MorpheusObject ([string]$r) 'Datastore' $dsList).id }
        foreach ($r in @(P $cfg 'cloud.share.networks' | Where-Object { $null -ne $_ })) { Add-Id $shareNets (Select-MorpheusObject ([string]$r) 'Network' $netsList).id }
        if ($sharePools.Count + $shareDs.Count + $shareNets.Count -gt 0) {
            Write-Ok "Resources to share: $($sharePools.Count) resource pool(s), $($shareDs.Count) datastore(s), $($shareNets.Count) network(s)"
        }
    }

    $layouts = @(Get-List (Invoke-MorpheusApi -Method GET -Path '/api/library/layouts' -Query @{ max = 1000 }) 'instanceTypeLayouts')
    $plansAll = @(Get-List (Invoke-MorpheusApi -Method GET -Path '/api/service-plans' -Query @{ max = 1000 }) 'servicePlans')
    function Resolve-Image([string]$Ref) {
        $q = if ($Ref -match '^\d+$') { @{ max = 1000 } } else { [ordered]@{ name = $Ref; max = 1000 } }
        $img = Select-MorpheusObject $Ref 'Virtual image' (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/virtual-images' -Query $q) 'virtualImages')
        if ((OrDefault (Get-Prop $img 'visibility') 'private') -ne 'public') { Write-Warn "Image '$($img.name)' is Private - the tenant can only use it if it is shared with the tenant." }
        return [long]$img.id
    }
    function Resolve-Ds([string]$Ref) { if ($Ref -match '^(auto|autoCluster)$') { $Ref } else { [long](Select-MorpheusObject $Ref 'Datastore' $dsList).id } }

    $vm = P $cfg 'catalog.vm'
    if ($vm) {
        $vmLayout = [long](Select-MorpheusObject ([string]$vm.layout) 'Layout' $layouts).id
        $vmImage = Resolve-Image ([string]$vm.image)
        $vmNet = [long](Select-MorpheusObject ([string]$vm.network) 'Network' $netsList).id
        $vmPool = [long](Select-MorpheusObject ([string]$vm.resourcePool) 'Resource pool' $poolsList).id
        $vmDs = Resolve-Ds ([string]$vm.datastore)
        $vmPlans = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($vm.plans)) {
            $plan = Select-MorpheusObject ([string]$p) 'Service plan' $plansAll
            if (-not ($vmPlans | Where-Object { $_.id -eq [long]$plan.id })) { $vmPlans.Add([ordered]@{ id = [long]$plan.id; name = [string]$plan.name }) }
        }
        Write-Ok "Catalog item '$($vm.name)': layout, image, network, pool, datastore and $($vmPlans.Count) plan(s) found"
    }
    $tt = P $cfg 'catalog.threeTier'
    $bpTemplate = $null
    if ($tt) {
        $bpNet = [long](Select-MorpheusObject ([string]$tt.network) 'Network' $netsList).id
        $bpPool = [long](Select-MorpheusObject ([string]$tt.resourcePool) 'Resource pool' $poolsList).id
        $bpDs = Resolve-Ds ([string]$tt.datastore)
        $bpTiers = [System.Collections.Generic.List[object]]::new()
        if (-not (P $tt 'templateFile')) {
            foreach ($t in @($tt.tiers)) {
                $plan = Select-MorpheusObject ([string]$t.plan) 'Service plan' $plansAll
                $bpTiers.Add([ordered]@{
                    name = [string]$t.name; linkTo = @(@(P $t 'linkTo') | Where-Object { $_ })
                    layoutId = [long](Select-MorpheusObject ([string]$t.layout) 'Layout' $layouts).id
                    imageId = Resolve-Image ([string]$t.image); planId = [long]$plan.id; diskGB = OrDefault (P $t 'diskGB') 40 })
            }
            Write-Ok "3-tier app '$($tt.name)': $(($bpTiers | ForEach-Object { $_.name }) -join ', ') tiers resolved"
        } else {
            $bpTemplate = [string]$tt.templateFile
            if (-not [IO.Path]::IsPathRooted($bpTemplate)) { $bpTemplate = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Config)) $bpTemplate }
            if (-not (Test-Path -LiteralPath $bpTemplate)) { throw "catalog.threeTier.templateFile '$bpTemplate' was not found." }
            $tplCheck = Get-Content -LiteralPath $bpTemplate -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            if (-not ($tplCheck.Contains('tiers') -and $tplCheck.tiers -is [System.Collections.IDictionary])) { throw "$bpTemplate has no 'tiers' object (export one with Get-MorpheusInventory.ps1 -ExportBlueprint)." }
            Write-Ok "3-tier app '$($tt.name)': using template $bpTemplate"
        }
    }

    # =======================================================================
    # 2. Shared mode: the cloud must be Public before a tenant role can be given access to it
    # =======================================================================
    if ($cloudMode -eq 'shared') {
        Write-Step "Cloud '$cloudName' available to tenants (Public)"
        if ($cloudVis -eq 'public') {
            Write-Ok 'Cloud is already Public'
        } else {
            Confirm-Change ("Cloud '$cloudName' is $cloudVis. Setting it to Public lets it be granted to ANY tenant's role, and tenants created later get it added automatically. " +
                            'Existing tenants only see it if their tenant role grants access.')
            Invoke-MorpheusApi -Method PUT -Path "/api/zones/$cloudId" -Body @{ zone = @{ visibility = 'public' } } | Out-Null
            Add-ManifestItem -Kind cloudVisibility -Scope master -Action changed -Id $cloudId -Name $cloudName -Extra @{ from = $cloudVis; to = 'public' }
            Write-Done 'Cloud visibility set to Public' 'Would set the cloud visibility to Public'
        }
    }

    # =======================================================================
    # 3. Tenant role
    # =======================================================================
    Write-Step "Tenant role '$troleName'"
    $trole = Find-ByName (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/roles' -Query ([ordered]@{ roleType = 'account'; name = $troleName; max = 1000 })) 'roles') 'authority' $troleName
    if ($trole) {
        $troleId = [long]$trole.id
        Write-Ok "Found existing tenant role (ID $troleId)"
        Save-ObjectRecord tenantRole master $troleId $troleName $false
    } else {
        $base = Resolve-CopyFromRole $troleTemplate 'account' $masterId
        if (-not $base) { Write-Warn 'No copyFrom template: the tenant role starts with NO feature permissions.' }
        $role = [ordered]@{ authority = $troleName; description = "Permission ceiling for tenant $tenantName"; roleType = 'account' }
        if ($base) { $role.baseRoleId = $base }
        $troleId = [long](OrDefault (P (Invoke-MorpheusApi -Method POST -Path '/api/roles' -Body @{ role = $role }) 'role.id') 0)
        Save-ObjectRecord tenantRole master $troleId $troleName $true
        Write-Done "Created tenant role (ID $troleId), copied from '$troleTemplate'" "Would create the tenant role, copied from '$troleTemplate'"
    }
    if ($cloudMode -eq 'shared') {
        if ($troleId) { Invoke-MorpheusApi -Method PUT -Path "/api/roles/$troleId/update-cloud" -Body ([ordered]@{ cloudId = $cloudId; access = 'full' }) | Out-Null }
        Write-Done "Tenant role has Full access to cloud '$cloudName'" "Would give the tenant role Full access to cloud '$cloudName'"
    }

    # =======================================================================
    # 4. Tenant
    # =======================================================================
    Write-Step "Tenant '$tenantName'"
    if ($tenant) {
        Write-Ok "Found existing tenant (ID $tenantId)"
        $existingRole = Get-Prop $tenant 'role'
        if ($existingRole -and (Get-Prop $existingRole 'id') -and [long]$existingRole.id -ne $troleId) {
            Write-Warn "The tenant's base role is '$((Get-Prop $existingRole 'authority') ?? (Get-Prop $existingRole 'name'))', not '$troleName'. Left unchanged."
        }
        Save-ObjectRecord tenant master $tenantId $tenantName $false
    } else {
        $account = [ordered]@{ name = $tenantName; description = $tenantDesc; role = @{ id = $troleId }; currency = $currency }
        if ($subdomain) { $account.subdomain = $subdomain }
        $tenantId = [long](OrDefault (P (Invoke-MorpheusApi -Method POST -Path '/api/accounts' -Body @{ account = $account }) 'account.id') 0)
        Save-ObjectRecord tenant master $tenantId $tenantName $true
        Write-Done "Created tenant (ID $tenantId)" 'Would create the tenant'
    }
    if ($tenantId) {
        Set-ManifestValue tenantId $tenantId
        Set-ManifestValue masterTenantId $masterId
        Set-ManifestValue subdomain $(if ($subdomain) { $subdomain } else { $null })
    }

    # =======================================================================
    # 5. Cloud: assign it (dedicated) or share its resources (shared)
    # =======================================================================
    if ($cloudMode -eq 'dedicated') {
        Write-Step "Assigning cloud '$cloudName' to the tenant"
        if ($tenantId -and $cloudOwner -eq $tenantId) {
            Write-Ok 'Cloud is already assigned to this tenant'
        } else {
            Confirm-Change "Cloud '$cloudName' and ALL of its resources will be available ONLY to tenant '$tenantName'. Other sub-tenants lose access to it; the master tenant keeps control."
            if ($tenantId) {
                Invoke-MorpheusApi -Method PUT -Path "/api/zones/$cloudId" -Body @{ zone = [ordered]@{ accountId = $tenantId; visibility = 'private' } } | Out-Null
                Add-ManifestItem -Kind cloudOwner -Scope master -Action changed -Id $cloudId -Name $cloudName -Extra @{ from = [long]$cloudOwner; to = $tenantId; fromVisibility = $cloudVis }
            }
            Write-Done 'Cloud assigned to the tenant (visibility Private)' 'Would assign the cloud to the tenant (visibility Private)'
        }
    } elseif ($cloudMode -eq 'shared' -and ($sharePools.Count + $shareDs.Count + $shareNets.Count) -gt 0) {
        Write-Step 'Sharing cloud resources with the tenant'
        $jobs = @($sharePools | ForEach-Object { @{ k = 'resourcePool'; id = $_ } }) + @($shareDs | ForEach-Object { @{ k = 'datastore'; id = $_ } }) + @($shareNets | ForEach-Object { @{ k = 'network'; id = $_ } })
        foreach ($job in $jobs) {
            $st = Get-ResourceState -Kind $job.k -CloudId $cloudId -Id $job.id
            if (-not $st) { throw "$($job.k) $($job.id) was not found in cloud '$cloudName'." }
            $label = "$($job.k) '$($st.Name)' (ID $($job.id))"
            if ($st.Visibility -eq 'public') { Write-Ok "$label is Public - every tenant can already use it"; continue }
            if (-not $tenantId) { Write-Plan "Would share $label with the new tenant"; continue }
            if ($st.Tenants -contains $tenantId) { Write-Ok "$label is already shared with the tenant"; continue }
            $others = $st.Tenants.Count
            Set-ResourceTenants $st (@($st.Tenants) + @($tenantId))
            Add-ManifestItem -Kind share -Scope master -Action changed -Id $job.id -Name $st.Name -Extra @{ resource = $job.k; cloudId = $cloudId }
            Write-Done "$label shared with the tenant ($others other tenant(s) kept)" "Would share $label with the tenant ($others other tenant(s) kept)"
        }
    }

    # =======================================================================
    # 6. Tenant admin: role owned by the tenant + local admin user
    # =======================================================================
    Write-Step "Tenant admin '$adminUser'"
    $adminRoleId = 0; $adminId = 0; $adminPw = $null; $adminPwShown = $null
    if (-not $tenantId) {
        Write-Plan "Would reuse or create role '$adminRoleName' in the new tenant and create admin user '$adminUser'"
    } else {
        $roles = Get-List (Invoke-MorpheusApi -Method GET -Path '/api/roles' -Query ([ordered]@{ tenant = $tenantId; roleType = 'user'; max = 1000 })) 'roles'
        $arole = $roles | Where-Object { $o = Get-Prop $_ 'owner'; (-not $o -or [long]$o.id -eq $tenantId) -and (((Get-Prop $_ 'authority') ?? (Get-Prop $_ 'name')) -ieq $adminRoleName) } | Select-Object -First 1
        if ($arole) {
            $adminRoleId = [long]$arole.id
            Write-Ok "Role '$adminRoleName' exists in the tenant (ID $adminRoleId)"
            Save-ObjectRecord adminRole master $adminRoleId $adminRoleName $false
        } else {
            $base = Resolve-CopyFromRole $adminRoleTemplate 'user' $tenantId
            $role = [ordered]@{ authority = $adminRoleName; description = "Administrator for tenant $tenantName"; roleType = 'user'; owner = $tenantId; globalSiteAccess = 'full' }
            if ($base) { $role.baseRoleId = $base }
            $adminRoleId = [long](OrDefault (P (Invoke-MorpheusApi -Method POST -Path '/api/roles' -Body @{ role = $role }) 'role.id') 0)
            Save-ObjectRecord adminRole master $adminRoleId $adminRoleName $true
            Write-Done "Created role '$adminRoleName' in the tenant (ID $adminRoleId)" "Would create role '$adminRoleName' in the tenant"
        }
        $admin = Find-ByName (Get-List (Invoke-MorpheusApi -Method GET -Path "/api/accounts/$tenantId/users" -Query ([ordered]@{ username = $adminUser; max = 1000 })) 'users') 'username' $adminUser
        if ($admin) {
            $adminId = [long]$admin.id
            Write-Ok "Admin user exists (ID $adminId)"
            Save-ObjectRecord adminUser master $adminId $adminUser $false
            if ($ResetAdminPassword) {
                if ($DryRun) { Write-Plan "Would set a new password for '$adminUser'" }
                else {
                    $adminPw = New-RandomPassword
                    Invoke-MorpheusApi -Method PUT -Path "/api/accounts/$tenantId/users/$adminId" -Body @{ user = [ordered]@{ password = $adminPw; passwordConfirmation = $adminPw } } | Out-Null
                    $adminPwShown = $adminPw
                    Write-Ok "New password set for '$adminUser' (shown in the summary)"
                }
            } elseif ($env:TENANT_ADMIN_PASSWORD) {
                $adminPw = $env:TENANT_ADMIN_PASSWORD
            } elseif (-not [Console]::IsInputRedirected -and -not $DryRun) {
                $sec = Read-Host "    Password for '$adminUser' (to sign in to the tenant)" -AsSecureString
                $adminPw = [System.Net.NetworkCredential]::new('', $sec).Password
            } elseif ($DryRun) {
                Write-Warn 'Set TENANT_ADMIN_PASSWORD to also check the objects inside the tenant in a dry run.'
            } else {
                throw 'The tenant admin exists but its password is unknown. Set TENANT_ADMIN_PASSWORD, or re-run with -ResetAdminPassword.'
            }
        } else {
            if ($env:TENANT_ADMIN_PASSWORD) { $adminPw = $env:TENANT_ADMIN_PASSWORD } else { $adminPw = New-RandomPassword; $adminPwShown = $adminPw }
            if (-not $adminRoleId) {
                Write-Plan "Would create admin user '$adminUser' with role '$adminRoleName'"
            } else {
                $avail = Get-List (Invoke-MorpheusApi -Method GET -Path "/api/accounts/$tenantId/users/available-roles") 'roles'
                if (-not ($avail | Where-Object { [long]$_.id -eq $adminRoleId })) { Write-Warn "Role ID $adminRoleId is not listed as assignable in this tenant; creating the user may fail." }
                $user = [ordered]@{ username = $adminUser; email = $adminEmail; firstName = $adminFirst; lastName = $adminLast
                                    password = $adminPw; passwordConfirmation = $adminPw; roles = @(@{ id = $adminRoleId }) }
                $adminId = [long](OrDefault (P (Invoke-MorpheusApi -Method POST -Path "/api/accounts/$tenantId/users" -Body @{ user = $user }) 'user.id') 0)
                Save-ObjectRecord adminUser master $adminId $adminUser $true
                Write-Done "Created admin user (ID $adminId)" "Would create admin user '$adminUser'"
            }
        }
    }
    $roleIds[$adminRoleName] = $adminRoleId
    $userIds[$adminUser] = $adminId

    # =======================================================================
    # Sign in to the tenant. Everything after this point is created inside it.
    # =======================================================================
    $tenantReady = $false
    $loginPrefix = if ($subdomain) { $subdomain } elseif ($tenantId) { [string]$tenantId } else { '<tenant-id>' }
    if ($tenantId -and $adminId -and $adminPw) {
        Write-Step "Signing in to the tenant as '$loginPrefix\$adminUser'"
        Connect-MorpheusTenant -Prefix $loginPrefix -Username $adminUser -Password $adminPw
        $tw = Invoke-MorpheusApi -Method GET -Path '/api/whoami'
        if ((Get-OwnerId $tw.user) -ne $tenantId) { throw "Signed in, but the session belongs to tenant $(Get-OwnerId $tw.user), not $tenantId." }
        Write-Ok "Signed in (tenant ID $tenantId)"
        $tenantReady = $true
    }
    function Skip-TenantStage([string]$Text) { if ($tenantReady) { return $false }; Write-Plan $Text; return $true }

    # =======================================================================
    # 7. Groups
    # =======================================================================
    Write-Step 'Groups'
    foreach ($g in $groupsCfg) {
        if (Skip-TenantStage "Would create group '$g'$(if ($cloudMode -ne 'none') { " containing cloud $cloudName" })") { continue }
        $grp = Find-ByName (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/groups' -Query ([ordered]@{ name = $g; max = 1000 })) 'groups') 'name' $g
        if ($grp) {
            Write-Ok "Group '$g' exists (ID $($grp.id))"; Save-ObjectRecord group tenant $grp.id $g $false
        } else {
            $res = Invoke-MorpheusApi -Method POST -Path '/api/groups' -Body @{ group = @{ name = $g } }
            $grp = OrDefault (Get-Prop $res 'group') ([pscustomobject]@{ id = 0; zones = @() })
            Save-ObjectRecord group tenant $grp.id $g $true
            Write-Done "Created group '$g' (ID $($grp.id))" "Would create group '$g'"
        }
        $groupIds[$g] = [long]$grp.id
        $zoneIds = @(@(Get-Prop $grp 'zones') | Where-Object { $_ } | ForEach-Object { [long]$_.id })
        if ($cloudMode -ne 'none' -and $zoneIds -notcontains $cloudId) {
            if ($grp.id) {
                Invoke-MorpheusApi -Method PUT -Path "/api/groups/$($grp.id)/update-zones" -Body @{ group = @{ zones = @(@($zoneIds + $cloudId) | Sort-Object -Unique | ForEach-Object { @{ id = $_ } }) } } | Out-Null
            }
            Write-Done "Cloud '$cloudName' added to group '$g'" "Would add cloud '$cloudName' to group '$g'"
        }
    }

    # =======================================================================
    # 8. Roles (personas) and what they can reach
    # =======================================================================
    if ($rolesCfg.Count) { Write-Step 'Roles' }
    foreach ($r in $rolesCfg) {
        $rname = [string]$r.name; $rcopy = [string](OrDefault (P $r 'copyFrom') ''); $rpersona = [string](OrDefault (P $r 'defaultPersona') '')
        if (Skip-TenantStage "Would create role '$rname'$(if ($rcopy) { " (copied from '$rcopy')" }) and map its groups, features and persona") { continue }
        $troles = Get-TenantRoles
        $existing = Find-ByName $troles 'name' $rname
        if ($existing) {
            $rid = [long]$existing.id; Write-Ok "Role '$rname' exists (ID $rid)"; Save-ObjectRecord role tenant $rid $rname $false
            $dp = Get-Prop $existing 'defaultPersona'
            $dpCode = if ($dp -is [string]) { $dp } elseif ($dp) { Get-Prop $dp 'code' } else { $null }
            if ($rpersona -and $dpCode -ne $rpersona) {
                Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid" -Body @{ role = @{ defaultPersona = $rpersona } } | Out-Null
                Write-Done "Default persona of '$rname' set to $rpersona" "Would set the default persona of '$rname' to $rpersona"
            }
        } else {
            $role = [ordered]@{ authority = $rname; description = "PoC role for $tenantName"; roleType = 'user' }
            if ($rcopy) { $role.baseRoleId = [long](Select-MorpheusObject $rcopy 'Role to copy from (copyFrom)' $troles).id }
            if ($rpersona) { $role.defaultPersona = $rpersona }
            $rid = [long](OrDefault (P (Invoke-MorpheusApi -Method POST -Path '/api/roles' -Body @{ role = $role }) 'role.id') 0)
            Save-ObjectRecord role tenant $rid $rname $true
            Write-Done "Created role '$rname' (ID $rid)$(if ($rcopy) { ", copied from '$rcopy'" })" "Would create role '$rname'"
        }
        $roleIds[$rname] = $rid
        if (-not $rid) { Write-Plan "Would map groups, features and persona of '$rname'"; continue }

        $rg = $r.groups
        if ($null -eq $rg -or ($rg -is [string] -and $rg -eq 'all')) {
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-group" -Body ([ordered]@{ allGroups = $true; access = 'full' }) | Out-Null
            $gdesc = 'all groups'
        } else {
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-group" -Body ([ordered]@{ allGroups = $true; access = 'none' }) | Out-Null
            foreach ($g in @($rg)) { Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-group" -Body ([ordered]@{ groupId = $groupIds[$g]; access = 'full' }) | Out-Null }
            $gdesc = "groups $(@($rg) -join ', ')"
        }
        $nf = 0
        $features = P $r 'features'
        if ($features) {
            foreach ($prop in $features.PSObject.Properties) {
                Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-permission" -Body ([ordered]@{ permissionCode = $prop.Name; access = [string]$prop.Value }) | Out-Null
                $nf++
            }
        }
        if ($rpersona) { Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-persona" -Body ([ordered]@{ personaCode = $rpersona; access = 'full' }) | Out-Null }
        Write-Done "'$rname': $gdesc, $nf feature permission(s)$(if ($rpersona) { ", persona $rpersona" })" "Would map '$rname': $gdesc, $nf feature permission(s)"
    }

    # =======================================================================
    # 9. Users
    # =======================================================================
    if ($usersCfg.Count) { Write-Step 'Users' }
    foreach ($u in $usersCfg) {
        $uname = [string]$u.username; $urole = [string]$u.role
        if (Skip-TenantStage "Would create user '$uname' with role '$urole'") { continue }
        $rid = $roleIds[$urole]
        if (-not $rid) { $rid = [long](Select-MorpheusObject $urole "Role of user $uname" (Get-TenantRoles)).id }
        $existing = Find-ByName (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/users' -Query ([ordered]@{ username = $uname; max = 1000 })) 'users') 'username' $uname
        if ($existing) {
            $uid = [long]$existing.id; Write-Ok "User '$uname' exists (ID $uid) - password and roles left unchanged"; Save-ObjectRecord user tenant $uid $uname $false
        } else {
            $pw = New-RandomPassword
            $user = [ordered]@{ username = $uname; email = [string]$u.email; firstName = (OrDefault (P $u 'firstName') $uname); lastName = (OrDefault (P $u 'lastName') 'PoC')
                                password = $pw; passwordConfirmation = $pw; roles = @(@{ id = [long](OrDefault $rid 0) }); passwordExpired = [bool](OrDefault (P $u 'mustChangePassword') $false) }
            $uid = [long](OrDefault (P (Invoke-MorpheusApi -Method POST -Path '/api/users' -Body @{ user = $user }) 'user.id') 0)
            Save-ObjectRecord user tenant $uid $uname $true
            if (-not $DryRun) { $newPasswords.Add(@($uname, $pw)) }
            Write-Done "Created user '$uname' (ID $uid) with role '$urole'" "Would create user '$uname' with role '$urole'"
        }
        $userIds[$uname] = $uid
    }

    # =======================================================================
    # 10. Tag dropdowns: one option list + one select input per tag
    # =======================================================================
    if ($tagsCfg.Count) { Write-Step 'Tag dropdowns' }
    foreach ($t in $tagsCfg) {
        $tname = [string]$t.name; $tlabel = [string](OrDefault (P $t 'label') $t.name)
        $tagField[$tname] = "tag$(Get-FieldName $tname)"
        if (Skip-TenantStage "Would create option list '$prefix - $tname values' and select input '$prefix - $tlabel'") { continue }
        $dataset = ConvertTo-Dataset @(@($t.values) | ForEach-Object { [ordered]@{ name = [string]$_; value = [string]$_ } })
        $tagListId[$tname] = Resolve-OptionList "$prefix - $tname values" $dataset
        $tagInputId[$tname] = Resolve-Input ([ordered]@{ name = "$prefix - $tlabel"; fieldName = $tagField[$tname]; type = 'select'; fieldLabel = $tlabel
                                                       required = $true; exportMeta = $false; optionList = @{ id = $tagListId[$tname] } })
    }
    $tagInputIds = @($tagsCfg | ForEach-Object { [long](OrDefault $tagInputId[[string]$_.name] 0) })
    $tagTags = @($tagsCfg | ForEach-Object { [ordered]@{ name = [string]$_.name; value = "<%= customOptions.$($tagField[[string]$_.name]) %>" } })
    function Get-StaticTags($Source) {
        $st = P $Source 'staticTags'
        if (-not $st) { return @() }
        return @($st.PSObject.Properties | ForEach-Object { [ordered]@{ name = $_.Name; value = [string]$_.Value } })
    }

    # =======================================================================
    # 11. VM catalog item
    # =======================================================================
    if ($vm) {
        Write-Step "Catalog item '$($vm.name)'"
        if (-not (Skip-TenantStage "Would create plan list, inputs and catalog item '$($vm.name)' in the tenant")) {
            $vmGroupId = [long]$groupIds[[string]$vm.group]
            Assert-TenantSees image $vmImage "Image '$($vm.image)'"
            Assert-TenantSees network $vmNet "Network '$($vm.network)'"
            Assert-TenantSees pool $vmPool "Resource pool '$($vm.resourcePool)'"
            Assert-TenantSees datastore $vmDs "Datastore '$($vm.datastore)'"
            foreach ($p in $vmPlans) { Assert-TenantSees plan $p.id "Service plan '$($p.name)'" }
            Write-Ok 'The tenant can see the image, network, resource pool, datastore and plans'

            $planListId = Resolve-OptionList "$prefix - Plan Sizes" (ConvertTo-Dataset @($vmPlans | ForEach-Object { [ordered]@{ name = $_.name; value = $_.id } }))
            $inputIds = [System.Collections.Generic.List[long]]::new()
            if (-not $namingFixed) {
                $inputIds.Add((Resolve-Input ([ordered]@{ name = "$prefix - VM Name"; fieldName = 'customVmName'; type = 'text'; fieldLabel = 'Server Name'
                    required = $true; exportMeta = $false; verifyPattern = '^[a-zA-Z][a-zA-Z0-9-]{0,62}$'; placeHolder = 'e.g. app-web-01' })))
            }
            $inputIds.Add((Resolve-Input ([ordered]@{ name = "$prefix - Description"; fieldName = 'customDesc'; type = 'textarea'; fieldLabel = 'Purpose / Description'; required = $false; exportMeta = $false })))
            $inputIds.Add((Resolve-Input ([ordered]@{ name = "$prefix - Plan"; fieldName = 'customPlan'; type = 'select'; fieldLabel = 'Server Size'; required = $true; exportMeta = $false; optionList = @{ id = $planListId } })))
            $inputIds.Add((Resolve-Input ([ordered]@{ name = "$prefix - Disk"; fieldName = 'customDiskSize'; type = 'number'; fieldLabel = 'Root Disk Size (GB)'; required = $true; exportMeta = $false
                defaultValue = [string](OrDefault (P $vm 'defaultDiskGB') 40) })))
            foreach ($i in $tagInputIds) { $inputIds.Add($i) }

            # Provisioning config: the structure of the lab script proven on a VME appliance (examples/create-catalog-tile.ps1).
            # <%= customOptions.<fieldName> %> is replaced with what the user picked on the order form.
            $type = OrDefault (P $vm 'instanceTypeCode') 'mvm'
            $vmNameValue = if ($namingFixed) { [string]$cfg.policies.naming.pattern } else { '<%= customOptions.customVmName %>' }
            $dsValue = if ([string]$vmDs -match '^\d+$') { [long]$vmDs } else { [string]$vmDs }
            $item = [ordered]@{
                name = [string]$vm.name; code = (Get-Slug "$prefix-$($vm.name)"); description = (OrDefault (P $vm 'description') 'Self-service VM')
                type = 'instance'; visibility = 'private'; enabled = $true; featured = [bool](OrDefault (P $vm 'featured') $true)
                formType = 'optionTypes'; optionTypes = [long[]]$inputIds.ToArray()
                config = [ordered]@{
                    plan        = @{ id = '<%= customOptions.customPlan %>' }
                    servicePlan = @{ id = '<%= customOptions.customPlan %>' }
                    layout      = @{ id = $vmLayout }
                    group       = @{ id = $vmGroupId }
                    zoneId      = $cloudId
                    instance    = [ordered]@{ name = $vmNameValue; description = '<%= customOptions.customDesc %>'; type = $type
                                              site = @{ id = $vmGroupId }; layout = @{ id = $vmLayout }; plan = @{ id = '<%= customOptions.customPlan %>' } }
                    config      = [ordered]@{ imageId = $vmImage; resourcePoolId = "pool-$vmPool"; poolProviderType = (OrDefault (P $vm 'poolProviderType') 'mvm'); createUser = $true }
                    volumes     = @([ordered]@{ id = -1; rootVolume = $true; name = 'root'; size = '<%= customOptions.customDiskSize %>'
                                                storageType = (OrDefault (P $vm 'storageTypeId') 1); datastoreId = $dsValue })
                    networkInterfaces = @(@{ network = @{ id = $vmNet } })
                    tags        = @(@($tagTags) + @(Get-StaticTags $vm))
                }
            }
            if (P $vm 'category') { $item.category = [string]$vm.category }
            $catalogIds[[string]$vm.name] = Resolve-CatalogItem $item
        }
    }

    # =======================================================================
    # 12. 3-tier app: blueprint + catalog item
    # =======================================================================
    if ($tt) {
        $bpName = [string]$tt.name; $bpGroup = [string]$tt.group
        Write-Step "3-tier app '$bpName'"
        if (-not (Skip-TenantStage "Would create blueprint '$bpName', an App Name input and its catalog item in the tenant")) {
            Assert-TenantSees network $bpNet "Network '$($tt.network)'"
            Assert-TenantSees pool $bpPool "Resource pool '$($tt.resourcePool)'"
            Assert-TenantSees datastore $bpDs "Datastore '$($tt.datastore)'"
            foreach ($tier in $bpTiers) { Assert-TenantSees image $tier.imageId "Image ID $($tier.imageId)"; Assert-TenantSees plan $tier.planId "Service plan ID $($tier.planId)" }

            $type = OrDefault (P $tt 'instanceTypeCode') 'mvm'
            $dsValue = if ([string]$bpDs -match '^\d+$') { [long]$bpDs } else { [string]$bpDs }
            if ($bpTemplate) {
                # An exported blueprint: point its single group and cloud at this tenant's group and cloud.
                function Set-BlueprintTarget($node) {
                    if ($node -is [System.Collections.IDictionary]) {
                        if ($node.Contains('groups') -and $node.groups -is [System.Collections.IDictionary] -and $node.groups.Count -eq 1) {
                            $gv = @($node.groups.Values)[0]
                            if ($gv -is [System.Collections.IDictionary] -and $gv.Contains('clouds') -and $gv.clouds -is [System.Collections.IDictionary] -and $gv.clouds.Count -eq 1) {
                                $gv.clouds = [ordered]@{ $cloudName = @($gv.clouds.Values)[0] }
                            }
                            $node.groups = [ordered]@{ $bpGroup = $gv }
                        }
                        foreach ($k in @($node.Keys)) { Set-BlueprintTarget $node[$k] }
                    } elseif ($node -is [System.Collections.IList]) { foreach ($x in $node) { Set-BlueprintTarget $x } }
                }
                $tpl = Get-Content -LiteralPath $bpTemplate -Raw | ConvertFrom-Json -AsHashtable -Depth 100
                Set-BlueprintTarget $tpl.tiers
                $bpBody = [ordered]@{ name = $bpName; type = 'morpheus'; tiers = $tpl.tiers }
            } else {
                $tiers = [ordered]@{}
                for ($i = 0; $i -lt $bpTiers.Count; $i++) {
                    $tier = $bpTiers[$i]
                    $tiers[$tier.name] = [ordered]@{
                        tierIndex = $i + 1; linkedTiers = @($tier.linkTo)
                        instances = @([ordered]@{
                            instance = @{ type = $type }
                            groups   = [ordered]@{ $bpGroup = @{ clouds = [ordered]@{ $cloudName = [ordered]@{
                                instance = [ordered]@{ type = $type; layout = @{ id = $tier.layoutId }; name = "$($tier.name.ToLowerInvariant())-`${sequence}" }
                                plan     = @{ id = $tier.planId }
                                config   = [ordered]@{ imageId = $tier.imageId; resourcePoolId = "pool-$bpPool"; poolProviderType = (OrDefault (P $tt 'poolProviderType') 'mvm'); createUser = $true }
                                volumes  = @([ordered]@{ rootVolume = $true; name = 'root'; size = $tier.diskGB; storageType = (OrDefault (P $tt 'storageTypeId') 1); datastoreId = $dsValue })
                                networkInterfaces = @([ordered]@{ primaryInterface = $true; network = @{ id = $bpNet } })
                                tags     = @(Get-StaticTags $tt)
                            } } } }
                        })
                    }
                }
                $bpBody = [ordered]@{ name = $bpName; type = 'morpheus'; tiers = $tiers }
            }
            $bp = Find-ByName (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/blueprints' -Query ([ordered]@{ name = $bpName; max = 1000 })) 'blueprints') 'name' $bpName
            if ($bp) {
                $bpId = [long]$bp.id; Write-Ok "Blueprint '$bpName' exists (ID $bpId) - left unchanged"; Save-ObjectRecord blueprint tenant $bpId $bpName $false
            } else {
                $bpId = [long](OrDefault (P (Invoke-MorpheusApi -Method POST -Path '/api/blueprints' -Body $bpBody) 'blueprint.id') 0)
                Save-ObjectRecord blueprint tenant $bpId $bpName $true
                Write-Done "Created blueprint '$bpName' (ID $bpId) with tiers $(@($bpBody.tiers.Keys) -join ', ')" "Would create blueprint '$bpName'"
            }

            $appInput = Resolve-Input ([ordered]@{ name = "$prefix - App Name"; fieldName = 'customAppName'; type = 'text'; fieldLabel = 'Application Name'
                required = $true; exportMeta = $false; verifyPattern = '^[a-zA-Z][a-zA-Z0-9-]{0,40}$'; placeHolder = 'e.g. payroll' })

            # App Spec (YAML) used when the item is ordered: app name and tags come from the order form.
            function Q([string]$s) { ConvertTo-Json -InputObject $s -Compress }
            $allTags = @(@($tagTags) + @(Get-StaticTags $tt))
            $spec = [System.Collections.Generic.List[string]]::new()
            $spec.Add('name: "<%= customOptions.customAppName %>"'); $spec.Add('group:'); $spec.Add("  name: $(Q $bpGroup)"); $spec.Add('tiers:')
            foreach ($tn in @($bpBody.tiers.Keys)) {
                $spec.Add("  $(Q $tn):"); $spec.Add('    instances:'); $spec.Add('      - instance:'); $spec.Add("          type: $(Q $type)"); $spec.Add("          cloud: $(Q $cloudName)")
                if ($allTags.Count) {
                    $spec.Add('        tags:')
                    foreach ($tg in $allTags) { $spec.Add("          - name: $(Q $tg.name)"); $spec.Add("            value: $(Q $tg.value)") }
                }
            }
            $bpItem = [ordered]@{
                name = $bpName; code = (Get-Slug "$prefix-$bpName"); description = (OrDefault (P $tt 'description') 'Multi-tier application')
                type = 'blueprint'; visibility = 'private'; enabled = $true; featured = $true; blueprint = @{ id = $bpId }
                appSpec = ($spec -join "`n"); formType = 'optionTypes'; optionTypes = [long[]]@(@($appInput) + $tagInputIds)
            }
            $catalogIds[$bpName] = Resolve-CatalogItem $bpItem
            $blueprintOf[$bpName] = $bpId
        }
    }

    # =======================================================================
    # 13. Role access to catalog items and blueprints
    # =======================================================================
    $accessRoles = @($rolesCfg | Where-Object { $null -ne (P $_ 'catalogItems') })
    if ($accessRoles.Count) { Write-Step 'Catalog access per role' }
    foreach ($r in $accessRoles) {
        $rname = [string]$r.name; $rid = [long](OrDefault $roleIds[$rname] 0); $ci = $r.catalogItems
        if (-not $tenantReady -or -not $rid) { Write-Plan "Would give '$rname' access to catalog items: $(@($ci) -join ', ')"; continue }
        if ($ci -is [string] -and $ci -eq 'all') {
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-catalog-item-type" -Body ([ordered]@{ allCatalogItemTypes = $true; access = 'full' }) | Out-Null
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-blueprint" -Body ([ordered]@{ allBlueprints = $true; access = 'full' }) | Out-Null
            Write-Done "'$rname' can order every catalog item" "Would let '$rname' order every catalog item"
        } elseif ($ci -is [string] -and $ci -eq 'none') {
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-catalog-item-type" -Body ([ordered]@{ allCatalogItemTypes = $true; access = 'none' }) | Out-Null
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-blueprint" -Body ([ordered]@{ allBlueprints = $true; access = 'none' }) | Out-Null
            Write-Done "'$rname' has no catalog access" "Would remove catalog access from '$rname'"
        } else {
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-catalog-item-type" -Body ([ordered]@{ allCatalogItemTypes = $true; access = 'none' }) | Out-Null
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-blueprint" -Body ([ordered]@{ allBlueprints = $true; access = 'none' }) | Out-Null
            foreach ($it in @($ci)) {
                $cid = $catalogIds[[string]$it]
                if (-not $cid) { $cid = [long](Select-MorpheusObject ([string]$it) 'Catalog item' (Get-List (Invoke-MorpheusApi -Method GET -Path '/api/catalog-item-types' -Query ([ordered]@{ name = [string]$it; max = 1000 })) 'catalogItemTypes')).id }
                if ($cid) { Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-catalog-item-type" -Body ([ordered]@{ catalogItemTypeId = [long]$cid; access = 'full' }) | Out-Null }
                if ($blueprintOf[[string]$it]) { Invoke-MorpheusApi -Method PUT -Path "/api/roles/$rid/update-blueprint" -Body ([ordered]@{ blueprintId = [long]$blueprintOf[[string]$it]; access = 'full' }) | Out-Null }
            }
            Write-Done "'$rname' can order: $(@($ci) -join ', ')" "Would let '$rname' order: $(@($ci) -join ', ')"
        }
    }

    # =======================================================================
    # 14. Policies (inside the tenant)
    # =======================================================================
    $pol = P $cfg 'policies'
    if ($pol) {
        Write-Step 'Policies'
        if (-not (Skip-TenantStage 'Would create the naming, approval, tag and quota policies in the tenant')) {
            if (P $pol 'naming') {
                $n = $pol.naming
                Resolve-Policy "$prefix - Instance naming" 'naming' ([ordered]@{ namingType = (OrDefault (P $n 'enforcement') 'user'); namingPattern = [string]$n.pattern
                    namingConflict = $(if ((P $n 'autoResolveConflicts') -eq $false) { '' } else { 'on' }) }) (OrDefault (P $n 'scope') 'global') $false
            }
            if (P $pol 'approval') {
                Resolve-Policy "$prefix - Provision approval" 'provisionApproval' ([ordered]@{ accountIntegrationId = '-100' }) (OrDefault (P $pol.approval 'scope') 'global') ([bool](OrDefault (P $pol.approval 'eachUser') $true))
            }
            if (P $pol 'tagEnforcement') {
                foreach ($t in $tagsCfg) {
                    Resolve-Policy "$prefix - Tag $($t.name)" 'tags' ([ordered]@{ strict = [bool](OrDefault (P $pol.tagEnforcement 'strict') $true); key = [string]$t.name; valueListId = [long](OrDefault $tagListId[[string]$t.name] 0) }) (OrDefault (P $pol.tagEnforcement 'scope') 'global') $false
                }
            }
            foreach ($q in @(P $pol 'quotas' | Where-Object { $_ })) {
                foreach ($m in @(@('maxVms', 'maxVms', 'Max VMs'), @('maxCores', 'maxCores', 'Max cores'), @('maxMemoryGB', 'maxMemory', 'Max memory (GB)'), @('maxStorageGB', 'maxStorage', 'Max storage (GB)'))) {
                    $v = P $q $m[0]
                    if ($null -eq $v) { continue }
                    Resolve-Policy "$($q.name) - $($m[2])" $m[1] ([ordered]@{ $m[1] = $v }) (OrDefault (P $q 'scope') 'global') ([bool](OrDefault (P $q 'eachUser') $true))
                }
            }
        }
    }

    # =======================================================================
    # Summary
    # =======================================================================
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host ($(if ($DryRun) { ' DRY RUN COMPLETE - nothing was changed' } else { ' PoC TENANT READY' })) -ForegroundColor Green
    Write-Host (' {0,-14} {1} ({2})' -f 'Tenant:', $tenantName, (Format-Id $tenantId))
    if ($cloudMode -ne 'none') { Write-Host (' {0,-14} {1} - {2}' -f 'Cloud:', $cloudName, $cloudMode) }
    Write-Host (' {0,-14} {1}' -f 'Groups:', ($groupsCfg -join ', '))
    Write-Host (' {0,-14} {1}  as  {2}\{3}' -f 'Sign in:', $baseUrl, $loginPrefix, $adminUser)
    if ($adminPwShown -and -not $DryRun) { Write-Host (' {0,-14} {1}' -f 'Admin password:', $adminPwShown) -ForegroundColor Yellow }
    foreach ($e in $newPasswords) { Write-Host (' {0,-14} {1}  password {2}' -f 'New user:', $e[0], $e[1]) -ForegroundColor Yellow }
    if (($adminPwShown -or $newPasswords.Count) -and -not $DryRun) { Write-Host '                (passwords are shown once - store them in your password manager)' -ForegroundColor Yellow }
    if (-not $DryRun) {
        Write-Host (' {0,-14} {1}' -f 'State file:', $manifestFile)
        Write-Host (' {0,-14} {1}' -f 'Undo with:', "powershell/Remove-PocTenant.ps1 -Config $Config")
    }
    Write-Host '================================================================' -ForegroundColor Cyan
}
catch {
    Write-Host "`n[error] $($_.Exception.Message)" -ForegroundColor Red
    $hint = if ($script:Hint) { $script:Hint } else { 'Fix the cause and re-run; completed steps are reused.' }
    Write-Host "        $hint" -ForegroundColor Red
    exit 1
}

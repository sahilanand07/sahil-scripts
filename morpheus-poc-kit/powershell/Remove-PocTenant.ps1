#Requires -Version 7.0
<#
.SYNOPSIS
    Undoes what Invoke-PocOnboarding.ps1 (or bash/poc-onboard.sh) built, using its state file.

.DESCRIPTION
    Only objects the kit CREATED are deleted. Objects it reused are left alone, and changes it made
    to shared infrastructure are reverted precisely:
      - the tenant is removed from each resource pool / datastore / network it was shared with
        (other tenants on those resources keep their access);
      - a cloud assigned to the tenant (dedicated mode) is given back to the master tenant BEFORE the
        tenant is deleted - deleting a tenant also deletes the clouds assigned to it;
      - a cloud the kit made Public stays Public unless -RestoreCloudVisibility is given, because
        other tenants may rely on it by now.

    When the kit created the tenant, deleting the tenant removes everything inside it (groups, roles,
    users, inputs, catalog items, blueprints, policies). With -KeepTenant, or when the tenant existed
    before the kit ran, those objects are deleted one by one instead, signed in as the tenant admin.

    Environment: MORPHEUS_URL, MORPHEUS_TOKEN (master-tenant admin); TENANT_ADMIN_PASSWORD (only
    needed when objects inside a kept tenant must be deleted and the admin user wasn't created by the kit).

.EXAMPLE
    ./Remove-PocTenant.ps1 -Config ../customers/acme.json -DryRun
.EXAMPLE
    ./Remove-PocTenant.ps1 -Manifest ../state/acme.json -Yes -RemoveResources
#>
[CmdletBinding(DefaultParameterSetName = 'Config')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Config')][string]$Config,
    [Parameter(Mandatory, ParameterSetName = 'Manifest')][string]$Manifest,
    [string]$StateDir = (Join-Path $PSScriptRoot '..' 'state'),
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$RemoveResources,
    [switch]$KeepTenant,
    [switch]$RestoreCloudVisibility,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorpheusPoc.psm1') -Force

try {
    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        if (-not (Test-Path -LiteralPath $Config)) { throw "Config file '$Config' not found." }
        $c = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
        $key = if ($c.tenant.subdomain) { $c.tenant.subdomain } else { $c.tenant.name }
        $Manifest = Join-Path $StateDir "$(Get-Slug $key).json"
    }
    if (-not (Test-Path -LiteralPath $Manifest)) { throw "State file '$Manifest' not found - nothing recorded to undo." }
    $m = Read-Manifest $Manifest
    if ($m.kit -ne 'morpheus-poc-kit') { throw "$Manifest is not a morpheus-poc-kit state file." }
    $items = @($m.items | Where-Object { $_ })

    $baseUrl = Initialize-MorpheusSession -SkipCertificateCheck:$SkipCertificateCheck -DryRun:$DryRun -Yes:$Yes
    $script:Hint = "Fix the cause and re-run teardown; finished steps are skipped. State: $Manifest"
    if (([string]$m.appliance).TrimEnd('/') -ne $baseUrl) { throw "This state file belongs to $($m.appliance), but MORPHEUS_URL is $baseUrl." }

    $tenantName = [string]$m.tenantName
    $tenantId = [long]($m.tenantId ?? 0)
    $subdomain = [string]($m.subdomain ?? '')
    function First-Item([string]$Kind, [string]$Action) {
        $items | Where-Object { $_.kind -eq $Kind -and (-not $Action -or $_.action -eq $Action) } | Select-Object -First 1
    }
    $tenantCreated = [bool](First-Item 'tenant' 'created')
    $deleteTenant = $tenantCreated -and -not $KeepTenant
    $createdCount = @($items | Where-Object { $_.action -eq 'created' }).Count
    $changedCount = @($items | Where-Object { $_.action -eq 'changed' }).Count
    $tenantGone = $false

    if ($DryRun) { Write-Host "`nDRY RUN - nothing will be deleted or changed." -ForegroundColor Magenta }

    Write-Step 'Checking access'
    $whoami = Invoke-MorpheusApi -Method GET -Path '/api/whoami'
    if (-not $whoami.isMasterAccount) { throw 'MORPHEUS_TOKEN must belong to a user in the MASTER tenant.' }
    Write-Ok "Connected as '$($whoami.user.username)'"
    if ($tenantId) {
        $r = Invoke-MorpheusApiStatus -Method GET -Path "/api/accounts/$tenantId"
        if ($r.Code -eq 404) {
            Write-Warn "Tenant '$tenantName' (ID $tenantId) no longer exists - only the master-side changes will be undone."
            $deleteTenant = $false; $tenantGone = $true
        } elseif ($r.Code -ne 200) { throw "Could not read tenant $tenantId (HTTP $($r.Code)): $(Get-ApiErrorText $r)" }
    }

    if ($deleteTenant) {
        Confirm-Change "Tenant '$tenantName' (ID $tenantId) will be DELETED with everything inside it, and $changedCount change(s) to shared infrastructure will be reverted."
    } else {
        Confirm-Change "$createdCount object(s) created by the kit for '$tenantName' will be deleted and $changedCount change(s) reverted. The tenant itself is kept."
    }
    if ($RemoveResources -and $deleteTenant) { Write-Warn '-RemoveResources: instances and apps in the tenant will be deleted too.' }

    function Remove-Thing([string]$Path, [string]$Label) {
        $r = Invoke-MorpheusApiStatus -Method DELETE -Path $Path
        switch ($r.Code) {
            { $_ -in 200, 204 } { Write-Done "Deleted $Label" "Would delete $Label"; return }
            404 { Write-Ok "$Label was already gone"; return }
            default { throw "Could not delete $Label (HTTP $($r.Code)): $(Get-ApiErrorText $r)" }
        }
    }

    # -----------------------------------------------------------------------
    # 1. Objects inside a kept tenant (signed in as its admin)
    # -----------------------------------------------------------------------
    $tenantItems = @($items | Where-Object { $_.scope -eq 'tenant' -and $_.action -eq 'created' })
    [array]::Reverse($tenantItems)
    if (-not $deleteTenant -and -not $tenantGone -and $tenantItems.Count -gt 0) {
        Write-Step "Objects the kit created inside tenant '$tenantName'"
        $admin = First-Item 'adminUser' ''
        if (-not $admin) { throw 'The state file has no tenant admin, so the kit cannot sign in to the tenant.' }
        $pw = $env:TENANT_ADMIN_PASSWORD
        if (-not $pw -and $admin.action -eq 'created') {
            # The kit made this user, so it may set a fresh password to sign in with.
            $pw = New-RandomPassword
            if (-not $DryRun) {
                Invoke-MorpheusApi -Method PUT -Path "/api/accounts/$tenantId/users/$($admin.id)" -Body @{ user = [ordered]@{ password = $pw; passwordConfirmation = $pw } } | Out-Null
                Write-Ok "Set a temporary password for '$($admin.name)' to sign in with"
            }
        }
        if (-not $pw) { throw "Set TENANT_ADMIN_PASSWORD for '$($admin.name)' so the kit can sign in to the tenant." }
        if ($DryRun -and -not $env:TENANT_ADMIN_PASSWORD) {
            foreach ($it in $tenantItems) { Write-Plan "Would delete $($it.kind) '$($it.name)' (ID $($it.id))" }
        } else {
            Connect-MorpheusTenant -Prefix $(if ($subdomain) { $subdomain } else { [string]$tenantId }) -Username $admin.name -Password $pw
            $paths = @{ policy = '/api/policies'; catalogItem = '/api/catalog-item-types'; blueprint = '/api/blueprints'; input = '/api/library/option-types'
                        optionList = '/api/library/option-type-lists'; user = '/api/users'; role = '/api/roles'; group = '/api/groups' }
            foreach ($it in $tenantItems) {
                if (-not $paths.Contains([string]$it.kind)) { Write-Warn "Unknown item kind '$($it.kind)' - skipped"; continue }
                Remove-Thing "$($paths[[string]$it.kind])/$($it.id)" "$($it.kind) '$($it.name)' (ID $($it.id))"
            }
            Set-MorpheusContext master
        }
    }

    # -----------------------------------------------------------------------
    # 2. Shared infrastructure: un-share resources, give a dedicated cloud back
    # -----------------------------------------------------------------------
    $shares = @($items | Where-Object { $_.kind -eq 'share' -and $_.action -eq 'changed' })
    [array]::Reverse($shares)
    if ($shares.Count -gt 0 -and $tenantId) {
        Write-Step 'Removing the tenant from shared resources'
        foreach ($it in $shares) {
            $label = "$($it.resource) '$($it.name)' (ID $($it.id))"
            $st = Get-ResourceState -Kind $it.resource -CloudId $it.cloudId -Id $it.id
            if (-not $st) { Write-Ok "$label no longer exists"; continue }
            if ($st.Tenants -notcontains $tenantId) { Write-Ok "$label is no longer shared with the tenant"; continue }
            $remaining = [long[]]@($st.Tenants | Where-Object { $_ -ne $tenantId })
            Set-ResourceTenants $st $remaining
            Write-Done "$label no longer shared with the tenant ($($remaining.Count) other tenant(s) keep access)" "Would remove the tenant from $label"
        }
    }

    $owner = First-Item 'cloudOwner' 'changed'
    if ($owner) {
        Write-Step "Giving cloud '$($owner.name)' back to the master tenant"
        $r = Invoke-MorpheusApiStatus -Method GET -Path "/api/zones/$($owner.id)"
        if ($r.Code -eq 404) { Write-Warn "Cloud ID $($owner.id) no longer exists." }
        else {
            $current = Get-OwnerId (Get-Prop $r.Body 'zone')
            if ($current -ne [long]$owner.to) { Write-Ok "Cloud is no longer assigned to the tenant (owner tenant ID $current) - left as is" }
            else {
                Invoke-MorpheusApi -Method PUT -Path "/api/zones/$($owner.id)" -Body @{ zone = [ordered]@{ accountId = [long]$owner.from; visibility = ($owner.fromVisibility ?? 'private') } } | Out-Null
                Write-Done "Cloud assigned back to tenant ID $($owner.from)" "Would assign the cloud back to tenant ID $($owner.from)"
            }
        }
    }

    # -----------------------------------------------------------------------
    # 3. Tenant, tenant admin, tenant role
    # -----------------------------------------------------------------------
    if ($deleteTenant) {
        Write-Step "Deleting tenant '$tenantName' (ID $tenantId)"
        $q = if ($RemoveResources) { '?removeResources=true' } else { '' }
        $r = Invoke-MorpheusApiStatus -Method DELETE -Path "/api/accounts/$tenantId$q"
        switch ($r.Code) {
            { $_ -in 200, 204 } { Write-Done "Deleted tenant '$tenantName' and everything inside it" "Would delete tenant '$tenantName' and everything inside it" }
            404 { Write-Ok 'Tenant was already gone' }
            default { throw "Could not delete the tenant (HTTP $($r.Code)): $(Get-ApiErrorText $r). If it still has instances, remove them or re-run with -RemoveResources." }
        }
    } elseif (-not $tenantGone -and $tenantId) {
        $admin = First-Item 'adminUser' 'created'
        $arole = First-Item 'adminRole' 'created'
        if ($admin -or $arole) { Write-Step 'Tenant admin created by the kit' }
        if ($admin) { Remove-Thing "/api/accounts/$tenantId/users/$($admin.id)" "admin user '$($admin.name)'" }
        if ($arole) { Remove-Thing "/api/roles/$($arole.id)" "admin role '$($arole.name)'" }
    }

    $trole = First-Item 'tenantRole' 'created'
    if ($trole) {
        Write-Step "Tenant role '$($trole.name)'"
        $baseRole = $null
        if (-not $deleteTenant -and -not $tenantGone -and $tenantId) {
            $acct = Invoke-MorpheusApi -Method GET -Path "/api/accounts/$tenantId"
            $baseRole = Get-Prop (Get-Prop $acct.account 'role') 'id'
        }
        if ($baseRole -and [long]$baseRole -eq [long]$trole.id) { Write-Ok "Kept - tenant '$tenantName' still uses it as its base role" }
        else { Remove-Thing "/api/roles/$($trole.id)" "tenant role '$($trole.name)'" }
    }

    $vis = First-Item 'cloudVisibility' 'changed'
    if ($vis) {
        Write-Step "Cloud '$($vis.name)' visibility"
        if ($RestoreCloudVisibility) {
            $r = Invoke-MorpheusApiStatus -Method GET -Path "/api/zones/$($vis.id)"
            if ($r.Code -eq 404) { Write-Warn 'Cloud no longer exists.' }
            else {
                Invoke-MorpheusApi -Method PUT -Path "/api/zones/$($vis.id)" -Body @{ zone = @{ visibility = $vis.from } } | Out-Null
                Write-Done "Visibility set back to $($vis.from)" "Would set the visibility back to $($vis.from)"
            }
        } else {
            Write-Info 'The kit made this cloud Public. It stays Public because other tenants may use it now;'
            Write-Info "re-run with -RestoreCloudVisibility to set it back to $($vis.from)."
        }
    }

    Write-Host "`n================================================================" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host ' DRY RUN COMPLETE - nothing was changed' -ForegroundColor Green
    } else {
        $archive = ($Manifest -replace '\.json$', '') + ".removed-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
        Move-Item -LiteralPath $Manifest -Destination $archive
        Write-Host ' TEARDOWN COMPLETE' -ForegroundColor Green
        Write-Host (' {0,-12} {1}' -f 'State file:', "archived as $archive")
    }
    Write-Host '================================================================' -ForegroundColor Cyan
}
catch {
    Write-Host "`n[error] $($_.Exception.Message)" -ForegroundColor Red
    $hint = if ($script:Hint) { $script:Hint } else { 'Fix the cause and re-run teardown; finished steps are skipped.' }
    Write-Host "        $hint" -ForegroundColor Red
    exit 1
}

#Requires -Version 7.0
<#
.SYNOPSIS
    Creates a ready-to-use sub-tenant on HPE Morpheus Enterprise / HPE VM Essentials (VME) Manager.

.DESCRIPTION
    Builds everything a new sub-tenant needs, in this order:

      1. Checks the API token belongs to a master-tenant user.
      2. Checks the target cloud (read-only) and, in "shared" mode, makes it Public.
      3. Tenant Role  - the permission ceiling for the tenant, copied from a template role,
                        with Full access to the cloud ("shared" mode).
      4. Tenant       - created with the Tenant Role as its Base Role.
      5. Cloud        - "dedicated" mode assigns the whole cloud to the tenant;
                        "shared" mode shares the resource pools / datastores / networks you list.
      6. Group        - a group inside the tenant that contains the cloud.
      7. User Role    - an admin role owned by the tenant (or an existing one, e.g. a multitenant copy).
      8. Admin user   - a local user in the tenant with that role.

    Every step is "get or create": re-running the script with the same names finishes a partly
    completed run instead of creating duplicates. Changes that affect other tenants (making a
    cloud Public, assigning a cloud to a tenant) ask for confirmation unless -Yes is given.

    Credentials are read from environment variables, never from the script:
      MORPHEUS_URL            e.g. https://vme-manager.example.local
      MORPHEUS_TOKEN          API access token of a master-tenant admin
      TENANT_ADMIN_PASSWORD   optional; otherwise you are prompted (or use -GeneratePassword)
      MORPHEUS_SKIP_TLS_VERIFY optional; true = ignore SSL certificate errors (lab appliances)

.PARAMETER CloudMode
    shared    : cloud stays in the master tenant, is made Public, and the tenant role gets Full access.
                Share individual resource pools / datastores / networks with -ResourcePoolIds etc.
    dedicated : the whole cloud and all its resources are assigned to this tenant only.
    none      : do not touch any cloud (no group is created either).

.EXAMPLE
    $env:MORPHEUS_URL = 'https://vme-manager.example.local'
    $env:MORPHEUS_TOKEN = '<token>'
    ./New-MorpheusTenant.ps1 -TenantName 'Acme' -Subdomain 'acme' -CloudId 1 -CloudMode shared `
        -ResourcePoolIds 3 -DatastoreIds 7,8 -NetworkIds 12 `
        -AdminUsername 'acme_admin' -AdminEmail 'admin@acme.example' -GeneratePassword

.EXAMPLE
    ./New-MorpheusTenant.ps1 -TenantName 'Acme' -CloudId 1 -CloudMode dedicated `
        -AdminUsername 'acme_admin' -AdminEmail 'admin@acme.example' -DryRun

.NOTES
    Requires PowerShell 7+. Not an official HPE tool - review and test in a lab before production use.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantName,
    [string]$TenantDescription,
    [ValidatePattern('^[A-Za-z0-9-]*$')][string]$Subdomain,
    [ValidatePattern('^[A-Z]{3}$')][string]$Currency = 'USD',

    [string]$TenantRoleName,
    [string]$TenantRoleTemplate = 'Tenant Admin',

    [ValidateRange(1, [long]::MaxValue)][long]$CloudId,
    [ValidateSet('shared', 'dedicated', 'none')][string]$CloudMode = 'shared',
    [string[]]$ResourcePoolIds = @(),
    [string[]]$DatastoreIds = @(),
    [string[]]$NetworkIds = @(),
    [string]$GroupName,

    [string]$UserRoleName = 'Tenant Admin',
    [string]$UserRoleTemplate = 'Tenant Admin',

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AdminUsername,
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string]$AdminEmail,
    [string]$AdminFirstName = 'Tenant',
    [string]$AdminLastName = 'Admin',
    [switch]$GeneratePassword,

    [switch]$SkipCertificateCheck,
    [switch]$Yes,
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
    $json = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 20 -Compress } else { $null }

    if ($Method -ne 'GET' -and $DryRun) {
        Write-Host "    [dry-run] $Method $Path" -ForegroundColor DarkGray
        if ($json) { Write-Host "              $(Hide-Secret $json)" -ForegroundColor DarkGray }
        return $null
    }

    $request = @{ Method = $Method; Uri = $uri; Headers = $script:Headers; ErrorAction = 'Stop' }
    if ($SkipCertificateCheck) { $request.SkipCertificateCheck = $true }
    if ($json) { $request.ContentType = 'application/json'; $request.Body = $json }

    try {
        $response = Invoke-RestMethod @request
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        try { $detail = $detail | ConvertFrom-Json -ErrorAction Stop | ConvertTo-Json -Depth 10 -Compress } catch { }
        if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + '...' }
        if ($detail -match 'SSL|TLS|trust relationship|certificate') {
            $detail += ' -> If the appliance uses a self-signed certificate, add -SkipCertificateCheck or set MORPHEUS_SKIP_TLS_VERIFY=true.'
        }
        $statusText = if ($status) { " (HTTP $status)" } else { '' }
        throw "API $Method $Path failed${statusText}: $(Hide-Secret $detail)"
    }
    if ($response -and $response.PSObject.Properties.Name -contains 'success' -and $response.success -eq $false) {
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

function Get-OwnerId($Object) {
    if ($null -eq $Object) { return $null }
    if ($Object.account -and $Object.account.id) { return [long]$Object.account.id }
    if ($Object.accountId) { return [long]$Object.accountId }
    if ($Object.owner -and $Object.owner.id) { return [long]$Object.owner.id }
    return $null
}

function Confirm-Change([string]$Message) {
    Write-Warn $Message
    if ($DryRun -or $Yes) { return }
    if ([Console]::IsInputRedirected) {
        throw 'This change needs confirmation. Re-run with -Yes to approve it non-interactively.'
    }
    $answer = Read-Host '    Proceed? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { throw 'Stopped at your request. Nothing after this point was changed.' }
}

function Resolve-CopyFromRole([string]$TemplateName, [string]$RoleType, [long]$OwnerTenantId) {
    if ([string]::IsNullOrWhiteSpace($TemplateName)) { return $null }
    $options = Invoke-MorpheusApi -Method GET -Path '/api/options/copyFromRole' -Query @{ roleType = $RoleType; tenantId = $OwnerTenantId }
    $match = @($options.data) | Where-Object { $_ -and $_.name -eq $TemplateName } | Select-Object -First 1
    if (-not $match) {
        $names = (@($options.data) | Where-Object { $_ } | ForEach-Object { "'$($_.name)'" }) -join ', '
        throw "Template role '$TemplateName' ($RoleType role) was not found. Roles you can copy from: $names"
    }
    return [long]$match.value
}

function ConvertTo-IdList([string[]]$Values, [string]$Name) {
    # Accepts "-DatastoreIds 7,8" from a PowerShell prompt and "-DatastoreIds 7,8" via pwsh -File (one string).
    $ids = foreach ($value in $Values) {
        foreach ($part in ($value -split '[,\s]+')) {
            if (-not $part) { continue }
            if ($part -notmatch '^\d+$') { throw "$Name must be numeric IDs separated by commas (got '$part')." }
            [long]$part
        }
    }
    return [long[]]@($ids | Select-Object -Unique)
}

function New-RandomPassword([int]$Length = 20) {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#%^*-_=+')
    $all  = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    return -join $chars
}

function Get-AdminPassword {
    if ($env:TENANT_ADMIN_PASSWORD) { return @{ Value = $env:TENANT_ADMIN_PASSWORD; Generated = $false } }
    if ($GeneratePassword) { return @{ Value = (New-RandomPassword); Generated = $true } }
    if ([Console]::IsInputRedirected) {
        throw 'No password available. Set TENANT_ADMIN_PASSWORD or use -GeneratePassword.'
    }
    $first  = Read-Host "    Password for '$AdminUsername'" -AsSecureString
    $second = Read-Host '    Confirm password' -AsSecureString
    $p1 = [System.Net.NetworkCredential]::new('', $first).Password
    $p2 = [System.Net.NetworkCredential]::new('', $second).Password
    if ($p1 -ne $p2) { throw 'Passwords did not match.' }
    if ($p1.Length -lt 8) { throw 'Password must be at least 8 characters.' }
    return @{ Value = $p1; Generated = $false }
}

function Add-TenantToResource {
    param([string]$Kind, [string]$Path, [string]$Key, [long]$TenantId)
    $object = (Invoke-MorpheusApi -Method GET -Path $Path).$Key
    if (-not $object) { throw "$Kind at $Path was not found." }
    $label = "$Kind '$($object.name)' (ID $($object.id))"
    if ($object.visibility -eq 'public') { Write-Ok "$label is Public - all tenants can already use it"; return }

    $ids = @(@($object.tenants) | Where-Object { $_ } | ForEach-Object { [long]$_.id })
    if ($ids -contains $TenantId) { Write-Ok "$label is already shared with the tenant"; return }
    $ids += $TenantId

    if ($Key -eq 'network') {
        $body = @{ network = @{ tenants = @($ids | ForEach-Object { @{ id = $_ } }) } }
    } else {
        $body = @{
            $Key              = @{ visibility = ($object.visibility ?? 'private') }
            tenantPermissions = @{ accounts = @($ids) }
        }
    }
    Invoke-MorpheusApi -Method PUT -Path $Path -Body $body | Out-Null
    Write-Done "$label shared with the tenant" "Would share $label with the tenant"
}

$summary = [ordered]@{}
$generatedPassword = $null

try {
    # -----------------------------------------------------------------------
    # Validate inputs and environment
    # -----------------------------------------------------------------------
    $script:BaseUrl = ($env:MORPHEUS_URL ?? '').TrimEnd('/')
    if (-not $script:BaseUrl) { throw 'Set MORPHEUS_URL (e.g. https://vme-manager.example.local).' }
    if ($script:BaseUrl -notmatch '^https://') { Write-Warn 'MORPHEUS_URL is not https:// - the API token will be sent unencrypted.' }
    if (-not $env:MORPHEUS_TOKEN) { throw 'Set MORPHEUS_TOKEN to the API access token of a master-tenant admin.' }
    $script:Headers = @{ Authorization = "Bearer $($env:MORPHEUS_TOKEN)"; Accept = 'application/json' }

    $ResourcePoolIds = ConvertTo-IdList $ResourcePoolIds '-ResourcePoolIds'
    $DatastoreIds    = ConvertTo-IdList $DatastoreIds '-DatastoreIds'
    $NetworkIds      = ConvertTo-IdList $NetworkIds '-NetworkIds'

    if ($CloudMode -ne 'none' -and -not $CloudId) { throw "-CloudId is required when -CloudMode is '$CloudMode'." }
    if ($CloudMode -ne 'shared' -and ($ResourcePoolIds.Count + $DatastoreIds.Count + $NetworkIds.Count) -gt 0) {
        throw '-ResourcePoolIds / -DatastoreIds / -NetworkIds only apply to -CloudMode shared.'
    }
    if (-not $TenantRoleName)    { $TenantRoleName = "$TenantName Tenant Role" }
    if (-not $GroupName)         { $GroupName = $TenantName }
    if (-not $TenantDescription) { $TenantDescription = "Sub-tenant $TenantName" }
    # SSL / TLS: lab appliances often use self-signed certificates. Certificate errors are ignored only
    # when -SkipCertificateCheck is passed or MORPHEUS_SKIP_TLS_VERIFY=true is set (never in production).
    if ([string]$env:MORPHEUS_SKIP_TLS_VERIFY -match '^(1|true|yes)$') { $SkipCertificateCheck = [switch]$true }
    if ($SkipCertificateCheck)   { Write-Warn 'SSL certificate errors are being IGNORED (lab mode). Do not use this against production.' }

    if ($DryRun) { Write-Host "`nDRY RUN - lookups are real, nothing will be created or changed." -ForegroundColor Magenta }

    # -----------------------------------------------------------------------
    # 0. Who am I?
    # -----------------------------------------------------------------------
    Write-Step 'Checking API access'
    $whoami = Invoke-MorpheusApi -Method GET -Path '/api/whoami'
    if (-not $whoami.isMasterAccount) { throw 'The API token must belong to a user in the MASTER tenant.' }
    $masterId = Get-OwnerId $whoami.user
    if (-not $masterId) { throw 'Could not determine the master tenant ID from /api/whoami.' }
    Write-Ok "Connected as '$($whoami.user.username)' (master tenant ID $masterId)"

    # Existing tenant? (lets a re-run pick up where it left off)
    $tenant = Find-ByName (Invoke-MorpheusApi -Method GET -Path '/api/accounts' -Query @{ name = $TenantName; max = 1000 }).accounts 'name' $TenantName
    $tenantId = if ($tenant) { [long]$tenant.id } else { 0 }

    # -----------------------------------------------------------------------
    # 1. Cloud pre-checks (read-only)
    # -----------------------------------------------------------------------
    $cloud = $null
    if ($CloudMode -ne 'none') {
        Write-Step "Checking cloud ID $CloudId"
        $cloud = (Invoke-MorpheusApi -Method GET -Path "/api/zones/$CloudId").zone
        if (-not $cloud) { throw "Cloud ID $CloudId was not found." }
        $cloudOwner = (Get-OwnerId $cloud) ?? $masterId
        Write-Ok "Cloud '$($cloud.name)' - visibility: $($cloud.visibility); owner tenant ID: $cloudOwner"

        if ($cloudOwner -ne $masterId -and $cloudOwner -ne $tenantId) {
            throw "Cloud '$($cloud.name)' is assigned to another tenant (ID $cloudOwner). Reassign it in the UI first."
        }
        if ($CloudMode -eq 'shared' -and $cloudOwner -ne $masterId) {
            throw "Cloud '$($cloud.name)' is already dedicated to this tenant. Use -CloudMode dedicated, or reassign it to the master tenant first."
        }
    }

    # -----------------------------------------------------------------------
    # 2. Shared mode: the cloud must be Public before a tenant role can be given access to it
    # -----------------------------------------------------------------------
    if ($CloudMode -eq 'shared') {
        Write-Step "Making cloud '$($cloud.name)' available to tenants (Public)"
        if ($cloud.visibility -eq 'public') {
            Write-Ok 'Cloud is already Public'
        } else {
            Confirm-Change ("Cloud '$($cloud.name)' is Private. Setting it to Public lets it be granted to ANY tenant's role, " +
                            'and tenants created later get it added automatically. Existing tenants only see it if their tenant role grants access.')
            Invoke-MorpheusApi -Method PUT -Path "/api/zones/$CloudId" -Body @{ zone = @{ visibility = 'public' } } | Out-Null
            Write-Done 'Cloud visibility set to Public' 'Would set the cloud visibility to Public'
        }
    }

    # -----------------------------------------------------------------------
    # 3. Tenant Role (roleType = account)
    # -----------------------------------------------------------------------
    Write-Step "Tenant role '$TenantRoleName'"
    $tenantRole = Find-ByName (Invoke-MorpheusApi -Method GET -Path '/api/roles' -Query @{ roleType = 'account'; name = $TenantRoleName; max = 1000 }).roles 'authority' $TenantRoleName
    if ($tenantRole) {
        $tenantRoleId = [long]$tenantRole.id
        Write-Ok "Found existing tenant role (ID $tenantRoleId)"
    } else {
        $baseRoleId = Resolve-CopyFromRole $TenantRoleTemplate 'account' $masterId
        if (-not $baseRoleId) { Write-Warn 'No -TenantRoleTemplate given: the role starts with NO feature permissions.' }
        $roleBody = @{ role = @{ authority = $TenantRoleName; description = "Permission ceiling for tenant $TenantName"; roleType = 'account' } }
        if ($baseRoleId) { $roleBody.role.baseRoleId = $baseRoleId }
        $res = Invoke-MorpheusApi -Method POST -Path '/api/roles' -Body $roleBody
        $tenantRoleId = if ($res) { [long]$res.role.id } else { 0 }
        Write-Done "Created tenant role (ID $tenantRoleId), copied from '$TenantRoleTemplate'" "Would create the tenant role, copied from '$TenantRoleTemplate'"
    }
    if ($CloudMode -eq 'shared') {
        if ($tenantRoleId) {
            Invoke-MorpheusApi -Method PUT -Path "/api/roles/$tenantRoleId/update-cloud" -Body @{ cloudId = $CloudId; access = 'full' } | Out-Null
        } else {
            Write-Host "    [dry-run] PUT /api/roles/<new-role-id>/update-cloud  {cloudId: $CloudId, access: full}" -ForegroundColor DarkGray
        }
        Write-Done "Tenant role has Full access to cloud '$($cloud.name)'" "Would give the tenant role Full access to cloud '$($cloud.name)'"
    }
    $summary['Tenant role'] = "$TenantRoleName ($(Format-Id $tenantRoleId))"

    # -----------------------------------------------------------------------
    # 4. Tenant
    # -----------------------------------------------------------------------
    Write-Step "Tenant '$TenantName'"
    if ($tenant) {
        Write-Ok "Found existing tenant (ID $tenantId)"
        if ($tenant.role -and $tenant.role.id -and [long]$tenant.role.id -ne $tenantRoleId) {
            Write-Warn "Tenant's base role is '$($tenant.role.authority ?? $tenant.role.name)', not '$TenantRoleName'. Left unchanged."
        }
    } else {
        $accountBody = @{ account = @{ name = $TenantName; description = $TenantDescription; role = @{ id = $tenantRoleId }; currency = $Currency } }
        if ($Subdomain) { $accountBody.account.subdomain = $Subdomain }
        $res = Invoke-MorpheusApi -Method POST -Path '/api/accounts' -Body $accountBody
        $tenantId = if ($res) { [long]$res.account.id } else { 0 }
        $tenant = if ($res) { $res.account } else { $null }
        Write-Done "Created tenant (ID $tenantId)" 'Would create the tenant'
    }
    $summary['Tenant'] = "$TenantName ($(Format-Id $tenantId))"

    # -----------------------------------------------------------------------
    # 5. Cloud: assign (dedicated) or share resources (shared)
    # -----------------------------------------------------------------------
    if ($CloudMode -eq 'dedicated') {
        Write-Step "Assigning cloud '$($cloud.name)' to the tenant"
        if ($tenantId -and ((Get-OwnerId $cloud) -eq $tenantId)) {
            Write-Ok 'Cloud is already assigned to this tenant'
        } else {
            Confirm-Change ("Cloud '$($cloud.name)' and ALL of its resources will be available ONLY to tenant '$TenantName'. " +
                            'Other sub-tenants lose access to it; the master tenant keeps control.')
            $target = if ($tenantId) { $tenantId } else { '<new-tenant-id>' }
            Invoke-MorpheusApi -Method PUT -Path "/api/zones/$CloudId" -Body @{ zone = @{ accountId = $target; visibility = 'private' } } | Out-Null
            Write-Done 'Cloud assigned to the tenant (visibility Private)' 'Would assign the cloud to the tenant (visibility Private)'
        }
        $summary['Cloud'] = "$($cloud.name) - dedicated to this tenant"
    }
    elseif ($CloudMode -eq 'shared') {
        Write-Step 'Sharing cloud resources with the tenant'
        $shareCount = $ResourcePoolIds.Count + $DatastoreIds.Count + $NetworkIds.Count
        if ($shareCount -gt 0 -and -not $tenantId) {
            Write-Info "[dry-run] would share $shareCount resource(s) with the new tenant once it exists"
        } elseif ($shareCount -gt 0) {
            foreach ($id in $ResourcePoolIds) { Add-TenantToResource 'Resource pool' "/api/zones/$CloudId/resource-pools/$id" 'resourcePool' $tenantId }
            foreach ($id in $DatastoreIds)    { Add-TenantToResource 'Datastore'     "/api/zones/$CloudId/data-stores/$id"    'datastore'    $tenantId }
            foreach ($id in $NetworkIds)      { Add-TenantToResource 'Network'       "/api/networks/$id"                      'network'      $tenantId }
        } else {
            Write-Warn 'No resources listed. The tenant will see the cloud but cannot provision until a resource pool,'
            Write-Warn 'datastore and network are shared (or Public). Candidates in this cloud:'
            $pools = @((Invoke-MorpheusApi -Method GET -Path "/api/zones/$CloudId/resource-pools" -Query @{ max = 200 }).resourcePools)
            $dss   = @((Invoke-MorpheusApi -Method GET -Path "/api/zones/$CloudId/data-stores" -Query @{ max = 200 }).datastores)
            $nets  = @((Invoke-MorpheusApi -Method GET -Path '/api/networks' -Query @{ zoneId = $CloudId; max = 200 }).networks)
            foreach ($p in ($pools | Where-Object { $_ })) { Write-Info ("  -ResourcePoolIds {0,-6} {1} [{2}]" -f $p.id, $p.name, $p.visibility) }
            foreach ($d in ($dss   | Where-Object { $_ })) { Write-Info ("  -DatastoreIds    {0,-6} {1} [{2}]" -f $d.id, $d.name, $d.visibility) }
            foreach ($n in ($nets  | Where-Object { $_ })) { Write-Info ("  -NetworkIds      {0,-6} {1} [{2}]" -f $n.id, $n.name, $n.visibility) }
            Write-Info 'Re-run with the IDs you want to share; finished steps are skipped.'
        }
        $summary['Cloud'] = "$($cloud.name) - shared (Public, tenant role Full)"
    }

    # -----------------------------------------------------------------------
    # 6. Group inside the tenant that contains the cloud
    # -----------------------------------------------------------------------
    if ($CloudMode -ne 'none') {
        Write-Step 'Tenant group for the cloud'
        if (-not $tenantId) {
            Write-Info "[dry-run] would create group '$GroupName' in the new tenant and add cloud ID $CloudId"
        } else {
            $groups = @((Invoke-MorpheusApi -Method GET -Path "/api/accounts/$tenantId/groups" -Query @{ max = 1000 }).groups) | Where-Object { $_ }
            $groupWithCloud = $groups | Where-Object { @(@($_.zones) | Where-Object { $_ } | ForEach-Object { [long]$_.id }) -contains $CloudId } | Select-Object -First 1
            if ($groupWithCloud) {
                Write-Ok "Group '$($groupWithCloud.name)' (ID $($groupWithCloud.id)) already contains the cloud"
                $summary['Group'] = "$($groupWithCloud.name) (ID $($groupWithCloud.id))"
            } else {
                $group = Find-ByName $groups 'name' $GroupName
                if ($group) {
                    Write-Ok "Found existing group '$GroupName' (ID $($group.id))"
                } else {
                    $res = Invoke-MorpheusApi -Method POST -Path "/api/accounts/$tenantId/groups" -Body @{ group = @{ name = $GroupName; description = "Default group for tenant $TenantName" } }
                    $group = if ($res) { $res.group } else { [pscustomobject]@{ id = 0; zones = @() } }
                    Write-Done "Created group '$GroupName' (ID $($group.id))" "Would create group '$GroupName'"
                }
                $zoneIds = @(@($group.zones) | Where-Object { $_ } | ForEach-Object { [long]$_.id }) + $CloudId | Select-Object -Unique
                $gid = if ($group.id) { $group.id } else { '<new-group-id>' }
                Invoke-MorpheusApi -Method PUT -Path "/api/accounts/$tenantId/groups/$gid/update-zones" -Body @{ group = @{ zones = @($zoneIds | ForEach-Object { @{ id = $_ } }) } } | Out-Null
                Write-Done "Cloud added to group '$GroupName'" "Would add the cloud to group '$GroupName'"
                $summary['Group'] = "$GroupName ($(Format-Id $group.id))"
            }
        }
    }

    # -----------------------------------------------------------------------
    # 7. User role owned by the tenant
    # -----------------------------------------------------------------------
    Write-Step "User role '$UserRoleName' in the tenant"
    $userRoleId = 0
    if (-not $tenantId) {
        Write-Info "[dry-run] would reuse or create user role '$UserRoleName' (copied from '$UserRoleTemplate') owned by the new tenant"
    } else {
        $tenantRoles = @((Invoke-MorpheusApi -Method GET -Path '/api/roles' -Query @{ tenant = $tenantId; roleType = 'user'; max = 1000 }).roles) |
            Where-Object { $_ -and (-not $_.owner -or [long]$_.owner.id -eq $tenantId) }
        $userRole = Find-ByName $tenantRoles 'authority' $UserRoleName
        if ($userRole) {
            $userRoleId = [long]$userRole.id
            Write-Ok "Found existing role in the tenant (ID $userRoleId)"
        } else {
            $baseUserRoleId = Resolve-CopyFromRole $UserRoleTemplate 'user' $tenantId
            if (-not $baseUserRoleId) { Write-Warn 'No -UserRoleTemplate given: the role starts with NO feature permissions.' }
            $roleBody = @{ role = @{
                authority        = $UserRoleName
                description      = "Administrator for tenant $TenantName"
                roleType         = 'user'
                owner            = $tenantId
                globalSiteAccess = 'full'
            } }
            if ($baseUserRoleId) { $roleBody.role.baseRoleId = $baseUserRoleId }
            $res = Invoke-MorpheusApi -Method POST -Path '/api/roles' -Body $roleBody
            $userRoleId = if ($res) { [long]$res.role.id } else { 0 }
            Write-Done "Created user role (ID $userRoleId) with access to all groups in the tenant" "Would create user role '$UserRoleName' with access to all groups in the tenant"
        }
        if ($userRoleId) {
            $assignable = @((Invoke-MorpheusApi -Method GET -Path "/api/accounts/$tenantId/users/available-roles").roles) |
                Where-Object { $_ -and [long]$_.id -eq $userRoleId }
            if (-not $assignable) { Write-Warn "Role ID $userRoleId is not listed as assignable in this tenant; user creation may fail." }
        }
    }
    $summary['User role'] = "$UserRoleName ($(Format-Id $userRoleId))"

    # -----------------------------------------------------------------------
    # 8. Admin user in the tenant
    # -----------------------------------------------------------------------
    Write-Step "Admin user '$AdminUsername'"
    $existingUser = $null
    if ($tenantId) {
        $existingUser = Find-ByName (Invoke-MorpheusApi -Method GET -Path "/api/accounts/$tenantId/users" -Query @{ max = 1000 }).users 'username' $AdminUsername
    }
    if ($existingUser) {
        Write-Ok "User already exists in the tenant (ID $($existingUser.id)) - password and roles left unchanged"
        $summary['Admin user'] = "$AdminUsername (ID $($existingUser.id))"
    } else {
        $password = if ($DryRun) { @{ Value = '(not used in dry run)'; Generated = $false } } else { Get-AdminPassword }
        $userBody = @{ user = @{
            username  = $AdminUsername
            email     = $AdminEmail
            firstName = $AdminFirstName
            lastName  = $AdminLastName
            password  = $password.Value
            roles     = @(@{ id = $userRoleId })
        } }
        $tenantPath = if ($tenantId) { $tenantId } else { '<new-tenant-id>' }
        $res = Invoke-MorpheusApi -Method POST -Path "/api/accounts/$tenantPath/users" -Body $userBody
        if ($res) {
            $createdIn = Get-OwnerId $res.user
            if ($createdIn -and $createdIn -ne $tenantId) { Write-Warn "User was created in tenant ID $createdIn, expected $tenantId. Check Administration > Tenants." }
            Write-Ok "Created user (ID $($res.user.id))"
            $summary['Admin user'] = "$AdminUsername (ID $($res.user.id))"
        }
        if ($DryRun) { Write-Host "    [plan] Would create user '$AdminUsername'" -ForegroundColor DarkGray; $summary['Admin user'] = "$AdminUsername (new)" }
        if ($password.Generated) { $generatedPassword = $password.Value }
    }

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host ($(if ($DryRun) { ' DRY RUN COMPLETE - nothing was changed' } else { ' TENANT READY' })) -ForegroundColor Green
    foreach ($key in $summary.Keys) { Write-Host (" {0,-12} {1}" -f "${key}:", $summary[$key]) }
    $loginPrefix = if ($Subdomain) { $Subdomain } elseif ($tenant -and $tenant.subdomain) { $tenant.subdomain } elseif ($tenantId) { $tenantId } else { '<tenant-id>' }
    Write-Host (" {0,-12} {1}" -f 'Sign in:', "$($script:BaseUrl)  as  $loginPrefix\$AdminUsername")
    if ($generatedPassword) {
        Write-Host (" {0,-12} {1}" -f 'Password:', $generatedPassword) -ForegroundColor Yellow
        Write-Host '              (shown once - store it in your password manager and have the user change it)' -ForegroundColor Yellow
    }
    Write-Host '================================================================' -ForegroundColor Cyan
}
catch {
    Write-Host "`n[error] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '        Fix the cause and re-run with the same parameters; completed steps are reused.' -ForegroundColor Red
    exit 1
}

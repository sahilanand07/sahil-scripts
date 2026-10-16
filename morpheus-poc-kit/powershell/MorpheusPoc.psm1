#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the morpheus-poc-kit PowerShell scripts (Get-MorpheusInventory.ps1,
    Invoke-PocOnboarding.ps1, Remove-PocTenant.ps1). Import it; it does nothing on its own.

.DESCRIPTION
    Output helpers, environment / TLS setup, an API client with a master and a tenant context,
    OAuth sign-in as a tenant user, name-or-ID resolution, confirmation prompts, password
    generation, tenant lists on shared cloud resources, and the run manifest (state file).

    The state file format is identical to the bash kit's, so a run started in one language can be
    completed or torn down in the other.
#>
Set-StrictMode -Version 3.0

$script:S = @{
    BaseUrl       = $null
    Headers       = @{ master = $null; tenant = $null }
    Context       = 'master'
    SkipCert      = $false
    DryRun        = $false
    Yes           = $false
    Manifest      = $null
    ManifestUrl   = $null
    ManifestName  = $null
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host '    [ok] ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Warn([string]$Text) { Write-Host "    [warn] $Text" -ForegroundColor Yellow }
function Write-Plan([string]$Text) { Write-Host "    [plan] $Text" -ForegroundColor DarkGray }
function Write-Done([string]$Done, [string]$Planned) { if ($script:S.DryRun) { Write-Plan $Planned } else { Write-Ok $Done } }
function Format-Id($Id) { if ($Id) { "ID $Id" } else { 'new' } }
function Hide-Secret([string]$Json) {
    return ($Json -replace '"(password|passwordConfirmation)"\s*:\s*"(?:[^"\\]|\\.)*"', '"$1":"********"')
}

# ---------------------------------------------------------------------------
# Session: environment, TLS, context
# ---------------------------------------------------------------------------
function Initialize-MorpheusSession {
    param([switch]$SkipCertificateCheck, [switch]$DryRun, [switch]$Yes)
    $url = ([string]$env:MORPHEUS_URL).TrimEnd('/')
    if (-not $url) { throw 'Set MORPHEUS_URL (e.g. https://vme-manager.example.local).' }
    if (-not $env:MORPHEUS_TOKEN) { throw 'Set MORPHEUS_TOKEN to the API access token of a master-tenant admin.' }
    if ($url -notmatch '^https://') { Write-Warn 'MORPHEUS_URL is not https:// - credentials will be sent unencrypted.' }
    $script:S.BaseUrl = $url
    $script:S.Headers.master = @{ Authorization = "Bearer $($env:MORPHEUS_TOKEN)"; Accept = 'application/json' }
    $script:S.Headers.tenant = $null
    $script:S.Context = 'master'
    $script:S.DryRun = [bool]$DryRun
    $script:S.Yes = [bool]$Yes

    # -----------------------------------------------------------------------
    # SSL / TLS certificate handling
    # -----------------------------------------------------------------------
    # Lab appliances usually present a self-signed certificate, which makes every call fail with
    # "The SSL connection could not be established" / "UntrustedRoot". Two ways around it:
    #   - trust the appliance CA: import it into the OS trust store (safer);
    #   - ignore certificate errors: -SkipCertificateCheck, or MORPHEUS_SKIP_TLS_VERIFY=true.
    # PowerShell 7 uses the per-request -SkipCertificateCheck switch. Never use it against production.
    $script:S.SkipCert = [bool]$SkipCertificateCheck -or ([string]$env:MORPHEUS_SKIP_TLS_VERIFY -match '^(1|true|yes)$')
    if ($script:S.SkipCert) { Write-Warn 'SSL certificate errors are being IGNORED (lab mode). Do not use this against production.' }
    return $url
}

function Get-MorpheusBaseUrl { $script:S.BaseUrl }
function Test-DryRun { $script:S.DryRun }

function Set-MorpheusContext {
    param([ValidateSet('master', 'tenant')][string]$Context)
    if ($Context -eq 'tenant' -and -not $script:S.Headers.tenant) { throw 'Internal error: not signed in to the tenant yet.' }
    $script:S.Context = $Context
}

function ConvertTo-QueryString([System.Collections.IDictionary]$Query) {
    if (-not $Query -or $Query.Count -eq 0) { return '' }
    $pairs = foreach ($key in $Query.Keys) {
        '{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$Query[$key])
    }
    return '?' + ($pairs -join '&')
}

function ConvertTo-JsonBody($Body) { ConvertTo-Json -InputObject $Body -Depth 40 -Compress }

# Invoke-MorpheusApiStatus: one HTTP call; never throws on HTTP errors.
# Returns @{ Code; Body (parsed object or $null); Raw }. Non-GET calls are only printed in a dry run.
function Invoke-MorpheusApiStatus {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.IDictionary]$Query,
        $Body
    )
    $json = if ($null -ne $Body) { if ($Body -is [string]) { $Body } else { ConvertTo-JsonBody $Body } } else { $null }
    if ($Method -ne 'GET' -and $script:S.DryRun) {
        Write-Host "    [dry-run] $Method $Path  (as $($script:S.Context))" -ForegroundColor DarkGray
        if ($json) { Write-Host "              $(Hide-Secret $json)" -ForegroundColor DarkGray }
        return @{ Code = 200; Body = [pscustomobject]@{}; Raw = '{}' }
    }
    $request = @{
        Method             = $Method
        Uri                = $script:S.BaseUrl + $Path + (ConvertTo-QueryString $Query)
        Headers            = $script:S.Headers[$script:S.Context]
        SkipHttpErrorCheck = $true
        TimeoutSec         = 180
        ErrorAction        = 'Stop'
    }
    if ($script:S.SkipCert) { $request.SkipCertificateCheck = $true }
    if ($json) { $request.ContentType = 'application/json; charset=utf-8'; $request.Body = [Text.Encoding]::UTF8.GetBytes($json) }
    try {
        $response = Invoke-WebRequest @request
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg += ' ' + $_.Exception.InnerException.Message }
        if ($msg -match 'SSL|TLS|certificate|trust relationship|UntrustedRoot|RemoteCertificate') {
            throw "SSL/TLS error talking to $($script:S.BaseUrl): $msg -> If the appliance uses a self-signed certificate, add -SkipCertificateCheck or set MORPHEUS_SKIP_TLS_VERIFY=true (or import its CA into the OS trust store)."
        }
        throw "Could not reach $($script:S.BaseUrl): $msg. Check MORPHEUS_URL, DNS and the network."
    }
    $raw = [string]$response.Content
    $parsed = $null
    if ($raw) { try { $parsed = $raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop } catch { $parsed = $null } }
    $code = [int]$response.StatusCode
    if ($code -eq 200 -and $parsed -and $parsed.PSObject.Properties.Name -contains 'success' -and $parsed.success -eq $false) { $code = 400 }
    return @{ Code = $code; Body = $parsed; Raw = $raw }
}

function Get-ApiErrorText($Result) {
    $b = $Result.Body
    if ($b) {
        foreach ($k in 'msg', 'error_description', 'error') {
            if ($b.PSObject.Properties.Name -contains $k -and $b.$k) { return [string]$b.$k }
        }
        if ($b.PSObject.Properties.Name -contains 'errors' -and $b.errors) { return (ConvertTo-Json $b.errors -Compress -Depth 5) }
    }
    $r = [string]$Result.Raw
    if ($r.Length -gt 300) { $r = $r.Substring(0, 300) }
    if ($r) { $r } else { 'no details' }
}

# Invoke-MorpheusApi: like Invoke-MorpheusApiStatus, but any HTTP error stops the script.
function Invoke-MorpheusApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.IDictionary]$Query,
        $Body
    )
    $r = Invoke-MorpheusApiStatus -Method $Method -Path $Path -Query $Query -Body $Body
    if ($r.Code -eq 401) { throw "API $Method $Path was refused (HTTP 401). The $($script:S.Context) token is invalid or expired." }
    if ($r.Code -ge 400) {
        $detail = $r.Raw
        if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + '...' }
        throw "API $Method $Path failed (HTTP $($r.Code), as $($script:S.Context)): $(Hide-Secret $detail)"
    }
    if ($r.Raw -and $null -eq $r.Body) { throw "API $Method $Path returned a non-JSON response (HTTP $($r.Code)). Is MORPHEUS_URL the appliance URL?" }
    if ($null -eq $r.Body) { return [pscustomobject]@{} }
    return $r.Body
}

# Connect-MorpheusTenant: OAuth password grant as a sub-tenant user; switches to the tenant context.
# Prefix is the tenant subdomain, or its ID when it has none (the API's own default).
function Connect-MorpheusTenant {
    param([string]$Prefix, [string]$Username, [string]$Password)
    $request = @{
        Method             = 'POST'
        Uri                = "$($script:S.BaseUrl)/oauth/token"
        Body               = @{ grant_type = 'password'; scope = 'write'; client_id = 'morph-api'; username = "$Prefix\$Username"; password = $Password }
        ContentType        = 'application/x-www-form-urlencoded'
        Headers            = @{ Accept = 'application/json' }
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    if ($script:S.SkipCert) { $request.SkipCertificateCheck = $true }
    try { $response = Invoke-WebRequest @request } catch {
        throw "Could not reach $($script:S.BaseUrl) to sign in: $($_.Exception.Message)"
    }
    $body = $null
    try { $body = $response.Content | ConvertFrom-Json -ErrorAction Stop } catch { }
    $token = if ($body -and $body.PSObject.Properties.Name -contains 'access_token') { $body.access_token } else { $null }
    if ([int]$response.StatusCode -ne 200 -or -not $token) {
        $why = if ($body) { Get-ApiErrorText @{ Body = $body; Raw = $response.Content } } else { 'no details' }
        throw "Could not sign in as '$Prefix\$Username' (HTTP $([int]$response.StatusCode)): $why. Check TENANT_ADMIN_PASSWORD, or re-run with -ResetAdminPassword."
    }
    $script:S.Headers.tenant = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
    $script:S.Context = 'tenant'
}

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------
# Get-Prop OBJECT NAME -> the property value, or $null when it doesn't exist.
# Like any PowerShell function output, a one-element array comes back as its element: wrap the
# call in @() where a list is expected, or read the property directly when the type matters.
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-List($Response, [string]$Key) { @(Get-Prop $Response $Key) | Where-Object { $null -ne $_ } }

# Find-ByName ITEMS PROPERTY VALUE -> first item whose PROPERTY equals VALUE (case-insensitive)
function Find-ByName($Items, [string]$Property, [string]$Value) {
    return @($Items) | Where-Object { $_ -and ([string](Get-Prop $_ $Property)) -ieq $Value } | Select-Object -First 1
}

function Get-OwnerId($Object) {
    if ($null -eq $Object) { return $null }
    foreach ($path in @(@('account', 'id'), @('accountId'), @('owner', 'id'))) {
        $v = $Object
        foreach ($p in $path) { $v = Get-Prop $v $p }
        if ($v) { return [long]$v }
    }
    return $null
}

# Select-MorpheusObject REF LABEL ITEMS -> the object matching an ID (digits) or a name (case-insensitive)
function Select-MorpheusObject {
    param([string]$Ref, [string]$Label, $Items, [string]$NameProperty = 'name')
    $items = @($Items) | Where-Object { $_ }
    if ($Ref -match '^\d+$') {
        $match = $items | Where-Object { [string]$_.id -eq $Ref } | Select-Object -First 1
    } else {
        $matches_ = @($items | Where-Object { ([string](Get-Prop $_ $NameProperty)) -ieq $Ref })
        if ($matches_.Count -gt 1) { throw "$Label '$Ref' matches $($matches_.Count) objects. Use its ID instead: $(($matches_ | ForEach-Object { $_.id }) -join ', ')" }
        $match = $matches_ | Select-Object -First 1
    }
    if (-not $match) {
        $available = ($items | Select-Object -First 25 | ForEach-Object { "$(Get-Prop $_ $NameProperty) ($($_.id))" }) -join ', '
        if (-not $available) { $available = 'none' }
        throw "$Label '$Ref' was not found. Available: $available"
    }
    return $match
}

# ---------------------------------------------------------------------------
# Prompts, passwords, small text helpers
# ---------------------------------------------------------------------------
function Confirm-Change([string]$Message) {
    Write-Warn $Message
    if ($script:S.DryRun -or $script:S.Yes) { return }
    if ([Console]::IsInputRedirected) { throw 'This change needs confirmation. Re-run with -Yes to approve it non-interactively.' }
    $answer = Read-Host '    Proceed? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { throw 'Stopped at your request. Nothing after this point was changed.' }
}

function New-RandomPassword([int]$Length = 20) {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#%^*-_=+')
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    return -join $chars
}

function Get-Slug([string]$Text) { (($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) }

# "Cost Center" -> CostCenter (used in input field names)
function Get-FieldName([string]$Text) {
    -join (($Text -split '[^A-Za-z0-9]+') | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })
}

# ---------------------------------------------------------------------------
# Tenant lists on shared cloud resources
# ---------------------------------------------------------------------------
# Get-ResourceState KIND CLOUD_ID ID -> @{ Path; Key; Name; Visibility; Tenants = [long[]] } or $null.
# Pool tenant lists only come back on the LIST call (a top-level "tenants" map keyed by pool ID), so both
# places are read. A PUT replaces the whole list, so the full current list must be known first.
function Get-ResourceState {
    param([ValidateSet('resourcePool', 'datastore', 'network')][string]$Kind, [long]$CloudId, [long]$Id)
    $ids = [System.Collections.Generic.List[long]]::new()
    switch ($Kind) {
        'resourcePool' {
            $res = Invoke-MorpheusApi -Method GET -Path "/api/zones/$CloudId/resource-pools" -Query @{ max = 1000 }
            $obj = Get-List $res 'resourcePools' | Where-Object { [long]$_.id -eq $Id } | Select-Object -First 1
            if (-not $obj) { return $null }
            $map = Get-Prop $res 'tenants'
            foreach ($t in @(Get-Prop $obj 'tenants') + @(Get-Prop $map ([string]$Id))) { if ($t) { $ids.Add([long]$t.id) } }
            $path = "/api/zones/$CloudId/resource-pools/$Id"
        }
        'datastore' {
            $path = "/api/zones/$CloudId/data-stores/$Id"
            $r = Invoke-MorpheusApiStatus -Method GET -Path $path
            if ($r.Code -ne 200) { return $null }
            $obj = Get-Prop $r.Body 'datastore'
            if (-not $obj) { return $null }
            foreach ($t in @(Get-Prop $obj 'tenants') + @(Get-Prop (Get-Prop $r.Body 'tenants') ([string]$Id))) { if ($t) { $ids.Add([long]$t.id) } }
        }
        'network' {
            $path = "/api/networks/$Id"
            $r = Invoke-MorpheusApiStatus -Method GET -Path $path
            if ($r.Code -ne 200) { return $null }
            $obj = Get-Prop $r.Body 'network'
            if (-not $obj) { return $null }
            foreach ($t in @(Get-Prop $obj 'tenants')) { if ($t) { $ids.Add([long]$t.id) } }
        }
    }
    $vis = Get-Prop $obj 'visibility'
    return @{ Path = $path; Key = $Kind; Name = [string]$obj.name; Visibility = $(if ($vis) { $vis } else { 'private' })
              Tenants = [long[]]@($ids | Sort-Object -Unique) }
}

function Set-ResourceTenants($State, [long[]]$TenantIds) {
    $ids = [long[]]@($TenantIds | Sort-Object -Unique)
    if ($State.Key -eq 'network') {
        $body = @{ network = @{ tenants = @($ids | ForEach-Object { @{ id = $_ } }) } }
    } else {
        $body = @{ $State.Key = @{ visibility = $State.Visibility }; tenantPermissions = @{ accounts = $ids } }
    }
    Invoke-MorpheusApi -Method PUT -Path $State.Path -Body $body | Out-Null
}

# ---------------------------------------------------------------------------
# Run manifest (state file) - same format as the bash kit
# ---------------------------------------------------------------------------
# items: { kind, scope (master|tenant), action (created|reused|changed), id, name, resource?, cloudId?, from?, to?, at }

function Initialize-Manifest([string]$Path, [string]$Appliance, [string]$TenantName) {
    $script:S.Manifest = $Path; $script:S.ManifestUrl = $Appliance; $script:S.ManifestName = $TenantName
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $m = Read-Manifest $Path
    if ($m.kit -ne 'morpheus-poc-kit') { throw "$Path is not a morpheus-poc-kit state file." }
    if ($m.appliance -and ([string]$m.appliance).TrimEnd('/') -ne $Appliance.TrimEnd('/')) {
        throw "$Path was written for $($m.appliance), not $Appliance. Use -StateDir to keep separate state per appliance."
    }
}

function Read-Manifest([string]$Path) {
    # -DateKind String keeps timestamps as text where supported (PowerShell 7.5+).
    $params = @{ AsHashtable = $true; Depth = 50 }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $params.DateKind = 'String' }
    $m = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @params
    if (-not $m.Contains('items') -or $null -eq $m.items) { $m.items = @() }
    return $m
}

function Save-Manifest($Manifest) {
    $Manifest.updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $tmp = "$($script:S.Manifest).tmp"
    ConvertTo-Json -InputObject $Manifest -Depth 20 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $script:S.Manifest -Force
}

function Get-ManifestData {
    $path = $script:S.Manifest
    if (Test-Path -LiteralPath $path) { return Read-Manifest $path }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return [ordered]@{ kit = 'morpheus-poc-kit'; manifestVersion = 1; appliance = $script:S.ManifestUrl; tenantName = $script:S.ManifestName
                       tenantId = $null; subdomain = $null; masterTenantId = $null; items = @(); updated = $null }
}

function Set-ManifestValue([string]$Key, $Value) {
    if ($script:S.DryRun -or -not $script:S.Manifest) { return }
    $m = Get-ManifestData
    $m[$Key] = $Value
    Save-Manifest $m
}

# Add-ManifestItem: an item keeps "created" once recorded, so a re-run never downgrades it to "reused".
function Add-ManifestItem {
    param([string]$Kind, [string]$Scope, [string]$Action, $Id, [string]$Name, [hashtable]$Extra = @{})
    if ($script:S.DryRun -or -not $script:S.Manifest -or -not $Id -or [long]$Id -eq 0) { return }
    $m = Get-ManifestData
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($i in @($m.items)) { if ($i) { $items.Add($i) } }
    $res = if ($Extra.ContainsKey('resource')) { [string]$Extra.resource } else { '' }
    $existing = $items | Where-Object { $_.kind -eq $Kind -and [long]$_.id -eq [long]$Id -and ([string]$_['resource']) -eq $res } | Select-Object -First 1
    if ($existing) {
        if ($existing.action -ne 'created') {
            $existing.action = $Action; $existing.name = $Name
            foreach ($k in $Extra.Keys) { $existing[$k] = $Extra[$k] }
        }
    } else {
        $item = [ordered]@{ kind = $Kind; scope = $Scope; action = $Action; id = [long]$Id; name = $Name; at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        foreach ($k in $Extra.Keys) { $item[$k] = $Extra[$k] }
        $items.Add($item)
    }
    $m.items = $items.ToArray()
    Save-Manifest $m
}

function Get-ManifestAction([string]$Kind, $Id) {
    if (-not $script:S.Manifest -or -not (Test-Path -LiteralPath $script:S.Manifest)) { return $null }
    $m = Read-Manifest $script:S.Manifest
    $hit = @($m.items) | Where-Object { $_ -and $_.kind -eq $Kind -and [long]$_.id -eq [long]$Id } | Select-Object -First 1
    if ($hit) { $hit.action } else { $null }
}

# Save-ObjectRecord KIND SCOPE ID NAME CREATED - created when the kit made it, otherwise reused
function Save-ObjectRecord([string]$Kind, [string]$Scope, $Id, [string]$Name, [bool]$Created) {
    Add-ManifestItem -Kind $Kind -Scope $Scope -Action $(if ($Created) { 'created' } else { 'reused' }) -Id $Id -Name $Name
}

Export-ModuleMember -Function *

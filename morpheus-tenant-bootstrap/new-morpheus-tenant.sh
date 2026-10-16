#!/usr/bin/env bash
#
# new-morpheus-tenant.sh
#
# Creates a ready-to-use sub-tenant on HPE Morpheus Enterprise / HPE VM Essentials (VME) Manager:
#
#   1. Checks the API token belongs to a master-tenant user.
#   2. Checks the target cloud (read-only) and, in "shared" mode, makes it Public.
#   3. Tenant Role  - the permission ceiling for the tenant, copied from a template role,
#                     with Full access to the cloud ("shared" mode).
#   4. Tenant       - created with the Tenant Role as its Base Role.
#   5. Cloud        - "dedicated" mode assigns the whole cloud to the tenant;
#                     "shared" mode shares the resource pools / datastores / networks you list.
#   6. Group        - a group inside the tenant that contains the cloud.
#   7. User Role    - an admin role owned by the tenant (or an existing one, e.g. a multitenant copy).
#   8. Admin user   - a local user in the tenant with that role.
#
# Every step is "get or create", so re-running with the same names finishes a partly completed run.
# Changes that affect other tenants ask for confirmation unless --yes is given.
#
# Credentials come from the environment, never from this file:
#   MORPHEUS_URL            e.g. https://vme-manager.example.local
#   MORPHEUS_TOKEN          API access token of a master-tenant admin
#   TENANT_ADMIN_PASSWORD   optional; otherwise you are prompted (or use --generate-password)
#   MORPHEUS_SKIP_TLS_VERIFY optional; true = ignore SSL certificate errors (lab appliances)
#   MORPHEUS_CA_CERT        optional; PEM file of the appliance CA - the safer alternative
#
# Requires: bash 4.4+, curl 7.55+, jq 1.6+.  Not an official HPE tool - test in a lab first.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # errors inside $(...) also stop the script (bash 4.4+)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TENANT_NAME="" TENANT_DESCRIPTION="" SUBDOMAIN="" CURRENCY="USD"
TENANT_ROLE_NAME="" TENANT_ROLE_TEMPLATE="Tenant Admin"
CLOUD_ID="" CLOUD_MODE="shared" GROUP_NAME=""
RESOURCE_POOL_IDS="" DATASTORE_IDS="" NETWORK_IDS=""
USER_ROLE_NAME="Tenant Admin" USER_ROLE_TEMPLATE="Tenant Admin"
ADMIN_USERNAME="" ADMIN_EMAIL="" ADMIN_FIRST="Tenant" ADMIN_LAST="Admin"
GENERATE_PASSWORD=0 INSECURE=0 ASSUME_YES=0 DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: new-morpheus-tenant.sh --tenant-name NAME --admin-username USER --admin-email EMAIL [options]

Tenant
  --tenant-name NAME            Tenant name (required)
  --tenant-description TEXT     Description (default: "Sub-tenant NAME")
  --subdomain SUB               Login prefix for tenant users, e.g. acme -> acme\username
  --currency CODE               3-letter currency code (default: USD)

Tenant role (permission ceiling for the whole tenant)
  --tenant-role-name NAME       Default: "NAME Tenant Role"
  --tenant-role-template NAME   Role to copy permissions from (default: "Tenant Admin"; "" = start empty)

Cloud
  --cloud-id ID                 Cloud (zone) ID; required unless --cloud-mode none
  --cloud-mode MODE             shared (default) | dedicated | none
  --resource-pools IDS          shared mode: comma-separated resource pool IDs to share
  --datastores IDS              shared mode: comma-separated datastore IDs to share
  --networks IDS                shared mode: comma-separated network IDs to share
  --group-name NAME             Group created inside the tenant (default: tenant name)

Admin user inside the tenant
  --admin-username USER         (required)
  --admin-email EMAIL           (required)
  --admin-first-name NAME       Default: Tenant
  --admin-last-name NAME        Default: Admin
  --user-role-name NAME         Role given to the admin (default: "Tenant Admin")
  --user-role-template NAME     Role to copy from if it must be created (default: "Tenant Admin")
  --generate-password           Generate a strong password and print it once

General
  --dry-run                     Do lookups only; print every change instead of making it
  --yes                         Approve changes that affect other tenants without prompting
  --insecure                    Ignore SSL certificate errors (lab appliances only)
  -h, --help                    Show this help

Environment: MORPHEUS_URL, MORPHEUS_TOKEN (required),
             TENANT_ADMIN_PASSWORD, MORPHEUS_SKIP_TLS_VERIFY, MORPHEUS_CA_CERT (optional)
EOF
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then C_CYAN=$'\e[36m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
else C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM="" C_OFF=""; fi

step() { printf '\n%s==> %s%s\n' "$C_CYAN" "$1" "$C_OFF"; }
ok()   { printf '    %s[ok]%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    %s[warn] %s%s\n' "$C_YELLOW" "$1" "$C_OFF"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$1" "$C_OFF" >&2; }
die()  {
  printf '\n%s[error] %s%s\n' "$C_RED" "$1" "$C_OFF" >&2
  printf '%s        Fix the cause and re-run with the same options; completed steps are reused.%s\n' "$C_RED" "$C_OFF" >&2
  exit 1
}
usage_error() { printf '%s\n\n' "error: $1" >&2; usage >&2; exit 2; }

done_msg() { if [[ $DRY_RUN == 1 ]]; then dim "    [plan] $2"; else ok "$1"; fi; }
fmt_id()   { if [[ -z $1 || $1 == 0 ]]; then printf 'new'; else printf 'ID %s' "$1"; fi; }

redact() { sed -E 's/"password"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"/"password":"********"/g' <<<"$1"; }

# ---------------------------------------------------------------------------
# Argument parsing (supports "--opt value" and "--opt=value")
# ---------------------------------------------------------------------------
need_value() { [[ $# -ge 2 && $2 != --* ]] || usage_error "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  if [[ $1 == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case $1 in
    --tenant-name)          need_value "$@"; TENANT_NAME=$2; shift 2 ;;
    --tenant-description)   need_value "$@"; TENANT_DESCRIPTION=$2; shift 2 ;;
    --subdomain)            need_value "$@"; SUBDOMAIN=$2; shift 2 ;;
    --currency)             need_value "$@"; CURRENCY=$2; shift 2 ;;
    --tenant-role-name)     need_value "$@"; TENANT_ROLE_NAME=$2; shift 2 ;;
    --tenant-role-template) need_value "$@"; TENANT_ROLE_TEMPLATE=$2; shift 2 ;;
    --cloud-id)             need_value "$@"; CLOUD_ID=$2; shift 2 ;;
    --cloud-mode)           need_value "$@"; CLOUD_MODE=$2; shift 2 ;;
    --resource-pools)       need_value "$@"; RESOURCE_POOL_IDS=$2; shift 2 ;;
    --datastores)           need_value "$@"; DATASTORE_IDS=$2; shift 2 ;;
    --networks)             need_value "$@"; NETWORK_IDS=$2; shift 2 ;;
    --group-name)           need_value "$@"; GROUP_NAME=$2; shift 2 ;;
    --user-role-name)       need_value "$@"; USER_ROLE_NAME=$2; shift 2 ;;
    --user-role-template)   need_value "$@"; USER_ROLE_TEMPLATE=$2; shift 2 ;;
    --admin-username)       need_value "$@"; ADMIN_USERNAME=$2; shift 2 ;;
    --admin-email)          need_value "$@"; ADMIN_EMAIL=$2; shift 2 ;;
    --admin-first-name)     need_value "$@"; ADMIN_FIRST=$2; shift 2 ;;
    --admin-last-name)      need_value "$@"; ADMIN_LAST=$2; shift 2 ;;
    --generate-password)    GENERATE_PASSWORD=1; shift ;;
    --dry-run)              DRY_RUN=1; shift ;;
    --yes|-y)               ASSUME_YES=1; shift ;;
    --insecure|-k)          INSECURE=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      usage_error "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "bash 4.4 or newer is required (found $BASH_VERSION)."
command -v curl >/dev/null || die "curl is required."
command -v jq >/dev/null   || die "jq is required."

[[ -n $TENANT_NAME ]]    || usage_error "--tenant-name is required"
[[ -n $ADMIN_USERNAME ]] || usage_error "--admin-username is required"
[[ $ADMIN_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || usage_error "--admin-email must be a valid email address"
[[ $CLOUD_MODE =~ ^(shared|dedicated|none)$ ]] || usage_error "--cloud-mode must be shared, dedicated or none"
[[ $SUBDOMAIN =~ ^[A-Za-z0-9-]*$ ]] || usage_error "--subdomain may only contain letters, digits and hyphens"
[[ $CURRENCY =~ ^[A-Z]{3}$ ]] || usage_error "--currency must be a 3-letter code such as USD or INR"
if [[ $CLOUD_MODE != none ]]; then
  [[ $CLOUD_ID =~ ^[1-9][0-9]*$ ]] || usage_error "--cloud-id is required (a number) when --cloud-mode is $CLOUD_MODE"
fi
for list in "$RESOURCE_POOL_IDS" "$DATASTORE_IDS" "$NETWORK_IDS"; do
  [[ -z $list || $list =~ ^[0-9]+(,[0-9]+)*$ ]] || usage_error "ID lists must be comma-separated numbers, e.g. 3,7"
done
if [[ $CLOUD_MODE != shared && -n $RESOURCE_POOL_IDS$DATASTORE_IDS$NETWORK_IDS ]]; then
  usage_error "--resource-pools / --datastores / --networks only apply to --cloud-mode shared"
fi

: "${TENANT_ROLE_NAME:=$TENANT_NAME Tenant Role}"
: "${GROUP_NAME:=$TENANT_NAME}"
: "${TENANT_DESCRIPTION:=Sub-tenant $TENANT_NAME}"

BASE_URL=${MORPHEUS_URL:-}
BASE_URL=${BASE_URL%/}
[[ -n $BASE_URL ]] || die "Set MORPHEUS_URL (e.g. https://vme-manager.example.local)."
[[ -n ${MORPHEUS_TOKEN:-} ]] || die "Set MORPHEUS_TOKEN to the API access token of a master-tenant admin."
[[ $BASE_URL == https://* ]] || warn "MORPHEUS_URL is not https:// - the API token will be sent unencrypted."

# The token goes into a private header file so it never appears in the process list.
umask 077
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
printf 'Authorization: Bearer %s\n' "$MORPHEUS_TOKEN" > "$WORKDIR/auth.hdr"

CURL_OPTS=(-sS --connect-timeout 15 --max-time 120 -H "@$WORKDIR/auth.hdr" -H 'Accept: application/json')

# ---------------------------------------------------------------------------
# SSL / TLS certificate handling
# ---------------------------------------------------------------------------
# Lab appliances usually present a self-signed certificate, which makes curl fail with
# "SSL certificate problem: self-signed certificate" (curl exit code 60).
# Two ways to deal with it:
#   - Trust the appliance CA (safer):  MORPHEUS_CA_CERT=/path/to/appliance-ca.pem
#   - Ignore certificate errors:       --insecure, or MORPHEUS_SKIP_TLS_VERIFY=true
# Never ignore certificate errors against production appliances.
if [[ -n ${MORPHEUS_CA_CERT:-} ]]; then
  [[ -r $MORPHEUS_CA_CERT ]] || die "MORPHEUS_CA_CERT points to '$MORPHEUS_CA_CERT', which is not a readable file."
  CURL_OPTS+=(--cacert "$MORPHEUS_CA_CERT")
fi
if [[ $INSECURE == 1 || ${MORPHEUS_SKIP_TLS_VERIFY:-} =~ ^(1|[Tt]rue|TRUE|[Yy]es|YES)$ ]]; then
  CURL_OPTS+=(-k)
  warn "SSL certificate errors are being IGNORED (lab mode). Do not use this against production."
fi

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# qs key value [key value ...]  ->  ?key=value&...
qs() {
  local out="" sep="?"
  while [[ $# -ge 2 ]]; do
    out+="${sep}$(urlenc "$1")=$(urlenc "$2")"; sep="&"; shift 2
  done
  printf '%s' "$out"
}

curl_failed() {
  case $1 in
    35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
      die "SSL/TLS error talking to $BASE_URL (curl exit $1). If the appliance uses a self-signed certificate, add --insecure or set MORPHEUS_SKIP_TLS_VERIFY=true (or trust its CA with MORPHEUS_CA_CERT=/path/ca.pem)." ;;
    *)
      die "Could not reach $BASE_URL (curl exit $1). Check MORPHEUS_URL, DNS and the network." ;;
  esac
}

# api METHOD PATH [JSON_BODY]  -> prints the response JSON. Exits the script on any error.
api() {
  local method=$1 path=$2 body=${3-} code out rc=0
  if [[ $method != GET && $DRY_RUN == 1 ]]; then
    dim "    [dry-run] $method ${path%%\?*}"
    if [[ -n $body ]]; then dim "              $(redact "$body")"; fi
    printf '{}'
    return 0
  fi
  out="$WORKDIR/response.json"
  if [[ -n $body ]]; then
    code=$(curl "${CURL_OPTS[@]}" -X "$method" -H 'Content-Type: application/json' \
             --data-binary @- -o "$out" -w '%{http_code}' "$BASE_URL$path" <<<"$body") || rc=$?
  else
    code=$(curl "${CURL_OPTS[@]}" -X "$method" -o "$out" -w '%{http_code}' "$BASE_URL$path") || rc=$?
  fi
  if (( rc != 0 )); then curl_failed "$rc"; fi
  if (( code >= 400 )); then
    die "API $method ${path%%\?*} failed (HTTP $code): $(redact "$(head -c 2000 "$out")")"
  fi
  if ! jq -e . "$out" >/dev/null 2>&1; then
    die "API $method ${path%%\?*} returned a non-JSON response (HTTP $code). Is MORPHEUS_URL the appliance URL?"
  fi
  if jq -e 'type == "object" and has("success") and .success == false' "$out" >/dev/null; then
    die "API $method ${path%%\?*} was rejected: $(redact "$(head -c 2000 "$out")")"
  fi
  cat "$out"
}

# find_by NAME_FIELD VALUE LIST_KEY  (JSON on stdin) -> first matching object (case-insensitive) or nothing
find_by() {
  jq -c --arg f "$1" --arg v "$2" --arg k "$3" \
    '[.[$k][]? | select(((.[$f] // "") | ascii_downcase) == ($v | ascii_downcase))][0] // empty'
}

# owner_id (JSON on stdin) -> tenant id that owns the object, or nothing
owner_id() { jq -r '.account.id // .accountId // .owner.id // empty'; }

confirm_change() {
  warn "$1"
  if [[ $DRY_RUN == 1 || $ASSUME_YES == 1 ]]; then return 0; fi
  [[ -t 0 ]] || die "This change needs confirmation. Re-run with --yes to approve it non-interactively."
  local answer
  read -rp "    Proceed? [y/N] " answer
  [[ $answer =~ ^([yY]|[yY][eE][sS])$ ]] || die "Stopped at your request. Nothing after this point was changed."
}

# resolve_copy_from TEMPLATE ROLE_TYPE OWNER_TENANT_ID -> role id to copy from (empty if TEMPLATE is empty)
resolve_copy_from() {
  local template=$1 role_type=$2 owner=$3 res match
  if [[ -z $template ]]; then return 0; fi
  res=$(api GET "/api/options/copyFromRole$(qs roleType "$role_type" tenantId "$owner")")
  match=$(jq -r --arg n "$template" '[.data[]? | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].value // empty' <<<"$res")
  if [[ -z $match ]]; then
    die "Template role '$template' ($role_type role) was not found. Roles you can copy from: $(jq -r '[.data[]?.name] | join(", ")' <<<"$res")"
  fi
  printf '%s' "$match"
}

gen_password() {
  local p special='[!@#%^*_=+-]'
  while :; do
    p=$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9!@#%^*_=+-' </dev/urandom | head -c 20 || true)
    if [[ ${#p} -eq 20 && $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] && $p =~ $special ]]; then break; fi
  done
  printf '%s' "$p"
}

PASSWORD="" GENERATED_PASSWORD=""
get_password() {
  if [[ -n ${TENANT_ADMIN_PASSWORD:-} ]]; then PASSWORD=$TENANT_ADMIN_PASSWORD; return 0; fi
  if [[ $GENERATE_PASSWORD == 1 ]]; then PASSWORD=$(gen_password); GENERATED_PASSWORD=$PASSWORD; return 0; fi
  [[ -t 0 ]] || die "No password available. Set TENANT_ADMIN_PASSWORD or use --generate-password."
  local p1 p2
  read -rsp "    Password for '$ADMIN_USERNAME': " p1; echo
  read -rsp "    Confirm password: " p2; echo
  [[ $p1 == "$p2" ]] || die "Passwords did not match."
  (( ${#p1} >= 8 )) || die "Password must be at least 8 characters."
  PASSWORD=$p1
}

# share_resource KIND PATH KEY -> adds TENANT_ID to a resource pool / datastore / network
share_resource() {
  local kind=$1 path=$2 key=$3 res obj label vis body
  res=$(api GET "$path")
  obj=$(jq -c --arg k "$key" '.[$k] // empty' <<<"$res")
  [[ -n $obj ]] || die "$kind at $path was not found."
  label="$kind '$(jq -r '.name' <<<"$obj")' (ID $(jq -r '.id' <<<"$obj"))"
  vis=$(jq -r '.visibility // "private"' <<<"$obj")
  if [[ $vis == public ]]; then ok "$label is Public - all tenants can already use it"; return 0; fi
  if jq -e --argjson t "$TENANT_ID" 'any(.tenants[]?; .id == $t)' <<<"$obj" >/dev/null; then
    ok "$label is already shared with the tenant"; return 0
  fi
  if [[ $key == network ]]; then
    body=$(jq -c --argjson t "$TENANT_ID" '{network: {tenants: ([.tenants[]?.id] + [$t] | unique | map({id: .}))}}' <<<"$obj")
  else
    body=$(jq -c --arg k "$key" --arg v "$vis" --argjson t "$TENANT_ID" \
      '{($k): {visibility: $v}, tenantPermissions: {accounts: ([.tenants[]?.id] + [$t] | unique)}}' <<<"$obj")
  fi
  api PUT "$path" "$body" >/dev/null
  done_msg "$label shared with the tenant" "Would share $label with the tenant"
}

declare -A SUMMARY=()
SUMMARY_ORDER=()
add_summary() { SUMMARY[$1]=$2; SUMMARY_ORDER+=("$1"); }

# ===========================================================================
# Main
# ===========================================================================
if [[ $DRY_RUN == 1 ]]; then printf '\nDRY RUN - lookups are real, nothing will be created or changed.\n'; fi

# 0. Who am I? -------------------------------------------------------------
step "Checking API access"
WHOAMI=$(api GET "/api/whoami")
[[ $(jq -r '.isMasterAccount // false' <<<"$WHOAMI") == true ]] || die "The API token must belong to a user in the MASTER tenant."
MASTER_ID=$(jq -c '.user' <<<"$WHOAMI" | owner_id)
[[ -n $MASTER_ID ]] || die "Could not determine the master tenant ID from /api/whoami."
ok "Connected as '$(jq -r '.user.username' <<<"$WHOAMI")' (master tenant ID $MASTER_ID)"

# Existing tenant? (lets a re-run pick up where it left off)
RES=$(api GET "/api/accounts$(qs name "$TENANT_NAME" max 1000)")
TENANT=$(find_by name "$TENANT_NAME" accounts <<<"$RES")
TENANT_ID=0
if [[ -n $TENANT ]]; then TENANT_ID=$(jq -r '.id' <<<"$TENANT"); fi

# 1. Cloud pre-checks (read-only) ------------------------------------------
CLOUD="" CLOUD_NAME="" CLOUD_OWNER=""
if [[ $CLOUD_MODE != none ]]; then
  step "Checking cloud ID $CLOUD_ID"
  RES=$(api GET "/api/zones/$CLOUD_ID")
  CLOUD=$(jq -c '.zone // empty' <<<"$RES")
  [[ -n $CLOUD ]] || die "Cloud ID $CLOUD_ID was not found."
  CLOUD_NAME=$(jq -r '.name' <<<"$CLOUD")
  CLOUD_OWNER=$(owner_id <<<"$CLOUD")
  CLOUD_OWNER=${CLOUD_OWNER:-$MASTER_ID}
  ok "Cloud '$CLOUD_NAME' - visibility: $(jq -r '.visibility' <<<"$CLOUD"); owner tenant ID: $CLOUD_OWNER"
  if [[ $CLOUD_OWNER != "$MASTER_ID" && $CLOUD_OWNER != "$TENANT_ID" ]]; then
    die "Cloud '$CLOUD_NAME' is assigned to another tenant (ID $CLOUD_OWNER). Reassign it in the UI first."
  fi
  if [[ $CLOUD_MODE == shared && $CLOUD_OWNER != "$MASTER_ID" ]]; then
    die "Cloud '$CLOUD_NAME' is already dedicated to this tenant. Use --cloud-mode dedicated, or reassign it to the master tenant first."
  fi
fi

# 2. Shared mode: cloud must be Public before a tenant role can get access --
if [[ $CLOUD_MODE == shared ]]; then
  step "Making cloud '$CLOUD_NAME' available to tenants (Public)"
  if [[ $(jq -r '.visibility' <<<"$CLOUD") == public ]]; then
    ok "Cloud is already Public"
  else
    confirm_change "Cloud '$CLOUD_NAME' is Private. Setting it to Public lets it be granted to ANY tenant's role, and tenants created later get it added automatically. Existing tenants only see it if their tenant role grants access."
    api PUT "/api/zones/$CLOUD_ID" '{"zone":{"visibility":"public"}}' >/dev/null
    done_msg "Cloud visibility set to Public" "Would set the cloud visibility to Public"
  fi
fi

# 3. Tenant role -------------------------------------------------------------
step "Tenant role '$TENANT_ROLE_NAME'"
RES=$(api GET "/api/roles$(qs roleType account name "$TENANT_ROLE_NAME" max 1000)")
TENANT_ROLE=$(find_by authority "$TENANT_ROLE_NAME" roles <<<"$RES")
if [[ -n $TENANT_ROLE ]]; then
  TENANT_ROLE_ID=$(jq -r '.id' <<<"$TENANT_ROLE")
  ok "Found existing tenant role (ID $TENANT_ROLE_ID)"
else
  BASE_ROLE_ID=$(resolve_copy_from "$TENANT_ROLE_TEMPLATE" account "$MASTER_ID")
  if [[ -z $BASE_ROLE_ID ]]; then warn "No --tenant-role-template given: the role starts with NO feature permissions."; fi
  BODY=$(jq -cn --arg a "$TENANT_ROLE_NAME" --arg d "Permission ceiling for tenant $TENANT_NAME" --arg b "$BASE_ROLE_ID" \
    '{role: ({authority: $a, description: $d, roleType: "account"} + (if $b == "" then {} else {baseRoleId: ($b | tonumber)} end))}')
  RES=$(api POST "/api/roles" "$BODY")
  TENANT_ROLE_ID=$(jq -r '.role.id // 0' <<<"$RES")
  done_msg "Created tenant role (ID $TENANT_ROLE_ID), copied from '$TENANT_ROLE_TEMPLATE'" "Would create the tenant role, copied from '$TENANT_ROLE_TEMPLATE'"
fi
if [[ $CLOUD_MODE == shared ]]; then
  if [[ $TENANT_ROLE_ID != 0 ]]; then
    api PUT "/api/roles/$TENANT_ROLE_ID/update-cloud" "$(jq -cn --argjson c "$CLOUD_ID" '{cloudId: $c, access: "full"}')" >/dev/null
  else
    dim "    [dry-run] PUT /api/roles/<new-role-id>/update-cloud  {cloudId: $CLOUD_ID, access: full}"
  fi
  done_msg "Tenant role has Full access to cloud '$CLOUD_NAME'" "Would give the tenant role Full access to cloud '$CLOUD_NAME'"
fi
add_summary "Tenant role" "$TENANT_ROLE_NAME ($(fmt_id "$TENANT_ROLE_ID"))"

# 4. Tenant ------------------------------------------------------------------
step "Tenant '$TENANT_NAME'"
if [[ -n $TENANT ]]; then
  ok "Found existing tenant (ID $TENANT_ID)"
  EXISTING_BASE=$(jq -r '.role.id // empty' <<<"$TENANT")
  if [[ -n $EXISTING_BASE && $EXISTING_BASE != "$TENANT_ROLE_ID" ]]; then
    warn "Tenant's base role is '$(jq -r '.role.authority // .role.name' <<<"$TENANT")', not '$TENANT_ROLE_NAME'. Left unchanged."
  fi
else
  BODY=$(jq -cn --arg n "$TENANT_NAME" --arg d "$TENANT_DESCRIPTION" --argjson r "$TENANT_ROLE_ID" \
                --arg c "$CURRENCY" --arg s "$SUBDOMAIN" \
    '{account: ({name: $n, description: $d, role: {id: $r}, currency: $c} + (if $s == "" then {} else {subdomain: $s} end))}')
  RES=$(api POST "/api/accounts" "$BODY")
  TENANT=$(jq -c '.account // empty' <<<"$RES")
  TENANT_ID=$(jq -r '.account.id // 0' <<<"$RES")
  done_msg "Created tenant (ID $TENANT_ID)" "Would create the tenant"
fi
add_summary "Tenant" "$TENANT_NAME ($(fmt_id "$TENANT_ID"))"

# 5. Cloud: assign (dedicated) or share resources (shared) -------------------
if [[ $CLOUD_MODE == dedicated ]]; then
  step "Assigning cloud '$CLOUD_NAME' to the tenant"
  if [[ $TENANT_ID != 0 && $CLOUD_OWNER == "$TENANT_ID" ]]; then
    ok "Cloud is already assigned to this tenant"
  else
    confirm_change "Cloud '$CLOUD_NAME' and ALL of its resources will be available ONLY to tenant '$TENANT_NAME'. Other sub-tenants lose access to it; the master tenant keeps control."
    api PUT "/api/zones/$CLOUD_ID" "$(jq -cn --argjson t "$TENANT_ID" '{zone: {accountId: $t, visibility: "private"}}')" >/dev/null
    done_msg "Cloud assigned to the tenant (visibility Private)" "Would assign the cloud to the tenant (visibility Private)"
  fi
  add_summary "Cloud" "$CLOUD_NAME - dedicated to this tenant"
elif [[ $CLOUD_MODE == shared ]]; then
  step "Sharing cloud resources with the tenant"
  if [[ -n $RESOURCE_POOL_IDS$DATASTORE_IDS$NETWORK_IDS ]]; then
    if [[ $TENANT_ID == 0 ]]; then
      info "[dry-run] would share the listed resources with the new tenant once it exists"
    else
      IFS=, read -ra IDS <<<"$RESOURCE_POOL_IDS"; for id in "${IDS[@]}"; do share_resource "Resource pool" "/api/zones/$CLOUD_ID/resource-pools/$id" resourcePool; done
      IFS=, read -ra IDS <<<"$DATASTORE_IDS";     for id in "${IDS[@]}"; do share_resource "Datastore" "/api/zones/$CLOUD_ID/data-stores/$id" datastore; done
      IFS=, read -ra IDS <<<"$NETWORK_IDS";       for id in "${IDS[@]}"; do share_resource "Network" "/api/networks/$id" network; done
    fi
  else
    warn "No resources listed. The tenant will see the cloud but cannot provision until a resource pool,"
    warn "datastore and network are shared (or Public). Candidates in this cloud:"
    RES=$(api GET "/api/zones/$CLOUD_ID/resource-pools$(qs max 200)")
    jq -r '.resourcePools[]? | "      --resource-pools \(.id)\t\(.name) [\(.visibility)]"' <<<"$RES"
    RES=$(api GET "/api/zones/$CLOUD_ID/data-stores$(qs max 200)")
    jq -r '.datastores[]? | "      --datastores     \(.id)\t\(.name) [\(.visibility)]"' <<<"$RES"
    RES=$(api GET "/api/networks$(qs zoneId "$CLOUD_ID" max 200)")
    jq -r '.networks[]? | "      --networks       \(.id)\t\(.name) [\(.visibility)]"' <<<"$RES"
    info "Re-run with the IDs you want to share; finished steps are skipped."
  fi
  add_summary "Cloud" "$CLOUD_NAME - shared (Public, tenant role Full)"
fi

# 6. Group inside the tenant that contains the cloud --------------------------
if [[ $CLOUD_MODE != none ]]; then
  step "Tenant group for the cloud"
  if [[ $TENANT_ID == 0 ]]; then
    info "[dry-run] would create group '$GROUP_NAME' in the new tenant and add cloud ID $CLOUD_ID"
  else
    RES=$(api GET "/api/accounts/$TENANT_ID/groups$(qs max 1000)")
    GROUP=$(jq -c --argjson c "$CLOUD_ID" '[.groups[]? | select(any(.zones[]?; .id == $c))][0] // empty' <<<"$RES")
    if [[ -n $GROUP ]]; then
      ok "Group '$(jq -r .name <<<"$GROUP")' (ID $(jq -r .id <<<"$GROUP")) already contains the cloud"
    else
      GROUP=$(find_by name "$GROUP_NAME" groups <<<"$RES")
      if [[ -n $GROUP ]]; then
        ok "Found existing group '$GROUP_NAME' (ID $(jq -r .id <<<"$GROUP"))"
      else
        BODY=$(jq -cn --arg n "$GROUP_NAME" --arg d "Default group for tenant $TENANT_NAME" '{group: {name: $n, description: $d}}')
        RES=$(api POST "/api/accounts/$TENANT_ID/groups" "$BODY")
        GROUP=$(jq -c '.group // {id: 0, zones: []}' <<<"$RES")
        done_msg "Created group '$GROUP_NAME' (ID $(jq -r .id <<<"$GROUP"))" "Would create group '$GROUP_NAME'"
      fi
      GROUP_ID=$(jq -r '.id' <<<"$GROUP")
      [[ $GROUP_ID != 0 ]] || GROUP_ID="<new-group-id>"
      BODY=$(jq -c --argjson c "$CLOUD_ID" '{group: {zones: ([.zones[]?.id] + [$c] | unique | map({id: .}))}}' <<<"$GROUP")
      api PUT "/api/accounts/$TENANT_ID/groups/$GROUP_ID/update-zones" "$BODY" >/dev/null
      done_msg "Cloud added to group '$GROUP_NAME'" "Would add the cloud to group '$GROUP_NAME'"
    fi
    add_summary "Group" "$(jq -r --arg n "$GROUP_NAME" '.name // $n' <<<"$GROUP") ($(fmt_id "$(jq -r '.id' <<<"$GROUP")"))"
  fi
fi

# 7. User role owned by the tenant --------------------------------------------
step "User role '$USER_ROLE_NAME' in the tenant"
USER_ROLE_ID=0
if [[ $TENANT_ID == 0 ]]; then
  info "[dry-run] would reuse or create user role '$USER_ROLE_NAME' (copied from '$USER_ROLE_TEMPLATE') owned by the new tenant"
else
  RES=$(api GET "/api/roles$(qs tenant "$TENANT_ID" roleType user max 1000)")
  RES=$(jq -c --argjson t "$TENANT_ID" '{roles: [.roles[]? | select((.owner.id // $t) == $t)]}' <<<"$RES")
  USER_ROLE=$(find_by authority "$USER_ROLE_NAME" roles <<<"$RES")
  if [[ -n $USER_ROLE ]]; then
    USER_ROLE_ID=$(jq -r '.id' <<<"$USER_ROLE")
    ok "Found existing role in the tenant (ID $USER_ROLE_ID)"
  else
    BASE_USER_ROLE_ID=$(resolve_copy_from "$USER_ROLE_TEMPLATE" user "$TENANT_ID")
    if [[ -z $BASE_USER_ROLE_ID ]]; then warn "No --user-role-template given: the role starts with NO feature permissions."; fi
    BODY=$(jq -cn --arg a "$USER_ROLE_NAME" --arg d "Administrator for tenant $TENANT_NAME" \
                  --argjson o "$TENANT_ID" --arg b "$BASE_USER_ROLE_ID" \
      '{role: ({authority: $a, description: $d, roleType: "user", owner: $o, globalSiteAccess: "full"}
               + (if $b == "" then {} else {baseRoleId: ($b | tonumber)} end))}')
    RES=$(api POST "/api/roles" "$BODY")
    USER_ROLE_ID=$(jq -r '.role.id // 0' <<<"$RES")
    done_msg "Created user role (ID $USER_ROLE_ID) with access to all groups in the tenant" "Would create user role '$USER_ROLE_NAME' with access to all groups in the tenant"
  fi
  if [[ $USER_ROLE_ID != 0 ]]; then
    RES=$(api GET "/api/accounts/$TENANT_ID/users/available-roles")
    if ! jq -e --argjson r "$USER_ROLE_ID" 'any(.roles[]?; .id == $r)' <<<"$RES" >/dev/null; then
      warn "Role ID $USER_ROLE_ID is not listed as assignable in this tenant; user creation may fail."
    fi
  fi
fi
add_summary "User role" "$USER_ROLE_NAME ($(fmt_id "$USER_ROLE_ID"))"

# 8. Admin user ----------------------------------------------------------------
step "Admin user '$ADMIN_USERNAME'"
EXISTING_USER=""
if [[ $TENANT_ID != 0 ]]; then
  RES=$(api GET "/api/accounts/$TENANT_ID/users$(qs max 1000)")
  EXISTING_USER=$(find_by username "$ADMIN_USERNAME" users <<<"$RES")
fi
if [[ -n $EXISTING_USER ]]; then
  ok "User already exists in the tenant (ID $(jq -r .id <<<"$EXISTING_USER")) - password and roles left unchanged"
  add_summary "Admin user" "$ADMIN_USERNAME (ID $(jq -r .id <<<"$EXISTING_USER"))"
else
  if [[ $DRY_RUN == 1 ]]; then PASSWORD="(not used in dry run)"; else get_password; fi
  BODY=$(jq -cn --arg u "$ADMIN_USERNAME" --arg e "$ADMIN_EMAIL" --arg f "$ADMIN_FIRST" --arg l "$ADMIN_LAST" \
                --arg p "$PASSWORD" --argjson r "$USER_ROLE_ID" \
    '{user: {username: $u, email: $e, firstName: $f, lastName: $l, password: $p, roles: [{id: $r}]}}')
  TENANT_PATH=$TENANT_ID; [[ $TENANT_ID != 0 ]] || TENANT_PATH="<new-tenant-id>"
  RES=$(api POST "/api/accounts/$TENANT_PATH/users" "$BODY")
  PASSWORD="" BODY=""
  if [[ $DRY_RUN == 1 ]]; then dim "    [plan] Would create user '$ADMIN_USERNAME'"; add_summary "Admin user" "$ADMIN_USERNAME (new)"; fi
  USER_ID=$(jq -r '.user.id // empty' <<<"$RES")
  if [[ -n $USER_ID ]]; then
    CREATED_IN=$(jq -c '.user' <<<"$RES" | owner_id)
    if [[ -n $CREATED_IN && $CREATED_IN != "$TENANT_ID" ]]; then
      warn "User was created in tenant ID $CREATED_IN, expected $TENANT_ID. Check Administration > Tenants."
    fi
    ok "Created user (ID $USER_ID)"
    add_summary "Admin user" "$ADMIN_USERNAME (ID $USER_ID)"
  fi
fi

# Summary ----------------------------------------------------------------------
LOGIN_PREFIX=$SUBDOMAIN
if [[ -z $LOGIN_PREFIX && -n $TENANT ]]; then LOGIN_PREFIX=$(jq -r '.subdomain // empty' <<<"$TENANT"); fi
if [[ -z $LOGIN_PREFIX ]]; then LOGIN_PREFIX=$TENANT_ID; [[ $LOGIN_PREFIX != 0 ]] || LOGIN_PREFIX="<tenant-id>"; fi

printf '\n%s================================================================%s\n' "$C_CYAN" "$C_OFF"
if [[ $DRY_RUN == 1 ]]; then printf '%s DRY RUN COMPLETE - nothing was changed%s\n' "$C_GREEN" "$C_OFF"
else printf '%s TENANT READY%s\n' "$C_GREEN" "$C_OFF"; fi
for key in "${SUMMARY_ORDER[@]}"; do printf ' %-12s %s\n' "$key:" "${SUMMARY[$key]}"; done
printf ' %-12s %s  as  %s\\%s\n' "Sign in:" "$BASE_URL" "$LOGIN_PREFIX" "$ADMIN_USERNAME"
if [[ -n $GENERATED_PASSWORD ]]; then
  printf '%s %-12s %s%s\n' "$C_YELLOW" "Password:" "$GENERATED_PASSWORD" "$C_OFF"
  printf '%s              (shown once - store it in your password manager and have the user change it)%s\n' "$C_YELLOW" "$C_OFF"
fi
printf '%s================================================================%s\n' "$C_CYAN" "$C_OFF"

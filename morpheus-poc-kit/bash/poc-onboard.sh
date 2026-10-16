#!/usr/bin/env bash
#
# poc-onboard.sh - build a customer PoC on HPE Morpheus / VME Manager from one JSON config file.
#
#   As the master tenant (MORPHEUS_TOKEN)          Inside the new tenant (signed in as its admin)
#   -------------------------------------          ----------------------------------------------
#    1 pre-flight: every name in the config is      7 groups that contain the cloud
#      looked up before anything is changed         8 roles mapped to groups, features and persona
#    2 cloud made Public (shared) or assigned       9 users
#      to the tenant (dedicated)                   10 tag dropdowns: option lists + select inputs
#    3 tenant role with Full access to the cloud   11 VM catalog item: plan list, inputs, tags
#    4 tenant                                      12 3-tier app blueprint + its catalog item
#    5 resource pools / datastores / networks      13 role access to catalog items and blueprints
#      shared with the tenant                      14 policies: naming, approval, tag enforcement,
#    6 tenant admin role and admin user               quotas
#
# Every step is get-or-create: re-running finishes a partial run and skips what already exists.
# Each object is recorded in state/<tenant>.json; poc-teardown.sh uses that file to undo the run.
#
# Environment:
#   MORPHEUS_URL, MORPHEUS_TOKEN (master-tenant admin)          required
#   TENANT_ADMIN_PASSWORD   password for the tenant admin; generated and printed once if unset
#   MORPHEUS_SKIP_TLS_VERIFY / MORPHEUS_CA_CERT                 lab certificates
# Requires bash 4.4+, curl 7.55+, jq 1.6+.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/morpheus.sh
source "$HERE/lib/morpheus.sh"

CONFIG="" STATE_DIR="$HERE/../state" DRY_RUN=0 ASSUME_YES=0 INSECURE=0 RESET_ADMIN_PW=0

usage() {
  cat <<'EOF'
Usage: poc-onboard.sh --config customers/NAME.json [options]

  --config FILE             Customer config (JSON). See customers/example-acme.json and the README.
  --dry-run                 Look everything up, print every change, make none
  --yes                     Approve changes that affect other tenants without prompting
                            (making the cloud Public, assigning it to this tenant)
  --reset-admin-password    The tenant admin already exists and you don't have its password:
                            set a new one (printed once) so the script can sign in as it
  --state-dir DIR           Where run manifests are kept (default: <kit>/state)
  --insecure                Ignore SSL certificate errors (lab appliances only)
  -h, --help                Show this help

Environment: MORPHEUS_URL, MORPHEUS_TOKEN (required); TENANT_ADMIN_PASSWORD,
             MORPHEUS_SKIP_TLS_VERIFY, MORPHEUS_CA_CERT (optional)
EOF
}
usage_error() { printf 'error: %s\n\n' "$1" >&2; usage >&2; exit 2; }
need_value() { [[ $# -ge 2 && $2 != --* ]] || usage_error "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  if [[ $1 == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case $1 in
    --config)               need_value "$@"; CONFIG=$2; shift 2 ;;
    --state-dir)            need_value "$@"; STATE_DIR=$2; shift 2 ;;
    --dry-run)              DRY_RUN=1; shift ;;
    --yes|-y)               ASSUME_YES=1; shift ;;
    --reset-admin-password) RESET_ADMIN_PW=1; shift ;;
    --insecure|-k)          INSECURE=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      usage_error "unknown option: $1" ;;
  esac
done
[[ -n $CONFIG ]] || usage_error "--config is required"
[[ -f $CONFIG ]] || usage_error "config file '$CONFIG' not found"

# ===========================================================================
# Config
# ===========================================================================
CFG=$(jq -c . "$CONFIG" 2>/dev/null) || die "$CONFIG is not valid JSON."
cfg() { jq -r "$1" <<<"$CFG"; }

# Structural checks that need no API call. Every problem is listed at once.
CONFIG_ERRORS=$(jq -r '
  def s: type == "string" and length > 0;
  def names($a): [$a[]? | .name];
  ((.groups // [.tenant.name]) | map(tostring)) as $groups
  | ([.roles[]?.name] + [(.admin.role // "Tenant Admin")]) as $roles
  | ([.users[]?.username] + [.admin.username]) as $users
  | ([.catalog.vm.name, .catalog.threeTier.name] | map(select(. != null))) as $items
  | def scope($p; $sc):
      if $sc == null or $sc == "global" then empty
      elif ($sc | type) != "object" then "\($p): scope must be \"global\" or an object such as {\"role\": \"NAME\"}"
      elif $sc.group then (if ($groups | index($sc.group)) == null then "\($p): group \"\($sc.group)\" is not listed in groups" else empty end)
      elif $sc.role  then (if ($roles  | index($sc.role))  == null then "\($p): role \"\($sc.role)\" is not defined in roles (or admin.role)" else empty end)
      elif $sc.user  then (if ($users  | index($sc.user))  == null then "\($p): user \"\($sc.user)\" is not defined in users (or admin)" else empty end)
      elif $sc.cloud then empty
      else "\($p): scope must have one of group, role, user, cloud" end;
  [
    (if (.tenant.name | s) then empty else "tenant.name is required" end),
    (if ((.tenant.subdomain // "") | test("^[A-Za-z0-9-]*$")) then empty else "tenant.subdomain may only contain letters, digits and hyphens" end),
    (if ((.tenant.currency // "USD") | test("^[A-Z]{3}$")) then empty else "tenant.currency must be a 3-letter code such as INR" end),
    (if (.admin.username | s) then empty else "admin.username is required" end),
    (if ((.admin.email // "") | test("^[^@[:space:]]+@[^@[:space:]]+$")) then empty else "admin.email must be an email address" end),
    (if ((.cloud.mode // "shared") | IN("shared", "dedicated", "none")) then empty else "cloud.mode must be shared, dedicated or none" end),
    (if .cloud != null and (.cloud.mode // "shared") != "none" and ((.cloud.name // .cloud.id) == null) then "cloud.name is required" else empty end),
    (if (.cloud.mode // "shared") != "shared" and ((.cloud.share // {}) | [.[]?[]?] | length) > 0 then "cloud.share only applies to cloud.mode shared" else empty end),
    (if (.cloud == null or .cloud.mode == "none") and .catalog != null then "catalog needs a cloud (cloud.mode shared or dedicated)" else empty end),
    (if ($groups | length) != ($groups | unique | length) then "groups contains duplicates" else empty end),
    (if (names(.roles) | length) != (names(.roles) | unique | length) then "roles contains duplicate names" else empty end),
    (.roles[]? | . as $r
      | (if ($r.name | s) then empty else "every role needs a name" end),
        (if $r.groups == null or $r.groups == "all" then empty
         elif ($r.groups | type) == "array" then ($r.groups[] | select(. as $g | $groups | index($g) == null) | "role \"\($r.name)\": group \"\(.)\" is not listed in groups")
         else "role \"\($r.name)\": groups must be \"all\" or a list" end),
        (if $r.defaultPersona == null or ($r.defaultPersona | IN("standard", "serviceCatalog", "vdi")) then empty
         else "role \"\($r.name)\": defaultPersona must be standard, serviceCatalog or vdi" end),
        (if $r.catalogItems == null or ($r.catalogItems | IN("all", "none")) then empty
         elif ($r.catalogItems | type) == "array" then empty
         else "role \"\($r.name)\": catalogItems must be \"all\", \"none\" or a list" end)),
    (.users[]? | . as $u
      | (if ($u.username | s) and ($u.email | s) and ($u.role | s) then empty else "every user needs username, email and role" end)),
    (if (names(.tags) | length) != (names(.tags) | unique | length) then "tags contains duplicate names" else empty end),
    (.tags[]? | select((.name | s | not) or ((.values // []) | length) == 0) | "every tag needs a name and at least one value"),
    (.catalog.vm // empty | . as $v
      | ("name", "group", "layout", "image", "network", "resourcePool", "datastore") as $k
      | select(($v[$k] // "" | tostring) == "") | "catalog.vm.\($k) is required"),
    (.catalog.vm // empty | select((.plans // []) | length == 0) | "catalog.vm.plans needs at least one plan"),
    (.catalog.vm.group // empty | select(. as $g | $groups | index($g) == null) | "catalog.vm.group \"\(.)\" is not listed in groups"),
    (.catalog.threeTier // empty | . as $t
      | (("name", "group", "network", "resourcePool", "datastore") as $k | select(($t[$k] // "" | tostring) == "") | "catalog.threeTier.\($k) is required"),
        (if ($t.group // null) != null and ($groups | index($t.group)) == null then "catalog.threeTier.group \"\($t.group)\" is not listed in groups" else empty end),
        (if $t.templateFile == null and (($t.tiers // []) | length) == 0 then "catalog.threeTier.tiers needs at least one tier (or set templateFile)" else empty end),
        ($t.tiers[]? | . as $tier | ("name", "layout", "image", "plan") as $k | select(($tier[$k] // "" | tostring) == "")
          | "catalog.threeTier.tiers[\($tier.name // "?")].\($k) is required"),
        ($t.tiers[]?.linkTo[]? | select(. as $l | [$t.tiers[].name] | index($l) == null) | "catalog.threeTier: linkTo \"\(.)\" is not a tier name")),
    (if .policies.naming != null and ((.policies.naming.pattern // "") | length) == 0 then "policies.naming.pattern is required" else empty end),
    (if .policies.naming != null and ((.policies.naming.enforcement // "user") | IN("user", "fixed") | not) then "policies.naming.enforcement must be user or fixed" else empty end),
    scope("policies.naming.scope"; .policies.naming.scope),
    scope("policies.approval.scope"; .policies.approval.scope),
    scope("policies.tagEnforcement.scope"; .policies.tagEnforcement.scope),
    (.policies.quotas[]? | . as $q
      | (if ($q.name | s) then empty else "every quota needs a name" end),
        (if ([$q.maxVms, $q.maxCores, $q.maxMemoryGB, $q.maxStorageGB] | map(select(. != null)) | length) == 0
         then "quota \"\($q.name)\": set at least one of maxVms, maxCores, maxMemoryGB, maxStorageGB" else empty end),
        scope("quota \"\($q.name)\""; $q.scope)),
    (.roles[]? | select((.catalogItems | type) == "array") | .name as $rn | .catalogItems[]
      | select(. as $i | $items | index($i) == null) | "role \"\($rn)\": catalog item \"\(.)\" is not defined in catalog (it must already exist in the tenant)" )
  ] | .[]' <<<"$CFG")
# Catalog items listed on a role but not defined in this config are allowed if they already exist; report them as notes.
CONFIG_NOTES=$(grep 'must already exist in the tenant' <<<"$CONFIG_ERRORS" || true)
CONFIG_ERRORS=$(grep -v 'must already exist in the tenant' <<<"$CONFIG_ERRORS" || true)
if [[ -n $CONFIG_ERRORS ]]; then
  printf '%s[error] %s has problems:%s\n' "$C_RED" "$CONFIG" "$C_OFF" >&2
  while IFS= read -r line; do printf '        - %s\n' "$line" >&2; done <<<"$CONFIG_ERRORS"
  exit 2
fi

TENANT_NAME=$(cfg '.tenant.name')
SUBDOMAIN=$(cfg '.tenant.subdomain // empty')
TENANT_DESC=$(cfg '.tenant.description // ("PoC tenant " + .tenant.name)')
CURRENCY=$(cfg '.tenant.currency // "USD"')
TROLE_NAME=$(cfg '.tenant.role.name // (.tenant.name + " Tenant Role")')
TROLE_TEMPLATE=$(cfg 'if (.tenant.role // {}) | has("copyFrom") then .tenant.role.copyFrom else "Tenant Admin" end')
CLOUD_MODE=$(cfg 'if .cloud == null then "none" else (.cloud.mode // "shared") end')
CLOUD_REF=$(cfg '.cloud.name // .cloud.id // empty')
ADMIN_USER=$(cfg '.admin.username')
ADMIN_EMAIL=$(cfg '.admin.email')
ADMIN_FIRST=$(cfg '.admin.firstName // "Tenant"')
ADMIN_LAST=$(cfg '.admin.lastName // "Admin"')
ADMIN_ROLE=$(cfg '.admin.role // "Tenant Admin"')
ADMIN_ROLE_TEMPLATE=$(cfg 'if (.admin | has("roleCopyFrom")) then .admin.roleCopyFrom else "Tenant Admin" end')
PREFIX=$(cfg '.catalog.inputPrefix // "PoC"')
mapfile -t GROUPS_CFG < <(jq -r '(.groups // [.tenant.name])[] | tostring' <<<"$CFG")
mapfile -t ROLES_CFG < <(jq -c '.roles[]?' <<<"$CFG")
mapfile -t USERS_CFG < <(jq -c '.users[]?' <<<"$CFG")
mapfile -t TAGS_CFG < <(jq -c '.tags[]?' <<<"$CFG")
NAMING_FIXED=$(cfg 'if (.policies.naming.enforcement // "") == "fixed" then 1 else 0 end')

declare -A GROUP_IDS=() ROLE_IDS=() USER_IDS=() TAG_FIELD=() TAG_LIST_ID=() TAG_INPUT_ID=() CATALOG_IDS=() BLUEPRINT_OF=()
NEW_PASSWORDS=()

mp_init
MANIFEST_FILE="$STATE_DIR/$(slug "${SUBDOMAIN:-$TENANT_NAME}").json"
manifest_init "$MANIFEST_FILE" "$BASE_URL" "$TENANT_NAME"
MP_DIE_HINT="Fix the cause and re-run the same command; completed steps are reused. State: $MANIFEST_FILE"

if [[ $DRY_RUN == 1 ]]; then printf '\n%sDRY RUN - lookups are real, nothing will be created or changed.%s\n' "$C_BOLD" "$C_OFF"; fi
if [[ -n $CONFIG_NOTES ]]; then while IFS= read -r line; do warn "$line"; done <<<"$CONFIG_NOTES"; fi

# ===========================================================================
# Helpers used by the stages
# ===========================================================================
# copy_from_role TEMPLATE ROLE_TYPE OWNER_TENANT_ID -> ID of the role to copy permissions from ("" = none)
copy_from_role() {
  local template=$1 role_type=$2 owner=$3 res match
  [[ -n $template ]] || return 0
  res=$(api GET "/api/options/copyFromRole$(qs roleType "$role_type" tenantId "$owner")")
  match=$(jq -r --arg n "$template" '[.data[]? | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].value // empty' <<<"$res")
  [[ -n $match ]] || die "Template role '$template' ($role_type role) was not found. Roles you can copy from: $(jq -r '[.data[]?.name] | unique | join(", ")' <<<"$res")"
  printf '%s' "$match"
}

# tenant_roles_list -> the tenant's user roles, each with a .name (the API calls it authority)
tenant_roles_list() { api GET "/api/roles$(qs roleType user max 1000)" | jq -c '{roles: [.roles[]? | . + {name: (.authority // .name)}]}'; }

# ensure_option_list NAME DATASET_JSON_STRING -> REPLY_ID
ensure_option_list() {
  local name=$1 dataset=$2 res existing body
  res=$(api GET "/api/library/option-type-lists$(qs name "$name" max 1000)")
  existing=$(find_by name "$name" optionTypeLists <<<"$res")
  if [[ -n $existing ]]; then
    REPLY_ID=$(jq -r .id <<<"$existing")
    if ! jq -e --arg d "$dataset" '(.initialDataset // "[]" | fromjson) == ($d | fromjson)' <<<"$existing" >/dev/null 2>&1; then
      if [[ $(manifest_action optionList "$REPLY_ID") == created ]]; then
        api PUT "/api/library/option-type-lists/$REPLY_ID" "$(jq -cn --arg d "$dataset" '{optionTypeList: {initialDataset: $d}}')" >/dev/null
        done_msg "Option list '$name' updated with the values from the config" "Would update the values of option list '$name'"
      else
        warn "Option list '$name' exists with different values and was not created by this kit - left unchanged."
      fi
    else
      ok "Option list '$name' exists (ID $REPLY_ID)"
    fi
    record optionList tenant "$REPLY_ID" "$name" 0
  else
    body=$(jq -cn --arg n "$name" --arg d "$dataset" \
      '{optionTypeList: {name: $n, description: "Created by morpheus-poc-kit", type: "manual", initialDataset: $d}}')
    REPLY_ID=$(api POST /api/library/option-type-lists "$body" | jq -r '.optionTypeList.id // 0')
    record optionList tenant "$REPLY_ID" "$name" 1
    done_msg "Created option list '$name' (ID $REPLY_ID)" "Would create option list '$name'"
  fi
}

# ensure_input SPEC_JSON -> REPLY_ID   (SPEC is the optionType object)
ensure_input() {
  local spec=$1 name field res existing
  name=$(jq -r .name <<<"$spec")
  field=$(jq -r .fieldName <<<"$spec")
  res=$(api GET "/api/library/option-types$(qs name "$name" max 1000)")
  existing=$(find_by name "$name" optionTypes <<<"$res")
  if [[ -n $existing ]]; then
    [[ $(jq -r .fieldName <<<"$existing") == "$field" ]] \
      || die "Input '$name' already exists with field name '$(jq -r .fieldName <<<"$existing")', but the kit needs '$field'. Rename it, or set a different catalog.inputPrefix."
    REPLY_ID=$(jq -r .id <<<"$existing")
    ok "Input '$name' exists (ID $REPLY_ID)"
    record input tenant "$REPLY_ID" "$name" 0
  else
    REPLY_ID=$(api POST /api/library/option-types "$(jq -c '{optionType: .}' <<<"$spec")" | jq -r '.optionType.id // 0')
    record input tenant "$REPLY_ID" "$name" 1
    done_msg "Created input '$name' (ID $REPLY_ID)" "Would create input '$name' [$(jq -r .type <<<"$spec")]"
  fi
}

# ensure_catalog_item BODY_JSON -> REPLY_ID   (BODY is the catalogItemType object)
ensure_catalog_item() {
  local body=$1 name res existing
  name=$(jq -r .name <<<"$body")
  res=$(api GET "/api/catalog-item-types$(qs name "$name" max 1000)")
  existing=$(find_by name "$name" catalogItemTypes <<<"$res")
  if [[ -n $existing ]]; then
    REPLY_ID=$(jq -r .id <<<"$existing")
    ok "Catalog item '$name' exists (ID $REPLY_ID) - left unchanged"
    record catalogItem tenant "$REPLY_ID" "$name" 0
  else
    REPLY_ID=$(api POST /api/catalog-item-types "$(jq -c '{catalogItemType: .}' <<<"$body")" | jq -r '.catalogItemType.id // 0')
    record catalogItem tenant "$REPLY_ID" "$name" 1
    done_msg "Created catalog item '$name' (ID $REPLY_ID)" "Would create catalog item '$name'"
  fi
}

# check_tenant_sees KIND ID LABEL - the tenant must be able to see an object the catalog refers to
check_tenant_sees() {
  local kind=$1 id=$2 label=$3 res
  case $kind in
    image)   res=$(api GET "/api/virtual-images$(qs max 1000)"); jq -e --argjson i "$id" 'any(.virtualImages[]?; .id == $i)' <<<"$res" >/dev/null \
               || die "$label is not visible to the tenant. Make the image Public, or share it with the tenant, then re-run." ;;
    plan)    res=$(api GET "/api/service-plans$(qs max 1000)"); jq -e --argjson i "$id" 'any(.servicePlans[]?; .id == $i)' <<<"$res" >/dev/null \
               || die "$label is not visible to the tenant. Make the plan available to the tenant, then re-run." ;;
    network) res=$(api GET "/api/networks$(qs zoneId "$CLOUD_ID" max 1000)"); jq -e --argjson i "$id" 'any(.networks[]?; .id == $i)' <<<"$res" >/dev/null \
               || die "$label is not visible to the tenant. Add it to cloud.share.networks (or make it Public), then re-run." ;;
    pool)    res=$(api GET "/api/zones/$CLOUD_ID/resource-pools$(qs max 1000)"); jq -e --argjson i "$id" 'any(.resourcePools[]?; .id == $i)' <<<"$res" >/dev/null \
               || die "$label is not visible to the tenant. Add it to cloud.share.resourcePools (or make it Public), then re-run." ;;
    datastore) [[ $id =~ ^[0-9]+$ ]] || return 0
             res=$(api GET "/api/zones/$CLOUD_ID/data-stores$(qs max 1000)"); jq -e --argjson i "$id" 'any(.datastores[]?; .id == $i)' <<<"$res" >/dev/null \
               || die "$label is not visible to the tenant. Add it to cloud.share.datastores (or make it Public), then re-run." ;;
  esac
}

# scope_fields SCOPE_JSON -> JSON fields to merge into a policy (refType/refId and the reference object)
scope_fields() {
  local sc=$1 kind name id=""
  if [[ $sc == null || $sc == '"global"' ]]; then printf '{}'; return 0; fi
  kind=$(jq -r 'keys[0]' <<<"$sc"); name=$(jq -r '.[keys[0]]' <<<"$sc")
  case $kind in
    group) id=${GROUP_IDS[$name]:-} ;;
    role)  id=${ROLE_IDS[$name]:-}
           [[ -n $id ]] || id=$(tenant_roles_list | find_by name "$name" roles | jq -r '.id // empty') ;;
    user)  id=${USER_IDS[$name]:-} ;;
    cloud) id=$CLOUD_ID ;;
  esac
  [[ -n $id && $id != 0 ]] || { printf 'unresolved'; return 0; }
  case $kind in
    group) jq -cn --argjson i "$id" '{refType: "ComputeSite", refId: $i, site: {id: $i}}' ;;
    cloud) jq -cn --argjson i "$id" '{refType: "ComputeZone", refId: $i, zone: {id: $i}}' ;;
    user)  jq -cn --argjson i "$id" '{refType: "User", refId: $i, user: {id: $i}}' ;;
    role)  jq -cn --argjson i "$id" '{refType: "Role", refId: $i, role: {id: $i}}' ;;
  esac
}

# ensure_policy NAME CODE CONFIG_JSON SCOPE_JSON EACH_USER(true/false)
ensure_policy() {
  local name=$1 code=$2 config=$3 scope=$4 each=$5 res existing fields body pid
  res=$(api GET "/api/policies$(qs name "$name" max 1000)")
  existing=$(find_by name "$name" policies <<<"$res")
  if [[ -n $existing ]]; then
    pid=$(jq -r .id <<<"$existing")
    ok "Policy '$name' exists (ID $pid) - left unchanged"
    record policy tenant "$pid" "$name" 0
    return 0
  fi
  fields=$(scope_fields "$scope")
  if [[ $fields == unresolved ]]; then plan "Would create policy '$name' (its scope is created earlier in a real run)"; return 0; fi
  body=$(jq -cn --arg n "$name" --arg c "$code" --argjson cfg "$config" --argjson f "$fields" --argjson each "$each" '
    {policy: ({name: $n, description: "Created by morpheus-poc-kit", enabled: true, policyType: {code: $c}, config: $cfg}
              + $f + (if $f.refType == "Role" then {eachUser: $each} else {} end))}')
  pid=$(api POST /api/policies "$body" | jq -r '.policy.id // 0')
  record policy tenant "$pid" "$name" 1
  done_msg "Created policy '$name' (ID $pid)" "Would create policy '$name' [$code]"
}

# ===========================================================================
# 1. Pre-flight (read-only)
# ===========================================================================
step "Pre-flight checks"
WHOAMI=$(api GET /api/whoami)
[[ $(jq -r '.isMasterAccount // false' <<<"$WHOAMI") == true ]] || die "MORPHEUS_TOKEN must belong to a user in the MASTER tenant."
MASTER_ID=$(jq -c .user <<<"$WHOAMI" | owner_id)
[[ -n $MASTER_ID ]] || die "Could not determine the master tenant ID from /api/whoami."
ok "Connected as '$(jq -r .user.username <<<"$WHOAMI")' (master tenant ID $MASTER_ID)"

PTYPES=$(api GET /api/policy-types | jq -c '[.policyTypes[]?.code]')
NEEDED=$(jq -c '[ (if .policies.naming then "naming" else empty end),
                  (if .policies.approval then "provisionApproval" else empty end),
                  (if .policies.tagEnforcement and ((.tags // []) | length) > 0 then "tags" else empty end),
                  (.policies.quotas[]? | (if .maxVms then "maxVms" else empty end), (if .maxCores then "maxCores" else empty end),
                                         (if .maxMemoryGB then "maxMemory" else empty end), (if .maxStorageGB then "maxStorage" else empty end))
                ] | unique' <<<"$CFG")
MISSING=$(jq -nr --argjson have "$PTYPES" --argjson need "$NEEDED" '$need - $have | join(", ")')
[[ -z $MISSING ]] || die "This appliance does not offer these policy types: $MISSING. On HPE VM Essentials some governance features need a Morpheus Enterprise licence; remove them from 'policies' or check the licence."
ok "Policy types needed by the config are available: $(jq -r 'join(", ") | if . == "" then "none" else . end' <<<"$NEEDED")"

TENANT=$(api GET "/api/accounts$(qs name "$TENANT_NAME" max 1000)" | find_by name "$TENANT_NAME" accounts)
TENANT_ID=0
if [[ -n $TENANT ]]; then
  TENANT_ID=$(jq -r .id <<<"$TENANT")
  ok "Tenant '$TENANT_NAME' already exists (ID $TENANT_ID) - this run will complete it"
  [[ -z $SUBDOMAIN ]] && SUBDOMAIN=$(jq -r '.subdomain // empty' <<<"$TENANT")
elif [[ -n $SUBDOMAIN ]]; then
  CLASH=$(api GET "/api/accounts$(qs max 1000)" | jq -r --arg s "$SUBDOMAIN" '[.accounts[]? | select(((.subdomain // "") | ascii_downcase) == ($s | ascii_downcase))][0].name // empty')
  [[ -z $CLASH ]] || die "Subdomain '$SUBDOMAIN' is already used by tenant '$CLASH'."
fi

CLOUD_ID=0 CLOUD_NAME="" CLOUD_VIS="" CLOUD_OWNER=""
SHARE_POOL_IDS=() SHARE_DS_IDS=() SHARE_NET_IDS=()
if [[ $CLOUD_MODE != none ]]; then
  CLOUD=$(api GET "/api/zones$(qs max 1000)" | pick "$CLOUD_REF" Cloud zones)
  CLOUD_ID=$(jq -r .id <<<"$CLOUD")
  CLOUD_NAME=$(jq -r .name <<<"$CLOUD")
  CLOUD_VIS=$(jq -r '.visibility // "private"' <<<"$CLOUD")
  CLOUD_OWNER=$(owner_id <<<"$CLOUD")
  CLOUD_OWNER=${CLOUD_OWNER:-$MASTER_ID}
  ok "Cloud '$CLOUD_NAME' (ID $CLOUD_ID) - visibility $CLOUD_VIS, owner tenant ID $CLOUD_OWNER"
  if [[ $CLOUD_OWNER != "$MASTER_ID" && $CLOUD_OWNER != "$TENANT_ID" ]]; then
    die "Cloud '$CLOUD_NAME' is assigned to another tenant (ID $CLOUD_OWNER). Reassign it in the UI first."
  fi
  if [[ $CLOUD_MODE == shared && $CLOUD_OWNER != "$MASTER_ID" ]]; then
    die "Cloud '$CLOUD_NAME' is already dedicated to this tenant. Use cloud.mode dedicated, or reassign it to the master tenant first."
  fi
  POOLS_LIST=$(api GET "/api/zones/$CLOUD_ID/resource-pools$(qs max 1000)")
  DS_LIST=$(api GET "/api/zones/$CLOUD_ID/data-stores$(qs max 1000)")
  NETS_LIST=$(api GET "/api/networks$(qs zoneId "$CLOUD_ID" max 1000)")
  mapfile -t REFS < <(jq -r '.cloud.share.resourcePools[]? | tostring' <<<"$CFG")
  for r in ${REFS[@]+"${REFS[@]}"}; do SHARE_POOL_IDS+=("$(pick "$r" "Resource pool" resourcePools <<<"$POOLS_LIST" | jq -r .id)"); done
  mapfile -t REFS < <(jq -r '.cloud.share.datastores[]? | tostring' <<<"$CFG")
  for r in ${REFS[@]+"${REFS[@]}"}; do SHARE_DS_IDS+=("$(pick "$r" Datastore datastores <<<"$DS_LIST" | jq -r .id)"); done
  mapfile -t REFS < <(jq -r '.cloud.share.networks[]? | tostring' <<<"$CFG")
  for r in ${REFS[@]+"${REFS[@]}"}; do SHARE_NET_IDS+=("$(pick "$r" Network networks <<<"$NETS_LIST" | jq -r .id)"); done
  if (( ${#SHARE_POOL_IDS[@]} + ${#SHARE_DS_IDS[@]} + ${#SHARE_NET_IDS[@]} > 0 )); then
    ok "Resources to share: ${#SHARE_POOL_IDS[@]} resource pool(s), ${#SHARE_DS_IDS[@]} datastore(s), ${#SHARE_NET_IDS[@]} network(s)"
  fi
fi

# Everything the catalog refers to, resolved by name as the master tenant (visibility to the tenant is checked later).
LAYOUTS=$(api GET "/api/library/layouts$(qs max 1000)")
PLANS=$(api GET "/api/service-plans$(qs max 1000)")
res_layout() { pick "$1" Layout instanceTypeLayouts <<<"$LAYOUTS" | jq -r .id; }
res_plan()   { pick "$1" "Service plan" servicePlans <<<"$PLANS" | jq -c '{id, name}'; }
res_pool()   { pick "$1" "Resource pool" resourcePools <<<"$POOLS_LIST" | jq -r .id; }
res_net()    { pick "$1" Network networks <<<"$NETS_LIST" | jq -r .id; }
res_ds()     { if [[ $1 =~ ^(auto|autoCluster)$ ]]; then printf '%s' "$1"; else pick "$1" Datastore datastores <<<"$DS_LIST" | jq -r .id; fi; }
res_image()  {
  local ref=$1 list img
  if [[ $ref =~ ^[0-9]+$ ]]; then list=$(api GET "/api/virtual-images$(qs max 1000)")
  else list=$(api GET "/api/virtual-images$(qs name "$ref" max 1000)"); fi
  img=$(pick "$ref" "Virtual image" virtualImages <<<"$list")
  if [[ $(jq -r '.visibility // "private"' <<<"$img") != public ]]; then
    warn "Image '$(jq -r .name <<<"$img")' is Private - the tenant can only use it if it is shared with the tenant." >&2
  fi
  jq -r .id <<<"$img"
}

if [[ $(cfg '.catalog.vm != null') == true ]]; then
  VM_LAYOUT=$(res_layout "$(cfg '.catalog.vm.layout|tostring')")
  VM_IMAGE=$(res_image "$(cfg '.catalog.vm.image|tostring')")
  VM_NET=$(res_net "$(cfg '.catalog.vm.network|tostring')")
  VM_POOL=$(res_pool "$(cfg '.catalog.vm.resourcePool|tostring')")
  VM_DS=$(res_ds "$(cfg '.catalog.vm.datastore|tostring')")
  VM_PLANS="[]"
  mapfile -t REFS < <(jq -r '.catalog.vm.plans[] | tostring' <<<"$CFG")
  for r in "${REFS[@]}"; do VM_PLANS=$(jq -c --argjson p "$(res_plan "$r")" '. + [$p] | unique_by(.id)' <<<"$VM_PLANS"); done
  ok "Catalog item '$(cfg .catalog.vm.name)': layout, image, network, pool, datastore and $(jq length <<<"$VM_PLANS") plan(s) found"
fi
if [[ $(cfg '.catalog.threeTier != null') == true ]]; then
  BP_NET=$(res_net "$(cfg '.catalog.threeTier.network|tostring')")
  BP_POOL=$(res_pool "$(cfg '.catalog.threeTier.resourcePool|tostring')")
  BP_DS=$(res_ds "$(cfg '.catalog.threeTier.datastore|tostring')")
  BP_TIERS="[]"
  if [[ $(cfg '.catalog.threeTier.templateFile // empty') == "" ]]; then
    mapfile -t TIERS_CFG < <(jq -c '.catalog.threeTier.tiers[]' <<<"$CFG")
    for t in "${TIERS_CFG[@]}"; do
      tl=$(res_layout "$(jq -r '.layout|tostring' <<<"$t")")
      ti=$(res_image "$(jq -r '.image|tostring' <<<"$t")")
      tp=$(res_plan "$(jq -r '.plan|tostring' <<<"$t")")
      BP_TIERS=$(jq -c --argjson t "$t" --argjson l "$tl" --argjson i "$ti" --argjson p "$tp" \
        '. + [{name: $t.name, linkTo: ($t.linkTo // [] | if type == "string" then [.] else . end), layoutId: $l, imageId: $i, planId: $p.id, diskGB: ($t.diskGB // 40)}]' <<<"$BP_TIERS")
    done
    ok "3-tier app '$(cfg .catalog.threeTier.name)': $(jq -r '[.[].name] | join(", ")' <<<"$BP_TIERS") tiers resolved"
  else
    BP_TEMPLATE_FILE=$(cfg '.catalog.threeTier.templateFile')
    [[ $BP_TEMPLATE_FILE == /* ]] || BP_TEMPLATE_FILE="$(dirname "$CONFIG")/$BP_TEMPLATE_FILE"
    [[ -f $BP_TEMPLATE_FILE ]] || die "catalog.threeTier.templateFile '$BP_TEMPLATE_FILE' was not found."
    jq -e '.tiers | type == "object"' "$BP_TEMPLATE_FILE" >/dev/null || die "$BP_TEMPLATE_FILE has no 'tiers' object (export one with morpheus-inventory.sh --export-blueprint)."
    ok "3-tier app '$(cfg .catalog.threeTier.name)': using template $BP_TEMPLATE_FILE"
  fi
fi

# ===========================================================================
# 2. Shared mode: the cloud must be Public before a tenant role can be given access to it
# ===========================================================================
if [[ $CLOUD_MODE == shared ]]; then
  step "Cloud '$CLOUD_NAME' available to tenants (Public)"
  if [[ $CLOUD_VIS == public ]]; then
    ok "Cloud is already Public"
  else
    confirm_change "Cloud '$CLOUD_NAME' is $CLOUD_VIS. Setting it to Public lets it be granted to ANY tenant's role, and tenants created later get it added automatically. Existing tenants only see it if their tenant role grants access."
    api PUT "/api/zones/$CLOUD_ID" '{"zone":{"visibility":"public"}}' >/dev/null
    manifest_add cloudVisibility master changed "$CLOUD_ID" "$CLOUD_NAME" "$(jq -cn --arg f "$CLOUD_VIS" '{from: $f, to: "public"}')"
    done_msg "Cloud visibility set to Public" "Would set the cloud visibility to Public"
  fi
fi

# ===========================================================================
# 3. Tenant role (roleType account) - the permission ceiling for the whole tenant
# ===========================================================================
step "Tenant role '$TROLE_NAME'"
TROLE=$(api GET "/api/roles$(qs roleType account name "$TROLE_NAME" max 1000)" | find_by authority "$TROLE_NAME" roles)
if [[ -n $TROLE ]]; then
  TROLE_ID=$(jq -r .id <<<"$TROLE")
  ok "Found existing tenant role (ID $TROLE_ID)"
  record tenantRole master "$TROLE_ID" "$TROLE_NAME" 0
else
  BASE=$(copy_from_role "$TROLE_TEMPLATE" account "$MASTER_ID")
  [[ -n $BASE ]] || warn "No copyFrom template: the tenant role starts with NO feature permissions."
  BODY=$(jq -cn --arg a "$TROLE_NAME" --arg d "Permission ceiling for tenant $TENANT_NAME" --arg b "$BASE" \
    '{role: ({authority: $a, description: $d, roleType: "account"} + (if $b == "" then {} else {baseRoleId: ($b | tonumber)} end))}')
  TROLE_ID=$(api POST /api/roles "$BODY" | jq -r '.role.id // 0')
  record tenantRole master "$TROLE_ID" "$TROLE_NAME" 1
  done_msg "Created tenant role (ID $TROLE_ID), copied from '$TROLE_TEMPLATE'" "Would create the tenant role, copied from '$TROLE_TEMPLATE'"
fi
if [[ $CLOUD_MODE == shared ]]; then
  if [[ $TROLE_ID != 0 ]]; then
    api PUT "/api/roles/$TROLE_ID/update-cloud" "$(jq -cn --argjson c "$CLOUD_ID" '{cloudId: $c, access: "full"}')" >/dev/null
  fi
  done_msg "Tenant role has Full access to cloud '$CLOUD_NAME'" "Would give the tenant role Full access to cloud '$CLOUD_NAME'"
fi

# ===========================================================================
# 4. Tenant
# ===========================================================================
step "Tenant '$TENANT_NAME'"
if [[ -n $TENANT ]]; then
  ok "Found existing tenant (ID $TENANT_ID)"
  EXISTING_BASE=$(jq -r '.role.id // empty' <<<"$TENANT")
  if [[ -n $EXISTING_BASE && $EXISTING_BASE != "$TROLE_ID" ]]; then
    warn "The tenant's base role is '$(jq -r '.role.authority // .role.name' <<<"$TENANT")', not '$TROLE_NAME'. Left unchanged."
  fi
  record tenant master "$TENANT_ID" "$TENANT_NAME" 0
else
  BODY=$(jq -cn --arg n "$TENANT_NAME" --arg d "$TENANT_DESC" --argjson r "$TROLE_ID" --arg c "$CURRENCY" --arg s "$SUBDOMAIN" \
    '{account: ({name: $n, description: $d, role: {id: $r}, currency: $c} + (if $s == "" then {} else {subdomain: $s} end))}')
  RES=$(api POST /api/accounts "$BODY")
  TENANT_ID=$(jq -r '.account.id // 0' <<<"$RES")
  record tenant master "$TENANT_ID" "$TENANT_NAME" 1
  done_msg "Created tenant (ID $TENANT_ID)" "Would create the tenant"
fi
if [[ $TENANT_ID != 0 ]]; then
  manifest_set tenantId "$TENANT_ID"
  manifest_set masterTenantId "$MASTER_ID"
  manifest_set subdomain "$(jq -cn --arg s "$SUBDOMAIN" 'if $s == "" then null else $s end')"
fi

# ===========================================================================
# 5. Cloud: assign it (dedicated) or share its resources (shared)
# ===========================================================================
if [[ $CLOUD_MODE == dedicated ]]; then
  step "Assigning cloud '$CLOUD_NAME' to the tenant"
  if [[ $TENANT_ID != 0 && $CLOUD_OWNER == "$TENANT_ID" ]]; then
    ok "Cloud is already assigned to this tenant"
  else
    confirm_change "Cloud '$CLOUD_NAME' and ALL of its resources will be available ONLY to tenant '$TENANT_NAME'. Other sub-tenants lose access to it; the master tenant keeps control."
    if [[ $TENANT_ID != 0 ]]; then
      api PUT "/api/zones/$CLOUD_ID" "$(jq -cn --argjson t "$TENANT_ID" '{zone: {accountId: $t, visibility: "private"}}')" >/dev/null
      manifest_add cloudOwner master changed "$CLOUD_ID" "$CLOUD_NAME" \
        "$(jq -cn --argjson f "$CLOUD_OWNER" --argjson t "$TENANT_ID" --arg v "$CLOUD_VIS" '{from: $f, to: $t, fromVisibility: $v}')"
    fi
    done_msg "Cloud assigned to the tenant (visibility Private)" "Would assign the cloud to the tenant (visibility Private)"
  fi
elif [[ $CLOUD_MODE == shared ]] && (( ${#SHARE_POOL_IDS[@]} + ${#SHARE_DS_IDS[@]} + ${#SHARE_NET_IDS[@]} > 0 )); then
  step "Sharing cloud resources with the tenant"

  # share_resource KIND ID - adds the tenant to the resource's tenant list, keeping every tenant already on it.
  share_resource() {
    local kind=$1 id=$2 st label others
    st=$(resource_state "$kind" "$CLOUD_ID" "$id")
    [[ -n $st ]] || die "$kind $id was not found in cloud '$CLOUD_NAME'."
    label="$kind '$(jq -r .name <<<"$st")' (ID $id)"
    if [[ $(jq -r .visibility <<<"$st") == public ]]; then ok "$label is Public - every tenant can already use it"; return 0; fi
    if [[ $TENANT_ID == 0 ]]; then plan "Would share $label with the new tenant"; return 0; fi
    if jq -e --argjson t "$TENANT_ID" '.tenants | index($t) != null' <<<"$st" >/dev/null; then
      ok "$label is already shared with the tenant"; return 0
    fi
    others=$(jq -r '.tenants | length' <<<"$st")
    resource_set_tenants "$st" "$(jq -c --argjson t "$TENANT_ID" '.tenants + [$t]' <<<"$st")"
    manifest_add share master changed "$id" "$(jq -r .name <<<"$st")" "$(jq -cn --arg r "$kind" --argjson c "$CLOUD_ID" '{resource: $r, cloudId: $c}')"
    done_msg "$label shared with the tenant ($others other tenant(s) kept)" "Would share $label with the tenant ($others other tenant(s) kept)"
  }
  for id in ${SHARE_POOL_IDS[@]+"${SHARE_POOL_IDS[@]}"}; do share_resource resourcePool "$id"; done
  for id in ${SHARE_DS_IDS[@]+"${SHARE_DS_IDS[@]}"};     do share_resource datastore "$id"; done
  for id in ${SHARE_NET_IDS[@]+"${SHARE_NET_IDS[@]}"};   do share_resource network "$id"; done
fi

# ===========================================================================
# 6. Tenant admin: role owned by the tenant + local admin user
# ===========================================================================
step "Tenant admin '$ADMIN_USER'"
ADMIN_ROLE_ID=0 ADMIN_ID=0 ADMIN_PW="" ADMIN_PW_SHOWN=""
if [[ $TENANT_ID == 0 ]]; then
  plan "Would reuse or create role '$ADMIN_ROLE' in the new tenant and create admin user '$ADMIN_USER'"
else
  RES=$(api GET "/api/roles$(qs tenant "$TENANT_ID" roleType user max 1000)")
  AROLE=$(jq -c --argjson t "$TENANT_ID" --arg n "$ADMIN_ROLE" \
    '[.roles[]? | select((.owner.id // $t) == $t) | select(((.authority // .name) | ascii_downcase) == ($n | ascii_downcase))][0] // empty' <<<"$RES")
  if [[ -n $AROLE ]]; then
    ADMIN_ROLE_ID=$(jq -r .id <<<"$AROLE")
    ok "Role '$ADMIN_ROLE' exists in the tenant (ID $ADMIN_ROLE_ID)"
    record adminRole master "$ADMIN_ROLE_ID" "$ADMIN_ROLE" 0
  else
    BASE=$(copy_from_role "$ADMIN_ROLE_TEMPLATE" user "$TENANT_ID")
    BODY=$(jq -cn --arg a "$ADMIN_ROLE" --arg d "Administrator for tenant $TENANT_NAME" --argjson o "$TENANT_ID" --arg b "$BASE" \
      '{role: ({authority: $a, description: $d, roleType: "user", owner: $o, globalSiteAccess: "full"}
               + (if $b == "" then {} else {baseRoleId: ($b | tonumber)} end))}')
    ADMIN_ROLE_ID=$(api POST /api/roles "$BODY" | jq -r '.role.id // 0')
    record adminRole master "$ADMIN_ROLE_ID" "$ADMIN_ROLE" 1
    done_msg "Created role '$ADMIN_ROLE' in the tenant (ID $ADMIN_ROLE_ID)" "Would create role '$ADMIN_ROLE' in the tenant"
  fi
  RES=$(api GET "/api/accounts/$TENANT_ID/users$(qs username "$ADMIN_USER" max 1000)")
  ADMIN=$(find_by username "$ADMIN_USER" users <<<"$RES")
  if [[ -n $ADMIN ]]; then
    ADMIN_ID=$(jq -r .id <<<"$ADMIN")
    ok "Admin user exists (ID $ADMIN_ID)"
    record adminUser master "$ADMIN_ID" "$ADMIN_USER" 0
    if [[ $RESET_ADMIN_PW == 1 ]]; then
      if [[ $DRY_RUN == 1 ]]; then
        plan "Would set a new password for '$ADMIN_USER'"
      else
        ADMIN_PW=$(gen_password)
        api PUT "/api/accounts/$TENANT_ID/users/$ADMIN_ID" \
          "$(jq -cn --arg p "$ADMIN_PW" '{user: {password: $p, passwordConfirmation: $p}}')" >/dev/null
        ADMIN_PW_SHOWN=$ADMIN_PW
        ok "New password set for '$ADMIN_USER' (shown in the summary)"
      fi
    elif [[ -n ${TENANT_ADMIN_PASSWORD:-} ]]; then
      ADMIN_PW=$TENANT_ADMIN_PASSWORD
    elif [[ -t 0 && $DRY_RUN == 0 ]]; then
      read -rsp "    Password for '$ADMIN_USER' (to sign in to the tenant): " ADMIN_PW; echo
    elif [[ $DRY_RUN == 1 ]]; then
      warn "Set TENANT_ADMIN_PASSWORD to also check the objects inside the tenant in a dry run."
    else
      die "The tenant admin exists but its password is unknown. Set TENANT_ADMIN_PASSWORD, or re-run with --reset-admin-password."
    fi
  else
    if [[ -n ${TENANT_ADMIN_PASSWORD:-} ]]; then ADMIN_PW=$TENANT_ADMIN_PASSWORD
    else ADMIN_PW=$(gen_password); ADMIN_PW_SHOWN=$ADMIN_PW; fi
    if [[ $ADMIN_ROLE_ID == 0 ]]; then
      plan "Would create admin user '$ADMIN_USER' with role '$ADMIN_ROLE'"
    else
      AVAIL=$(api GET "/api/accounts/$TENANT_ID/users/available-roles")
      jq -e --argjson r "$ADMIN_ROLE_ID" 'any(.roles[]?; .id == $r)' <<<"$AVAIL" >/dev/null \
        || warn "Role ID $ADMIN_ROLE_ID is not listed as assignable in this tenant; creating the user may fail."
      BODY=$(jq -cn --arg u "$ADMIN_USER" --arg e "$ADMIN_EMAIL" --arg f "$ADMIN_FIRST" --arg l "$ADMIN_LAST" \
                    --arg p "$ADMIN_PW" --argjson r "$ADMIN_ROLE_ID" \
        '{user: {username: $u, email: $e, firstName: $f, lastName: $l, password: $p, passwordConfirmation: $p, roles: [{id: $r}]}}')
      ADMIN_ID=$(api POST "/api/accounts/$TENANT_ID/users" "$BODY" | jq -r '.user.id // 0')
      record adminUser master "$ADMIN_ID" "$ADMIN_USER" 1
      done_msg "Created admin user (ID $ADMIN_ID)" "Would create admin user '$ADMIN_USER'"
    fi
  fi
fi
ROLE_IDS[$ADMIN_ROLE]=$ADMIN_ROLE_ID
USER_IDS[$ADMIN_USER]=$ADMIN_ID

# ===========================================================================
# Sign in to the tenant. Everything after this point is created inside it.
# ===========================================================================
TENANT_READY=0
LOGIN_PREFIX=${SUBDOMAIN:-$TENANT_ID}
if [[ $TENANT_ID != 0 && $ADMIN_ID != 0 && -n $ADMIN_PW ]]; then
  step "Signing in to the tenant as '$LOGIN_PREFIX\\$ADMIN_USER'"
  tenant_login "$LOGIN_PREFIX" "$ADMIN_USER" "$ADMIN_PW"
  TW=$(api GET /api/whoami)
  [[ $(jq -c .user <<<"$TW" | owner_id) == "$TENANT_ID" ]] || die "Signed in, but the session belongs to tenant $(jq -c .user <<<"$TW" | owner_id), not $TENANT_ID."
  ok "Signed in (tenant ID $TENANT_ID)"
  TENANT_READY=1
fi

# tenant_plan TEXT -> true when the tenant session isn't available (dry run of a new tenant); prints TEXT as the plan
tenant_plan() { if [[ $TENANT_READY == 1 ]]; then return 1; fi; plan "$1"; return 0; }

# ===========================================================================
# 7. Groups
# ===========================================================================
step "Groups"
for g in "${GROUPS_CFG[@]}"; do
  if tenant_plan "Would create group '$g'$( [[ $CLOUD_MODE != none ]] && printf ' containing cloud %s' "$CLOUD_NAME")"; then continue; fi
  G=$(api GET "/api/groups$(qs name "$g" max 1000)" | find_by name "$g" groups)
  if [[ -n $G ]]; then
    GID=$(jq -r .id <<<"$G"); ok "Group '$g' exists (ID $GID)"; record group tenant "$GID" "$g" 0
  else
    G=$(api POST /api/groups "$(jq -cn --arg n "$g" '{group: {name: $n}}')" | jq -c '.group // {id: 0, zones: []}')
    GID=$(jq -r .id <<<"$G"); record group tenant "$GID" "$g" 1
    done_msg "Created group '$g' (ID $GID)" "Would create group '$g'"
  fi
  GROUP_IDS[$g]=$GID
  if [[ $CLOUD_MODE != none ]] && ! jq -e --argjson c "$CLOUD_ID" 'any(.zones[]?; .id == $c)' <<<"$G" >/dev/null; then
    if [[ $GID != 0 ]]; then
      api PUT "/api/groups/$GID/update-zones" \
        "$(jq -c --argjson c "$CLOUD_ID" '{group: {zones: ([.zones[]?.id] + [$c] | unique | map({id: .}))}}' <<<"$G")" >/dev/null
    fi
    done_msg "Cloud '$CLOUD_NAME' added to group '$g'" "Would add cloud '$CLOUD_NAME' to group '$g'"
  fi
done

# ===========================================================================
# 8. Roles (personas) and what they can reach
# ===========================================================================
if (( ${#ROLES_CFG[@]} > 0 )); then step "Roles"; fi
for role in ${ROLES_CFG[@]+"${ROLES_CFG[@]}"}; do
  RNAME=$(jq -r .name <<<"$role")
  RCOPY=$(jq -r '.copyFrom // empty' <<<"$role")
  RPERSONA=$(jq -r '.defaultPersona // empty' <<<"$role")
  if tenant_plan "Would create role '$RNAME'${RCOPY:+ (copied from '$RCOPY')} and map its groups, features and persona"; then continue; fi
  TROLES=$(tenant_roles_list)
  R=$(find_by name "$RNAME" roles <<<"$TROLES")
  if [[ -n $R ]]; then
    RID=$(jq -r .id <<<"$R"); ok "Role '$RNAME' exists (ID $RID)"; record role tenant "$RID" "$RNAME" 0
    if [[ -n $RPERSONA && $(jq -r '.defaultPersona.code // .defaultPersona // empty' <<<"$R") != "$RPERSONA" ]]; then
      api PUT "/api/roles/$RID" "$(jq -cn --arg p "$RPERSONA" '{role: {defaultPersona: $p}}')" >/dev/null
      done_msg "Default persona of '$RNAME' set to $RPERSONA" "Would set the default persona of '$RNAME' to $RPERSONA"
    fi
  else
    BASE=""
    if [[ -n $RCOPY ]]; then BASE=$(pick "$RCOPY" "Role to copy from (copyFrom)" roles <<<"$TROLES" | jq -r .id); fi
    BODY=$(jq -cn --arg a "$RNAME" --arg b "$BASE" --arg p "$RPERSONA" --arg t "$TENANT_NAME" \
      '{role: ({authority: $a, description: "PoC role for \($t)", roleType: "user"}
               + (if $b == "" then {} else {baseRoleId: ($b | tonumber)} end)
               + (if $p == "" then {} else {defaultPersona: $p} end))}')
    RID=$(api POST /api/roles "$BODY" | jq -r '.role.id // 0')
    record role tenant "$RID" "$RNAME" 1
    done_msg "Created role '$RNAME' (ID $RID)${RCOPY:+, copied from '$RCOPY'}" "Would create role '$RNAME'"
  fi
  ROLE_IDS[$RNAME]=$RID
  if [[ $RID == 0 ]]; then plan "Would map groups, features and persona of '$RNAME'"; continue; fi

  # Group access: "all", or no default access plus Full on each listed group
  if [[ $(jq -r '.groups // "all" | if type == "string" then . else "list" end' <<<"$role") == all ]]; then
    api PUT "/api/roles/$RID/update-group" '{"allGroups":true,"access":"full"}' >/dev/null
    GDESC="all groups"
  else
    api PUT "/api/roles/$RID/update-group" '{"allGroups":true,"access":"none"}' >/dev/null
    mapfile -t RG < <(jq -r '.groups[]' <<<"$role")
    for g in "${RG[@]}"; do
      api PUT "/api/roles/$RID/update-group" "$(jq -cn --argjson i "${GROUP_IDS[$g]}" '{groupId: $i, access: "full"}')" >/dev/null
    done
    GDESC="groups $(join_by ", " "${RG[@]}")"
  fi
  NF=0
  while IFS=$'\t' read -r code acc; do
    [[ -n $code ]] || continue
    api PUT "/api/roles/$RID/update-permission" "$(jq -cn --arg c "$code" --arg a "$acc" '{permissionCode: $c, access: $a}')" >/dev/null
    NF=$((NF + 1))
  done < <(jq -r '(.features // {}) | to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$role")
  if [[ -n $RPERSONA ]]; then
    api PUT "/api/roles/$RID/update-persona" "$(jq -cn --arg p "$RPERSONA" '{personaCode: $p, access: "full"}')" >/dev/null
  fi
  done_msg "'$RNAME': $GDESC, $NF feature permission(s)${RPERSONA:+, persona $RPERSONA}" "Would map '$RNAME': $GDESC, $NF feature permission(s)"
done

# ===========================================================================
# 9. Users
# ===========================================================================
if (( ${#USERS_CFG[@]} > 0 )); then step "Users"; fi
for user in ${USERS_CFG[@]+"${USERS_CFG[@]}"}; do
  UNAME=$(jq -r .username <<<"$user"); UROLE=$(jq -r .role <<<"$user")
  if tenant_plan "Would create user '$UNAME' with role '$UROLE'"; then continue; fi
  RID=${ROLE_IDS[$UROLE]:-}
  if [[ -z $RID ]]; then RID=$(tenant_roles_list | pick "$UROLE" "Role of user $UNAME" roles | jq -r .id); fi
  U=$(api GET "/api/users$(qs username "$UNAME" max 1000)" | find_by username "$UNAME" users)
  if [[ -n $U ]]; then
    UID_=$(jq -r .id <<<"$U"); ok "User '$UNAME' exists (ID $UID_) - password and roles left unchanged"
    record user tenant "$UID_" "$UNAME" 0
  else
    PW=$(gen_password)
    BODY=$(jq -cn --argjson u "$user" --arg p "$PW" --argjson r "${RID:-0}" '
      {user: {username: $u.username, email: $u.email, firstName: ($u.firstName // $u.username), lastName: ($u.lastName // "PoC"),
              password: $p, passwordConfirmation: $p, roles: [{id: $r}], passwordExpired: ($u.mustChangePassword // false)}}')
    UID_=$(api POST /api/users "$BODY" | jq -r '.user.id // 0')
    record user tenant "$UID_" "$UNAME" 1
    [[ $DRY_RUN == 1 ]] || NEW_PASSWORDS+=("$UNAME"$'\t'"$PW")
    done_msg "Created user '$UNAME' (ID $UID_) with role '$UROLE'" "Would create user '$UNAME' with role '$UROLE'"
  fi
  USER_IDS[$UNAME]=$UID_
done

# ===========================================================================
# 10. Tag dropdowns: one option list + one select input per tag
# ===========================================================================
if (( ${#TAGS_CFG[@]} > 0 )); then step "Tag dropdowns"; fi
for tag in ${TAGS_CFG[@]+"${TAGS_CFG[@]}"}; do
  TNAME=$(jq -r .name <<<"$tag"); TLABEL=$(jq -r '.label // .name' <<<"$tag")
  TAG_FIELD[$TNAME]="tag$(field_name "$TNAME")"
  if tenant_plan "Would create option list '$PREFIX - $TNAME values' and select input '$PREFIX - $TLABEL'"; then continue; fi
  ensure_option_list "$PREFIX - $TNAME values" "$(jq -c '[.values[] | tostring | {name: ., value: .}] | tojson' <<<"$tag" | jq -r .)"
  TAG_LIST_ID[$TNAME]=$REPLY_ID
  SPEC=$(jq -cn --arg n "$PREFIX - $TLABEL" --arg f "${TAG_FIELD[$TNAME]}" --arg l "$TLABEL" --argjson list "$REPLY_ID" \
    '{name: $n, fieldName: $f, type: "select", fieldLabel: $l, required: true, exportMeta: false, optionList: {id: $list}}')
  ensure_input "$SPEC"
  TAG_INPUT_ID[$TNAME]=$REPLY_ID
done
TAG_INPUT_IDS_JSON="[]" TAGS_JSON="[]"
for tag in ${TAGS_CFG[@]+"${TAGS_CFG[@]}"}; do
  TNAME=$(jq -r .name <<<"$tag")
  TAG_INPUT_IDS_JSON=$(jq -c --argjson i "${TAG_INPUT_ID[$TNAME]:-0}" '. + [$i]' <<<"$TAG_INPUT_IDS_JSON")
  TAGS_JSON=$(jq -c --arg n "$TNAME" --arg f "${TAG_FIELD[$TNAME]}" '. + [{name: $n, value: "<%= customOptions.\($f) %>"}]' <<<"$TAGS_JSON")
done

# ===========================================================================
# 11. VM catalog item
# ===========================================================================
if [[ $(cfg '.catalog.vm != null') == true ]]; then
  VM=$(cfg '.catalog.vm | tojson')
  VM_NAME=$(jq -r .name <<<"$VM")
  step "Catalog item '$VM_NAME'"
  if ! tenant_plan "Would create plan list, inputs and catalog item '$VM_NAME' in the tenant"; then
    VM_GROUP_ID=${GROUP_IDS[$(jq -r .group <<<"$VM")]}
    check_tenant_sees image "$VM_IMAGE" "Image '$(jq -r .image <<<"$VM")'"
    check_tenant_sees network "$VM_NET" "Network '$(jq -r .network <<<"$VM")'"
    check_tenant_sees pool "$VM_POOL" "Resource pool '$(jq -r .resourcePool <<<"$VM")'"
    check_tenant_sees datastore "$VM_DS" "Datastore '$(jq -r .datastore <<<"$VM")'"
    while IFS=$'\t' read -r pid pname; do check_tenant_sees plan "$pid" "Service plan '$pname'"; done < <(jq -r '.[] | [.id, .name] | @tsv' <<<"$VM_PLANS")
    ok "The tenant can see the image, network, resource pool, datastore and plans"

    ensure_option_list "$PREFIX - Plan Sizes" "$(jq -c '[.[] | {name, value: .id}] | tojson' <<<"$VM_PLANS" | jq -r .)"
    PLAN_LIST_ID=$REPLY_ID
    INPUT_IDS="[]"
    if [[ $NAMING_FIXED == 0 ]]; then
      ensure_input "$(jq -cn --arg p "$PREFIX" '{name: "\($p) - VM Name", fieldName: "customVmName", type: "text", fieldLabel: "Server Name",
        required: true, exportMeta: false, verifyPattern: "^[a-zA-Z][a-zA-Z0-9-]{0,62}$", placeHolder: "e.g. app-web-01"}')"
      INPUT_IDS=$(jq -c --argjson i "$REPLY_ID" '. + [$i]' <<<"$INPUT_IDS")
    fi
    ensure_input "$(jq -cn --arg p "$PREFIX" '{name: "\($p) - Description", fieldName: "customDesc", type: "textarea", fieldLabel: "Purpose / Description", required: false, exportMeta: false}')"
    INPUT_IDS=$(jq -c --argjson i "$REPLY_ID" '. + [$i]' <<<"$INPUT_IDS")
    ensure_input "$(jq -cn --arg p "$PREFIX" --argjson l "$PLAN_LIST_ID" '{name: "\($p) - Plan", fieldName: "customPlan", type: "select", fieldLabel: "Server Size", required: true, exportMeta: false, optionList: {id: $l}}')"
    INPUT_IDS=$(jq -c --argjson i "$REPLY_ID" '. + [$i]' <<<"$INPUT_IDS")
    ensure_input "$(jq -cn --arg p "$PREFIX" --arg d "$(jq -r '.defaultDiskGB // 40' <<<"$VM")" '{name: "\($p) - Disk", fieldName: "customDiskSize", type: "number", fieldLabel: "Root Disk Size (GB)", required: true, exportMeta: false, defaultValue: $d}')"
    INPUT_IDS=$(jq -c --argjson i "$REPLY_ID" '. + [$i]' <<<"$INPUT_IDS")
    INPUT_IDS=$(jq -c --argjson t "$TAG_INPUT_IDS_JSON" '. + $t' <<<"$INPUT_IDS")

    # Provisioning config: the structure of the lab script proven on a VME appliance (examples/create-catalog-tile.ps1).
    # <%= customOptions.<fieldName> %> is replaced with what the user picked on the order form.
    VM_NAME_VALUE='<%= customOptions.customVmName %>'
    if [[ $NAMING_FIXED == 1 ]]; then VM_NAME_VALUE=$(cfg '.policies.naming.pattern'); fi
    ITEM=$(jq -cn --argjson vm "$VM" --arg p "$PREFIX" --argjson inputs "$INPUT_IDS" --argjson tags "$TAGS_JSON" \
      --argjson group "$VM_GROUP_ID" --argjson cloud "$CLOUD_ID" --argjson layout "$VM_LAYOUT" --argjson image "$VM_IMAGE" \
      --argjson net "$VM_NET" --arg pool "pool-$VM_POOL" --arg ds "$VM_DS" --arg vmname "$VM_NAME_VALUE" '
      ($vm.instanceTypeCode // "mvm") as $type
      | {name: $vm.name, code: ("\($p)-\($vm.name)" | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-|-$"; "")),
         description: ($vm.description // "Self-service VM"), type: "instance", visibility: "private", enabled: true,
         featured: ($vm.featured | if . == null then true else . end), formType: "optionTypes", optionTypes: $inputs,
         config: {
           plan:        {id: "<%= customOptions.customPlan %>"},
           servicePlan: {id: "<%= customOptions.customPlan %>"},
           layout:      {id: $layout},
           group:       {id: $group},
           zoneId:      $cloud,
           instance: {name: $vmname, description: "<%= customOptions.customDesc %>", type: $type,
                      site: {id: $group}, layout: {id: $layout}, plan: {id: "<%= customOptions.customPlan %>"}},
           config: {imageId: $image, resourcePoolId: $pool, poolProviderType: ($vm.poolProviderType // "mvm"), createUser: true},
           volumes: [{id: -1, rootVolume: true, name: "root", size: "<%= customOptions.customDiskSize %>",
                      storageType: ($vm.storageTypeId // 1), datastoreId: (if ($ds | test("^[0-9]+$")) then ($ds | tonumber) else $ds end)}],
           networkInterfaces: [{network: {id: $net}}],
           tags: ($tags + [($vm.staticTags // {}) | to_entries[] | {name: .key, value: (.value | tostring)}])}}
      + (if $vm.category then {category: $vm.category} else {} end)')
    ensure_catalog_item "$ITEM"
    CATALOG_IDS[$VM_NAME]=$REPLY_ID
  fi
fi

# ===========================================================================
# 12. 3-tier app: blueprint + catalog item
# ===========================================================================
if [[ $(cfg '.catalog.threeTier != null') == true ]]; then
  TT=$(cfg '.catalog.threeTier | tojson')
  BP_NAME=$(jq -r .name <<<"$TT"); BP_GROUP=$(jq -r .group <<<"$TT")
  step "3-tier app '$BP_NAME'"
  if ! tenant_plan "Would create blueprint '$BP_NAME', an App Name input and its catalog item in the tenant"; then
    check_tenant_sees network "$BP_NET" "Network '$(jq -r .network <<<"$TT")'"
    check_tenant_sees pool "$BP_POOL" "Resource pool '$(jq -r .resourcePool <<<"$TT")'"
    check_tenant_sees datastore "$BP_DS" "Datastore '$(jq -r .datastore <<<"$TT")'"
    while IFS=$'\t' read -r iid pid; do
      check_tenant_sees image "$iid" "Image ID $iid"; check_tenant_sees plan "$pid" "Service plan ID $pid"
    done < <(jq -r '.[] | [.imageId, .planId] | @tsv' <<<"$BP_TIERS")

    if [[ -n ${BP_TEMPLATE_FILE:-} ]]; then
      # An exported blueprint: point its single group and cloud at this tenant's group and cloud.
      BP_BODY=$(jq -c --arg n "$BP_NAME" --arg g "$BP_GROUP" --arg c "$CLOUD_NAME" '
        def retarget: walk(if type == "object" and has("groups") and (.groups | type) == "object" and (.groups | length) == 1
                           then .groups |= with_entries(.key = $g | .value |= (if (.clouds | type) == "object" and (.clouds | length) == 1
                                                                                 then .clouds |= with_entries(.key = $c) else . end))
                           else . end);
        {name: $n, type: "morpheus", tiers: (.tiers | retarget)}' "$BP_TEMPLATE_FILE")
    else
      BP_BODY=$(jq -cn --arg n "$BP_NAME" --arg g "$BP_GROUP" --arg c "$CLOUD_NAME" --argjson tiers "$BP_TIERS" --argjson tt "$TT" \
        --argjson net "$BP_NET" --arg pool "pool-$BP_POOL" --arg ds "$BP_DS" '
        ($tt.instanceTypeCode // "mvm") as $type
        | {name: $n, type: "morpheus",
           tiers: (reduce range(0; $tiers | length) as $i ({}; . + {($tiers[$i].name): {
             tierIndex: ($i + 1), linkedTiers: $tiers[$i].linkTo,
             instances: [{instance: {type: $type},
               groups: {($g): {clouds: {($c): {
                 instance: {type: $type, layout: {id: $tiers[$i].layoutId}, name: (($tiers[$i].name | ascii_downcase) + "-${sequence}")},
                 plan: {id: $tiers[$i].planId},
                 config: {imageId: $tiers[$i].imageId, resourcePoolId: $pool, poolProviderType: ($tt.poolProviderType // "mvm"), createUser: true},
                 volumes: [{rootVolume: true, name: "root", size: $tiers[$i].diskGB, storageType: ($tt.storageTypeId // 1),
                            datastoreId: (if ($ds | test("^[0-9]+$")) then ($ds | tonumber) else $ds end)}],
                 networkInterfaces: [{primaryInterface: true, network: {id: $net}}],
                 tags: [($tt.staticTags // {}) | to_entries[] | {name: .key, value: (.value | tostring)}]
               }}}}}]}}))}')
    fi
    BP=$(api GET "/api/blueprints$(qs name "$BP_NAME" max 1000)" | find_by name "$BP_NAME" blueprints)
    if [[ -n $BP ]]; then
      BP_ID=$(jq -r .id <<<"$BP"); ok "Blueprint '$BP_NAME' exists (ID $BP_ID) - left unchanged"; record blueprint tenant "$BP_ID" "$BP_NAME" 0
    else
      BP_ID=$(api POST /api/blueprints "$BP_BODY" | jq -r '.blueprint.id // 0')
      record blueprint tenant "$BP_ID" "$BP_NAME" 1
      done_msg "Created blueprint '$BP_NAME' (ID $BP_ID) with tiers $(jq -r '.tiers | keys_unsorted | join(", ")' <<<"$BP_BODY")" "Would create blueprint '$BP_NAME'"
    fi

    ensure_input "$(jq -cn --arg p "$PREFIX" '{name: "\($p) - App Name", fieldName: "customAppName", type: "text", fieldLabel: "Application Name",
      required: true, exportMeta: false, verifyPattern: "^[a-zA-Z][a-zA-Z0-9-]{0,40}$", placeHolder: "e.g. payroll"}')"
    BP_INPUTS=$(jq -c --argjson i "$REPLY_ID" '[$i] + .' <<<"$TAG_INPUT_IDS_JSON")

    # App Spec (YAML) used when the item is ordered: app name and tags come from the order form.
    APP_SPEC=$(jq -rn --arg g "$BP_GROUP" --arg c "$CLOUD_NAME" --argjson body "$BP_BODY" --argjson tags "$TAGS_JSON" --argjson tt "$TT" '
      ($tags + [($tt.staticTags // {}) | to_entries[] | {name: .key, value: (.value | tostring)}]) as $all
      | ($tt.instanceTypeCode // "mvm") as $type
      | ["name: \"<%= customOptions.customAppName %>\"", "group:", "  name: \($g | tojson)", "tiers:"]
        + ([$body.tiers | keys_unsorted[] as $t
            | "  \($t | tojson):", "    instances:", "      - instance:", "          type: \($type | tojson)", "          cloud: \($c | tojson)",
              (if ($all | length) > 0 then "        tags:", ($all[] | "          - name: \(.name | tojson)", "            value: \(.value | tojson)") else empty end)])
      | join("\n")')
    BP_ITEM=$(jq -cn --arg n "$BP_NAME" --arg p "$PREFIX" --arg d "$(jq -r '.description // "Multi-tier application"' <<<"$TT")" \
      --argjson bp "$BP_ID" --arg spec "$APP_SPEC" --argjson inputs "$BP_INPUTS" '
      {name: $n, code: ("\($p)-\($n)" | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-|-$"; "")), description: $d,
       type: "blueprint", visibility: "private", enabled: true, featured: true, blueprint: {id: $bp}, appSpec: $spec,
       formType: "optionTypes", optionTypes: $inputs}')
    ensure_catalog_item "$BP_ITEM"
    CATALOG_IDS[$BP_NAME]=$REPLY_ID
    BLUEPRINT_OF[$BP_NAME]=$BP_ID
  fi
fi

# ===========================================================================
# 13. Role access to catalog items and blueprints
# ===========================================================================
ACCESS_ROLES=$(jq -c '[.roles[]? | select(.catalogItems != null)]' <<<"$CFG")
if [[ $(jq length <<<"$ACCESS_ROLES") -gt 0 ]]; then
  step "Catalog access per role"
  while IFS= read -r role; do
    RNAME=$(jq -r .name <<<"$role"); RID=${ROLE_IDS[$RNAME]:-0}
    CI=$(jq -c .catalogItems <<<"$role")
    if [[ $TENANT_READY == 0 || $RID == 0 ]]; then plan "Would give '$RNAME' access to catalog items: $(jq -r 'if type == "array" then join(", ") else . end' <<<"$CI")"; continue; fi
    case $CI in
      '"all"')  api PUT "/api/roles/$RID/update-catalog-item-type" '{"allCatalogItemTypes":true,"access":"full"}' >/dev/null
                api PUT "/api/roles/$RID/update-blueprint" '{"allBlueprints":true,"access":"full"}' >/dev/null
                done_msg "'$RNAME' can order every catalog item" "Would let '$RNAME' order every catalog item" ;;
      '"none"') api PUT "/api/roles/$RID/update-catalog-item-type" '{"allCatalogItemTypes":true,"access":"none"}' >/dev/null
                api PUT "/api/roles/$RID/update-blueprint" '{"allBlueprints":true,"access":"none"}' >/dev/null
                done_msg "'$RNAME' has no catalog access" "Would remove catalog access from '$RNAME'" ;;
      *)        api PUT "/api/roles/$RID/update-catalog-item-type" '{"allCatalogItemTypes":true,"access":"none"}' >/dev/null
                api PUT "/api/roles/$RID/update-blueprint" '{"allBlueprints":true,"access":"none"}' >/dev/null
                mapfile -t ITEMS < <(jq -r '.[]' <<<"$CI")
                for it in "${ITEMS[@]}"; do
                  CID=${CATALOG_IDS[$it]:-}
                  if [[ -z $CID ]]; then
                    CID=$(api GET "/api/catalog-item-types$(qs name "$it" max 1000)" | pick "$it" "Catalog item" catalogItemTypes | jq -r .id)
                  fi
                  if [[ $CID != 0 ]]; then
                    api PUT "/api/roles/$RID/update-catalog-item-type" "$(jq -cn --argjson i "$CID" '{catalogItemTypeId: $i, access: "full"}')" >/dev/null
                  fi
                  if [[ -n ${BLUEPRINT_OF[$it]:-} && ${BLUEPRINT_OF[$it]} != 0 ]]; then
                    api PUT "/api/roles/$RID/update-blueprint" "$(jq -cn --argjson i "${BLUEPRINT_OF[$it]}" '{blueprintId: $i, access: "full"}')" >/dev/null
                  fi
                done
                done_msg "'$RNAME' can order: $(join_by ", " "${ITEMS[@]}")" "Would let '$RNAME' order: $(join_by ", " "${ITEMS[@]}")" ;;
    esac
  done < <(jq -c '.[]' <<<"$ACCESS_ROLES")
fi

# ===========================================================================
# 14. Policies (inside the tenant)
# ===========================================================================
if [[ $(cfg '.policies != null') == true ]]; then
  step "Policies"
  if ! tenant_plan "Would create the naming, approval, tag and quota policies in the tenant"; then
    if [[ $(cfg '.policies.naming != null') == true ]]; then
      ensure_policy "$PREFIX - Instance naming" naming \
        "$(cfg '.policies.naming | {namingType: (.enforcement // "user"), namingPattern: .pattern, namingConflict: (if .autoResolveConflicts == false then "" else "on" end)} | tojson')" \
        "$(cfg '.policies.naming.scope // "global" | tojson')" false
    fi
    if [[ $(cfg '.policies.approval != null') == true ]]; then
      ensure_policy "$PREFIX - Provision approval" provisionApproval '{"accountIntegrationId":"-100"}' \
        "$(cfg '.policies.approval.scope // "global" | tojson')" "$(cfg '.policies.approval.eachUser | if . == null then true else . end')"
    fi
    if [[ $(cfg '.policies.tagEnforcement != null') == true ]]; then
      for tag in ${TAGS_CFG[@]+"${TAGS_CFG[@]}"}; do
        TNAME=$(jq -r .name <<<"$tag")
        ensure_policy "$PREFIX - Tag $TNAME" tags \
          "$(jq -cn --arg k "$TNAME" --argjson l "${TAG_LIST_ID[$TNAME]:-0}" --argjson s "$(cfg '.policies.tagEnforcement.strict | if . == null then true else . end')" '{strict: $s, key: $k, valueListId: $l}')" \
          "$(cfg '.policies.tagEnforcement.scope // "global" | tojson')" false
      done
    fi
    while IFS= read -r q; do
      [[ -n $q ]] || continue
      QNAME=$(jq -r .name <<<"$q"); QSCOPE=$(jq -c '.scope // "global"' <<<"$q"); QEACH=$(jq -r '.eachUser | if . == null then true else . end' <<<"$q")
      while IFS=$'\t' read -r key code label value; do
        ensure_policy "$QNAME - $label" "$code" "$(jq -cn --arg k "$code" --argjson v "$value" '{($k): $v}')" "$QSCOPE" "$QEACH"
      done < <(jq -r '[["maxVms","maxVms","Max VMs"],["maxCores","maxCores","Max cores"],["maxMemoryGB","maxMemory","Max memory (GB)"],["maxStorageGB","maxStorage","Max storage (GB)"]][] as $m
                      | select(.[$m[0]] != null) | [$m[0], $m[1], $m[2], (.[$m[0]] | tostring)] | @tsv' <<<"$q")
    done < <(jq -c '.policies.quotas[]?' <<<"$CFG")
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s================================================================%s\n' "$C_CYAN" "$C_OFF"
if [[ $DRY_RUN == 1 ]]; then printf '%s DRY RUN COMPLETE - nothing was changed%s\n' "$C_GREEN" "$C_OFF"
else printf '%s PoC TENANT READY%s\n' "$C_GREEN" "$C_OFF"; fi
printf ' %-14s %s (%s)\n' "Tenant:" "$TENANT_NAME" "$(fmt_id "$TENANT_ID")"
[[ $CLOUD_MODE == none ]] || printf ' %-14s %s - %s\n' "Cloud:" "$CLOUD_NAME" "$CLOUD_MODE"
printf ' %-14s %s\n' "Groups:" "$(join_by ", " "${GROUPS_CFG[@]}")"
printf ' %-14s %s  as  %s\\%s\n' "Sign in:" "$BASE_URL" "${LOGIN_PREFIX:-<tenant-id>}" "$ADMIN_USER"
if [[ -n $ADMIN_PW_SHOWN && $DRY_RUN == 0 ]]; then
  printf '%s %-14s %s%s\n' "$C_YELLOW" "Admin password:" "$ADMIN_PW_SHOWN" "$C_OFF"
fi
for entry in ${NEW_PASSWORDS[@]+"${NEW_PASSWORDS[@]}"}; do
  printf '%s %-14s %s  password %s%s\n' "$C_YELLOW" "New user:" "${entry%%$'\t'*}" "${entry#*$'\t'}" "$C_OFF"
done
if [[ -n $ADMIN_PW_SHOWN || ${#NEW_PASSWORDS[@]} -gt 0 ]] && [[ $DRY_RUN == 0 ]]; then
  printf '%s                (passwords are shown once - store them in your password manager)%s\n' "$C_YELLOW" "$C_OFF"
fi
[[ $DRY_RUN == 1 ]] || printf ' %-14s %s\n' "State file:" "$MANIFEST_FILE"
[[ $DRY_RUN == 1 ]] || printf ' %-14s %s\n' "Undo with:" "bash/poc-teardown.sh --config $CONFIG"
printf '%s================================================================%s\n' "$C_CYAN" "$C_OFF"

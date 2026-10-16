#!/usr/bin/env bash
#
# new-morpheus-catalog-item.sh
#
# Creates a self-service VM catalog item (with its form inputs) on HPE Morpheus Enterprise /
# HPE VM Essentials (VME) Manager:
#
#   1. Pre-checks every ID you pass (group, cloud, layout, image, network, resource pool,
#      datastore, service plans) and prints what each one is - nothing is created if one is wrong.
#   2. Option list  - a manual list of the service plans users may pick.
#   3. Inputs       - VM name, description, plan (select), root disk size, cost center, department.
#   4. Catalog item - an "instance" item whose provisioning config uses those inputs,
#                     and tags the VM with CostCenter / Department plus any static tags.
#
# Every step is "get or create"; --update pushes changed settings into an existing item.
#
# Credentials come from the environment, never from this file:
#   MORPHEUS_URL               e.g. https://vme-manager.example.local
#   MORPHEUS_TOKEN             API access token
#   MORPHEUS_SKIP_TLS_VERIFY   optional; true = ignore SSL certificate errors (lab appliances)
#   MORPHEUS_CA_CERT           optional; PEM file of the appliance CA - the safer alternative
#
# Requires: bash 4.4+, curl 7.55+, jq 1.6+.  Not an official HPE tool - test in a lab first.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # errors inside $(...) also stop the script (bash 4.4+)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAME="" CODE="" CATEGORY="" VISIBILITY="private" FEATURED=true
DESCRIPTION="Provision a customizable VM with metadata and mandatory cost tagging."
GROUP_ID="" CLOUD_ID="" LAYOUT_ID="" IMAGE_ID="" NETWORK_ID="" RESOURCE_POOL="" DATASTORE="" PLAN_IDS=""
STORAGE_TYPE_ID=1 INSTANCE_TYPE_CODE="mvm" POOL_PROVIDER_TYPE="mvm"
DEFAULT_DISK_GB=40 INPUT_PREFIX="Cat" EXPORT_META=false
TAGS=() UPDATE=0 INSECURE=0 DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: new-morpheus-catalog-item.sh --name NAME --group-id ID --cloud-id ID --layout-id ID --image-id ID
                                    --network-id ID --resource-pool POOL --datastore DS --plans IDS [options]

Catalog item
  --name NAME                 Catalog item name (required)
  --code CODE                 Short code (default: derived from the name)
  --description TEXT          Description shown in the catalog
  --category TEXT             Optional category
  --visibility VIS            private (default) | public (all tenants)
  --not-featured              Do not mark the item as featured

What gets provisioned (all IDs are checked before anything is created)
  --group-id ID               Group (must contain the cloud)
  --cloud-id ID               Cloud (zone)
  --layout-id ID              Instance type layout
  --image-id ID               Virtual image
  --network-id ID             Network for the primary interface
  --resource-pool POOL        Resource pool / cluster: 5 or pool-5
  --datastore DS              Datastore ID, or auto / autoCluster
  --plans IDS                 Comma-separated service plan IDs offered on the form, e.g. 25,26
  --storage-type-id ID        Root volume storage type (default: 1)
  --instance-type-code CODE   Default: mvm
  --pool-provider-type CODE   Default: mvm

Form and tags
  --default-disk-gb N         Default root disk size (default: 40)
  --tag KEY=VALUE             Static tag; repeat for more. Replaces the defaults
                              (Environment=Production, ManagedBy=Self-Service)
  --input-prefix TEXT         Prefix for input / option list names (default: Cat)
  --export-inputs-as-tags     Also export every input as a tag (off: only the tags above are set)

General
  --update                    Apply settings to an existing catalog item / plan list
  --dry-run                   Do lookups only; print every change instead of making it
  --insecure                  Ignore SSL certificate errors (lab appliances only)
  -h, --help                  Show this help

Environment: MORPHEUS_URL, MORPHEUS_TOKEN (required), MORPHEUS_SKIP_TLS_VERIFY, MORPHEUS_CA_CERT (optional)
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
redact()   { sed -E 's/"password"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"/"password":"********"/g' <<<"$1"; }

# ---------------------------------------------------------------------------
# Argument parsing (supports "--opt value" and "--opt=value")
# ---------------------------------------------------------------------------
need_value() { [[ $# -ge 2 && $2 != --* ]] || usage_error "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  if [[ $1 == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case $1 in
    --name)                   need_value "$@"; NAME=$2; shift 2 ;;
    --code)                   need_value "$@"; CODE=$2; shift 2 ;;
    --description)            need_value "$@"; DESCRIPTION=$2; shift 2 ;;
    --category)               need_value "$@"; CATEGORY=$2; shift 2 ;;
    --visibility)             need_value "$@"; VISIBILITY=$2; shift 2 ;;
    --not-featured)           FEATURED=false; shift ;;
    --group-id)               need_value "$@"; GROUP_ID=$2; shift 2 ;;
    --cloud-id)               need_value "$@"; CLOUD_ID=$2; shift 2 ;;
    --layout-id)              need_value "$@"; LAYOUT_ID=$2; shift 2 ;;
    --image-id)               need_value "$@"; IMAGE_ID=$2; shift 2 ;;
    --network-id)             need_value "$@"; NETWORK_ID=$2; shift 2 ;;
    --resource-pool)          need_value "$@"; RESOURCE_POOL=$2; shift 2 ;;
    --datastore)              need_value "$@"; DATASTORE=$2; shift 2 ;;
    --plans)                  need_value "$@"; PLAN_IDS=$2; shift 2 ;;
    --storage-type-id)        need_value "$@"; STORAGE_TYPE_ID=$2; shift 2 ;;
    --instance-type-code)     need_value "$@"; INSTANCE_TYPE_CODE=$2; shift 2 ;;
    --pool-provider-type)     need_value "$@"; POOL_PROVIDER_TYPE=$2; shift 2 ;;
    --default-disk-gb)        need_value "$@"; DEFAULT_DISK_GB=$2; shift 2 ;;
    --tag)                    need_value "$@"; TAGS+=("$2"); shift 2 ;;
    --input-prefix)           need_value "$@"; INPUT_PREFIX=$2; shift 2 ;;
    --export-inputs-as-tags)  EXPORT_META=true; shift ;;
    --update)                 UPDATE=1; shift ;;
    --dry-run)                DRY_RUN=1; shift ;;
    --insecure|-k)            INSECURE=1; shift ;;
    -h|--help)                usage; exit 0 ;;
    *)                        usage_error "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "bash 4.4 or newer is required (found $BASH_VERSION)."
command -v curl >/dev/null || die "curl is required."
command -v jq >/dev/null   || die "jq is required."

[[ -n $NAME ]] || usage_error "--name is required"
for pair in "group-id:$GROUP_ID" "cloud-id:$CLOUD_ID" "layout-id:$LAYOUT_ID" "image-id:$IMAGE_ID" \
            "network-id:$NETWORK_ID" "storage-type-id:$STORAGE_TYPE_ID" "default-disk-gb:$DEFAULT_DISK_GB"; do
  [[ ${pair#*:} =~ ^[1-9][0-9]*$ ]] || usage_error "--${pair%%:*} is required and must be a number"
done
[[ $RESOURCE_POOL =~ ^(pool-)?[0-9]+$ ]] || usage_error "--resource-pool is required, e.g. 5 or pool-5"
[[ $DATASTORE =~ ^([0-9]+|auto|autoCluster)$ ]] || usage_error "--datastore is required: a datastore ID, auto or autoCluster"
[[ $PLAN_IDS =~ ^[0-9]+(,[0-9]+)*$ ]] || usage_error "--plans is required: comma-separated service plan IDs, e.g. 25,26"
[[ $VISIBILITY =~ ^(private|public)$ ]] || usage_error "--visibility must be private or public"
[[ -z $CODE || $CODE =~ ^[a-z0-9-]+$ ]] || usage_error "--code may only contain lowercase letters, digits and hyphens"
for tag in ${TAGS[@]+"${TAGS[@]}"}; do
  [[ $tag =~ ^[^=]+=.*$ ]] || usage_error "--tag must look like KEY=VALUE (got '$tag')"
done
if [[ ${#TAGS[@]} -eq 0 ]]; then TAGS=("Environment=Production" "ManagedBy=Self-Service"); fi

if [[ -z $CODE ]]; then
  CODE=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [[ -n $CODE ]] || usage_error "could not derive a code from --name; pass --code"
fi
POOL_NUMBER=${RESOURCE_POOL#pool-}
POOL_REF="pool-$POOL_NUMBER"

BASE_URL=${MORPHEUS_URL:-}
BASE_URL=${BASE_URL%/}
[[ -n $BASE_URL ]] || die "Set MORPHEUS_URL (e.g. https://vme-manager.example.local)."
[[ -n ${MORPHEUS_TOKEN:-} ]] || die "Set MORPHEUS_TOKEN to your Morpheus API access token."
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

# get_object LABEL PATH KEY -> the object, or exits if it does not exist
get_object() {
  local res obj
  res=$(api GET "$2")
  obj=$(jq -c --arg k "$3" '.[$k] // empty' <<<"$res")
  [[ -n $obj ]] || die "$1 was not found ($2)."
  printf '%s' "$obj"
}

# resolve_input SPEC_JSON -> id of an existing or newly created input (0 in a dry run)
resolve_input() {
  local spec=$1 name field res existing id
  name=$(jq -r '.name' <<<"$spec")
  field=$(jq -r '.fieldName' <<<"$spec")
  res=$(api GET "/api/library/option-types$(qs name "$name" max 1000)")
  existing=$(find_by name "$name" optionTypes <<<"$res")
  if [[ -n $existing ]]; then
    if [[ $(jq -r '.fieldName' <<<"$existing") != "$field" ]]; then
      die "Input '$name' already exists with field name '$(jq -r '.fieldName' <<<"$existing")', but this catalog item needs '$field'. Rename it or use --input-prefix."
    fi
    if [[ $(jq -r '.type' <<<"$existing") != "$(jq -r '.type' <<<"$spec")" ]]; then
      warn "Input '$name' is type '$(jq -r '.type' <<<"$existing")', expected '$(jq -r '.type' <<<"$spec")'. Left unchanged." >&2
    fi
    id=$(jq -r '.id' <<<"$existing")
    ok "Input '$name' exists (ID $id)" >&2
  else
    res=$(api POST "/api/library/option-types" "$(jq -c '{optionType: .}' <<<"$spec")")
    id=$(jq -r '.optionType.id // 0' <<<"$res")
    done_msg "Created input '$name' (ID $id)" "Would create input '$name' [$(jq -r '.type' <<<"$spec")]" >&2
  fi
  printf '%s' "$id"
}

# ===========================================================================
# Main
# ===========================================================================
if [[ $DRY_RUN == 1 ]]; then printf '\nDRY RUN - lookups are real, nothing will be created or changed.\n'; fi

# 1. Check every referenced ID (read-only) -----------------------------------
step "Checking the IDs this catalog item will use"
WHOAMI=$(api GET "/api/whoami")
ok "Connected as '$(jq -r '.user.username' <<<"$WHOAMI")'"

CLOUD=$(get_object "Cloud ID $CLOUD_ID" "/api/zones/$CLOUD_ID" zone)
ok "Cloud        $CLOUD_ID = '$(jq -r .name <<<"$CLOUD")'"

GROUP=$(get_object "Group ID $GROUP_ID" "/api/groups/$GROUP_ID" group)
if ! jq -e --argjson c "$CLOUD_ID" 'any(.zones[]?; .id == $c)' <<<"$GROUP" >/dev/null; then
  die "Group '$(jq -r .name <<<"$GROUP")' does not contain cloud '$(jq -r .name <<<"$CLOUD")'. Add the cloud to the group first."
fi
ok "Group        $GROUP_ID = '$(jq -r .name <<<"$GROUP")' (contains the cloud)"

LAYOUT=$(get_object "Layout ID $LAYOUT_ID" "/api/library/layouts/$LAYOUT_ID" instanceTypeLayout)
LAYOUT_TYPE_CODE=$(jq -r '.instanceType.code // empty' <<<"$LAYOUT")
if [[ -n $LAYOUT_TYPE_CODE && $LAYOUT_TYPE_CODE != "$INSTANCE_TYPE_CODE" ]]; then
  warn "Layout belongs to instance type '$LAYOUT_TYPE_CODE', but the config will use '$INSTANCE_TYPE_CODE'. Pass --instance-type-code $LAYOUT_TYPE_CODE if ordering fails."
fi
ok "Layout       $LAYOUT_ID = '$(jq -r .name <<<"$LAYOUT")' (instance type '$INSTANCE_TYPE_CODE')"

IMAGE=$(get_object "Image ID $IMAGE_ID" "/api/virtual-images/$IMAGE_ID" virtualImage)
ok "Image        $IMAGE_ID = '$(jq -r .name <<<"$IMAGE")'"

NETWORK=$(get_object "Network ID $NETWORK_ID" "/api/networks/$NETWORK_ID" network)
ok "Network      $NETWORK_ID = '$(jq -r .name <<<"$NETWORK")'"

POOL=$(get_object "Resource pool $POOL_REF" "/api/zones/$CLOUD_ID/resource-pools/$POOL_NUMBER" resourcePool)
ok "Pool         $POOL_REF = '$(jq -r .name <<<"$POOL")'"

if [[ $DATASTORE =~ ^[0-9]+$ ]]; then
  DS=$(get_object "Datastore ID $DATASTORE" "/api/zones/$CLOUD_ID/data-stores/$DATASTORE" datastore)
  ok "Datastore    $DATASTORE = '$(jq -r .name <<<"$DS")'"
  DATASTORE_JSON=$DATASTORE
else
  ok "Datastore    $DATASTORE (selected automatically at provision time)"
  DATASTORE_JSON=$(jq -cn --arg d "$DATASTORE" '$d')
fi

PLAN_CHOICES="[]"
IFS=, read -ra PLAN_LIST <<<"$PLAN_IDS"
for plan_id in "${PLAN_LIST[@]}"; do
  PLAN=$(get_object "Service plan ID $plan_id" "/api/service-plans/$plan_id" servicePlan)
  ok "Plan         $plan_id = '$(jq -r .name <<<"$PLAN")'"
  PLAN_CHOICES=$(jq -c --argjson p "$PLAN" --argjson id "$plan_id" 'if any(.[]; .value == $id) then . else . + [{name: $p.name, value: $id}] end' <<<"$PLAN_CHOICES")
done

# Inputs that already exist must use the field names the config refers to - check before creating anything.
for pair in "VM Name:customVmName" "Description:customDesc" "Plan:customPlan" "Disk:customDiskSize" \
            "Cost Center:customCostCenter" "Department:customDept"; do
  input_name="$INPUT_PREFIX - ${pair%%:*}"
  RES=$(api GET "/api/library/option-types$(qs name "$input_name" max 1000)")
  existing_field=$(find_by name "$input_name" optionTypes <<<"$RES" | jq -r '.fieldName // empty')
  if [[ -n $existing_field && $existing_field != "${pair#*:}" ]]; then
    die "Input '$input_name' already exists with field name '$existing_field', but this catalog item needs '${pair#*:}'. Rename it or use --input-prefix."
  fi
done
ok "Input names are free or compatible (prefix '$INPUT_PREFIX')"

# 2. Option list with the allowed plans --------------------------------------
LIST_NAME="$INPUT_PREFIX - Plan Sizes"
step "Option list '$LIST_NAME'"
RES=$(api GET "/api/library/option-type-lists$(qs name "$LIST_NAME" max 1000)")
PLAN_LIST_OBJ=$(find_by name "$LIST_NAME" optionTypeLists <<<"$RES")
if [[ -n $PLAN_LIST_OBJ ]]; then
  PLAN_LIST_ID=$(jq -r '.id' <<<"$PLAN_LIST_OBJ")
  if [[ $UPDATE == 1 ]]; then
    api PUT "/api/library/option-type-lists/$PLAN_LIST_ID" \
      "$(jq -cn --arg d "$PLAN_CHOICES" '{optionTypeList: {initialDataset: $d}}')" >/dev/null
    done_msg "Updated plan choices in option list (ID $PLAN_LIST_ID)" "Would update the plan choices in option list (ID $PLAN_LIST_ID)"
  else
    ok "Option list exists (ID $PLAN_LIST_ID) - plan choices left unchanged (use --update to refresh them)"
  fi
else
  BODY=$(jq -cn --arg n "$LIST_NAME" --arg d "$PLAN_CHOICES" \
    '{optionTypeList: {name: $n, description: "Service plans offered in the self-service catalog", type: "manual", initialDataset: $d}}')
  RES=$(api POST "/api/library/option-type-lists" "$BODY")
  PLAN_LIST_ID=$(jq -r '.optionTypeList.id // 0' <<<"$RES")
  done_msg "Created option list (ID $PLAN_LIST_ID)" "Would create option list with ${#PLAN_LIST[@]} plan(s)"
fi

# 3. Inputs (the order here is the order on the order form) -------------------
step "Form inputs"
INPUT_SPECS=$(jq -cn --arg p "$INPUT_PREFIX" --argjson meta "$EXPORT_META" --argjson list "$PLAN_LIST_ID" --arg disk "$DEFAULT_DISK_GB" '[
  {name: "\($p) - VM Name",     fieldName: "customVmName",     type: "text",     fieldLabel: "Server Name",           required: true,  exportMeta: $meta,
   verifyPattern: "^[a-zA-Z][a-zA-Z0-9-]{0,62}$", placeHolder: "e.g. app-web-01"},
  {name: "\($p) - Description", fieldName: "customDesc",       type: "textarea", fieldLabel: "Purpose / Description", required: false, exportMeta: $meta},
  {name: "\($p) - Plan",        fieldName: "customPlan",       type: "select",   fieldLabel: "Server Plan Size",      required: true,  exportMeta: $meta,
   optionList: {id: $list}},
  {name: "\($p) - Disk",        fieldName: "customDiskSize",   type: "number",   fieldLabel: "Root Disk Size (GB)",   required: true,  exportMeta: $meta,
   defaultValue: $disk},
  {name: "\($p) - Cost Center", fieldName: "customCostCenter", type: "text",     fieldLabel: "Cost Center Tag",       required: true,  exportMeta: $meta},
  {name: "\($p) - Department",  fieldName: "customDept",       type: "text",     fieldLabel: "Department Tag",        required: true,  exportMeta: $meta}
]')
INPUT_IDS=()
while IFS= read -r spec; do
  INPUT_IDS+=("$(resolve_input "$spec")")
done < <(jq -c '.[]' <<<"$INPUT_SPECS")
INPUT_IDS_JSON=$(printf '%s\n' "${INPUT_IDS[@]}" | jq -cs '.')

# 4. Catalog item ----------------------------------------------------------------
step "Catalog item '$NAME'"
TAGS_JSON=$(printf '%s\n' "${TAGS[@]}" | jq -cR 'capture("^(?<name>[^=]+)=(?<value>.*)$")' | jq -cs \
  '[{name: "CostCenter", value: "<%= customOptions.customCostCenter %>"},
    {name: "Department", value: "<%= customOptions.customDept %>"}] + .')

# Provisioning config - same structure as the lab script proven on a VME appliance
# (examples/create-catalog-tile.sh). <%= customOptions.<fieldName> %> is replaced with
# what the user entered on the order form when the item is ordered.
ITEM_BODY=$(jq -cn \
  --arg name "$NAME" --arg code "$CODE" --arg desc "$DESCRIPTION" --arg cat "$CATEGORY" --arg vis "$VISIBILITY" \
  --argjson featured "$FEATURED" --argjson inputs "$INPUT_IDS_JSON" --argjson tags "$TAGS_JSON" \
  --argjson group "$GROUP_ID" --argjson cloud "$CLOUD_ID" --arg type "$INSTANCE_TYPE_CODE" \
  --argjson layout "$LAYOUT_ID" --argjson image "$IMAGE_ID" --arg pool "$POOL_REF" --arg poolType "$POOL_PROVIDER_TYPE" \
  --argjson storage "$STORAGE_TYPE_ID" --argjson ds "$DATASTORE_JSON" --argjson net "$NETWORK_ID" '
  {catalogItemType: ({
    name: $name, code: $code, description: $desc, type: "instance", visibility: $vis,
    enabled: true, featured: $featured, formType: "optionTypes", optionTypes: $inputs,
    config: {
      plan:        {id: "<%= customOptions.customPlan %>"},
      servicePlan: {id: "<%= customOptions.customPlan %>"},
      layout:      {id: $layout},
      group:       {id: $group},
      zoneId:      $cloud,
      instance: {
        name:        "<%= customOptions.customVmName %>",
        description: "<%= customOptions.customDesc %>",
        type:        $type,
        site:        {id: $group},
        layout:      {id: $layout},
        plan:        {id: "<%= customOptions.customPlan %>"}
      },
      config: {imageId: $image, resourcePoolId: $pool, poolProviderType: $poolType, createUser: true},
      volumes: [{id: -1, rootVolume: true, name: "root", size: "<%= customOptions.customDiskSize %>", storageType: $storage, datastoreId: $ds}],
      networkInterfaces: [{network: {id: $net}}],
      tags: $tags
    }
  } + (if $cat == "" then {} else {category: $cat} end))}')

RES=$(api GET "/api/catalog-item-types$(qs name "$NAME" max 1000)")
EXISTING_ITEM=$(find_by name "$NAME" catalogItemTypes <<<"$RES")
if [[ -n $EXISTING_ITEM ]]; then
  ITEM_ID=$(jq -r '.id' <<<"$EXISTING_ITEM")
  if [[ $UPDATE == 1 ]]; then
    api PUT "/api/catalog-item-types/$ITEM_ID" "$ITEM_BODY" >/dev/null
    done_msg "Updated catalog item (ID $ITEM_ID)" "Would update catalog item (ID $ITEM_ID) with the settings above"
  else
    ok "Catalog item exists (ID $ITEM_ID) - left unchanged (use --update to apply new settings)"
  fi
else
  RES=$(api POST "/api/catalog-item-types" "$ITEM_BODY")
  ITEM_ID=$(jq -r '.catalogItemType.id // 0' <<<"$RES")
  done_msg "Created catalog item (ID $ITEM_ID)" "Would create the catalog item"
fi

# Summary ----------------------------------------------------------------------
INPUT_SUMMARY=""
for id in "${INPUT_IDS[@]}"; do INPUT_SUMMARY+="${INPUT_SUMMARY:+, }$(fmt_id "$id")"; done
printf '\n%s================================================================%s\n' "$C_CYAN" "$C_OFF"
if [[ $DRY_RUN == 1 ]]; then printf '%s DRY RUN COMPLETE - nothing was changed%s\n' "$C_GREEN" "$C_OFF"
else printf '%s CATALOG ITEM READY%s\n' "$C_GREEN" "$C_OFF"; fi
printf ' %-13s %s\n' "Catalog item:" "$NAME ($(fmt_id "$ITEM_ID")), code '$CODE'"
printf ' %-13s %s\n' "Inputs:" "$INPUT_SUMMARY"
printf ' %-13s %s\n' "Plan list:" "$LIST_NAME ($(fmt_id "$PLAN_LIST_ID"))"
printf ' %-13s %s\n' "Tags:" "$(jq -r '[.[].name] | join(", ")' <<<"$TAGS_JSON")"
printf ' %-13s %s\n' "Find it:" "Library > Blueprints > Catalog Items; order it from Provisioning > Catalog"
printf '%s================================================================%s\n' "$C_CYAN" "$C_OFF"

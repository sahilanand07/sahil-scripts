#!/usr/bin/env bash
# ============================================================================
# CREATE ADVANCED CATALOG TILE (DYNAMIC SIZING, TAGS, & METADATA) - bash version
# ============================================================================
# Line-for-line port of create-catalog-tile.ps1. It sends the same eight API calls
# with the same request bodies:
#   1-2. Inputs "Cat - VM Name", "Cat - Description"
#   3.   Option list "Plan Sizes" + select input "Cat - Plan"
#   4-6. Inputs "Cat - Disk", "Cat - Cost Center", "Cat - Department"
#   7.   Catalog item (instance) that uses all six inputs
#
# Note: like the PowerShell original it always CREATES - running it twice makes
# duplicates. Use ../new-morpheus-catalog-item.sh for a re-runnable version.
#
# Needs: bash 4.4+, curl, jq
# Environment:
#   MORPHEUS_URL               e.g. https://vme-manager.example.local   (required)
#   MORPHEUS_TOKEN             API access token                         (required)
#   MORPHEUS_SKIP_TLS_VERIFY   true = ignore SSL certificate errors (lab appliances)
#   MORPHEUS_CA_CERT           PEM file of the appliance CA (safer alternative)
# ============================================================================
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ----------------------------------------------------------------------------
# Standard variables (same values as the PowerShell script; override via env)
# ----------------------------------------------------------------------------
GROUP_ID=${GROUP_ID:-3}
CLOUD_ID=${CLOUD_ID:-1}
LAYOUT_ID=${LAYOUT_ID:-32}
IMAGE_ID=${IMAGE_ID:-194}
NETWORK_ID=${NETWORK_ID:-1}
RESOURCE_POOL_ID=${RESOURCE_POOL_ID:-pool-1}
DATASTORE_ID=${DATASTORE_ID:-6}
CATALOG_NAME=${CATALOG_NAME:-"Advanced VM (Self-Service)"}

BASE_URL=${MORPHEUS_URL:?Set MORPHEUS_URL, e.g. https://vme-manager.example.local}
BASE_URL=${BASE_URL%/}
: "${MORPHEUS_TOKEN:?Set MORPHEUS_TOKEN to your Morpheus API token}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# Keep the token out of the process list: curl reads it from a private header file.
umask 077
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
printf 'Authorization: Bearer %s\n' "$MORPHEUS_TOKEN" > "$WORKDIR/auth.hdr"
CURL_OPTS=(-sS --connect-timeout 15 --max-time 120 -H "@$WORKDIR/auth.hdr" -H 'Accept: application/json')

# ----------------------------------------------------------------------------
# SSL / TLS certificate handling
# ----------------------------------------------------------------------------
# The PowerShell original always bypasses certificate validation. Here it is opt-in:
#   MORPHEUS_SKIP_TLS_VERIFY=true  -> ignore SSL errors (self-signed lab certificate)
#   MORPHEUS_CA_CERT=/path/ca.pem  -> trust the appliance CA instead (safer)
if [[ -n ${MORPHEUS_CA_CERT:-} ]]; then CURL_OPTS+=(--cacert "$MORPHEUS_CA_CERT"); fi
if [[ ${MORPHEUS_SKIP_TLS_VERIFY:-} =~ ^(1|[Tt]rue|TRUE|[Yy]es|YES)$ ]]; then
  CURL_OPTS+=(-k)
  echo "[warn] SSL certificate errors are being ignored (lab mode)." >&2
fi

# ----------------------------------------------------------------------------
# Invoke-MorpheusApi equivalent: morpheus_api METHOD PATH [JSON_BODY]
# Prints the response JSON; stops the script on any error (like `throw`).
# ----------------------------------------------------------------------------
morpheus_api() {
  local method=$1 path=$2 body=${3-} code rc=0 out="$WORKDIR/response.json"
  if [[ -n $body ]]; then
    code=$(curl "${CURL_OPTS[@]}" -X "$method" -H 'Content-Type: application/json' \
             --data-binary @- -o "$out" -w '%{http_code}' "$BASE_URL$path" <<<"$body") || rc=$?
  else
    code=$(curl "${CURL_OPTS[@]}" -X "$method" -o "$out" -w '%{http_code}' "$BASE_URL$path") || rc=$?
  fi
  if (( rc == 60 || rc == 35 || rc == 51 || rc == 58 || rc == 77 )); then
    echo "API Error on $path : SSL/TLS problem (curl exit $rc). For a self-signed lab certificate set MORPHEUS_SKIP_TLS_VERIFY=true." >&2
    exit 1
  elif (( rc != 0 )); then
    echo "API Error on $path : could not reach $BASE_URL (curl exit $rc)" >&2
    exit 1
  fi
  if (( code >= 400 )); then
    echo "API Error on $path : HTTP $code $(head -c 2000 "$out")" >&2
    exit 1
  fi
  cat "$out"
}

# create_input JSON -> prints the new input (option type) id
create_input() {
  morpheus_api POST '/api/library/option-types' "$(jq -c '{optionType: .}' <<<"$1")" | jq -r '.optionType.id'
}

echo "Building Advanced Form Fields..."

# 1. VM Name
NAME_ID=$(create_input '{"name":"Cat - VM Name","fieldName":"customVmName","type":"text","fieldLabel":"Server Name","required":true,"exportMeta":true}')

# 2. Description (Text Area)
DESC_ID=$(create_input '{"name":"Cat - Description","fieldName":"customDesc","type":"textarea","fieldLabel":"Purpose / Description","required":false,"exportMeta":true}')

# 3. Plan Selection: a manual option list (label -> service plan id) and a select input using it
PLAN_LIST_ID=$(morpheus_api POST '/api/library/option-type-lists' \
  '{"optionTypeList":{"name":"Plan Sizes","type":"manual","initialDataset":"[{\"name\":\"Standard Sizing (Plan 25)\",\"value\":25},{\"name\":\"Performance Sizing (Plan 26)\",\"value\":26}]"}}' \
  | jq -r '.optionTypeList.id')
PLAN_ID=$(create_input "$(jq -cn --argjson list "$PLAN_LIST_ID" \
  '{name: "Cat - Plan", fieldName: "customPlan", type: "select", fieldLabel: "Server Plan Size", required: true, exportMeta: true, optionList: {id: $list}}')")

# 4. Disk Size
DISK_ID=$(create_input '{"name":"Cat - Disk","fieldName":"customDiskSize","type":"number","fieldLabel":"Root Disk Size (GB)","defaultValue":"40","required":true,"exportMeta":true}')

# 5. Cost Center Tag
COST_ID=$(create_input '{"name":"Cat - Cost Center","fieldName":"customCostCenter","type":"text","fieldLabel":"Cost Center Tag","required":true,"exportMeta":true}')

# 6. Department Tag
DEPT_ID=$(create_input '{"name":"Cat - Department","fieldName":"customDept","type":"text","fieldLabel":"Department Tag","required":true,"exportMeta":true}')

echo "-> Success! Form Fields created."

# ----------------------------------------------------------------------------
# Create the Advanced Catalog Tile
# ----------------------------------------------------------------------------
echo
echo "Creating Advanced Catalog Item..."

CATALOG_BODY=$(jq -cn \
  --arg name "$CATALOG_NAME" --arg code "adv-vm-$(( RANDOM % 10000 ))" \
  --argjson group "$GROUP_ID" --argjson cloud "$CLOUD_ID" --argjson layout "$LAYOUT_ID" \
  --argjson image "$IMAGE_ID" --argjson network "$NETWORK_ID" --arg pool "$RESOURCE_POOL_ID" \
  --argjson datastore "$DATASTORE_ID" \
  --argjson inputs "[$NAME_ID,$DESC_ID,$PLAN_ID,$DISK_ID,$COST_ID,$DEPT_ID]" '
{
  catalogItemType: {
    name: $name,
    code: $code,
    description: "Provision a highly customizable VM with metadata and strict tagging.",
    type: "instance",
    enabled: true,
    featured: true,

    # Attach all 6 form fields in the exact order you want them to appear in the UI
    optionTypes: $inputs,

    config: {
      plan:        {id: "<%= customOptions.customPlan %>"},
      servicePlan: {id: "<%= customOptions.customPlan %>"},
      layout:      {id: $layout},
      group:       {id: $group},
      zoneId:      $cloud,

      instance: {
        name:        "<%= customOptions.customVmName %>",
        description: "<%= customOptions.customDesc %>",
        type:        "mvm",
        site:        {id: $group},
        layout:      {id: $layout},
        plan:        {id: "<%= customOptions.customPlan %>"}
      },
      config: {
        imageId:          $image,
        resourcePoolId:   $pool,
        poolProviderType: "mvm",
        createUser:       true
      },
      volumes: [
        {id: -1, rootVolume: true, name: "root", size: "<%= customOptions.customDiskSize %>", storageType: 1, datastoreId: $datastore}
      ],
      networkInterfaces: [
        {network: {id: $network}}
      ],
      tags: [
        {name: "CostCenter",  value: "<%= customOptions.customCostCenter %>"},
        {name: "Department",  value: "<%= customOptions.customDept %>"},
        {name: "Environment", value: "Production"},
        {name: "ManagedBy",   value: "Self-Service"}
      ]
    }
  }
}')

CATALOG_ITEM_ID=$(morpheus_api POST '/api/catalog-item-types' "$CATALOG_BODY" | jq -r '.catalogItemType.id')

echo "-> Success! Catalog Item created with ID: $CATALOG_ITEM_ID"

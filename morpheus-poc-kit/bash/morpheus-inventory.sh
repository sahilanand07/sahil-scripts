#!/usr/bin/env bash
#
# morpheus-inventory.sh - read everything a PoC config refers to from an HPE Morpheus / VME Manager
# appliance, and write it to disk. It changes nothing on the appliance.
#
# Output (in a new folder under --out, default ./inventory):
#   summary.txt          human-readable tables: clouds with their resource pools, datastores and
#                        networks (with visibility and which tenants they are shared with), tenants,
#                        groups, roles, feature-permission codes, layouts, images, plans, policy types,
#                        and existing option lists, inputs, catalog items, blueprints and policies
#   inventory.json       the same data as JSON
#   starter-config.json  a customer config pre-filled with real names from this appliance - copy it
#                        into customers/ and edit it
#   blueprints/NAME.json (with --export-blueprint NAME) a blueprint's config, usable as
#                        catalog.threeTier.templateFile
#
# Environment: MORPHEUS_URL, MORPHEUS_TOKEN (master-tenant admin), MORPHEUS_SKIP_TLS_VERIFY, MORPHEUS_CA_CERT
# Requires bash 4.4+, curl 7.55+, jq 1.6+.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/morpheus.sh
source "$HERE/lib/morpheus.sh"

OUT_DIR="./inventory" EXPORT_BP=() INSECURE=0 PERM_ROLE=""

usage() {
  cat <<'EOF'
Usage: morpheus-inventory.sh [--out DIR] [--export-blueprint NAME]... [--permissions-from ROLE] [--insecure]

  --out DIR                 Parent folder for the output (default: ./inventory)
  --export-blueprint NAME   Also save this blueprint's config as blueprints/NAME.json (repeatable)
  --permissions-from ROLE   User role whose feature-permission codes are listed (default: Tenant Admin)
  --insecure                Ignore SSL certificate errors (lab appliances only)
  -h, --help                Show this help

Environment: MORPHEUS_URL, MORPHEUS_TOKEN (required), MORPHEUS_SKIP_TLS_VERIFY, MORPHEUS_CA_CERT (optional)
EOF
}
usage_error() { printf 'error: %s\n\n' "$1" >&2; usage >&2; exit 2; }
need_value() { [[ $# -ge 2 && $2 != --* ]] || usage_error "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  if [[ $1 == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case $1 in
    --out)                need_value "$@"; OUT_DIR=$2; shift 2 ;;
    --export-blueprint)   need_value "$@"; EXPORT_BP+=("$2"); shift 2 ;;
    --permissions-from)   need_value "$@"; PERM_ROLE=$2; shift 2 ;;
    --insecure|-k)        INSECURE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    usage_error "unknown option: $1" ;;
  esac
done

mp_init

# get_list PATH KEY -> the list response; warns when the appliance has more items than one page
get_list() {
  local path=$1 key=$2 sep="?" res
  [[ $path == *\?* ]] && sep="&"
  res=$(api GET "${path}${sep}max=1000")
  if jq -e --arg k "$key" '(.meta.total // 0) > ((.[$k] // []) | length)' <<<"$res" >/dev/null; then
    warn "$path: only the first $(jq --arg k "$key" '.[$k] | length' <<<"$res") of $(jq '.meta.total' <<<"$res") items were read."
  fi
  printf '%s' "$res"
}

step "Reading from $BASE_URL"
WHOAMI=$(api GET /api/whoami)
[[ $(jq -r '.isMasterAccount // false' <<<"$WHOAMI") == true ]] || die "The token must belong to a master-tenant user (the inventory reads every tenant)."
ok "Connected as '$(jq -r .user.username <<<"$WHOAMI")'"

INV=$(jq -n --arg url "$BASE_URL" --argjson w "$WHOAMI" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{appliance: $url, readAt: $at, user: $w.user.username, masterTenant: ($w.user.account // {id: $w.user.accountId})}')
add() { INV=$(jq --arg k "$1" --argjson v "$2" '.[$k] = $v' <<<"$INV"); }

# --- tenants ---
RES=$(get_list /api/accounts accounts)
add tenants "$(jq '[.accounts[] | {id, name, subdomain, baseRole: (.role.authority // .role.name // null)}]' <<<"$RES")"
ok "Tenants: $(jq '.tenants | length' <<<"$INV")"

# --- clouds with resource pools, datastores and networks ---
RES=$(get_list /api/zones zones)
CLOUDS="[]"
while IFS= read -r z; do
  zid=$(jq -r .id <<<"$z")
  POOLS=$(get_list "/api/zones/$zid/resource-pools" resourcePools)
  DSS=$(get_list "/api/zones/$zid/data-stores" datastores)
  NETS=$(get_list "/api/networks$(qs zoneId "$zid")" networks)
  CLOUDS=$(jq --argjson z "$z" --argjson p "$POOLS" --argjson d "$DSS" --argjson n "$NETS" '
    def tl($o; $map): ([($o.tenants // [])[] | .name // (.id|tostring)] + [($map[($o.id|tostring)] // [])[] | .name // (.id|tostring)]) | unique;
    . + [{id: $z.id, name: $z.name, type: ($z.zoneType.code // $z.zoneType.name // null), visibility: $z.visibility,
          ownerTenant: ($z.account.name // $z.owner.name // null), ownerTenantId: ($z.account.id // $z.accountId // $z.owner.id // null),
          resourcePools: [$p.resourcePools[]? | {id, name, poolRef: "pool-\(.id)", visibility, sharedWith: tl(.; ($p.tenants // {}))}],
          datastores:    [$d.datastores[]? | {id, name, visibility, sharedWith: tl(.; ($d.tenants // {}))}],
          networks:      [$n.networks[]? | {id, name, visibility, sharedWith: tl(.; {})}]}]' <<<"$CLOUDS")
done < <(jq -c '.zones[]' <<<"$RES")
add clouds "$CLOUDS"
ok "Clouds: $(jq '.clouds | length' <<<"$INV")"

# --- groups (master tenant) ---
RES=$(get_list /api/groups groups)
add groups "$(jq '[.groups[] | {id, name, clouds: [.zones[]?.name]}]' <<<"$RES")"

# --- roles and feature-permission codes ---
RES=$(get_list "/api/roles$(qs roleType account)" roles)
add tenantRoles "$(jq '[.roles[] | {id, name: (.authority // .name)}]' <<<"$RES")"
RES=$(get_list "/api/roles$(qs roleType user)" roles)
add userRoles "$(jq '[.roles[] | {id, name: (.authority // .name), multitenant: (.multitenant // false)}]' <<<"$RES")"
PERM_ROLE_ID=$(jq -r --arg n "${PERM_ROLE:-Tenant Admin}" '[.roles[] | select(((.authority // .name)|ascii_downcase) == ($n|ascii_downcase))][0].id // .roles[0].id // empty' <<<"$RES")
if [[ -n $PERM_ROLE_ID ]]; then
  RES=$(api GET "/api/roles/$PERM_ROLE_ID")
  add featurePermissions "$(jq '{fromRole: (.role.authority // .role.name), codes: [.featurePermissions[]? | {code, name, access}]}' <<<"$RES")"
  add personas "$(jq '[.personaPermissions[]? | {code, name}]' <<<"$RES")"
fi
ok "Roles: $(jq '.tenantRoles | length' <<<"$INV") tenant, $(jq '.userRoles | length' <<<"$INV") user"

# --- provisioning building blocks ---
RES=$(get_list /api/library/instance-types instanceTypes)
add instanceTypes "$(jq '[.instanceTypes[] | {id, code, name}]' <<<"$RES")"
RES=$(get_list /api/library/layouts instanceTypeLayouts)
add layouts "$(jq '[.instanceTypeLayouts[] | {id, name, code, instanceType: (.instanceType.code // null)}]' <<<"$RES")"
RES=$(get_list /api/virtual-images virtualImages)
add images "$(jq '[.virtualImages[] | {id, name, visibility, imageType}]' <<<"$RES")"
RES=$(get_list /api/service-plans servicePlans)
add plans "$(jq '[.servicePlans[] | {id, name, code}]' <<<"$RES")"
ok "Layouts: $(jq '.layouts|length' <<<"$INV"), images: $(jq '.images|length' <<<"$INV"), plans: $(jq '.plans|length' <<<"$INV")"

# --- governance and library already on the appliance ---
RES=$(api GET /api/policy-types)
add policyTypes "$(jq '[.policyTypes[] | {code, name}]' <<<"$RES")"
RES=$(get_list /api/policies policies)
add policies "$(jq '[.policies[] | {id, name, type: .policyType.code, scope: (.refType // "global"), enabled}]' <<<"$RES")"
RES=$(get_list /api/library/option-type-lists optionTypeLists)
add optionLists "$(jq '[.optionTypeLists[] | {id, name, type}]' <<<"$RES")"
RES=$(get_list /api/library/option-types optionTypes)
add inputs "$(jq '[.optionTypes[] | {id, name, fieldName, type}]' <<<"$RES")"
RES=$(get_list /api/catalog-item-types catalogItemTypes)
add catalogItems "$(jq '[.catalogItemTypes[] | {id, name, type}]' <<<"$RES")"
BPS=$(get_list /api/blueprints blueprints)
add blueprints "$(jq '[.blueprints[] | {id, name, type}]' <<<"$BPS")"
ok "Policy types available: $(jq -r '[.policyTypes[].code] | join(", ")' <<<"$INV")"

# ---------------------------------------------------------------------------
# Write the output
# ---------------------------------------------------------------------------
HOST=$(sed -E 's#^https?://##; s#[:/].*$##' <<<"$BASE_URL")
DEST="$OUT_DIR/$HOST-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
umask 022
jq . <<<"$INV" > "$DEST/inventory.json"

# Summary tables
{
  printf 'Morpheus inventory - %s - read %s as %s\n' "$BASE_URL" "$(jq -r .readAt <<<"$INV")" "$(jq -r .user <<<"$INV")"
  jq -r '
    def row($c): $c | map(tostring) | join("\t");
    def section($t): "## \($t)";
    section("Tenants"),
    row(["ID","Name","Subdomain","Base role"]),
    (.tenants[] | row([.id, .name, (.subdomain // "-"), (.baseRole // "-")])),
    (.clouds[] |
      section("Cloud \(.name) (ID \(.id), \(.type // "?"), \(.visibility), owner \(.ownerTenant // "?"))"),
      row(["Kind","ID","Name","Visibility","Shared with"]),
      (.resourcePools[] | row(["resourcePool", .id, .name, (.visibility // "-"), (.sharedWith | join(", ") | if . == "" then "-" else . end)])),
      (.datastores[]    | row(["datastore", .id, .name, (.visibility // "-"), (.sharedWith | join(", ") | if . == "" then "-" else . end)])),
      (.networks[]      | row(["network", .id, .name, (.visibility // "-"), (.sharedWith | join(", ") | if . == "" then "-" else . end)]))),
    section("Groups (master tenant)"), row(["ID","Name","Clouds"]),
    (.groups[] | row([.id, .name, (.clouds | join(", "))])),
    section("Tenant roles (copy-from templates for tenant.role.copyFrom)"), row(["ID","Name"]),
    (.tenantRoles[] | row([.id, .name])),
    section("User roles"), row(["ID","Name","Multitenant"]),
    (.userRoles[] | row([.id, .name, .multitenant])),
    section("Feature-permission codes (for roles[].features) - from role \(.featurePermissions.fromRole // "-")"),
    row(["Code","Name","Access in that role"]),
    ((.featurePermissions.codes // [])[] | row([.code, .name, .access])),
    section("Instance types"), row(["ID","Code","Name"]), (.instanceTypes[] | row([.id, .code, .name])),
    section("Layouts"), row(["ID","Name","Instance type"]), (.layouts[] | row([.id, .name, (.instanceType // "-")])),
    section("Virtual images"), row(["ID","Name","Visibility","Type"]), (.images[] | row([.id, .name, (.visibility // "-"), (.imageType // "-")])),
    section("Service plans"), row(["ID","Name","Code"]), (.plans[] | row([.id, .name, (.code // "-")])),
    section("Policy types available on this appliance"), row(["Code","Name"]), (.policyTypes[] | row([.code, .name])),
    section("Existing policies (master tenant)"), row(["ID","Name","Type","Scope"]), (.policies[] | row([.id, .name, .type, .scope])),
    section("Existing option lists"), row(["ID","Name","Type"]), (.optionLists[] | row([.id, .name, (.type // "-")])),
    section("Existing inputs"), row(["ID","Name","Field name","Type"]), (.inputs[] | row([.id, .name, (.fieldName // "-"), (.type // "-")])),
    section("Existing catalog items"), row(["ID","Name","Type"]), (.catalogItems[] | row([.id, .name, (.type // "-")])),
    section("Existing blueprints"), row(["ID","Name","Type"]), (.blueprints[] | row([.id, .name, (.type // "-")]))
  ' <<<"$INV" | awk -F'\t' '
    function flush(   i, j, line) {
      for (i = 1; i <= n; i++) {
        line = ""
        for (j = 1; j <= nf[i]; j++) line = line sprintf("%-" (w[j] + 2) "s", cell[i, j])
        sub(/ +$/, "", line); print line
      }
      n = 0; split("", w)
    }
    /^## / { flush(); print ""; print; next }
    { n++; nf[n] = NF; for (j = 1; j <= NF; j++) { cell[n, j] = $j; if (length($j) > w[j]) w[j] = length($j) } }
    END { flush() }'
  printf '\nNote: lists show what the master tenant sees. Images or plans that are Private are not visible to\nsub-tenants unless they are shared.\n'
} > "$DEST/summary.txt"

# Starter config with real names from this appliance
jq '
  def first_or($a; $d): if ($a | length) > 0 then $a[0] else $d end;
  (first_or([.clouds[] | select((.type // "") | test("mvm|hvm|kvm"; "i"))]; first_or(.clouds; {name: "CHANGE-ME", resourcePools: [], datastores: [], networks: []}))) as $c
  | (first_or($c.resourcePools; {name: "CHANGE-ME"}).name) as $pool
  | (first_or($c.datastores; {name: "CHANGE-ME"}).name) as $ds
  | (first_or($c.networks; {name: "CHANGE-ME"}).name) as $net
  | (first_or([.layouts[] | select((.instanceType // "") == "mvm")]; first_or(.layouts; {name: "CHANGE-ME"})).name) as $layout
  | (first_or([.images[] | select(.visibility == "public")]; first_or(.images; {name: "CHANGE-ME"})).name) as $image
  | ([.plans[:2][] | .name] | if length == 0 then ["CHANGE-ME"] else . end) as $plans
  | {
    tenant: {name: "Customer", subdomain: "customer", description: "Customer PoC", currency: "USD",
             role: {name: "Customer Tenant Role", copyFrom: (first_or(.tenantRoles; {name: "Tenant Admin"}).name)}},
    cloud: {name: $c.name, mode: "shared", share: {resourcePools: [$pool], datastores: [$ds], networks: [$net]}},
    admin: {username: "customer_admin", email: "admin@customer.example", firstName: "Customer", lastName: "Admin",
            role: "Tenant Admin", roleCopyFrom: "Tenant Admin"},
    groups: ["Customer-Dev"],
    roles: [
      {name: "Customer Approver", copyFrom: "Tenant Admin", groups: "all", defaultPersona: "standard",
       features: {"operations-approvals": "full"}, catalogItems: "all"},
      {name: "Customer Requester", groups: ["Customer-Dev"], defaultPersona: "serviceCatalog",
       features: {"service-catalog": "full", "service-catalog-dashboard": "full", "service-catalog-inventory": "full"},
       catalogItems: ["Linux VM", "3-Tier App"]}],
    users: [
      {username: "customer_approver", email: "approver@customer.example", role: "Customer Approver"},
      {username: "customer_dev1", email: "dev1@customer.example", role: "Customer Requester"}],
    tags: [{name: "Application", values: ["App-1", "App-2"]}, {name: "CostCenter", label: "Cost Center", values: ["CC-1001", "CC-2002"]}],
    catalog: {
      inputPrefix: "Customer",
      vm: {name: "Linux VM", group: "Customer-Dev", layout: $layout, image: $image, network: $net,
           resourcePool: $pool, datastore: $ds, plans: $plans, defaultDiskGB: 40,
           staticTags: {Environment: "PoC", ManagedBy: "Self-Service"}},
      threeTier: {name: "3-Tier App", group: "Customer-Dev", network: $net, resourcePool: $pool, datastore: $ds,
        tiers: [
          {name: "Web", linkTo: ["App"], layout: $layout, image: $image, plan: $plans[0], diskGB: 40},
          {name: "App", linkTo: ["DB"],  layout: $layout, image: $image, plan: $plans[-1], diskGB: 60},
          {name: "DB",  linkTo: [],      layout: $layout, image: $image, plan: $plans[-1], diskGB: 100}],
        staticTags: {Environment: "PoC"}}},
    policies: {
      naming: {pattern: "cust-${sequence}", enforcement: "user", autoResolveConflicts: true, scope: "global"},
      approval: {scope: {role: "Customer Requester"}, eachUser: true},
      tagEnforcement: {strict: true, scope: "global"},
      quotas: [
        {name: "Requester quota", scope: {role: "Customer Requester"}, eachUser: true, maxVms: 5, maxCores: 16, maxMemoryGB: 64, maxStorageGB: 500},
        {name: "Dev group quota", scope: {group: "Customer-Dev"}, maxVms: 20}]}
  }' "$DEST/inventory.json" > "$DEST/starter-config.json"

# Blueprint exports
for name in ${EXPORT_BP[@]+"${EXPORT_BP[@]}"}; do
  bp=$(find_by name "$name" blueprints <<<"$BPS")
  [[ -n $bp ]] || die "Blueprint '$name' was not found. Existing: $(jq -r '[.blueprints[].name] | join(", ")' <<<"$BPS")"
  mkdir -p "$DEST/blueprints"
  full=$(api GET "/api/blueprints/$(jq -r .id <<<"$bp")")
  jq '.blueprint | {name, type, tiers: (.config.tiers // .tiers)}' <<<"$full" > "$DEST/blueprints/$(slug "$name").json"
  ok "Exported blueprint '$name' to $DEST/blueprints/$(slug "$name").json"
done

printf '\n%s================================================================%s\n' "$C_CYAN" "$C_OFF"
printf '%s INVENTORY SAVED%s  %s\n' "$C_GREEN" "$C_OFF" "$DEST"
printf ' summary.txt          read this first\n'
printf ' inventory.json       the same data as JSON\n'
printf ' starter-config.json  copy to customers/<name>.json and edit\n'
printf '%s================================================================%s\n' "$C_CYAN" "$C_OFF"

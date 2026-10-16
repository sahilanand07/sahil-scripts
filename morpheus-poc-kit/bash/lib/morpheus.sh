# shellcheck shell=bash
#
# lib/morpheus.sh - shared helpers for the morpheus-poc-kit bash scripts.
# Source it from a script; it does nothing on its own.
#
# Provides: output helpers, environment / TLS setup, an API client with a master and a tenant
# context, OAuth login as a tenant user, name-or-ID resolution, confirmation prompts, password
# generation and the run manifest (state file) used by teardown.
#
# Requires bash 4.4+, curl 7.55+, jq 1.6+.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # colour variables are used by the scripts that source this file
if [[ -t 1 ]]; then
  C_CYAN=$'\e[36m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM="" C_BOLD="" C_OFF=""
fi

step() { printf '\n%s==> %s%s\n' "$C_CYAN" "$1" "$C_OFF"; }
ok()   { printf '    %s[ok]%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '    %s[warn] %s%s\n' "$C_YELLOW" "$1" "$C_OFF"; }
plan() { printf '    %s[plan] %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$1" "$C_OFF" >&2; }
die()  {
  printf '\n%s[error] %s%s\n' "$C_RED" "$1" "$C_OFF" >&2
  printf '%s        %s%s\n' "$C_RED" "${MP_DIE_HINT:-Fix the cause and re-run; completed steps are reused.}" "$C_OFF" >&2
  exit 1
}

# done_msg DONE_TEXT PLANNED_TEXT -> [ok] in a real run, [plan] in a dry run
done_msg() { if [[ ${DRY_RUN:-0} == 1 ]]; then plan "$2"; else ok "$1"; fi; }
fmt_id()   { if [[ -z ${1:-} || $1 == 0 ]]; then printf 'new'; else printf 'ID %s' "$1"; fi; }
redact()   { sed -E 's/"(password|passwordConfirmation)"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"/"\1":"********"/g' <<<"$1"; }

# ---------------------------------------------------------------------------
# Environment, TLS and the API client
# ---------------------------------------------------------------------------
# mp_init: checks tools and environment, prepares the private work directory and curl options.
# Uses: MORPHEUS_URL, MORPHEUS_TOKEN, MORPHEUS_SKIP_TLS_VERIFY, MORPHEUS_CA_CERT, INSECURE (0/1).
mp_init() {
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) \
    || die "bash 4.4 or newer is required (found $BASH_VERSION)."
  command -v curl >/dev/null || die "curl is required."
  command -v jq >/dev/null   || die "jq is required."

  BASE_URL=${MORPHEUS_URL:-}
  BASE_URL=${BASE_URL%/}
  [[ -n $BASE_URL ]] || die "Set MORPHEUS_URL (e.g. https://vme-manager.example.local)."
  [[ -n ${MORPHEUS_TOKEN:-} ]] || die "Set MORPHEUS_TOKEN to the API access token of a master-tenant admin."
  [[ $BASE_URL == https://* ]] || warn "MORPHEUS_URL is not https:// - credentials will be sent unencrypted."

  # Secrets go into private files so they never appear in the process list.
  umask 077
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  printf 'Authorization: Bearer %s\n' "$MORPHEUS_TOKEN" > "$WORKDIR/master.hdr"
  CTX=master
  CTX_HDR="$WORKDIR/master.hdr"

  CURL_BASE=(-sS --connect-timeout 15 --max-time 180)

  # -------------------------------------------------------------------------
  # SSL / TLS certificate handling
  # -------------------------------------------------------------------------
  # Lab appliances usually present a self-signed certificate, which makes curl fail with
  # "SSL certificate problem: self-signed certificate" (curl exit code 60). Two ways around it:
  #   - trust the appliance CA (safer):  MORPHEUS_CA_CERT=/path/to/appliance-ca.pem
  #   - ignore certificate errors:       --insecure, or MORPHEUS_SKIP_TLS_VERIFY=true
  # Never ignore certificate errors against a production appliance.
  if [[ -n ${MORPHEUS_CA_CERT:-} ]]; then
    [[ -r $MORPHEUS_CA_CERT ]] || die "MORPHEUS_CA_CERT points to '$MORPHEUS_CA_CERT', which is not a readable file."
    CURL_BASE+=(--cacert "$MORPHEUS_CA_CERT")
  fi
  if [[ ${INSECURE:-0} == 1 || ${MORPHEUS_SKIP_TLS_VERIFY:-} =~ ^(1|[Tt]rue|TRUE|[Yy]es|YES)$ ]]; then
    CURL_BASE+=(-k)
    warn "SSL certificate errors are being IGNORED (lab mode). Do not use this against production."
  fi
}

# use_ctx master|tenant - which identity the next api calls use
use_ctx() {
  case $1 in
    master) CTX=master; CTX_HDR="$WORKDIR/master.hdr" ;;
    tenant) [[ -f $WORKDIR/tenant.hdr ]] || die "Internal error: not logged in to the tenant yet."
            CTX=tenant; CTX_HDR="$WORKDIR/tenant.hdr" ;;
    *) die "Internal error: unknown context '$1'" ;;
  esac
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# qs key value [key value ...] -> ?key=value&...
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

# api METHOD PATH [JSON_BODY] -> prints the response JSON; exits the script on any error.
# In a dry run, anything other than GET is printed instead of sent and returns {}.
api() {
  local method=$1 path=$2 body=${3-} code out rc=0
  if [[ $method != GET && ${DRY_RUN:-0} == 1 ]]; then
    dim "    [dry-run] $method ${path%%\?*}  (as $CTX)"
    if [[ -n $body ]]; then dim "              $(redact "$body")"; fi
    printf '{}'
    return 0
  fi
  out="$WORKDIR/response.json"
  if [[ -n $body ]]; then
    code=$(curl "${CURL_BASE[@]}" -H "@$CTX_HDR" -H 'Accept: application/json' -X "$method" \
             -H 'Content-Type: application/json' --data-binary @- -o "$out" -w '%{http_code}' \
             "$BASE_URL$path" <<<"$body") || rc=$?
  else
    code=$(curl "${CURL_BASE[@]}" -H "@$CTX_HDR" -H 'Accept: application/json' -X "$method" \
             -o "$out" -w '%{http_code}' "$BASE_URL$path") || rc=$?
  fi
  if (( rc != 0 )); then curl_failed "$rc"; fi
  if [[ $code == 401 ]]; then
    die "API $method ${path%%\?*} was refused (HTTP 401). The $CTX token is invalid or expired."
  fi
  if (( code >= 400 )); then
    die "API $method ${path%%\?*} failed (HTTP $code, as $CTX): $(redact "$(head -c 2000 "$out")")"
  fi
  if [[ ! -s $out ]]; then printf '{}'; return 0; fi
  if ! jq -e . "$out" >/dev/null 2>&1; then
    die "API $method ${path%%\?*} returned a non-JSON response (HTTP $code). Is MORPHEUS_URL the appliance URL?"
  fi
  if jq -e 'type == "object" and has("success") and .success == false' "$out" >/dev/null; then
    die "API $method ${path%%\?*} was rejected: $(redact "$(head -c 2000 "$out")")"
  fi
  cat "$out"
}

# tenant_login PREFIX USERNAME PASSWORD - OAuth password grant as a sub-tenant user; switches to the tenant context.
# PREFIX is the tenant subdomain, or its ID when it has none (the API's own default).
tenant_login() {
  local prefix=$1 user=$2 pw=$3 out="$WORKDIR/oauth.json" code rc=0 token
  printf '%s' "$pw" > "$WORKDIR/pw.txt"
  code=$(curl "${CURL_BASE[@]}" -X POST -H 'Accept: application/json' \
           --data-urlencode grant_type=password --data-urlencode scope=write \
           --data-urlencode client_id=morph-api --data-urlencode "username=${prefix}\\${user}" \
           --data-urlencode "password@$WORKDIR/pw.txt" \
           -o "$out" -w '%{http_code}' "$BASE_URL/oauth/token") || rc=$?
  rm -f "$WORKDIR/pw.txt"
  if (( rc != 0 )); then curl_failed "$rc"; fi
  token=$(jq -r '.access_token // empty' "$out" 2>/dev/null || true)
  if [[ $code != 200 || -z $token ]]; then
    die "Could not sign in as '${prefix}\\${user}' (HTTP $code): $(jq -r '.error_description // .msg // .error // "no details"' "$out" 2>/dev/null). Check TENANT_ADMIN_PASSWORD, or re-run with --reset-admin-password."
  fi
  printf 'Authorization: Bearer %s\n' "$token" > "$WORKDIR/tenant.hdr"
  use_ctx tenant
}

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------
# find_by FIELD VALUE LIST_KEY  (JSON on stdin) -> first object whose FIELD equals VALUE (case-insensitive)
find_by() {
  jq -c --arg f "$1" --arg v "$2" --arg k "$3" \
    '[.[$k][]? | select(((.[$f] // "") | tostring | ascii_downcase) == ($v | ascii_downcase))][0] // empty'
}

# owner_id (JSON on stdin) -> tenant ID that owns the object, or nothing
owner_id() { jq -r '.account.id // .accountId // .owner.id // empty'; }

# pick REF LABEL LIST_KEY (list JSON on stdin) -> the matching object.
# REF is an ID (digits) or a name (case-insensitive). Dies with the available names if nothing matches.
pick() {
  local ref=$1 label=$2 key=$3 list match count
  list=$(cat)
  if [[ $ref =~ ^[0-9]+$ ]]; then
    match=$(jq -c --argjson id "$ref" --arg k "$key" '[.[$k][]? | select(.id == $id)][0] // empty' <<<"$list")
  else
    count=$(jq --arg v "$ref" --arg k "$key" '[.[$k][]? | select(((.name // "") | ascii_downcase) == ($v | ascii_downcase))] | length' <<<"$list")
    if (( count > 1 )); then
      die "$label '$ref' matches $count objects. Use its ID instead: $(jq -r --arg v "$ref" --arg k "$key" '[.[$k][] | select((.name|ascii_downcase) == ($v|ascii_downcase)) | "\(.id)"] | join(", ")' <<<"$list")"
    fi
    match=$(jq -c --arg v "$ref" --arg k "$key" '[.[$k][]? | select(((.name // "") | ascii_downcase) == ($v | ascii_downcase))][0] // empty' <<<"$list")
  fi
  if [[ -z $match ]]; then
    die "$label '$ref' was not found. Available: $(jq -r --arg k "$key" '[.[$k][]? | "\(.name) (\(.id))"] | .[:25] | join(", ") | if . == "" then "none" else . end' <<<"$list")"
  fi
  printf '%s' "$match"
}

# ---------------------------------------------------------------------------
# Prompts and passwords
# ---------------------------------------------------------------------------
confirm_change() {
  warn "$1"
  if [[ ${DRY_RUN:-0} == 1 || ${ASSUME_YES:-0} == 1 ]]; then return 0; fi
  [[ -t 0 ]] || die "This change needs confirmation. Re-run with --yes to approve it non-interactively."
  local answer
  read -rp "    Proceed? [y/N] " answer
  [[ $answer =~ ^([yY]|[yY][eE][sS])$ ]] || die "Stopped at your request. Nothing after this point was changed."
}

gen_password() {
  local p special='[!@#%^*_=+-]'
  while :; do
    p=$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9!@#%^*_=+-' </dev/urandom | head -c 20 || true)
    if [[ ${#p} -eq 20 && $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] && $p =~ $special ]]; then break; fi
  done
  printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# Run manifest (state file)
# ---------------------------------------------------------------------------
# One JSON file per tenant records every object the kit created, reused or changed, in order.
# Teardown walks it backwards. Items: {kind, scope, action, id, name, resource?, cloudId?, from?, to?, at}
# action: created (kit made it), reused (existed already; teardown leaves it), changed (kit modified it).

manifest_init() {   # manifest_init PATH APPLIANCE TENANT_NAME - the file itself is created on the first change
  MANIFEST=$1 MANIFEST_APPLIANCE=$2 MANIFEST_TENANT=$3
  [[ -f $MANIFEST ]] || return 0
  jq -e '.kit == "morpheus-poc-kit"' "$MANIFEST" >/dev/null 2>&1 || die "$MANIFEST is not a morpheus-poc-kit state file."
  local recorded
  recorded=$(jq -r '.appliance // ""' "$MANIFEST")
  if [[ -n $recorded && ${recorded%/} != "${MANIFEST_APPLIANCE%/}" ]]; then
    die "$MANIFEST was written for $recorded, not $MANIFEST_APPLIANCE. Use --state-dir to keep separate state per appliance."
  fi
}

manifest_ensure() {
  [[ -f $MANIFEST ]] && return 0
  mkdir -p "$(dirname "$MANIFEST")"
  jq -n --arg a "$MANIFEST_APPLIANCE" --arg t "$MANIFEST_TENANT" '{kit: "morpheus-poc-kit", manifestVersion: 1, appliance: $a,
    tenantName: $t, tenantId: null, subdomain: null, masterTenantId: null, items: [], updated: null}' > "$MANIFEST"
}

manifest_set() {    # manifest_set KEY JSON_VALUE  (top-level field)
  [[ ${DRY_RUN:-0} == 1 || -z ${MANIFEST:-} ]] && return 0
  manifest_ensure
  local tmp="$MANIFEST.tmp"
  jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# manifest_add KIND SCOPE ACTION ID NAME [EXTRA_JSON]
# An item keeps "created" once recorded, so a re-run never downgrades something the kit made to "reused".
manifest_add() {
  [[ ${DRY_RUN:-0} == 1 || -z ${MANIFEST:-} ]] && return 0
  [[ -n ${4:-} && $4 != 0 ]] || return 0
  manifest_ensure
  local extra=${6:-'{}'} tmp="$MANIFEST.tmp" now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg kind "$1" --arg scope "$2" --arg action "$3" --argjson id "$4" --arg name "$5" \
     --argjson extra "$extra" --arg now "$now" '
    ($extra.resource // null) as $res
    | (.items | map(.kind == $kind and .id == $id and (.resource // null) == $res) | index(true)) as $i
    | if $i == null then .items += [{kind: $kind, scope: $scope, action: $action, id: $id, name: $name, at: $now} + $extra]
      elif .items[$i].action == "created" then .
      else .items[$i] += ({action: $action, name: $name} + $extra) end
    | .updated = $now' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# manifest_action KIND ID [RESOURCE] -> created | reused | changed | (nothing)
manifest_action() {
  [[ -n ${MANIFEST:-} && -f $MANIFEST ]] || return 0
  jq -r --arg kind "$1" --argjson id "$2" --arg res "${3:-}" \
    '[.items[] | select(.kind == $kind and .id == $id and ((.resource // "") == $res))][0].action // empty' "$MANIFEST"
}

# record KIND SCOPE ID NAME WAS_CREATED(0/1) - created when we made it, otherwise reused (unless already known)
record() {
  if [[ $5 == 1 ]]; then manifest_add "$1" "$2" created "$3" "$4"; else manifest_add "$1" "$2" reused "$3" "$4"; fi
}

# slug TEXT -> lowercase, letters/digits/hyphens (used for manifest file names and catalog codes)
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

# field_name TEXT -> camel-ish identifier for input field names, e.g. "Cost Center" -> CostCenter
field_name() { printf '%s' "$1" | sed -E 's/[^A-Za-z0-9]+/ /g' | awk '{for(i=1;i<=NF;i++){printf "%s%s", toupper(substr($i,1,1)), substr($i,2)}}'; }

# join_by SEP ITEM... -> items joined with SEP (SEP may be several characters)
join_by() { local sep=$1 out="" first=1; shift; for x in "$@"; do if [[ $first == 1 ]]; then out=$x; first=0; else out+="$sep$x"; fi; done; printf '%s' "$out"; }

# api_status METHOD PATH [JSON_BODY] - like api, but HTTP errors don't stop the script.
# Sets API_CODE (HTTP status) and API_BODY. Used by teardown, where "already gone" (404) is fine.
api_status() {
  local method=$1 path=$2 body=${3-} out="$WORKDIR/response.json" rc=0
  if [[ $method != GET && ${DRY_RUN:-0} == 1 ]]; then
    dim "    [dry-run] $method ${path%%\?*}  (as $CTX)"
    if [[ -n $body ]]; then dim "              $(redact "$body")"; fi
    API_CODE=200 API_BODY='{}'
    return 0
  fi
  if [[ -n $body ]]; then
    API_CODE=$(curl "${CURL_BASE[@]}" -H "@$CTX_HDR" -H 'Accept: application/json' -X "$method" \
                 -H 'Content-Type: application/json' --data-binary @- -o "$out" -w '%{http_code}' \
                 "$BASE_URL$path" <<<"$body") || rc=$?
  else
    API_CODE=$(curl "${CURL_BASE[@]}" -H "@$CTX_HDR" -H 'Accept: application/json' -X "$method" \
                 -o "$out" -w '%{http_code}' "$BASE_URL$path") || rc=$?
  fi
  if (( rc != 0 )); then curl_failed "$rc"; fi
  API_BODY=$(cat "$out" 2>/dev/null || true)
  [[ -n $API_BODY ]] || API_BODY='{}'
  if [[ $API_CODE == 200 ]] && jq -e 'type == "object" and .success == false' <<<"$API_BODY" >/dev/null 2>&1; then API_CODE=400; fi
}

# api_error_text -> the message of the last api_status call
api_error_text() { jq -r '.msg // .error_description // .error // (.errors | tostring) // "no details"' <<<"$API_BODY" 2>/dev/null || head -c 300 <<<"$API_BODY"; }

# ---------------------------------------------------------------------------
# Tenant lists on shared cloud resources
# ---------------------------------------------------------------------------
# resource_state KIND CLOUD_ID ID -> {path, key, name, visibility, tenants: [ids]} or nothing if not found.
# KIND: resourcePool | datastore | network. Pool tenant lists only come back on the LIST call (a top-level
# "tenants" map keyed by pool ID), so both places are read; a PUT replaces the whole list.
resource_state() {
  local kind=$1 cid=$2 id=$3 res
  case $kind in
    resourcePool)
      res=$(api GET "/api/zones/$cid/resource-pools$(qs max 1000)")
      jq -c --argjson i "$id" --arg p "/api/zones/$cid/resource-pools/$id" '
        ([.resourcePools[]? | select(.id == $i)][0]) as $o
        | if $o == null then empty else
          {path: $p, key: "resourcePool", name: $o.name, visibility: ($o.visibility // "private"),
           tenants: ([($o.tenants // [])[] | .id] + [((.tenants // {})[($i|tostring)] // [])[] | .id] | unique)} end' <<<"$res" ;;
    datastore)
      api_status GET "/api/zones/$cid/data-stores/$id"
      [[ $API_CODE == 200 ]] || return 0
      jq -c --argjson i "$id" --arg p "/api/zones/$cid/data-stores/$id" '
        (.datastore // null) as $o | if $o == null then empty else
        {path: $p, key: "datastore", name: $o.name, visibility: ($o.visibility // "private"),
         tenants: ([($o.tenants // [])[] | .id] + [((.tenants // {})[($i|tostring)] // [])[] | .id] | unique)} end' <<<"$API_BODY" ;;
    network)
      api_status GET "/api/networks/$id"
      [[ $API_CODE == 200 ]] || return 0
      jq -c --arg p "/api/networks/$id" '
        (.network // null) as $o | if $o == null then empty else
        {path: $p, key: "network", name: $o.name, visibility: ($o.visibility // "private"),
         tenants: ([($o.tenants // [])[] | .id] | unique)} end' <<<"$API_BODY" ;;
  esac
}

# resource_set_tenants STATE_JSON TENANT_IDS_JSON - writes the full tenant list back
resource_set_tenants() {
  local st=$1 ids=$2 body
  if [[ $(jq -r .key <<<"$st") == network ]]; then
    body=$(jq -cn --argjson ids "$ids" '{network: {tenants: ($ids | unique | map({id: .}))}}')
  else
    body=$(jq -cn --argjson s "$st" --argjson ids "$ids" '{($s.key): {visibility: $s.visibility}, tenantPermissions: {accounts: ($ids | unique)}}')
  fi
  api PUT "$(jq -r .path <<<"$st")" "$body" >/dev/null
}

#!/usr/bin/env bash
#
# poc-teardown.sh - undo what poc-onboard.sh (or Invoke-PocOnboarding.ps1) built, using its state file.
#
# Only objects the kit CREATED are deleted. Objects it reused are left alone, and changes it made to
# shared infrastructure are reverted precisely:
#   - the tenant is removed from each resource pool / datastore / network it was shared with
#     (other tenants on those resources keep their access);
#   - a cloud assigned to the tenant (dedicated mode) is given back to the master tenant BEFORE the
#     tenant is deleted - deleting a tenant also deletes the clouds assigned to it;
#   - a cloud the kit made Public stays Public unless you pass --restore-cloud-visibility, because
#     other tenants may rely on it by now.
#
# When the kit created the tenant, deleting the tenant removes everything inside it (groups, roles,
# users, inputs, catalog items, blueprints, policies). With --keep-tenant, or when the tenant existed
# before the kit ran, those objects are deleted one by one instead, signed in as the tenant admin.
#
# Environment: MORPHEUS_URL, MORPHEUS_TOKEN (master-tenant admin); TENANT_ADMIN_PASSWORD (only needed
# when objects inside a kept tenant must be deleted and the admin user wasn't created by the kit).

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/morpheus.sh
source "$HERE/lib/morpheus.sh"

CONFIG="" MANIFEST_IN="" STATE_DIR="$HERE/../state" DRY_RUN=0 ASSUME_YES=0 INSECURE=0
REMOVE_RESOURCES=0 RESTORE_VIS=0 KEEP_TENANT=0

usage() {
  cat <<'EOF'
Usage: poc-teardown.sh (--config customers/NAME.json | --manifest state/NAME.json) [options]

  --config FILE                The customer config used for onboarding (finds its state file)
  --manifest FILE              The state file directly
  --dry-run                    Show what would be deleted or reverted, change nothing
  --yes                        Don't ask for confirmation
  --remove-resources           Also delete instances/apps still running in the tenant
                               (without it, a tenant that still has instances is not deleted)
  --keep-tenant                Keep the tenant; delete only the objects the kit created inside it
  --restore-cloud-visibility   Set the cloud back to Private if the kit made it Public
  --state-dir DIR              Where state files are kept (default: <kit>/state)
  --insecure                   Ignore SSL certificate errors (lab appliances only)
  -h, --help                   Show this help
EOF
}
usage_error() { printf 'error: %s\n\n' "$1" >&2; usage >&2; exit 2; }
need_value() { [[ $# -ge 2 && $2 != --* ]] || usage_error "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  if [[ $1 == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case $1 in
    --config)                   need_value "$@"; CONFIG=$2; shift 2 ;;
    --manifest)                 need_value "$@"; MANIFEST_IN=$2; shift 2 ;;
    --state-dir)                need_value "$@"; STATE_DIR=$2; shift 2 ;;
    --dry-run)                  DRY_RUN=1; shift ;;
    --yes|-y)                   ASSUME_YES=1; shift ;;
    --remove-resources)         REMOVE_RESOURCES=1; shift ;;
    --keep-tenant)              KEEP_TENANT=1; shift ;;
    --restore-cloud-visibility) RESTORE_VIS=1; shift ;;
    --insecure|-k)              INSECURE=1; shift ;;
    -h|--help)                  usage; exit 0 ;;
    *)                          usage_error "unknown option: $1" ;;
  esac
done

if [[ -z $MANIFEST_IN ]]; then
  [[ -n $CONFIG ]] || usage_error "--config or --manifest is required"
  [[ -f $CONFIG ]] || usage_error "config file '$CONFIG' not found"
  KEY=$(jq -r '.tenant.subdomain // .tenant.name // empty' "$CONFIG") || usage_error "$CONFIG is not valid JSON"
  MANIFEST_IN="$STATE_DIR/$(slug "$KEY").json"
fi
[[ -f $MANIFEST_IN ]] || die "State file '$MANIFEST_IN' not found - nothing recorded to undo."
M=$(jq -c . "$MANIFEST_IN") || die "$MANIFEST_IN is not valid JSON."
[[ $(jq -r .kit <<<"$M") == morpheus-poc-kit ]] || die "$MANIFEST_IN is not a morpheus-poc-kit state file."

mp_init
MP_DIE_HINT="Fix the cause and re-run teardown; finished steps are skipped. State: $MANIFEST_IN"
RECORDED_URL=$(jq -r '.appliance // ""' <<<"$M")
[[ ${RECORDED_URL%/} == "$BASE_URL" ]] || die "This state file belongs to $RECORDED_URL, but MORPHEUS_URL is $BASE_URL."

TENANT_NAME=$(jq -r .tenantName <<<"$M")
TENANT_ID=$(jq -r '.tenantId // 0' <<<"$M")
SUBDOMAIN=$(jq -r '.subdomain // empty' <<<"$M")
item_action() { jq -r --arg k "$1" '[.items[] | select(.kind == $k)][0].action // empty' <<<"$M"; }
TENANT_CREATED=0; [[ $(item_action tenant) == created ]] && TENANT_CREATED=1
DELETE_TENANT=$(( TENANT_CREATED == 1 && KEEP_TENANT == 0 ? 1 : 0 ))
CREATED_COUNT=$(jq '[.items[] | select(.action == "created")] | length' <<<"$M")
CHANGED_COUNT=$(jq '[.items[] | select(.action == "changed")] | length' <<<"$M")

if [[ $DRY_RUN == 1 ]]; then printf '\n%sDRY RUN - nothing will be deleted or changed.%s\n' "$C_BOLD" "$C_OFF"; fi

step "Checking access"
WHOAMI=$(api GET /api/whoami)
[[ $(jq -r '.isMasterAccount // false' <<<"$WHOAMI") == true ]] || die "MORPHEUS_TOKEN must belong to a user in the MASTER tenant."
ok "Connected as '$(jq -r .user.username <<<"$WHOAMI")'"
if [[ $TENANT_ID != 0 ]]; then
  api_status GET "/api/accounts/$TENANT_ID"
  if [[ $API_CODE == 404 ]]; then
    warn "Tenant '$TENANT_NAME' (ID $TENANT_ID) no longer exists - only the master-side changes will be undone."
    DELETE_TENANT=0; TENANT_GONE=1
  elif [[ $API_CODE != 200 ]]; then
    die "Could not read tenant $TENANT_ID (HTTP $API_CODE): $(api_error_text)"
  fi
fi
TENANT_GONE=${TENANT_GONE:-0}

if [[ $DELETE_TENANT == 1 ]]; then
  confirm_change "Tenant '$TENANT_NAME' (ID $TENANT_ID) will be DELETED with everything inside it, and $CHANGED_COUNT change(s) to shared infrastructure will be reverted."
else
  confirm_change "$CREATED_COUNT object(s) created by the kit for '$TENANT_NAME' will be deleted and $CHANGED_COUNT change(s) reverted. The tenant itself is kept."
fi
[[ $REMOVE_RESOURCES == 0 || $DELETE_TENANT == 0 ]] || warn "--remove-resources: instances and apps in the tenant will be deleted too."

# del PATH LABEL - DELETE that tolerates "already gone"
del() {
  api_status DELETE "$1"
  case $API_CODE in
    200|204) done_msg "Deleted $2" "Would delete $2" ;;
    404)     ok "$2 was already gone" ;;
    *)       die "Could not delete $2 (HTTP $API_CODE): $(api_error_text)" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Objects inside a kept tenant (signed in as its admin)
# ---------------------------------------------------------------------------
TENANT_ITEMS=$(jq -c '[.items[] | select(.scope == "tenant" and .action == "created")] | reverse' <<<"$M")
if [[ $DELETE_TENANT == 0 && $TENANT_GONE == 0 && $(jq length <<<"$TENANT_ITEMS") -gt 0 ]]; then
  step "Objects the kit created inside tenant '$TENANT_NAME'"
  ADMIN_ID=$(jq -r '[.items[] | select(.kind == "adminUser")][0].id // 0' <<<"$M")
  ADMIN_NAME=$(jq -r '[.items[] | select(.kind == "adminUser")][0].name // empty' <<<"$M")
  [[ -n $ADMIN_NAME ]] || die "The state file has no tenant admin, so the kit cannot sign in to the tenant."
  PW=${TENANT_ADMIN_PASSWORD:-}
  if [[ -z $PW && $(item_action adminUser) == created ]]; then
    # The kit made this user, so it may set a fresh password to sign in with.
    PW=$(gen_password)
    if [[ $DRY_RUN == 0 ]]; then
      api PUT "/api/accounts/$TENANT_ID/users/$ADMIN_ID" "$(jq -cn --arg p "$PW" '{user: {password: $p, passwordConfirmation: $p}}')" >/dev/null
      ok "Set a temporary password for '$ADMIN_NAME' to sign in with"
    fi
  fi
  [[ -n $PW ]] || die "Set TENANT_ADMIN_PASSWORD for '$ADMIN_NAME' so the kit can sign in to the tenant."
  if [[ $DRY_RUN == 1 && -z ${TENANT_ADMIN_PASSWORD:-} ]]; then
    while IFS= read -r it; do plan "Would delete $(jq -r .kind <<<"$it") '$(jq -r .name <<<"$it")' (ID $(jq -r .id <<<"$it"))"; done < <(jq -c '.[]' <<<"$TENANT_ITEMS")
  else
    tenant_login "${SUBDOMAIN:-$TENANT_ID}" "$ADMIN_NAME" "$PW"
    while IFS= read -r it; do
      kind=$(jq -r .kind <<<"$it"); id=$(jq -r .id <<<"$it"); label="$kind '$(jq -r .name <<<"$it")' (ID $id)"
      case $kind in
        policy)      del "/api/policies/$id" "$label" ;;
        catalogItem) del "/api/catalog-item-types/$id" "$label" ;;
        blueprint)   del "/api/blueprints/$id" "$label" ;;
        input)       del "/api/library/option-types/$id" "$label" ;;
        optionList)  del "/api/library/option-type-lists/$id" "$label" ;;
        user)        del "/api/users/$id" "$label" ;;
        role)        del "/api/roles/$id" "$label" ;;
        group)       del "/api/groups/$id" "$label" ;;
        *)           warn "Unknown item kind '$kind' - skipped" ;;
      esac
    done < <(jq -c '.[]' <<<"$TENANT_ITEMS")
    use_ctx master
  fi
fi

# ---------------------------------------------------------------------------
# 2. Shared infrastructure: un-share resources, give a dedicated cloud back
# ---------------------------------------------------------------------------
SHARES=$(jq -c '[.items[] | select(.kind == "share" and .action == "changed")] | reverse' <<<"$M")
if [[ $(jq length <<<"$SHARES") -gt 0 && $TENANT_ID != 0 ]]; then
  step "Removing the tenant from shared resources"
  while IFS= read -r it; do
    kind=$(jq -r .resource <<<"$it"); id=$(jq -r .id <<<"$it"); cid=$(jq -r .cloudId <<<"$it")
    label="$kind '$(jq -r .name <<<"$it")' (ID $id)"
    st=$(resource_state "$kind" "$cid" "$id")
    if [[ -z $st ]]; then ok "$label no longer exists"; continue; fi
    if ! jq -e --argjson t "$TENANT_ID" '.tenants | index($t) != null' <<<"$st" >/dev/null; then
      ok "$label is no longer shared with the tenant"; continue
    fi
    resource_set_tenants "$st" "$(jq -c --argjson t "$TENANT_ID" '.tenants - [$t]' <<<"$st")"
    done_msg "$label no longer shared with the tenant ($(jq --argjson t "$TENANT_ID" '.tenants - [$t] | length' <<<"$st") other tenant(s) keep access)" \
             "Would remove the tenant from $label"
  done < <(jq -c '.[]' <<<"$SHARES")
fi

OWNER=$(jq -c '[.items[] | select(.kind == "cloudOwner" and .action == "changed")][0] // empty' <<<"$M")
if [[ -n $OWNER ]]; then
  step "Giving cloud '$(jq -r .name <<<"$OWNER")' back to the master tenant"
  cid=$(jq -r .id <<<"$OWNER")
  api_status GET "/api/zones/$cid"
  if [[ $API_CODE == 404 ]]; then
    warn "Cloud ID $cid no longer exists."
  else
    current=$(jq -r '.zone.account.id // .zone.accountId // .zone.owner.id // empty' <<<"$API_BODY")
    if [[ $current != "$(jq -r .to <<<"$OWNER")" ]]; then
      ok "Cloud is no longer assigned to the tenant (owner tenant ID ${current:-?}) - left as is"
    else
      api PUT "/api/zones/$cid" "$(jq -c '{zone: {accountId: .from, visibility: (.fromVisibility // "private")}}' <<<"$OWNER")" >/dev/null
      done_msg "Cloud assigned back to tenant ID $(jq -r .from <<<"$OWNER")" "Would assign the cloud back to tenant ID $(jq -r .from <<<"$OWNER")"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. Tenant, tenant admin, tenant role
# ---------------------------------------------------------------------------
if [[ $DELETE_TENANT == 1 ]]; then
  step "Deleting tenant '$TENANT_NAME' (ID $TENANT_ID)"
  Q=""; [[ $REMOVE_RESOURCES == 1 ]] && Q="?removeResources=true"
  api_status DELETE "/api/accounts/$TENANT_ID$Q"
  case $API_CODE in
    200|204) done_msg "Deleted tenant '$TENANT_NAME' and everything inside it" "Would delete tenant '$TENANT_NAME' and everything inside it" ;;
    404)     ok "Tenant was already gone" ;;
    *)       die "Could not delete the tenant (HTTP $API_CODE): $(api_error_text). If it still has instances, remove them or re-run with --remove-resources." ;;
  esac
elif [[ $TENANT_GONE == 0 && $TENANT_ID != 0 ]]; then
  ADMIN=$(jq -c '[.items[] | select(.kind == "adminUser" and .action == "created")][0] // empty' <<<"$M")
  AROLE=$(jq -c '[.items[] | select(.kind == "adminRole" and .action == "created")][0] // empty' <<<"$M")
  if [[ -n $ADMIN || -n $AROLE ]]; then step "Tenant admin created by the kit"; fi
  if [[ -n $ADMIN ]]; then del "/api/accounts/$TENANT_ID/users/$(jq -r .id <<<"$ADMIN")" "admin user '$(jq -r .name <<<"$ADMIN")'"; fi
  if [[ -n $AROLE ]]; then del "/api/roles/$(jq -r .id <<<"$AROLE")" "admin role '$(jq -r .name <<<"$AROLE")'"; fi
fi

TROLE=$(jq -c '[.items[] | select(.kind == "tenantRole" and .action == "created")][0] // empty' <<<"$M")
if [[ -n $TROLE ]]; then
  step "Tenant role '$(jq -r .name <<<"$TROLE")'"
  BASE_ROLE=""
  if [[ $DELETE_TENANT == 0 && $TENANT_GONE == 0 && $TENANT_ID != 0 ]]; then
    BASE_ROLE=$(api GET "/api/accounts/$TENANT_ID" | jq -r '.account.role.id // empty')
  fi
  if [[ -n $BASE_ROLE && $BASE_ROLE == "$(jq -r .id <<<"$TROLE")" ]]; then
    ok "Kept - tenant '$TENANT_NAME' still uses it as its base role"
  else
    del "/api/roles/$(jq -r .id <<<"$TROLE")" "tenant role '$(jq -r .name <<<"$TROLE")'"
  fi
fi

VIS=$(jq -c '[.items[] | select(.kind == "cloudVisibility" and .action == "changed")][0] // empty' <<<"$M")
if [[ -n $VIS ]]; then
  step "Cloud '$(jq -r .name <<<"$VIS")' visibility"
  if [[ $RESTORE_VIS == 1 ]]; then
    api_status GET "/api/zones/$(jq -r .id <<<"$VIS")"
    if [[ $API_CODE == 404 ]]; then warn "Cloud no longer exists."
    else
      api PUT "/api/zones/$(jq -r .id <<<"$VIS")" "$(jq -c '{zone: {visibility: .from}}' <<<"$VIS")" >/dev/null
      done_msg "Visibility set back to $(jq -r .from <<<"$VIS")" "Would set the visibility back to $(jq -r .from <<<"$VIS")"
    fi
  else
    info "The kit made this cloud Public. It stays Public because other tenants may use it now;"
    info "re-run with --restore-cloud-visibility to set it back to $(jq -r .from <<<"$VIS")."
  fi
fi

# ---------------------------------------------------------------------------
# Archive the state file
# ---------------------------------------------------------------------------
printf '\n%s================================================================%s\n' "$C_CYAN" "$C_OFF"
if [[ $DRY_RUN == 1 ]]; then
  printf '%s DRY RUN COMPLETE - nothing was changed%s\n' "$C_GREEN" "$C_OFF"
else
  ARCHIVE="${MANIFEST_IN%.json}.removed-$(date +%Y%m%d-%H%M%S).json"
  mv "$MANIFEST_IN" "$ARCHIVE"
  printf '%s TEARDOWN COMPLETE%s\n' "$C_GREEN" "$C_OFF"
  printf ' %-12s %s\n' "State file:" "archived as $ARCHIVE"
fi
printf '%s================================================================%s\n' "$C_CYAN" "$C_OFF"

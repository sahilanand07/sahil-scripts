#!/usr/bin/env bash
#
# run-tests.sh - end-to-end tests of the bash and PowerShell kits against mock_morpheus.py.
#
#   test/run-tests.sh            run everything (needs python3, openssl, jq, curl, shellcheck, pwsh)
#   PWSH=/path/to/pwsh test/run-tests.sh
#
# The mock is served over HTTPS with a freshly made self-signed certificate, so the TLS options
# (--insecure / -SkipCertificateCheck / MORPHEUS_CA_CERT) are exercised for real.

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/.." && pwd)
PWSH=${PWSH:-pwsh}
PORT=${PORT:-18555}
TOKEN="test-master-token"
T=$(mktemp -d)
trap 'kill "$MOCK_PID" 2>/dev/null; rm -rf "$T"' EXIT

PASS=0 FAIL=0 FAILED=()
ok()   { PASS=$((PASS + 1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  \e[31mFAIL\e[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" | tail -15 | sed 's/^/       | /'; }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
section() { printf '\n\e[36m== %s\e[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# Mock appliance
# ---------------------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
python3 "$HERE/mock_morpheus.py" --port "$PORT" --cert "$T/cert.pem" --key "$T/key.pem" --token "$TOKEN" >"$T/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do curl -sk "https://127.0.0.1:$PORT/__mock/state" >/dev/null 2>&1 && break; sleep 0.2; done

export MORPHEUS_URL="https://127.0.0.1:$PORT" MORPHEUS_TOKEN="$TOKEN"
unset MORPHEUS_SKIP_TLS_VERIFY MORPHEUS_CA_CERT TENANT_ADMIN_PASSWORD
M="https://127.0.0.1:$PORT"
reset()  { curl -sk -X POST "$M/__mock/reset" >/dev/null; }
mstate() { curl -sk "$M/__mock/state"; }
q()      { mstate | jq -e "$1" >/dev/null; }   # q 'jq expression that must be true'
counts() { mstate | jq -c '{acc: (.accounts|length), roles: (.roles|length), users: (.users|length), groups: (.groups|length),
                            ol: (.optionLists|length), ot: (.optionTypes|length), ci: (.catalogItems|length), bp: (.blueprints|length), pol: (.policies|length)}'; }
writes() { curl -sk "$M/__mock/requests" | jq -S '[.requests[] | select(.method != "GET") | {method, path, as,
             body: (.body | if type == "object" then walk(if type == "object" and has("password") then (.password = "X")
                    | (if has("passwordConfirmation") then .passwordConfirmation = "X" else . end) else . end) else . end)}]'; }
# The state that must come back after teardown: the seed, ignoring ID counters and cloud 1's visibility.
baseline() { mstate | jq -S 'del(.next) | .zones["1"].visibility = "x"'; }

B="$KIT/bash"
PSD="$KIT/powershell"
EX="$KIT/customers/example-acme.json"
DED="$HERE/fixtures/dedicated-globex.json"
ps() { local script=$1; shift; "$PWSH" -NoLogo -NoProfile -File "$PSD/$script" "$@"; }

reset; BASE=$(baseline)

# ---------------------------------------------------------------------------
section "Static checks"
# ---------------------------------------------------------------------------
check "bash -n on every bash script" bash -c "for f in '$B'/*.sh '$B'/lib/*.sh '$HERE'/run-tests.sh; do bash -n \"\$f\" || exit 1; done"
if command -v shellcheck >/dev/null; then
  OUT=$(shellcheck -x -S warning "$B"/*.sh "$B"/lib/morpheus.sh 2>&1); [[ -z $OUT ]] && ok "ShellCheck (warnings and above): clean" || bad "ShellCheck" "$OUT"
else bad "ShellCheck is not installed"; fi
OUT=$("$PWSH" -NoProfile -Command "\$bad = 0; foreach (\$f in Get-ChildItem '$PSD' -Include *.ps1,*.psm1 -Recurse) { \$e = \$null; [void][System.Management.Automation.Language.Parser]::ParseFile(\$f.FullName, [ref]\$null, [ref]\$e); foreach (\$x in \$e) { \"\$(\$f.Name): \$(\$x.Message)\"; \$bad++ } }; exit \$bad" 2>&1)
[[ $? == 0 ]] && ok "PowerShell parser: every .ps1/.psm1 parses" || bad "PowerShell parser" "$OUT"
check "example config is valid JSON" jq -e . "$EX"

# ---------------------------------------------------------------------------
section "TLS handling"
# ---------------------------------------------------------------------------
OUT=$("$B/morpheus-inventory.sh" --out "$T/inv-x" 2>&1); [[ $? != 0 && $OUT == *"SSL/TLS error"*"--insecure"* ]] && ok "bash: self-signed cert without --insecure fails with a TLS hint" || bad "bash TLS hint" "$OUT"
OUT=$(ps Get-MorpheusInventory.ps1 -OutDir "$T/inv-x" 2>&1); [[ $? != 0 && $OUT == *"SSL"*"SkipCertificateCheck"* ]] && ok "PowerShell: self-signed cert without -SkipCertificateCheck fails with a TLS hint" || bad "PS TLS hint" "$OUT"
OUT=$(MORPHEUS_CA_CERT="$T/cert.pem" "$B/morpheus-inventory.sh" --out "$T/inv-ca" 2>&1); [[ $? == 0 ]] && ok "bash: MORPHEUS_CA_CERT trusts the appliance CA" || bad "bash CA cert" "$OUT"
OUT=$(MORPHEUS_SKIP_TLS_VERIFY=true ps Get-MorpheusInventory.ps1 -OutDir "$T/inv-env" 2>&1); [[ $? == 0 && $OUT == *"IGNORED"* ]] && ok "PowerShell: MORPHEUS_SKIP_TLS_VERIFY=true works and warns" || bad "PS env skip" "$OUT"
OUT=$(MORPHEUS_TOKEN=wrong "$B/morpheus-inventory.sh" --insecure --out "$T/inv-x" 2>&1); [[ $? != 0 && $OUT == *"HTTP 401"* ]] && ok "bash: a wrong token reports HTTP 401" || bad "bash 401" "$OUT"
OUT=$(MORPHEUS_TOKEN=wrong ps Get-MorpheusInventory.ps1 -SkipCertificateCheck -OutDir "$T/inv-x" 2>&1); [[ $? != 0 && $OUT == *"HTTP 401"* ]] && ok "PowerShell: a wrong token reports HTTP 401" || bad "PS 401" "$OUT"

# ---------------------------------------------------------------------------
section "Inventory"
# ---------------------------------------------------------------------------
OUT=$("$B/morpheus-inventory.sh" --insecure --out "$T/inv-b" 2>&1) && ok "bash inventory runs" || bad "bash inventory" "$OUT"
OUT=$(ps Get-MorpheusInventory.ps1 -SkipCertificateCheck -OutDir "$T/inv-p" 2>&1) && ok "PowerShell inventory runs" || bad "PS inventory" "$OUT"
IB=$(ls -d "$T"/inv-b/*/ | head -1); IP=$(ls -d "$T"/inv-p/*/ | head -1)
check "inventory: summary, JSON and starter config written" test -s "$IB/summary.txt" -a -s "$IB/inventory.json" -a -s "$IB/starter-config.json"
check "inventory: summary shows that prod-cluster is shared with OtherCo" grep -qE 'resourcePool +11 +prod-cluster +private +OtherCo' "$IB/summary.txt"
check "inventory: bash and PowerShell summaries are identical" diff <(sed 1d "$IB/summary.txt") <(sed 1d "$IP/summary.txt")
check "inventory: bash and PowerShell JSON are identical" diff <(jq -S 'del(.readAt)' "$IB/inventory.json") <(jq -S 'del(.readAt)' "$IP/inventory.json")
check "inventory: bash and PowerShell starter configs are identical" diff <(jq -S . "$IB/starter-config.json") <(jq -S . "$IP/starter-config.json")
OUT=$("$B/poc-onboard.sh" --config "$IB/starter-config.json" --dry-run --insecure --state-dir "$T/st-x" 2>&1); [[ $? == 0 ]] && ok "the starter config passes a full pre-flight (dry run)" || bad "starter config dry run" "$OUT"

# ---------------------------------------------------------------------------
section "Config validation and pre-flight (nothing may change)"
# ---------------------------------------------------------------------------
jq '.tenant.name = "" | .roles[1].groups = ["NoSuchGroup"] | .policies.approval.scope = {"role": "Ghost"} | .tags[0].values = []' "$EX" > "$T/bad.json"
OUT=$("$B/poc-onboard.sh" --config "$T/bad.json" --insecure --state-dir "$T/st-x" 2>&1); RC=$?
[[ $RC == 2 && $OUT == *"tenant.name is required"* && $OUT == *"NoSuchGroup"* && $OUT == *"Ghost"* && $OUT == *"at least one value"* ]] && ok "bash: config errors are all listed at once (exit 2)" || bad "bash config errors" "$OUT"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$T/bad.json" -SkipCertificateCheck -StateDir "$T/st-x" 2>&1); RC=$?
[[ $RC == 2 && $OUT == *"tenant.name is required"* && $OUT == *"NoSuchGroup"* && $OUT == *"Ghost"* && $OUT == *"at least one value"* ]] && ok "PowerShell: config errors are all listed at once (exit 2)" || bad "PS config errors" "$OUT"
jq '.catalog.vm.layout = "Ubuntu 99.04"' "$EX" > "$T/typo.json"
S0=$(baseline)
OUT=$("$B/poc-onboard.sh" --config "$T/typo.json" --yes --insecure --state-dir "$T/st-x" 2>&1); [[ $? == 1 && $OUT == *"Layout 'Ubuntu 99.04' was not found. Available: Ubuntu 22.04 (51), Rocky 9 (52)"* ]] && ok "bash: an unknown layout stops pre-flight and lists what exists" || bad "bash typo" "$OUT"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$T/typo.json" -Yes -SkipCertificateCheck -StateDir "$T/st-x" 2>&1); [[ $? == 1 && $OUT == *"Layout 'Ubuntu 99.04' was not found"* ]] && ok "PowerShell: an unknown layout stops pre-flight" || bad "PS typo" "$OUT"
check "pre-flight failures changed nothing on the appliance" diff <(echo "$S0") <(baseline)
check "pre-flight failures left no state file" test ! -e "$T/st-x/acme.json"
curl -sk -X POST "$M/__mock/disable-policy-type?code=provisionApproval" >/dev/null
OUT=$("$B/poc-onboard.sh" --config "$EX" --yes --insecure --state-dir "$T/st-x" 2>&1); [[ $OUT == *"does not offer these policy types: provisionApproval"*"Enterprise licence"* ]] && ok "bash: a missing policy type (licence) is caught in pre-flight" || bad "bash licence" "$OUT"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$EX" -Yes -SkipCertificateCheck -StateDir "$T/st-x" 2>&1); [[ $OUT == *"does not offer these policy types: provisionApproval"* ]] && ok "PowerShell: a missing policy type (licence) is caught in pre-flight" || bad "PS licence" "$OUT"
reset

# ---------------------------------------------------------------------------
section "Dry runs change nothing"
# ---------------------------------------------------------------------------
S0=$(baseline)
OUT=$("$B/poc-onboard.sh" --config "$EX" --dry-run --insecure --state-dir "$T/st-dry" 2>&1); [[ $? == 0 && $OUT == *"DRY RUN COMPLETE"* ]] && ok "bash dry run completes" || bad "bash dry run" "$OUT"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$EX" -DryRun -SkipCertificateCheck -StateDir "$T/st-dry" 2>&1); [[ $? == 0 && $OUT == *"DRY RUN COMPLETE"* ]] && ok "PowerShell dry run completes" || bad "PS dry run" "$OUT"
check "dry runs changed nothing on the appliance" diff <(echo "$S0") <(baseline)
check "dry runs wrote no state file" test ! -e "$T/st-dry"

# ---------------------------------------------------------------------------
section "bash onboarding (shared cloud) - checked object by object"
# ---------------------------------------------------------------------------
export TENANT_ADMIN_PASSWORD='Adm1n-Pass!word'
OUT=$("$B/poc-onboard.sh" --config "$EX" --yes --insecure --state-dir "$T/st-b" 2>&1); [[ $? == 0 && $OUT == *"PoC TENANT READY"* ]] && ok "bash onboarding completes" || bad "bash onboarding" "$OUT"
TID=$(mstate | jq '[.accounts[] | select(.name == "Acme")][0].id')
check "tenant Acme exists with subdomain acme and the kit's tenant role as base role" \
  q "(.accounts[\"$TID\"]) as \$a | \$a.subdomain == \"acme\" and (.roles[(\$a.role|tostring)].authority == \"Acme Tenant Role\")"
check "cloud VME-Cluster-01 is Public" q '.zones["1"].visibility == "public"'
check "tenant role has Full access to the cloud" q '[.roles[] | select(.authority == "Acme Tenant Role")][0].zones["1"] == "full"'
check "pool, datastore and network are shared with Acme AND still with OtherCo" \
  q "(.pools[\"11\"].tenants == [2, $TID]) and (.datastores[\"21\"].tenants == [2, $TID]) and (.networks[\"31\"].tenants == [2, $TID])"
check "admin user is in the tenant with the tenant's Tenant Admin role" \
  q "[.users[] | select(.username == \"acme_admin\")][0] as \$u | \$u.accountId == $TID and (.roles[(\$u.roles[0]|tostring)] | .owner == $TID and .authority == \"Tenant Admin\")"
check "groups Acme-Dev and Acme-Prod are in the tenant and contain the cloud" \
  q "[.groups[] | select(.accountId == $TID) | select(.zones == [1]) | .name] | sort == [\"Acme-Dev\", \"Acme-Prod\"]"
check "Requester role: only Acme-Dev, serviceCatalog persona, approvals none" \
  q "[.roles[] | select(.authority == \"Acme Requester\")][0] as \$r | \$r.globalSiteAccess == \"none\" and (\$r.sites | to_entries | map(.value) == [\"full\"]) and \$r.defaultPersona == \"serviceCatalog\" and \$r.features[\"operations-approvals\"] == \"none\" and \$r.features[\"service-catalog\"] == \"full\""
check "Approver role: all groups, approvals full, copied from Tenant Admin" \
  q '[.roles[] | select(.authority == "Acme Approver")][0] as $r | $r.globalSiteAccess == "full" and $r.features["operations-approvals"] == "full" and $r.features["admin-roles"] == "full"'
check "users have the right roles" \
  q '[.users[] | select(.username == "acme_dev1")][0].roles as $r | (.roles[($r[0]|tostring)].authority == "Acme Requester")'
check "tag option lists hold the configured values" \
  q '[.optionLists[] | select(.name == "Acme - CostCenter values")][0].initialDataset | fromjson | map(.value) == ["CC-1001","CC-2002","CC-3003"]'
check "catalog item: tags from the dropdowns plus static tags; VM name from its input" \
  q '[.catalogItems[] | select(.name == "Linux VM")][0].config as $c | ($c.tags | map(.name)) == ["Application","CostCenter","Environment","ManagedBy"] and $c.instance.name == "<%= customOptions.customVmName %>" and $c.config.resourcePoolId == "pool-11"'
check "catalog item form: VM name, description, plan, disk, then the two tag dropdowns" \
  q '[.catalogItems[] | select(.name == "Linux VM")][0].optionTypes as $ids | [$ids[] as $i | .optionTypes[($i|tostring)].fieldName] == ["customVmName","customDesc","customPlan","customDiskSize","tagApplication","tagCostCenter"]'
check "blueprint: Web->App->DB tiers in the tenant group and cloud" \
  q '[.blueprints[] | select(.name == "3-Tier App")][0].config.tiers as $t | ($t | keys_unsorted) == ["Web","App","DB"] and $t.Web.linkedTiers == ["App"] and ($t.DB.instances[0].groups["Acme-Dev"].clouds["VME-Cluster-01"].volumes[0].size == 100)'
check "blueprint catalog item: App Spec carries app name and tags" \
  q '[.catalogItems[] | select(.type == "blueprint")][0].appSpec | contains("customOptions.customAppName") and contains("customOptions.tagCostCenter") and contains("cloud: \"VME-Cluster-01\"")'
check "Requester can order exactly the two items and the blueprint" \
  q '[.roles[] | select(.authority == "Acme Requester")][0] as $r | $r.globalCatalogItemTypeAccess == "none" and ($r.catalogItemTypes | length) == 2 and ($r.appTemplates | length) == 1'
check "9 policies: naming, approval (role, each user, internal), 2 tag, 5 quota" \
  q "[.policies[] | select(.accountId == $TID)] as \$p | (\$p|length) == 9 and ([\$p[] | select(.code == \"provisionApproval\" and .refType == \"Role\" and .eachUser and .config.accountIntegrationId == \"-100\")] | length) == 1 and ([\$p[] | select(.code == \"tags\")] | length) == 2"
check "tag policy enforces the CostCenter option list" \
  q '[.policies[] | select(.name == "Acme - Tag CostCenter")][0].config.valueListId as $l | .optionLists[($l|tostring)].name == "Acme - CostCenter values"'
check "group quota is scoped to Acme-Dev" \
  q '[.policies[] | select(.name == "Dev group quota - Max VMs")][0] as $p | $p.refType == "ComputeSite" and .groups[($p.refId|tostring)].name == "Acme-Dev"'
check "state file records 36 items" test "$(jq '.items | length' "$T/st-b/acme.json")" == 36
C1=$(counts)

# ---------------------------------------------------------------------------
section "Re-runs create nothing new (and the other language can finish the job)"
# ---------------------------------------------------------------------------
OUT=$("$B/poc-onboard.sh" --config "$EX" --yes --insecure --state-dir "$T/st-b" 2>&1); [[ $? == 0 && $OUT != *"Created"* ]] && ok "bash re-run: everything found, nothing created" || bad "bash re-run" "$OUT"
check "bash re-run: object counts unchanged" test "$(counts)" == "$C1"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$EX" -Yes -SkipCertificateCheck -StateDir "$T/st-b" 2>&1); [[ $? == 0 && $OUT != *"Created"* ]] && ok "PowerShell re-run of the bash-built tenant: nothing created" || bad "PS re-run" "$OUT"
check "PowerShell re-run: object counts unchanged" test "$(counts)" == "$C1"
check "state file: the 31 objects the kit made are still marked created" test "$(jq '[.items[] | select(.action == "created")] | length' "$T/st-b/acme.json")" == 31
jq '.tags[1].values += ["CC-4004"]' "$EX" > "$T/more-values.json"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$T/more-values.json" -Yes -SkipCertificateCheck -StateDir "$T/st-b" 2>&1); [[ $? == 0 && $OUT == *"updated with the values from the config"* ]] && ok "a changed tag value list is pushed to the kit's option list" || bad "option list update" "$OUT"
check "...and the dropdown now offers CC-4004" q '[.optionLists[] | select(.name == "Acme - CostCenter values")][0].initialDataset | fromjson | map(.value) | index("CC-4004") != null'
OUT=$("$B/poc-onboard.sh" --config "$EX" --dry-run --insecure --state-dir "$T/st-b" 2>&1); [[ $? == 0 && $OUT == *"Signed in"* && $OUT == *"Policy 'Acme - Tag CostCenter' exists"* ]] && ok "dry run of an existing tenant signs in and checks every object" || bad "dry run existing" "$OUT"
unset TENANT_ADMIN_PASSWORD
OUT=$("$B/poc-onboard.sh" --config "$EX" --yes --insecure --state-dir "$T/st-b" </dev/null 2>&1); [[ $? == 1 && $OUT == *"--reset-admin-password"* ]] && ok "re-run without the admin password explains how to continue" || bad "no password" "$OUT"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$EX" -Yes -SkipCertificateCheck -StateDir "$T/st-b" -ResetAdminPassword 2>&1); [[ $? == 0 && $OUT == *"Admin password:"* ]] && ok "-ResetAdminPassword sets a new password and continues" || bad "reset password" "$OUT"

# ---------------------------------------------------------------------------
section "bash and PowerShell send identical requests"
# ---------------------------------------------------------------------------
export TENANT_ADMIN_PASSWORD='Adm1n-Pass!word'
reset; "$B/poc-onboard.sh" --config "$EX" --yes --insecure --state-dir "$T/st-pb" >/dev/null 2>&1; WB=$(writes); cp "$T/st-pb/acme.json" "$T/m-b.json"
reset; rm -rf "$T/st-pb"; ps Invoke-PocOnboarding.ps1 -Config "$EX" -Yes -SkipCertificateCheck -StateDir "$T/st-pb" >/dev/null 2>&1; WP=$(writes)
check "all $(jq length <<<"$WB") write requests (method, path, identity, body) are identical" diff <(echo "$WB") <(echo "$WP")
check "the state files are identical" diff <(jq -S '.items | map(del(.at))' "$T/m-b.json") <(jq -S '.items | map(del(.at))' "$T/st-pb/acme.json")

# ---------------------------------------------------------------------------
section "Teardown"
# ---------------------------------------------------------------------------
OUT=$("$B/poc-teardown.sh" --config "$EX" --dry-run --insecure --state-dir "$T/st-pb" 2>&1); [[ $? == 0 ]] && ok "bash teardown dry run" || bad "teardown dry run" "$OUT"
curl -sk -X POST "$M/__mock/instances?tenantId=$(mstate | jq '[.accounts[] | select(.name == "Acme")][0].id')&count=2" >/dev/null
OUT=$("$B/poc-teardown.sh" --config "$EX" --yes --insecure --state-dir "$T/st-pb" 2>&1); [[ $? == 1 && $OUT == *"--remove-resources"* ]] && ok "a tenant with running instances is not deleted without --remove-resources" || bad "instances guard" "$OUT"
check "...and the shares it already reverted stay reverted (OtherCo keeps access)" q '.pools["11"].tenants == [2]'
OUT=$("$B/poc-teardown.sh" --config "$EX" --yes --insecure --state-dir "$T/st-pb" --remove-resources 2>&1); [[ $? == 0 && $OUT == *"TEARDOWN COMPLETE"* ]] && ok "bash teardown of the PowerShell-built tenant with --remove-resources" || bad "teardown remove-resources" "$OUT"
check "appliance is back to its starting state (cloud stays Public by default)" diff <(echo "$BASE") <(baseline)
check "state file archived" bash -c "ls '$T/st-pb' | grep -q 'acme.removed-'"

reset; rm -rf "$T/st-k"
"$B/poc-onboard.sh" --config "$EX" --yes --insecure --state-dir "$T/st-k" >/dev/null 2>&1
TID=$(mstate | jq '[.accounts[] | select(.name == "Acme")][0].id')
OUT=$(ps Remove-PocTenant.ps1 -Config "$EX" -Yes -SkipCertificateCheck -StateDir "$T/st-k" -KeepTenant -RestoreCloudVisibility 2>&1); [[ $? == 0 ]] && ok "PowerShell teardown -KeepTenant" || bad "keep tenant" "$OUT"
check "-KeepTenant: tenant kept, its multitenant role copies kept" q ".accounts[\"$TID\"] != null and ([.roles[] | select(.owner == $TID)] | length) == 2"
check "-KeepTenant: every object the kit made inside it is gone" q "([.groups[], .users[], .optionLists[], .optionTypes[], .catalogItems[], .blueprints[], .policies[] | select(.accountId == $TID)] | length) == 0"
check "-KeepTenant: shares reverted, tenant role kept (still the base role)" q ".pools[\"11\"].tenants == [2] and ([.roles[] | select(.authority == \"Acme Tenant Role\")] | length) == 1"
check "-RestoreCloudVisibility: cloud is Private again" q '.zones["1"].visibility == "private"'

# ---------------------------------------------------------------------------
section "Dedicated cloud (PowerShell builds, bash tears down)"
# ---------------------------------------------------------------------------
reset; rm -rf "$T/st-d"
OUT=$(ps Invoke-PocOnboarding.ps1 -Config "$DED" -Yes -SkipCertificateCheck -StateDir "$T/st-d" 2>&1); [[ $? == 0 ]] && ok "PowerShell onboarding, dedicated mode" || bad "dedicated onboard" "$OUT"
GID=$(mstate | jq '[.accounts[] | select(.name == "Globex")][0].id')
check "cloud VME-Cluster-02 is assigned to Globex and Private" q ".zones[\"2\"].accountId == $GID and .zones[\"2\"].visibility == \"private\""
check "fixed naming policy: no VM Name input, instance name is the pattern" \
  q '[.catalogItems[] | select(.name == "Rocky VM")][0] as $c | $c.config.instance.name == "gx-${sequence}" and ([$c.optionTypes[] as $i | .optionTypes[($i|tostring)].fieldName] | index("customVmName")) == null'
check "naming policy without auto-resolve; tag policy not strict, scoped to the group" \
  q '([.policies[] | select(.code == "naming")][0].config.namingConflict == "") and ([.policies[] | select(.code == "tags")][0] | .config.strict == false and .refType == "ComputeSite")'
check "user quota scoped to the user; user must change password" \
  q '[.policies[] | select(.code == "maxVms")][0] as $p | $p.refType == "User" and (.users[($p.refId|tostring)] | .username == "globex_dev" and .passwordExpired)'
check "datastore 'auto' is passed through" q '[.catalogItems[] | select(.name == "Rocky VM")][0].config.volumes[0].datastoreId == "auto"'
OUT=$("$B/poc-teardown.sh" --config "$DED" --yes --insecure --state-dir "$T/st-d" 2>&1); [[ $? == 0 ]] && ok "bash teardown of the dedicated tenant" || bad "dedicated teardown" "$OUT"
check "the cloud was given back to the master tenant BEFORE the tenant was deleted (it still exists, Private)" \
  q '.zones["2"].accountId == 1 and .zones["2"].visibility == "private" and (.pools["13"] != null)'
check "appliance is back to its starting state" diff <(echo "$BASE") <(baseline)

# ---------------------------------------------------------------------------
section "Blueprint from an exported template"
# ---------------------------------------------------------------------------
reset; rm -rf "$T/st-t" "$T/inv-t"
curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST "$M/api/blueprints" -d '{"name":"Lab 2-Tier","type":"morpheus","tiers":{
  "Front":{"tierIndex":1,"linkedTiers":["Back"],"instances":[{"instance":{"type":"mvm"},"groups":{"Master-Lab":{"clouds":{"VME-Cluster-01":{
     "instance":{"type":"mvm","layout":{"id":51},"name":"front-${sequence}"},"plan":{"id":71},
     "config":{"imageId":61,"resourcePoolId":"pool-11","poolProviderType":"mvm","createUser":true},
     "volumes":[{"rootVolume":true,"name":"root","size":30,"storageType":1,"datastoreId":21}],"networkInterfaces":[{"primaryInterface":true,"network":{"id":31}}]}}}}}]},
  "Back":{"tierIndex":2,"linkedTiers":[],"instances":[{"instance":{"type":"mvm"},"groups":{"Master-Lab":{"clouds":{"VME-Cluster-01":{
     "instance":{"type":"mvm","layout":{"id":52},"name":"back-${sequence}"},"plan":{"id":72},
     "config":{"imageId":61,"resourcePoolId":"pool-11","poolProviderType":"mvm","createUser":true},
     "volumes":[{"rootVolume":true,"name":"root","size":50,"storageType":1,"datastoreId":21}],"networkInterfaces":[{"primaryInterface":true,"network":{"id":31}}]}}}}}]}}}' >/dev/null
OUT=$(ps Get-MorpheusInventory.ps1 -SkipCertificateCheck -OutDir "$T/inv-t" -ExportBlueprint 'Lab 2-Tier' 2>&1); [[ $? == 0 ]] && ok "PowerShell inventory exports a blueprint" || bad "export blueprint" "$OUT"
TPL=$(ls "$T"/inv-t/*/blueprints/lab-2-tier.json 2>/dev/null)
check "exported template has the two tiers" jq -e '.tiers | keys == ["Back","Front"]' "$TPL"
jq --arg f "$TPL" '.catalog.threeTier = {name: "2-Tier App", group: "Acme-Dev", network: "VLAN-110", resourcePool: "prod-cluster", datastore: "gfs2-ds01", templateFile: $f}
                   | .roles[1].catalogItems = ["Linux VM", "2-Tier App"]' "$EX" > "$T/tpl.json"
OUT=$("$B/poc-onboard.sh" --config "$T/tpl.json" --yes --insecure --state-dir "$T/st-t" 2>&1); [[ $? == 0 ]] && ok "bash onboarding with templateFile" || bad "template onboarding" "$OUT"
check "template blueprint was retargeted to the tenant's group and cloud" \
  q '[.blueprints[] | select(.name == "2-Tier App")][0].config.tiers.Front.instances[0].groups["Acme-Dev"].clouds["VME-Cluster-01"].volumes[0].size == 30'
check "its App Spec lists the template's tiers" q '[.catalogItems[] | select(.name == "2-Tier App")][0].appSpec | contains("\"Front\":") and contains("\"Back\":")'
OUT=$(ps Remove-PocTenant.ps1 -Config "$T/tpl.json" -Yes -SkipCertificateCheck -StateDir "$T/st-t" 2>&1); [[ $? == 0 ]] && ok "PowerShell teardown of the template run" || bad "template teardown" "$OUT"

# ---------------------------------------------------------------------------
section "Images the tenant cannot see"
# ---------------------------------------------------------------------------
reset; rm -rf "$T/st-i"
jq '.catalog.vm.image = "rocky-9-golden" | del(.catalog.threeTier) | .roles[1].catalogItems = ["Linux VM"]' "$EX" > "$T/img.json"
OUT=$("$B/poc-onboard.sh" --config "$T/img.json" --yes --insecure --state-dir "$T/st-i" 2>&1); RC=$?
[[ $OUT == *"Image 'rocky-9-golden' is Private"* ]] && ok "pre-flight warns that the image is Private" || bad "private image warning" "$OUT"
[[ $RC == 1 && $OUT == *"is not visible to the tenant. Make the image Public"* ]] && ok "the catalog stage stops with a clear fix" || bad "private image stop" "$OUT"
OUT=$("$B/poc-teardown.sh" --config "$T/img.json" --yes --insecure --state-dir "$T/st-i" 2>&1); [[ $? == 0 ]] && ok "a partial run can be torn down" || bad "partial teardown" "$OUT"
check "appliance is back to its starting state" diff <(echo "$BASE") <(baseline)

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi

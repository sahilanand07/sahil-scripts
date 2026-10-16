# morpheus-poc-kit

Onboard a customer PoC on HPE Morpheus Enterprise or HPE VM Essentials (VME) Manager from **one JSON config file**, and remove it again when the PoC ends. The same three tools come in bash and PowerShell:

| Tool | bash | PowerShell 7 | What it does |
|---|---|---|---|
| Inventory | `bash/morpheus-inventory.sh` | `powershell/Get-MorpheusInventory.ps1` | Reads the appliance (changes nothing) and writes a summary, a JSON dump and a **starter config** filled with real names |
| Onboarding | `bash/poc-onboard.sh` | `powershell/Invoke-PocOnboarding.ps1` | Builds the tenant, roles, users, tag dropdowns, catalog items, 3-tier app and policies |
| Teardown | `bash/poc-teardown.sh` | `powershell/Remove-PocTenant.ps1` | Undoes exactly what onboarding did, using its state file |

The two languages send identical API requests and write the same state file, so a PoC built with one can be re-run or torn down with the other.

> Community scripts, not an official HPE tool. Tested end to end against a strict mock of the API (see [Testing](#testing)), **not yet against a live appliance** - start with `--dry-run` on your lab.

## Requirements

- **bash:** bash 4.4+, `curl` 7.55+, `jq` 1.6+
- **PowerShell:** PowerShell 7+ (Windows, Linux, macOS)
- An API token of a **master-tenant** admin (*User Settings > API Access*)
- On Windows, after extracting the zip: `Get-ChildItem -Recurse -Include *.ps1,*.psm1 | Unblock-File`

## The workflow

```bash
# 0. Credentials (or copy .env.example to .env and load it)
export MORPHEUS_URL=https://vme-manager.example.local
export MORPHEUS_TOKEN=<master admin API token>

# 1. See what the appliance has
bash/morpheus-inventory.sh --insecure
#    -> inventory/<host>-<time>/summary.txt and starter-config.json

# 2. Make the customer config
cp inventory/<host>-<time>/starter-config.json customers/acme.json   # then edit names, values, quotas

# 3. Preview, then build
bash/poc-onboard.sh --config customers/acme.json --dry-run --insecure
bash/poc-onboard.sh --config customers/acme.json --insecure

# 4. When the PoC is over
bash/poc-teardown.sh --config customers/acme.json --insecure
```

PowerShell is the same, with `-SkipCertificateCheck`, `-DryRun`, `-Yes`:

```powershell
$env:MORPHEUS_URL = 'https://vme-manager.example.local'; $env:MORPHEUS_TOKEN = '<token>'
./powershell/Get-MorpheusInventory.ps1 -SkipCertificateCheck
./powershell/Invoke-PocOnboarding.ps1 -Config ./customers/acme.json -DryRun -SkipCertificateCheck
./powershell/Invoke-PocOnboarding.ps1 -Config ./customers/acme.json -SkipCertificateCheck
./powershell/Remove-PocTenant.ps1 -Config ./customers/acme.json -SkipCertificateCheck
```

At the end of onboarding the script prints the sign-in URL (`subdomain\username`), the generated passwords (shown once) and the state file location.

## What onboarding builds

| # | Stage | Runs as | API |
|---|---|---|---|
| 1 | **Pre-flight:** every name in the config is looked up, and the needed policy types must exist on this appliance, before anything changes | master | `GET` only |
| 2 | Cloud made **Public** (shared mode) | master | `PUT /api/zones/{id}` |
| 3 | **Tenant role** (permission ceiling), copied from a template, with Full access to the cloud | master | `POST /api/roles`, `PUT …/update-cloud` |
| 4 | **Tenant** with that base role | master | `POST /api/accounts` |
| 5 | Resource pools / datastores / networks **shared** with the tenant (shared mode), or the cloud **assigned** to it (dedicated mode) | master | `PUT …/resource-pools/{id}`, `…/data-stores/{id}`, `/api/networks/{id}`, `/api/zones/{id}` |
| 6 | **Tenant admin** role and user | master | `POST /api/roles` (owner = tenant), `POST /api/accounts/{id}/users` |
| | *sign in to the tenant as its admin (OAuth)* | | `POST /oauth/token` |
| 7 | **Groups** containing the cloud | tenant | `POST /api/groups`, `PUT …/update-zones` |
| 8 | **Roles** mapped to groups, feature permissions and default persona | tenant | `POST /api/roles`, `PUT /api/roles/{id}/update-group`, `update-permission`, `update-persona` |
| 9 | **Users** with those roles | tenant | `POST /api/users` |
| 10 | **Tag dropdowns**: one option list + one select input per tag | tenant | `POST /api/library/option-type-lists`, `…/option-types` |
| 11 | **VM catalog item**: plan list, inputs, provisioning config, tags | tenant | `POST /api/catalog-item-types` |
| 12 | **3-tier app**: blueprint + catalog item with an App Spec | tenant | `POST /api/blueprints`, `POST /api/catalog-item-types` |
| 13 | **Role access** to catalog items and blueprints | tenant | `PUT …/update-catalog-item-type`, `update-blueprint` |
| 14 | **Policies**: naming, provision approval, tag enforcement, quotas | tenant | `POST /api/policies` |

Notes on the design:

- **Inside the tenant.** Everything from stage 7 on is created *inside* the customer tenant, signed in as its admin. The customer sees a self-contained portal, nothing leaks into the master tenant or other PoC tenants, and deleting the tenant removes it all.
- **Get-or-create.** Re-running the same command finishes a partial run and skips what exists. Users keep their passwords and catalog items, blueprints and policies are left unchanged. Option lists the kit created are updated to the config's values.
- **One source of truth for tags.** Each tag's option list feeds the catalog dropdown *and* the tag policy's value list, so VMs built outside the catalog are held to the same values.
- **Shared pools, datastores and networks.** The API replaces the whole tenant list on update. The scripts read the current list first, including the place pool lists actually come back from, which is the list call and not the single-object call. They only ever add or remove their own tenant, so other tenants never lose access.
- **Changes that affect other tenants ask first:** making the cloud Public, or assigning it to one tenant. `--yes` / `-Yes` approves them in automation.

## The config file

`customers/example-acme.json` is a complete example. Names are used everywhere, never IDs; they are resolved at run time, so the same file works on your lab and on the customer's appliance. Any name can also be given as a numeric ID.

| Key | Meaning |
|---|---|
| `tenant.name`, `subdomain`, `description`, `currency` | The tenant. Users sign in as `subdomain\username` (the tenant ID if no subdomain). |
| `tenant.role.name`, `copyFrom` | Tenant role (ceiling); default `"<name> Tenant Role"` copied from `Tenant Admin`. `copyFrom: ""` starts empty. |
| `cloud.name`, `mode` | `shared` (cloud stays in master, made Public, resources shared), `dedicated` (whole cloud assigned to the tenant) or `none`. |
| `cloud.share.resourcePools` / `datastores` / `networks` | Shared mode: what the tenant may use. |
| `admin.username`, `email`, `firstName`, `lastName`, `role`, `roleCopyFrom` | Tenant admin. The role (default `Tenant Admin`) is reused if the tenant already has it (multitenant copy), else created. |
| `groups` | Group names created in the tenant, each containing the cloud. Default: the tenant name. |
| `roles[]` | `name`; `copyFrom` (a role in the tenant); `groups`: `"all"` or a list; `features`: `{ "code": "access" }`; `defaultPersona`: `standard`, `serviceCatalog` or `vdi`; `catalogItems`: `"all"`, `"none"` or a list of names. |
| `users[]` | `username`, `email`, `role`, optional `firstName`, `lastName`, `mustChangePassword`. Passwords are generated and printed once. |
| `tags[]` | `name` (the tag key), optional `label` (form label), `values` (the dropdown). |
| `catalog.inputPrefix` | Prefix for input, option-list and policy names (default `PoC`). |
| `catalog.vm` | `name`, `group`, `layout`, `image`, `network`, `resourcePool`, `datastore` (name, `auto` or `autoCluster`), `plans`, optional `defaultDiskGB`, `staticTags`, `description`, `category`, `instanceTypeCode` (default `mvm`). |
| `catalog.threeTier` | `name`, `group`, `network`, `resourcePool`, `datastore`, `tiers[]` (`name`, `linkTo`, `layout`, `image`, `plan`, `diskGB`), `staticTags`. Or `templateFile`: a blueprint exported with the inventory tool. |
| `policies.naming` | `pattern` (e.g. `acme-${sequence}`), `enforcement`: `user` (pre-filled, editable) or `fixed`, `autoResolveConflicts`, `scope`. With `fixed`, the VM catalog item drops its free-text name input. |
| `policies.approval` | Provision approval with Morpheus's built-in approvals; `scope`, `eachUser`. |
| `policies.tagEnforcement` | One tag policy per tag: `strict`, `scope`. |
| `policies.quotas[]` | `name`, `scope`, `eachUser`, and any of `maxVms`, `maxCores`, `maxMemoryGB`, `maxStorageGB`. One policy per limit. |

A **scope** is `"global"` or one of `{"group": NAME}`, `{"role": NAME}`, `{"user": NAME}`, `{"cloud": NAME}`. With a role scope, `eachUser: true` gives every user holding the role their own quota or approval.

Feature-permission codes for `roles[].features` are listed in the inventory summary, with the access each has in the `Tenant Admin` role.

## Teardown

Teardown reads the state file (`state/<subdomain>.json`) and only touches what the kit recorded:

- **Created** objects are deleted. If the kit created the tenant, deleting the tenant removes everything inside it.
- **Reused** objects are left alone.
- **Shares are reverted:** the tenant is removed from each pool, datastore and network, and other tenants keep access.
- **A dedicated cloud is given back to the master tenant *before* the tenant is deleted.** Deleting a tenant also deletes the clouds assigned to it.
- **A cloud the kit made Public stays Public**, because other tenants may rely on it. Add `--restore-cloud-visibility` / `-RestoreCloudVisibility` to set it back.
- **A tenant with running instances is not deleted** unless you add `--remove-resources` / `-RemoveResources`.
- **`--keep-tenant` / `-KeepTenant`** keeps the tenant and deletes only the kit's objects inside it.

On success the state file is renamed `*.removed-<time>.json`.

## Passwords and re-runs

- **First run:** the tenant admin password comes from `TENANT_ADMIN_PASSWORD`, or is generated and printed once.
- **Re-runs** need it to sign in to the tenant. Set `TENANT_ADMIN_PASSWORD`, or pass `--reset-admin-password` / `-ResetAdminPassword` to set a new one, printed once.
- **Teardown** sets a temporary password on an admin user the kit created when it needs to sign in. It only does this when it keeps the tenant.

## SSL with self-signed certificates

| Option | bash | PowerShell |
|---|---|---|
| Trust the appliance CA (safer) | `MORPHEUS_CA_CERT=/path/ca.pem` | import the CA into the OS trust store |
| Ignore certificate errors for one run | `--insecure` | `-SkipCertificateCheck` |
| Always ignore them (lab `.env`) | `MORPHEUS_SKIP_TLS_VERIFY=true` | `MORPHEUS_SKIP_TLS_VERIFY=true` |

A TLS failure stops the script with this hint. Never ignore certificate errors against production.

## What is verified, and what to check on your lab first

**Checked against HPE's published sources.** Every endpoint and request field name was checked against the [Morpheus OpenAPI spec](https://github.com/gomorpheus/morpheus-openapi), the official [morpheus-cli](https://github.com/gomorpheus/morpheus-cli) and the [Terraform provider](https://github.com/gomorpheus/terraform-provider-morpheus) source:

- role permission updates;
- the OAuth sign-in format for sub-tenant users;
- policy bodies: scope by `refType`/`refId`, built-in approvals via integration ID `-100`, and memory/storage quotas in GB;
- the blueprint body: `{name, type: "morpheus", tiers}`, with groups and clouds keyed by name;
- the blueprint catalog item's `appSpec`;
- resource-sharing payloads.

The VM catalog item's provisioning config is the one from the lab script that already works on VME (`morpheus-tenant-bootstrap/examples/create-catalog-tile.ps1`).

**Not yet confirmed on a live appliance - check these on your lab first:**

1. **3-tier blueprint.** The per-cloud config inside each tier is modelled on the working catalog item. If VME rejects it, build one in the UI and export it with `--export-blueprint` / `-ExportBlueprint`. Then set it as `catalog.threeTier.templateFile`; the kit retargets its group and cloud.
2. **Tags in the 3-tier App Spec.** Confirm the order form's tags reach every tier's VM.
3. **Requester feature permissions.** Confirm the codes in the example are enough for a catalog-only user to order, and adjust them from the inventory's code list.
4. **Tenant role template.** Confirm the role you copy from includes Library, Policies, Roles, Users and Approvals; the in-tenant stages need them.
5. **Licence.** On VME, approvals and some policy types may need a Morpheus Enterprise licence. Pre-flight checks `/api/policy-types` and stops early if they're missing.

## Testing

```bash
test/run-tests.sh            # PWSH=/path/to/pwsh if pwsh is not on PATH
```

The suite starts `test/mock_morpheus.py`, a stateful mock served over HTTPS with a self-signed certificate. The mock is strict:

- Request bodies are checked against the field names in the OpenAPI spec and CLI; unknown fields fail.
- Sub-tenant tokens only see their own objects plus Public or shared infrastructure.
- Deletes fail while something still uses the object.
- Deleting a tenant deletes clouds assigned to it.

The 92 tests cover:

- ShellCheck and the PowerShell parser;
- the TLS options;
- inventory: bash and PowerShell output must be identical;
- config validation, and pre-flight failures that must change nothing;
- dry runs that must change nothing;
- every object and mapping the onboarding creates;
- re-runs in both languages;
- request-for-request parity between bash and PowerShell;
- teardown with instances, `--keep-tenant` and visibility restore;
- dedicated mode;
- blueprint templates;
- an image the tenant can't see.

## Layout

```
customers/example-acme.json      example config (copy per customer)
bash/       lib/morpheus.sh, morpheus-inventory.sh, poc-onboard.sh, poc-teardown.sh
powershell/ MorpheusPoc.psm1, Get-MorpheusInventory.ps1, Invoke-PocOnboarding.ps1, Remove-PocTenant.ps1
test/       mock_morpheus.py, run-tests.sh, fixtures/
state/      run state files (git-ignored, created at run time)
inventory/  inventory output (git-ignored)
```

## Security

- **No credentials in files.** Tokens and passwords come from the environment.
- **Secrets stay out of the process list.** The bash scripts hand the token and passwords to `curl` through private temp files.
- **Passwords are masked** in dry-run output and error messages.
- **Generated passwords are printed once** and never written to disk.
- **The state file holds IDs and names only.**
- **`.env`, `state/` and `inventory/` are git-ignored.** Inventory output names the customer's infrastructure, so don't commit it.

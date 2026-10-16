# Morpheus / VME Automation Scripts

Scripts for HPE Morpheus Enterprise and HPE Morpheus VM Essentials (VME) Manager that work through the REST API. Each tool is provided in PowerShell and in bash, with the same options and behaviour.

| Tool | PowerShell | bash | What it does |
|---|---|---|---|
| Tenant bootstrap | `New-MorpheusTenant.ps1` | `new-morpheus-tenant.sh` | Creates a ready-to-use sub-tenant: tenant role, tenant, cloud access, group, admin role and user |
| Catalog item | `New-MorpheusCatalogItem.ps1` | `new-morpheus-catalog-item.sh` | Creates a self-service VM catalog item with its order-form inputs, plan list and tags |
| Catalog item, simple version | `examples/create-catalog-tile.ps1` | `examples/create-catalog-tile.sh` | The original single-file lab script and its line-for-line bash port. These always create; re-running makes duplicates |

| Runtime | Requirement |
|---|---|
| `New-MorpheusTenant.ps1` | PowerShell 7+ (Windows, Linux, macOS) |
| `New-MorpheusCatalogItem.ps1`, `examples/create-catalog-tile.ps1` | Windows PowerShell 5.1 or PowerShell 7+ |
| bash scripts | bash 4.4+, `curl` 7.55+, `jq` 1.6+ |

> Community scripts, not an official HPE tool. Run them in a lab (start with dry-run mode) before using them on a production appliance.

The four main scripts share these behaviours:

- **Get-or-create.** Re-running the same command finishes a partly completed run and skips what already exists.
- **Dry run.** `--dry-run` / `-DryRun` performs only the lookups and prints every change instead of making it.
- **Credentials from the environment.** Nothing secret is stored in the scripts.

## Setup

1. Create an API token: *User Settings > API Access*. The tenant script needs a **master-tenant** admin.
2. Copy `.env.example` to `.env`, which Git ignores, and fill it in:

   ```bash
   cp .env.example .env    # then edit .env
   ```

   Load it in bash:

   ```bash
   set -a; source .env; set +a
   ```

   Load it in PowerShell:

   ```powershell
   Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$' } |
       ForEach-Object { Set-Item "env:$($Matches[1])" $Matches[2] }
   ```

| Variable | Required | Purpose |
|---|---|---|
| `MORPHEUS_URL` | yes | Appliance URL, e.g. `https://vme-manager.example.local` |
| `MORPHEUS_TOKEN` | yes | API token |
| `MORPHEUS_SKIP_TLS_VERIFY` | no | `true` = ignore SSL certificate errors (see below) |
| `MORPHEUS_CA_CERT` | no | bash only: PEM file of the appliance CA to trust |
| `TENANT_ADMIN_PASSWORD` | no | Tenant script: password for the new admin user. Otherwise you are prompted, or you can use generate-password |

## SSL errors with self-signed certificates

Lab appliances usually present a self-signed certificate. API calls then fail with errors such as *"SSL certificate problem: self-signed certificate"* (curl) or *"The remote certificate is invalid… UntrustedRoot"* (PowerShell). The scripts detect this and tell you how to proceed. You have three options, from safest to least safe:

| Option | bash | PowerShell |
|---|---|---|
| Trust the appliance's CA | `MORPHEUS_CA_CERT=/path/ca.pem` | Import the CA into the OS trust store |
| Ignore certificate errors for one run | `--insecure` | `-SkipCertificateCheck` |
| Always ignore them (lab `.env`) | `MORPHEUS_SKIP_TLS_VERIFY=true` | `MORPHEUS_SKIP_TLS_VERIFY=true` |

When certificate errors are ignored, every run prints a warning. Never do this against a production appliance: it removes the protection against someone impersonating the appliance and capturing your API token.

Each script has a clearly marked **"SSL / TLS certificate handling"** section. The PowerShell catalog script handles both runtimes:

- **PowerShell 7:** uses the per-request `-SkipCertificateCheck` switch. The old `ServicePointManager` callback has no effect on PowerShell 7.
- **Windows PowerShell 5.1:** installs a compiled trust-all certificate policy and enables TLS 1.2.

---

## Tenant bootstrap

### What gets created

| # | Object | API | Where to see it in the UI |
|---|---|---|---|
| 1 | Pre-checks: master-tenant token, cloud state | `GET /api/whoami`, `GET /api/zones/{id}` | – |
| 2 | Cloud set to **Public** (shared mode only) | `PUT /api/zones/{id}` | Infrastructure > Clouds > *cloud* > Edit |
| 3 | **Tenant role**, the permission ceiling for the tenant, copied from a template; Full cloud access in shared mode | `POST /api/roles`, `PUT /api/roles/{id}/update-cloud` | Administration > Roles |
| 4 | **Tenant** with that role as its Base Role | `POST /api/accounts` | Administration > Tenants |
| 5 | **Cloud** assigned to the tenant (dedicated mode), or listed resource pools / datastores / networks shared with it (shared mode) | `PUT /api/zones/{id}`, `PUT …/resource-pools/{id}`, `PUT …/data-stores/{id}`, `PUT /api/networks/{id}` | Cloud detail page > Resources / Storage / Networks |
| 6 | **Group** inside the tenant that contains the cloud | `POST /api/accounts/{id}/groups`, `PUT …/update-zones` | Tenant > Infrastructure > Groups |
| 7 | **User role** owned by the tenant, or an existing one such as a multitenant copy | `POST /api/roles` (`owner` = tenant) | Administration > Tenants > *tenant* > Roles |
| 8 | **Admin user** in the tenant | `POST /api/accounts/{id}/users` | Administration > Tenants > *tenant* > Users |

Existing users keep their password when you re-run.

### Quick start

Preview first:

```bash
./new-morpheus-tenant.sh --tenant-name Acme --subdomain acme --cloud-id 1 \
  --admin-username acme_admin --admin-email admin@acme.example --dry-run
```

```powershell
./New-MorpheusTenant.ps1 -TenantName Acme -Subdomain acme -CloudId 1 `
  -AdminUsername acme_admin -AdminEmail admin@acme.example -DryRun
```

**Shared cloud.** One VME cluster serves several tenants, and you choose which resources each tenant gets:

```bash
./new-morpheus-tenant.sh --tenant-name Acme --subdomain acme --cloud-id 1 \
  --resource-pools 5 --datastores 7,8 --networks 12 \
  --admin-username acme_admin --admin-email admin@acme.example --generate-password
```

If you leave out the resource IDs, the script lists the cloud's resource pools, datastores and networks with their IDs and visibility so you can pick them.

**Dedicated cloud.** The whole cloud and all of its resources go to one tenant:

```powershell
./New-MorpheusTenant.ps1 -TenantName Globex -CloudId 2 -CloudMode dedicated `
  -AdminUsername globex_admin -AdminEmail admin@globex.example -GeneratePassword
```

Changes that affect other tenants ask for confirmation first: making a cloud Public, and assigning a cloud to one tenant. Add `--yes` / `-Yes` to approve them in automation.

### Options

| bash | PowerShell | Default | Meaning |
|---|---|---|---|
| `--tenant-name` | `-TenantName` | *(required)* | Tenant name |
| `--subdomain` | `-Subdomain` | – | Login prefix: users sign in as `subdomain\username` (without one, the prefix is the tenant ID) |
| `--tenant-description` | `-TenantDescription` | `Sub-tenant NAME` | |
| `--currency` | `-Currency` | `USD` | e.g. `INR` |
| `--tenant-role-name` | `-TenantRoleName` | `NAME Tenant Role` | |
| `--tenant-role-template` | `-TenantRoleTemplate` | `Tenant Admin` | Tenant role to copy permissions from (`""` = start empty) |
| `--cloud-id` | `-CloudId` | – | Required unless the cloud mode is `none` |
| `--cloud-mode` | `-CloudMode` | `shared` | `shared`, `dedicated` or `none` |
| `--resource-pools` | `-ResourcePoolIds` | – | Shared mode only; comma-separated IDs |
| `--datastores` | `-DatastoreIds` | – | Shared mode only |
| `--networks` | `-NetworkIds` | – | Shared mode only |
| `--group-name` | `-GroupName` | tenant name | Group created in the tenant if none contains the cloud |
| `--user-role-name` | `-UserRoleName` | `Tenant Admin` | Reused if the tenant already has it, e.g. a multitenant copy |
| `--user-role-template` | `-UserRoleTemplate` | `Tenant Admin` | Copied from if the user role has to be created |
| `--admin-username` | `-AdminUsername` | *(required)* | |
| `--admin-email` | `-AdminEmail` | *(required)* | |
| `--admin-first-name` / `--admin-last-name` | `-AdminFirstName` / `-AdminLastName` | `Tenant` / `Admin` | |
| `--generate-password` | `-GeneratePassword` | off | 20-character random password, printed once |
| `--dry-run` | `-DryRun` | off | Lookups only, no changes |
| `--yes` | `-Yes` | off | Approve cross-tenant changes without prompting |
| `--insecure` | `-SkipCertificateCheck` | off | Ignore SSL certificate errors (lab only) |

Built-in role names differ between versions and installs. If a template name doesn't exist, the script stops and prints the roles you *can* copy from. Re-run with one of those names.

### Cloud modes

- **shared**: the cloud stays in the master tenant and is made **Public**. The tenant role gets **Full** access to it. The tenant then sees the cloud, but it can only provision onto resource pools, datastores and networks that are Public or shared with it, which is what the resource ID options are for.
- **dedicated**: the cloud is assigned to the tenant. Morpheus then makes the cloud and *all* of its resources available only to that tenant; the master tenant keeps control.
- **none**: no cloud changes and no group.

### Check the result in the UI

1. Administration > Tenants > *tenant*: the base role, Users tab and Roles tab are as expected.
2. Sign in as `subdomain\username`, or `tenantID\username`, using the details printed at the end of the run.
3. Confirm that Infrastructure > Clouds shows the cloud and Infrastructure > Groups shows a group containing it.
4. Try Provisioning > Instances > Add. If no cluster, datastore or network can be chosen, share more resources (shared mode).

---

## Catalog item

### What gets created

| # | Object | API | Where to see it in the UI |
|---|---|---|---|
| 1 | Pre-checks: every ID you pass is looked up and printed by name; the group must contain the cloud | `GET` on groups, clouds, layouts, images, networks, resource pools, datastores, service plans | – |
| 2 | **Option list** `<prefix> - Plan Sizes` with the plans you allow, labelled with their real names | `POST /api/library/option-type-lists` | Library > Options > Option Lists |
| 3 | Six **inputs**: VM name, description, plan (select), root disk size, cost center, department | `POST /api/library/option-types` | Library > Options > Inputs |
| 4 | **Catalog item** (type `instance`) whose provisioning config uses the inputs and tags the VM | `POST /api/catalog-item-types` | Library > Blueprints > Catalog Items |

Users order the item from *Provisioning > Catalog*. Each VM is tagged with `CostCenter` and `Department` from the form, plus the static tags (default `Environment=Production`, `ManagedBy=Self-Service`).

Nothing is created if any ID is wrong or if an existing input with the same name uses a different field name. Re-runs reuse the option list, inputs and catalog item. Add `--update` / `-Update` to push changed settings, such as different plans, tags or IDs, into the existing option list and catalog item.

### Quick start

```bash
./new-morpheus-catalog-item.sh --name "Linux VM (Self-Service)" \
  --group-id 3 --cloud-id 1 --layout-id 32 --image-id 194 --network-id 1 \
  --resource-pool pool-1 --datastore 6 --plans 25,26 --dry-run
```

```powershell
./New-MorpheusCatalogItem.ps1 -Name 'Linux VM (Self-Service)' `
  -GroupId 3 -CloudId 1 -LayoutId 32 -ImageId 194 -NetworkId 1 `
  -ResourcePoolId pool-1 -DatastoreId 6 -PlanIds 25,26 -DryRun
```

To find an ID in the UI, open the object's detail page (group, cloud, image, network, service plan, layout). The ID is the number at the end of the URL.

### Options

| bash | PowerShell | Default | Meaning |
|---|---|---|---|
| `--name` | `-Name` | *(required)* | Catalog item name |
| `--code` | `-Code` | from the name | Short code, lowercase letters, digits and hyphens |
| `--description` / `--category` | `-Description` / `-Category` | | |
| `--visibility` | `-Visibility` | `private` | `public` shows it to all tenants |
| `--not-featured` | `-NotFeatured` | featured | |
| `--group-id`, `--cloud-id`, `--layout-id`, `--image-id`, `--network-id` | `-GroupId`, `-CloudId`, `-LayoutId`, `-ImageId`, `-NetworkId` | *(required)* | |
| `--resource-pool` | `-ResourcePoolId` | *(required)* | `5` or `pool-5` |
| `--datastore` | `-DatastoreId` | *(required)* | Datastore ID, `auto` or `autoCluster` |
| `--plans` | `-PlanIds` | *(required)* | Service plan IDs offered on the form, in display order |
| `--storage-type-id` | `-StorageTypeId` | `1` | Root volume storage type |
| `--instance-type-code` | `-InstanceTypeCode` | `mvm` | Warns if the layout belongs to a different instance type |
| `--pool-provider-type` | `-PoolProviderType` | `mvm` | |
| `--default-disk-gb` | `-DefaultDiskSizeGB` | `40` | |
| `--tag KEY=VALUE` (repeatable) | `-Tags @{KEY='VALUE'}` | `Environment=Production`, `ManagedBy=Self-Service` | Static tags; replace the defaults |
| `--input-prefix` | `-InputPrefix` | `Cat` | Prefix for input and option-list names; use a different one per catalog item if the forms should differ |
| `--export-inputs-as-tags` | `-ExportInputsAsTags` | off | Also export every input as a tag |
| `--update` | `-Update` | off | Apply settings to an existing item and plan list |
| `--dry-run` | `-DryRun` | off | Lookups only, no changes |
| `--insecure` | `-SkipCertificateCheck` | off | Ignore SSL certificate errors (lab only) |

### How this relates to the lab script in `examples/`

The provisioning config these scripts send is the same as in `examples/create-catalog-tile.ps1`, the lab script that works on a VME appliance (`zoneId`, `group`, `layout`, `plan`/`servicePlan`, `instance{…}`, `config{…}`, `volumes`, `networkInterfaces`, `tags`). What's different:

- **Re-runnable.** Inputs, the plan list and the catalog item are reused instead of created again on every run.
- **Checked IDs.** Every ID is a parameter that is looked up before anything is created, so nothing is hard-coded.
- **Plan list.** It is named `<prefix> - Plan Sizes`, and its labels are the real plan names from the API.
- **No duplicate tags.** Inputs are not exported as tags by default. In the lab script every input (including plan ID and disk size) is also added as a tag next to `CostCenter` / `Department`. Use `--export-inputs-as-tags` / `-ExportInputsAsTags` for the old behaviour.
- **Name validation.** The VM-name input only accepts host-name-safe names: a letter first, then letters, digits and hyphens, up to 63 characters.

---

## Testing status

All four scripts were syntax-checked (PowerShell parser, `bash -n`, ShellCheck). They were then run end to end on PowerShell 7 and bash against a strict mock of the Morpheus API served over HTTPS with a self-signed certificate. The runs covered:

- creating new objects, re-runs, dry runs and updates;
- PowerShell and bash re-running each other's results;
- bad IDs and name clashes;
- SSL failure without the skip option, the skip option and env var, and a trusted CA file.

The mock checks request field names against HPE's published OpenAPI spec and the official `morpheus-cli`.

For the catalog item, the original working PowerShell lab script was also run against the same mock. The results:

- `examples/create-catalog-tile.sh` sends the same eight requests with identical bodies.
- The provisioning config from both full catalog scripts is identical to the original's.

**Not yet tested:** a live appliance, and Windows PowerShell 5.1 (the catalog script supports it, but the test environment only had PowerShell 7). Use dry-run mode on your own appliance first.

## Security notes

- No credentials live in the scripts. The token comes from the environment, and the bash scripts pass it to `curl` through a private temp file so it doesn't show in the process list.
- Passwords are masked in dry-run output and error messages.
- `.env` is git-ignored. Never commit real tokens, appliance hostnames or customer names.

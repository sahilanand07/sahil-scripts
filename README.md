# sahil-scripts

Scripts for automation. Each tool comes in **PowerShell and bash** with the same options and behaviour.

## HPE Morpheus / VM Essentials (VME) Manager

| Folder | What it is | Start here |
|---|---|---|
| [`morpheus-tenant-bootstrap/`](morpheus-tenant-bootstrap/) | Stand-alone scripts: create a ready-to-use sub-tenant, and create a self-service VM catalog item | [README](morpheus-tenant-bootstrap/README.md) |
| [`morpheus-poc-kit/`](morpheus-poc-kit/) | Onboard a whole customer PoC from one JSON file (tenant, roles, users, tag dropdowns, catalog items, 3-tier app, policies), plus inventory and teardown | [README](morpheus-poc-kit/README.md) |

Quick start:

```bash
git clone https://github.com/sahilanand07/sahil-scripts.git
cd sahil-scripts/morpheus-tenant-bootstrap
cp .env.example .env          # fill in MORPHEUS_URL and MORPHEUS_TOKEN; .env is git-ignored
set -a; source .env; set +a
./new-morpheus-tenant.sh --help
```

## Credentials

Nothing secret is stored in this repository. The scripts read the appliance URL and API token from environment variables (or a local `.env` file, which Git ignores). **Never commit a real token** - if one is ever pushed, revoke it in *User Settings > API Access* straight away, because removing it from the history does not make it safe again.

> Community scripts, not an official HPE tool. Run them in a lab first, starting with the dry-run option.

#!/usr/bin/env python3
"""
mock_morpheus.py - a stateful mock of the HPE Morpheus / VME Manager REST API.

Used only to test morpheus-poc-kit. It implements the endpoints the kit calls and is deliberately
strict:

  * request bodies are checked against the field names in HPE's published OpenAPI spec
    (github.com/gomorpheus/morpheus-openapi) and the official morpheus-cli; unknown fields fail;
  * a sub-tenant token only sees its own objects plus Public / shared infrastructure, and gets
    HTTP 403 on master-only endpoints;
  * deletes fail while something still uses the object (role assigned to a user, list used by an
    input, blueprint used by a catalog item, tenant with instances);
  * deleting a tenant deletes a cloud assigned to it - as a real appliance would.

Resource-pool tenant lists are only returned by the LIST call (in a top-level "tenants" map), as
morpheus-cli shows; datastores and networks carry them on the object.

  python3 mock_morpheus.py --port 8443 --cert cert.pem --key key.pem --token MASTERTOKEN

Test helpers (no auth):
  GET  /__mock/state                      full state
  GET  /__mock/requests                   request log since the last reset
  POST /__mock/reset                      restore the seed data
  POST /__mock/instances?tenantId=N&count=M   pretend a tenant has running instances
  POST /__mock/disable-policy-type?code=X     remove a policy type (licence gating)
"""
import argparse
import copy
import json
import re
import secrets
import ssl
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.RLock()

FEATURE_CODES = set("""account-usage activity admin-accounts admin-accounts-users admin-appliance admin-backupSettings
admin-certificates admin-clients admin-cm admin-containers admin-distributed-workers
admin-environments admin-global-policies admin-groups admin-guidanceSettings admin-health
admin-identity-sources admin-keypairs admin-licenses admin-logSettings admin-monitorSettings
admin-motd admin-packages admin-plugins admin-policies admin-profiles admin-provisioningSettings
admin-roles admin-server-devices admin-server-software admin-servers admin-servicePlans admin-users
admin-whitelabel admin-zones app-templates apps arm-template automation-services backup-services
backups billing catalog cloudFormation-template code-repositories credentials dashboard
deployment-services deployments execution-request executions guidance helm-template
infrastructure-boot infrastructure-cluster infrastructure-dhcp-pool infrastructure-domains
infrastructure-ippools infrastructure-kube-cntl infrastructure-loadbalancer
infrastructure-move-server infrastructure-nat infrastructure-network-dhcp-relay
infrastructure-network-dhcp-routes infrastructure-network-dhcp-server
infrastructure-network-firewalls infrastructure-network-integrations
infrastructure-network-router-firewalls infrastructure-network-router-interfaces
infrastructure-network-router-redistribution infrastructure-network-router-routes
infrastructure-network-server-groups infrastructure-networks infrastructure-proxies
infrastructure-router-dhcp-binding infrastructure-router-dhcp-relay infrastructure-routers
infrastructure-securityGroups infrastructure-servers-maintenance infrastructure-servers-placement
infrastructure-state infrastructure-storage infrastructure-storage-browser integrations-ansible
job-executions job-templates kubernetes-template library-advanced-node-type-options
library-operating-systems library-options library-templates logs monitoring operations-alarms
operations-approvals operations-budgets operations-invoices operations-wiki projects provisioning
provisioning-add provisioning-admin provisioning-clone provisioning-delete provisioning-edit
provisioning-environment provisioning-execute-script provisioning-execute-task
provisioning-execute-workflow provisioning-force-delete provisioning-import-image provisioning-lock
provisioning-power provisioning-reconfigure provisioning-reconfigure-add-disk
provisioning-reconfigure-add-network provisioning-reconfigure-change-plan
provisioning-reconfigure-disk-type provisioning-reconfigure-modify-disk
provisioning-reconfigure-modify-network provisioning-reconfigure-remove-disk
provisioning-reconfigure-remove-network provisioning-remove-control provisioning-scale
provisioning-settings provisioning-state reports reports-analytics scheduling-execute
scheduling-power security-scan service-catalog service-catalog-dashboard service-catalog-inventory
services-archives services-cypher services-image-builder services-kubernetes services-migrations
services-network-registry services-vdi-copy services-vdi-pools services-vdi-printer snapshots
task-scripts tasks terminal terminal-access terraform-template thresholds trust-services
virtual-images workflows""".split())
FEATURE_ACCESS = {"full", "full_decrypted", "group", "listfiles", "managerules", "none", "provision",
                  "read", "rolemappings", "user", "view", "yes", "no"}
SPECIAL_PERMISSION_CODES = {"ComputeSite", "ComputeZone", "InstanceType", "AppTemplate", "ReportTypes",
                            "Persona", "CatalogItemType", "VdiPools", "TaskSet", "Task"}
CURRENCIES = {"AUD", "BGN", "BRL", "CAD", "CHF", "CLF", "CLP", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD",
              "HRK", "HUF", "IDR", "ILS", "INR", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN",
              "RON", "RUB", "SEK", "SGD", "THB", "TRY", "USD", "ZAR"}
PERSONAS = {"standard": "Standard", "serviceCatalog": "Service Catalog", "vdi": "Virtual Desktop"}
POLICY_TYPES = [
    (37, "provisionApproval", "Approve Provision"), (38, "deleteApproval", "Approve Delete"),
    (12, "naming", "Instance Name"), (13, "hostNaming", "Hostname"), (40, "tags", "Tags"),
    (20, "maxVms", "Max VMs"), (21, "maxCores", "Max Cores"), (22, "maxMemory", "Max Memory"),
    (23, "maxStorage", "Max Storage"), (24, "maxContainers", "Max Containers"),
    (30, "powerSchedule", "Power Schedule"), (31, "lifecycle", "Expiration"), (32, "shutdown", "Shutdown"),
]
POLICY_CONFIG = {  # allowed keys, required keys  (from the OpenAPI policy config schemas)
    "provisionApproval": ({"accountIntegrationId", "workflowId", "flowId", "workflowType"}, {"accountIntegrationId"}),
    "deleteApproval": ({"accountIntegrationId", "workflowId", "flowId", "workflowType"}, {"accountIntegrationId"}),
    "naming": ({"namingType", "namingPattern", "namingConflict"}, {"namingType", "namingPattern"}),
    "tags": ({"strict", "key", "valueListId", "value"}, {"key"}),
    "maxVms": ({"maxVms"}, {"maxVms"}),
    "maxCores": ({"maxCores", "excludeContainers"}, {"maxCores"}),
    "maxMemory": ({"maxMemory", "excludeContainers"}, {"maxMemory"}),
    "maxStorage": ({"maxStorage", "excludeContainers"}, {"maxStorage"}),
}
REF_TYPES = {"ComputeSite": "site", "ComputeZone": "zone", "User": "user", "Role": "role"}
INPUT_TYPES = {"text", "textarea", "select", "number", "checkbox", "hidden", "password", "typeahead", "radio"}
ACCESS3 = {"default", "full", "read", "none"}
ACCESS2 = {"default", "full", "none"}

ROLE_KEYS = {"authority", "name", "description", "landingUrl", "roleType", "baseRoleId", "multitenant",
             "multitenantLocked", "defaultPersona", "featurePermissions", "globalSiteAccess", "sites",
             "globalZoneAccess", "zones", "globalInstanceTypeAccess", "instanceTypePermissions",
             "globalAppTemplateAccess", "appTemplatePermissions", "globalCatalogItemTypeAccess",
             "catalogItemTypePermissions", "globalPersonaAccess", "personaPermissions", "owner", "tenant",
             "tenantId"}
USER_KEYS = {"firstName", "lastName", "username", "email", "password", "passwordConfirmation", "roles", "role",
             "receiveNotifications", "enabled", "accountLocked", "passwordExpired", "linuxUsername",
             "linuxPassword", "windowsUsername", "windowsPassword"}


class ApiError(Exception):
    def __init__(self, status, msg, errors=None):
        super().__init__(msg)
        self.status, self.msg, self.errors = status, msg, errors or {}


# ---------------------------------------------------------------------------------------------
# Seed data
# ---------------------------------------------------------------------------------------------
def seed(master_token):
    full = {c: "full" for c in FEATURE_CODES}
    s = {
        "next": 1000,
        "accounts": {
            1: {"id": 1, "name": "Home", "subdomain": None, "description": "Master tenant", "currency": "USD",
                "role": None, "master": True, "instances": 0},
            2: {"id": 2, "name": "OtherCo", "subdomain": "otherco", "description": "Existing tenant",
                "currency": "USD", "role": 2, "master": False, "instances": 0},
        },
        "roles": {},
        "users": {
            1: {"id": 1, "username": "admin", "email": "admin@master.example", "firstName": "Master",
                "lastName": "Admin", "accountId": 1, "password": "MasterPass!1", "roles": [1],
                "passwordExpired": False},
        },
        "zones": {
            1: {"id": 1, "name": "VME-Cluster-01", "code": "vme1", "visibility": "private", "accountId": 1},
            2: {"id": 2, "name": "VME-Cluster-02", "code": "vme2", "visibility": "private", "accountId": 1},
        },
        "pools": {
            11: {"id": 11, "name": "prod-cluster", "externalId": "pool-11", "zoneId": 1, "visibility": "private", "tenants": [2]},
            12: {"id": 12, "name": "dev-cluster", "externalId": "pool-12", "zoneId": 1, "visibility": "private", "tenants": []},
            13: {"id": 13, "name": "cluster-b", "externalId": "pool-13", "zoneId": 2, "visibility": "private", "tenants": []},
        },
        "datastores": {
            21: {"id": 21, "name": "gfs2-ds01", "zoneId": 1, "visibility": "private", "tenants": [2]},
            22: {"id": 22, "name": "local-ds", "zoneId": 1, "visibility": "private", "tenants": []},
            23: {"id": 23, "name": "ds-b", "zoneId": 2, "visibility": "private", "tenants": []},
        },
        "networks": {
            31: {"id": 31, "name": "VLAN-110", "zoneId": 1, "visibility": "private", "tenants": [2]},
            32: {"id": 32, "name": "VLAN-120", "zoneId": 1, "visibility": "private", "tenants": []},
            33: {"id": 33, "name": "net-b", "zoneId": 2, "visibility": "private", "tenants": []},
        },
        "instanceTypes": {41: {"id": 41, "code": "mvm", "name": "HPE VM"}},
        "layouts": {
            51: {"id": 51, "name": "Ubuntu 22.04", "code": "mvm-ubuntu-2204", "instanceTypeId": 41},
            52: {"id": 52, "name": "Rocky 9", "code": "mvm-rocky-9", "instanceTypeId": 41},
        },
        "images": {
            61: {"id": 61, "name": "ubuntu-22.04-cloudimg", "imageType": "qcow2", "visibility": "public", "accountId": 1},
            62: {"id": 62, "name": "rocky-9-golden", "imageType": "qcow2", "visibility": "private", "accountId": 1},
        },
        "plans": {
            71: {"id": 71, "name": "Small (2 vCPU, 4 GB)", "code": "mvm-small"},
            72: {"id": 72, "name": "Medium (4 vCPU, 8 GB)", "code": "mvm-medium"},
            73: {"id": 73, "name": "Large (8 vCPU, 16 GB)", "code": "mvm-large"},
        },
        "groups": {81: {"id": 81, "name": "Master-Lab", "accountId": 1, "zones": [1, 2]}},
        "optionLists": {}, "optionTypes": {}, "catalogItems": {}, "blueprints": {}, "policies": {},
        "policyTypes": [{"id": i, "code": c, "name": n} for i, c, n in POLICY_TYPES],
        "tokens": {master_token: 1},
        "requests": [],
    }
    roles = [
        dict(id=1, authority="System Admin", roleType="user", owner=1, multitenant=False, features=dict(full)),
        dict(id=2, authority="Tenant Admin", roleType="account", owner=1, multitenant=False, features=dict(full)),
        dict(id=3, authority="Tenant Admin", roleType="user", owner=1, multitenant=True, features=dict(full)),
        dict(id=4, authority="Tenant User", roleType="user", owner=1, multitenant=True,
             features={"service-catalog": "full", "provisioning": "user"}),
        dict(id=5, authority="Tenant Admin", roleType="user", owner=2, multitenant=False, features=dict(full)),
    ]
    for r in roles:
        s["roles"][r["id"]] = new_role_record(r["id"], r["authority"], r["roleType"], r["owner"],
                                              r["multitenant"], r["features"])
    return s


def new_role_record(rid, authority, role_type, owner, multitenant=False, features=None):
    return {"id": rid, "authority": authority, "description": None, "roleType": role_type, "owner": owner,
            "multitenant": multitenant, "multitenantLocked": False, "defaultPersona": "standard",
            "features": dict(features or {}), "globalSiteAccess": "none", "sites": {},
            "globalZoneAccess": "none", "zones": {}, "globalCatalogItemTypeAccess": "none",
            "catalogItemTypes": {}, "globalAppTemplateAccess": "none", "appTemplates": {},
            "globalPersonaAccess": "full", "personas": {}}


STATE = {}
MASTER_TOKEN = None


def nid():
    STATE["next"] += 1
    return STATE["next"]


# ---------------------------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------------------------
def obj(body, key, where="request body"):
    if not isinstance(body, dict) or not isinstance(body.get(key), dict):
        raise ApiError(400, f"{where} must contain a '{key}' object")
    return body[key]


def check_keys(o, allowed, where):
    unknown = sorted(set(o) - set(allowed))
    if unknown:
        raise ApiError(400, f"Unknown field(s) in {where}: {', '.join(unknown)}", {k: "unknown field" for k in unknown})


def need(o, key, where, types=None):
    if key not in o or o[key] is None or o[key] == "":
        raise ApiError(400, f"{where}.{key} is required", {key: "required"})
    if types:
        v = o[key]
        if int in types and isinstance(v, bool) and bool not in types:
            raise ApiError(400, f"{where}.{key} must be {types}")
        if not isinstance(v, tuple(types)):
            raise ApiError(400, f"{where}.{key} has the wrong type ({type(v).__name__})")
    return o[key]


def as_id(v, where):
    if isinstance(v, bool):
        raise ApiError(400, f"{where} must be an id")
    if isinstance(v, int):
        return v
    if isinstance(v, str) and re.fullmatch(r"\d+", v):
        return int(v)
    raise ApiError(400, f"{where} must be a numeric id (got {v!r})")


def ref_id(v, where):
    if isinstance(v, dict):
        return as_id(v.get("id"), where + ".id")
    return as_id(v, where)


def access(v, allowed, where):
    if v not in allowed:
        raise ApiError(400, f"{where} must be one of {sorted(allowed)} (got {v!r})")
    return v


def flt_name(items, q, field="name"):
    name = q.get("name") or (q.get("username") if field == "username" else None)
    if name:
        items = [i for i in items if str(i.get(field, "")).lower() == name.lower()]
    phrase = q.get("phrase")
    if phrase:
        items = [i for i in items if phrase.lower() in str(i.get(field, "")).lower()]
    return items


def page(items, q):
    mx = int(q.get("max", 25) or 25)
    off = int(q.get("offset", 0) or 0)
    sl = items[off:off + mx] if mx >= 0 else items[off:]
    return sl, {"size": len(sl), "total": len(items), "offset": off, "max": mx}


# ---------------------------------------------------------------------------------------------
# Visibility
# ---------------------------------------------------------------------------------------------
def acct_name(aid):
    a = STATE["accounts"].get(aid)
    return a["name"] if a else None


def zone_visible(z, ctx):
    return ctx["master"] or z["accountId"] == ctx["acct"] or z["visibility"] == "public"


def get_zone(zid, ctx):
    z = STATE["zones"].get(zid)
    if not z or not zone_visible(z, ctx):
        raise ApiError(404, f"Cloud {zid} not found")
    return z


def shared_visible(o, ctx):
    z = STATE["zones"].get(o["zoneId"])
    if not z or not zone_visible(z, ctx):
        return False
    if ctx["master"] or z["accountId"] == ctx["acct"]:
        return True
    return o["visibility"] == "public" or ctx["acct"] in o["tenants"]


def image_visible(i, ctx):
    return ctx["master"] or i["visibility"] == "public" or i["accountId"] == ctx["acct"]


def owned(coll, oid, ctx, label):
    o = STATE[coll].get(oid)
    owner = o.get("accountId", o.get("owner")) if o else None
    if not o or owner != ctx["acct"]:
        raise ApiError(404, f"{label} {oid} not found")
    return o


def require_master(ctx):
    if not ctx["master"]:
        raise ApiError(403, "Unauthorized: this endpoint is only available to the master tenant")


# ---------------------------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------------------------
def r_account(a):
    role = STATE["roles"].get(a["role"]) if a["role"] else None
    return {"id": a["id"], "name": a["name"], "subdomain": a["subdomain"], "description": a["description"],
            "currency": a["currency"], "master": a["master"],
            "role": {"id": role["id"], "authority": role["authority"]} if role else None}


def r_role(r):
    return {"id": r["id"], "authority": r["authority"], "name": r["authority"], "description": r["description"],
            "roleType": r["roleType"], "multitenant": r["multitenant"],
            "owner": {"id": r["owner"], "name": acct_name(r["owner"])},
            "defaultPersona": {"code": r["defaultPersona"], "name": PERSONAS.get(r["defaultPersona"])}}


def r_role_full(r):
    out = {"role": r_role(r)}
    out["featurePermissions"] = [{"code": c, "name": c, "access": a} for c, a in sorted(r["features"].items())]
    out["globalSiteAccess"] = r["globalSiteAccess"]
    out["sites"] = [{"id": g, "name": (STATE["groups"].get(g) or {}).get("name"), "access": a} for g, a in r["sites"].items()]
    out["globalZoneAccess"] = r["globalZoneAccess"]
    out["zones"] = [{"id": z, "name": (STATE["zones"].get(z) or {}).get("name"), "access": a} for z, a in r["zones"].items()]
    out["globalCatalogItemTypeAccess"] = r["globalCatalogItemTypeAccess"]
    out["catalogItemTypePermissions"] = [{"id": c, "access": a} for c, a in r["catalogItemTypes"].items()]
    out["globalAppTemplateAccess"] = r["globalAppTemplateAccess"]
    out["appTemplatePermissions"] = [{"id": b, "access": a} for b, a in r["appTemplates"].items()]
    out["personaPermissions"] = [{"code": p, "name": n, "access": r["personas"].get(p, "full")} for p, n in PERSONAS.items()]
    return out


def r_user(u):
    return {"id": u["id"], "username": u["username"], "email": u["email"], "firstName": u["firstName"],
            "lastName": u["lastName"], "accountId": u["accountId"],
            "account": {"id": u["accountId"], "name": acct_name(u["accountId"])},
            "roles": [{"id": rid, "authority": STATE["roles"][rid]["authority"]} for rid in u["roles"] if rid in STATE["roles"]],
            "passwordExpired": u.get("passwordExpired", False)}


def r_zone(z):
    return {"id": z["id"], "name": z["name"], "code": z["code"], "visibility": z["visibility"],
            "accountId": z["accountId"], "account": {"id": z["accountId"], "name": acct_name(z["accountId"])},
            "owner": {"id": z["accountId"], "name": acct_name(z["accountId"])},
            "zoneType": {"code": "mvm", "name": "HPE VM Essentials"}}


def tenants_of(o):
    return [{"id": t, "name": acct_name(t)} for t in o["tenants"] if t in STATE["accounts"]]


def r_pool(p):
    return {"id": p["id"], "name": p["name"], "externalId": p["externalId"], "visibility": p["visibility"],
            "zone": {"id": p["zoneId"]}, "type": "mvm"}


def r_ds(d):
    return {"id": d["id"], "name": d["name"], "visibility": d["visibility"], "zone": {"id": d["zoneId"]},
            "type": "gfs2", "tenants": tenants_of(d)}


def r_net(n):
    return {"id": n["id"], "name": n["name"], "visibility": n["visibility"],
            "zone": {"id": n["zoneId"], "name": STATE["zones"].get(n["zoneId"], {}).get("name")},
            "tenants": tenants_of(n)}


def r_group(g):
    return {"id": g["id"], "name": g["name"], "accountId": g["accountId"],
            "zones": [{"id": z, "name": STATE["zones"][z]["name"]} for z in g["zones"] if z in STATE["zones"]]}


def r_layout(l):
    it = STATE["instanceTypes"][l["instanceTypeId"]]
    return {"id": l["id"], "name": l["name"], "code": l["code"],
            "instanceType": {"id": it["id"], "code": it["code"], "name": it["name"]},
            "provisionType": {"code": "kvm"}}


def r_policy(p):
    pt = next(t for t in STATE["policyTypes"] if t["code"] == p["code"])
    out = {"id": p["id"], "name": p["name"], "description": p.get("description"), "enabled": p["enabled"],
           "policyType": dict(pt), "config": p["config"], "refType": p["refType"], "refId": p["refId"],
           "eachUser": p["eachUser"], "owner": {"id": p["accountId"], "name": acct_name(p["accountId"])},
           "site": None, "zone": None, "user": None, "role": None, "accounts": []}
    if p["refType"]:
        out[REF_TYPES[p["refType"]]] = {"id": p["refId"]}
    return out


# ---------------------------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------------------------
ROUTES = []


def route(method, pattern, master_only=False):
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), fn, master_only))
        return fn
    return deco


@route("GET", r"/api/whoami")
def whoami(ctx, m, q, b):
    u = STATE["users"][ctx["user"]]
    return {"user": r_user(u), "isMasterAccount": ctx["master"], "permissions": []}


# --- tenants -----------------------------------------------------------------------------------
@route("GET", r"/api/accounts", master_only=True)
def accounts_list(ctx, m, q, b):
    items = flt_name([r_account(a) for a in STATE["accounts"].values()], q)
    items, meta = page(items, q)
    return {"accounts": items, "meta": meta}


@route("POST", r"/api/accounts", master_only=True)
def accounts_create(ctx, m, q, b):
    a = obj(b, "account")
    check_keys(a, {"name", "description", "active", "parentAccount", "role", "subdomain", "currency",
                   "accountNumber", "accountName", "customerNumber"}, "account")
    name = need(a, "name", "account", [str])
    if any(x["name"].lower() == name.lower() for x in STATE["accounts"].values()):
        raise ApiError(400, f"A tenant named '{name}' already exists", {"name": "must be unique"})
    sub = a.get("subdomain")
    if sub:
        if not re.fullmatch(r"[A-Za-z0-9-]+", sub):
            raise ApiError(400, "subdomain is invalid")
        if any((x["subdomain"] or "").lower() == sub.lower() for x in STATE["accounts"].values()):
            raise ApiError(400, "subdomain must be unique", {"subdomain": "must be unique"})
    if a.get("currency") and a["currency"] not in CURRENCIES:
        raise ApiError(400, "currency is invalid")
    role_id = None
    if a.get("role") is not None:
        role_id = ref_id(a["role"], "account.role")
        r = STATE["roles"].get(role_id)
        if not r or r["roleType"] != "account" or r["owner"] != 1:
            raise ApiError(400, f"Tenant role {role_id} not found", {"role": "invalid"})
    aid = nid()
    STATE["accounts"][aid] = {"id": aid, "name": name, "subdomain": sub, "description": a.get("description"),
                              "currency": a.get("currency", "USD"), "role": role_id, "master": False, "instances": 0}
    for r in list(STATE["roles"].values()):  # multitenant roles are copied into every new tenant
        if r["multitenant"] and r["owner"] == 1:
            rid = nid()
            copy_r = copy.deepcopy(r)
            copy_r.update(id=rid, owner=aid, multitenant=False)
            STATE["roles"][rid] = copy_r
    return {"success": True, "account": r_account(STATE["accounts"][aid])}


@route("GET", r"/api/accounts/(\d+)", master_only=True)
def accounts_get(ctx, m, q, b):
    a = STATE["accounts"].get(int(m[1]))
    if not a:
        raise ApiError(404, "Tenant not found")
    return {"account": r_account(a)}


@route("DELETE", r"/api/accounts/(\d+)", master_only=True)
def accounts_delete(ctx, m, q, b):
    aid = int(m[1])
    a = STATE["accounts"].get(aid)
    if not a or a["master"]:
        raise ApiError(404, "Tenant not found")
    if a["instances"] and str(q.get("removeResources", "")).lower() not in ("true", "on", "1"):
        raise ApiError(400, f"Tenant has {a['instances']} instance(s). Remove them first or pass removeResources=true.")
    for coll in ("users", "groups", "optionLists", "optionTypes", "catalogItems", "blueprints", "policies"):
        for oid in [k for k, v in STATE[coll].items() if v.get("accountId") == aid]:
            del STATE[coll][oid]
    for rid in [k for k, v in STATE["roles"].items() if v["owner"] == aid]:
        del STATE["roles"][rid]
    for zid in [k for k, v in STATE["zones"].items() if v["accountId"] == aid]:
        del STATE["zones"][zid]  # a cloud assigned to the tenant goes with it
        for coll in ("pools", "datastores", "networks"):
            for oid in [k for k, v in STATE[coll].items() if v["zoneId"] == zid]:
                del STATE[coll][oid]
    for coll in ("pools", "datastores", "networks"):
        for o in STATE[coll].values():
            o["tenants"] = [t for t in o["tenants"] if t != aid]
    del STATE["accounts"][aid]
    return {"success": True}


def tenant_or_404(aid):
    a = STATE["accounts"].get(aid)
    if not a or a["master"]:
        raise ApiError(404, "Tenant not found")
    return a


def validate_user_body(u, aid, creating):
    check_keys(u, USER_KEYS, "user")
    if creating:
        username = need(u, "username", "user", [str])
        need(u, "email", "user", [str])
        need(u, "password", "user", [str])
        need(u, "roles", "user", [list])
        if any(x["username"].lower() == username.lower() and x["accountId"] == aid for x in STATE["users"].values()):
            raise ApiError(400, f"Username '{username}' already exists in this tenant", {"username": "must be unique"})
    role_ids = []
    for r in u.get("roles", []) or []:
        rid = ref_id(r, "user.roles[]")
        role = STATE["roles"].get(rid)
        if not role or role["owner"] != aid or role["roleType"] != "user":
            raise ApiError(400, f"Role {rid} is not available in this tenant", {"roles": "invalid"})
        role_ids.append(rid)
    if "password" in u and len(u["password"]) < 8:
        raise ApiError(400, "password must be at least 8 characters", {"password": "too short"})
    return role_ids


@route("GET", r"/api/accounts/(\d+)/users", master_only=True)
def tusers_list(ctx, m, q, b):
    aid = int(m[1])
    tenant_or_404(aid)
    items = [r_user(u) for u in STATE["users"].values() if u["accountId"] == aid]
    items = flt_name(items, q, "username")
    items, meta = page(items, q)
    return {"users": items, "meta": meta}


@route("POST", r"/api/accounts/(\d+)/users", master_only=True)
def tusers_create(ctx, m, q, b):
    aid = int(m[1])
    tenant_or_404(aid)
    u = obj(b, "user")
    roles = validate_user_body(u, aid, True)
    uid = nid()
    STATE["users"][uid] = {"id": uid, "username": u["username"], "email": u["email"],
                           "firstName": u.get("firstName"), "lastName": u.get("lastName"), "accountId": aid,
                           "password": u["password"], "roles": roles,
                           "passwordExpired": bool(u.get("passwordExpired", False))}
    return {"success": True, "user": r_user(STATE["users"][uid])}


@route("PUT", r"/api/accounts/(\d+)/users/(\d+)", master_only=True)
def tusers_update(ctx, m, q, b):
    aid, uid = int(m[1]), int(m[2])
    usr = STATE["users"].get(uid)
    if not usr or usr["accountId"] != aid:
        raise ApiError(404, "User not found")
    u = obj(b, "user")
    roles = validate_user_body(u, aid, False)
    if "password" in u:
        if "passwordConfirmation" in u and u["passwordConfirmation"] != u["password"]:
            raise ApiError(400, "passwordConfirmation does not match")
        usr["password"] = u["password"]
    if "roles" in u:
        usr["roles"] = roles
    return {"success": True, "user": r_user(usr)}


@route("DELETE", r"/api/accounts/(\d+)/users/(\d+)", master_only=True)
def tusers_delete(ctx, m, q, b):
    aid, uid = int(m[1]), int(m[2])
    usr = STATE["users"].get(uid)
    if not usr or usr["accountId"] != aid:
        raise ApiError(404, "User not found")
    del STATE["users"][uid]
    return {"success": True}


@route("GET", r"/api/accounts/(\d+)/users/available-roles", master_only=True)
def tusers_roles(ctx, m, q, b):
    aid = int(m[1])
    tenant_or_404(aid)
    return {"roles": [r_role(r) for r in STATE["roles"].values() if r["owner"] == aid and r["roleType"] == "user"]}


# --- roles -------------------------------------------------------------------------------------
def visible_roles(ctx, q):
    if ctx["master"] and q.get("tenant"):
        owner = int(q["tenant"])
    else:
        owner = ctx["acct"]
    rs = [r for r in STATE["roles"].values() if r["owner"] == owner]
    if q.get("roleType"):
        rs = [r for r in rs if r["roleType"] == q["roleType"]]
    return rs


def role_visible(rid, ctx):
    r = STATE["roles"].get(rid)
    if not r or not (ctx["master"] or r["owner"] == ctx["acct"]):
        raise ApiError(404, f"Role {rid} not found")
    return r


@route("GET", r"/api/roles")
def roles_list(ctx, m, q, b):
    items = [r_role(r) for r in visible_roles(ctx, q)]
    if q.get("name"):
        items = [i for i in items if i["authority"].lower() == q["name"].lower()]
    items, meta = page(items, q)
    return {"roles": items, "meta": meta}


@route("POST", r"/api/roles")
def roles_create(ctx, m, q, b):
    r = obj(b, "role")
    check_keys(r, ROLE_KEYS, "role")
    authority = need(r, "authority", "role", [str])
    rtype = r.get("roleType", "user")
    if rtype not in ("user", "account"):
        raise ApiError(400, "roleType must be user or account")
    owner = ctx["acct"]
    for k in ("owner", "tenant", "tenantId"):
        if r.get(k) is not None:
            o = ref_id(r[k], "role." + k)
            if o != ctx["acct"] and not ctx["master"]:
                raise ApiError(403, "Only the master tenant can create roles for another tenant")
            if o not in STATE["accounts"]:
                raise ApiError(400, f"Tenant {o} not found")
            owner = o
    if rtype == "account" and owner != 1:
        raise ApiError(400, "Tenant roles can only be owned by the master tenant")
    if any(x["authority"].lower() == authority.lower() and x["owner"] == owner and x["roleType"] == rtype
           for x in STATE["roles"].values()):
        raise ApiError(400, f"A role named '{authority}' already exists", {"authority": "must be unique"})
    rid = nid()
    rec = new_role_record(rid, authority, rtype, owner)
    if r.get("baseRoleId") is not None:
        base = STATE["roles"].get(as_id(r["baseRoleId"], "role.baseRoleId"))
        if not base or base["roleType"] != rtype or base["owner"] not in (1, owner):
            raise ApiError(400, "baseRoleId is not a role you can copy from", {"baseRoleId": "invalid"})
        for k in ("features", "globalSiteAccess", "globalZoneAccess", "globalCatalogItemTypeAccess",
                  "globalAppTemplateAccess", "defaultPersona"):
            rec[k] = copy.deepcopy(base[k])
    rec["description"] = r.get("description")
    if r.get("defaultPersona") is not None:
        p = r["defaultPersona"]
        p = p.get("code") if isinstance(p, dict) else p
        if p not in PERSONAS:
            raise ApiError(400, "defaultPersona is invalid")
        rec["defaultPersona"] = p
    for k, allowed in (("globalSiteAccess", {"full", "read", "none"}), ("globalZoneAccess", {"full", "read", "none"}),
                       ("globalCatalogItemTypeAccess", {"full", "none"}), ("globalAppTemplateAccess", {"full", "none"})):
        if r.get(k) is not None:
            rec[k] = access(r[k], allowed, "role." + k)
    for fp in r.get("featurePermissions") or []:
        code = need(fp, "code", "role.featurePermissions[]", [str])
        if code not in FEATURE_CODES:
            raise ApiError(400, f"Unknown feature permission code '{code}'")
        rec["features"][code] = access(fp.get("access"), FEATURE_ACCESS, "featurePermissions.access")
    STATE["roles"][rid] = rec
    return {"success": True, "role": r_role(rec)}


@route("GET", r"/api/roles/(\d+)")
def roles_get(ctx, m, q, b):
    return r_role_full(role_visible(int(m[1]), ctx))


@route("PUT", r"/api/roles/(\d+)")
def roles_update(ctx, m, q, b):
    rec = role_visible(int(m[1]), ctx)
    r = obj(b, "role")
    check_keys(r, {"authority", "name", "description", "landingUrl", "multitenant", "multitenantLocked", "defaultPersona"}, "role")
    if "defaultPersona" in r:
        p = r["defaultPersona"]
        p = p.get("code") if isinstance(p, dict) else p
        if p not in PERSONAS:
            raise ApiError(400, "defaultPersona is invalid")
        rec["defaultPersona"] = p
    if "description" in r:
        rec["description"] = r["description"]
    if "authority" in r:
        rec["authority"] = r["authority"]
    return {"success": True, "role": r_role(rec)}


@route("DELETE", r"/api/roles/(\d+)")
def roles_delete(ctx, m, q, b):
    rid = int(m[1])
    role_visible(rid, ctx)
    if any(rid in u["roles"] for u in STATE["users"].values()):
        raise ApiError(400, "Role is assigned to one or more users and cannot be deleted")
    if any(a["role"] == rid for a in STATE["accounts"].values()):
        raise ApiError(400, "Role is the base role of a tenant and cannot be deleted")
    del STATE["roles"][rid]
    return {"success": True}


def role_access_update(ctx, m, b, id_key, all_key, allowed, store, lookup):
    rec = role_visible(int(m[1]), ctx)
    if not isinstance(b, dict):
        raise ApiError(400, "body must be an object")
    a = access(b.get("access"), allowed, "access")
    if b.get(all_key) or b.get("all"):
        check_keys(b, {all_key, "all", "access"}, "body")
        rec["global" + store[0]] = a
        return {"success": True, "access": a}
    check_keys(b, {id_key, "access"} | set(store[2]), "body")
    oid = as_id(need(b, id_key, "body"), id_key)
    lookup(oid, rec)
    rec[store[1]][oid] = a
    return {"success": True, "access": a}


def lookup_group(gid, rec):
    g = STATE["groups"].get(gid)
    if not g or g["accountId"] != rec["owner"]:
        raise ApiError(400, f"Group {gid} does not belong to the role's tenant")


def lookup_zone(zid, rec):
    z = STATE["zones"].get(zid)
    if not z or not (z["accountId"] == rec["owner"] or z["visibility"] == "public" or rec["owner"] == 1):
        raise ApiError(400, f"Cloud {zid} is not available to the role's tenant (is it Public?)")


def lookup_cit(cid, rec):
    c = STATE["catalogItems"].get(cid)
    if not c or c["accountId"] != rec["owner"]:
        raise ApiError(400, f"Catalog item {cid} does not belong to the role's tenant")


def lookup_bp(bid, rec):
    c = STATE["blueprints"].get(bid)
    if not c or c["accountId"] != rec["owner"]:
        raise ApiError(400, f"Blueprint {bid} does not belong to the role's tenant")


@route("PUT", r"/api/roles/(\d+)/update-group")
def ru_group(ctx, m, q, b):
    return role_access_update(ctx, m, b, "groupId", "allGroups", ACCESS3, ("SiteAccess", "sites", []), lookup_group)


@route("PUT", r"/api/roles/(\d+)/update-cloud")
def ru_cloud(ctx, m, q, b):
    return role_access_update(ctx, m, b, "cloudId", "allClouds", ACCESS3, ("ZoneAccess", "zones", []), lookup_zone)


@route("PUT", r"/api/roles/(\d+)/update-catalog-item-type")
def ru_cit(ctx, m, q, b):
    return role_access_update(ctx, m, b, "catalogItemTypeId", "allCatalogItemTypes", ACCESS2,
                              ("CatalogItemTypeAccess", "catalogItemTypes", []), lookup_cit)


@route("PUT", r"/api/roles/(\d+)/update-blueprint")
def ru_bp(ctx, m, q, b):
    return role_access_update(ctx, m, b, "blueprintId", "allBlueprints", ACCESS2,
                              ("AppTemplateAccess", "appTemplates", []), lookup_bp)


@route("PUT", r"/api/roles/(\d+)/update-persona")
def ru_persona(ctx, m, q, b):
    rec = role_visible(int(m[1]), ctx)
    check_keys(b, {"personaCode", "personaId", "allPersonas", "all", "access"}, "body")
    a = access(b.get("access"), ACCESS2, "access")
    if b.get("allPersonas") or b.get("all"):
        rec["globalPersonaAccess"] = a
    else:
        code = need(b, "personaCode", "body", [str])
        if code not in PERSONAS:
            raise ApiError(400, f"Unknown persona '{code}'")
        rec["personas"][code] = a
    return {"success": True, "access": a}


@route("PUT", r"/api/roles/(\d+)/update-permission")
def ru_perm(ctx, m, q, b):
    rec = role_visible(int(m[1]), ctx)
    check_keys(b, {"permissionCode", "access"}, "body")
    code = need(b, "permissionCode", "body", [str])
    if code in SPECIAL_PERMISSION_CODES:
        access(b.get("access"), ACCESS3, "access")
        return {"success": True, "access": b["access"]}
    if code not in FEATURE_CODES:
        raise ApiError(400, f"Unknown permissionCode '{code}'", {"permissionCode": "invalid"})
    rec["features"][code] = access(b.get("access"), FEATURE_ACCESS, "access")
    return {"success": True, "access": b["access"]}


@route("GET", r"/api/options/copyFromRole", master_only=True)
def opt_copy_from(ctx, m, q, b):
    rtype = q.get("roleType", "user")
    tid = int(q["tenantId"]) if q.get("tenantId") else 1
    rs = [r for r in STATE["roles"].values() if r["roleType"] == rtype and r["owner"] in (1, tid)]
    return {"success": True, "data": [{"name": r["authority"], "value": r["id"]} for r in rs]}


# --- clouds and their resources ---------------------------------------------------------------
@route("GET", r"/api/zones")
def zones_list(ctx, m, q, b):
    items = flt_name([r_zone(z) for z in STATE["zones"].values() if zone_visible(z, ctx)], q)
    items, meta = page(items, q)
    return {"zones": items, "meta": meta}


@route("GET", r"/api/zones/(\d+)")
def zones_get(ctx, m, q, b):
    return {"zone": r_zone(get_zone(int(m[1]), ctx))}


@route("PUT", r"/api/zones/(\d+)", master_only=True)
def zones_update(ctx, m, q, b):
    z = get_zone(int(m[1]), ctx)
    zb = obj(b, "zone")
    check_keys(zb, {"name", "code", "labels", "location", "visibility", "accountId", "enabled", "groupId"}, "zone")
    if "visibility" in zb:
        z["visibility"] = access(zb["visibility"], {"public", "private"}, "zone.visibility")
    if "accountId" in zb:
        aid = as_id(zb["accountId"], "zone.accountId")
        if aid not in STATE["accounts"]:
            raise ApiError(400, f"Tenant {aid} not found")
        z["accountId"] = aid
    return {"success": True, "zone": r_zone(z)}


def res_list(coll, render, key, ctx, zid, q, top_tenants=False):
    get_zone(zid, ctx)
    objs = [o for o in STATE[coll].values() if o["zoneId"] == zid and shared_visible(o, ctx)]
    items = flt_name([render(o) for o in objs], q)
    items, meta = page(items, q)
    out = {key: items, "meta": meta}
    if top_tenants:
        out["tenants"] = {str(o["id"]): tenants_of(o) for o in objs}
    return out


def res_get(coll, ctx, zid, oid, label):
    get_zone(zid, ctx)
    o = STATE[coll].get(oid)
    if not o or o["zoneId"] != zid or not shared_visible(o, ctx):
        raise ApiError(404, f"{label} {oid} not found")
    return o


def res_update(o, b, key):
    check_keys(b, {key, "tenantPermissions", "resourcePermissions"}, "body")
    inner = obj(b, key)
    check_keys(inner, {"visibility", "name", "active", "defaultStore", "defaultImage"}, key)
    if "visibility" in inner:
        o["visibility"] = access(inner["visibility"], {"public", "private"}, key + ".visibility")
    if "tenantPermissions" in b:
        tp = b["tenantPermissions"]
        if not isinstance(tp, dict):
            raise ApiError(400, "tenantPermissions must be an object")
        check_keys(tp, {"accounts"}, "tenantPermissions")
        ids = [as_id(x, "tenantPermissions.accounts[]") for x in tp.get("accounts") or []]
        for t in ids:
            if t not in STATE["accounts"]:
                raise ApiError(400, f"Tenant {t} not found")
        o["tenants"] = sorted(set(ids))


@route("GET", r"/api/zones/(\d+)/resource-pools")
def pools_list(ctx, m, q, b):
    return res_list("pools", r_pool, "resourcePools", ctx, int(m[1]), q, top_tenants=True)


@route("GET", r"/api/zones/(\d+)/resource-pools/(\d+)")
def pools_get(ctx, m, q, b):
    return {"resourcePool": r_pool(res_get("pools", ctx, int(m[1]), int(m[2]), "Resource pool"))}


@route("PUT", r"/api/zones/(\d+)/resource-pools/(\d+)", master_only=True)
def pools_update(ctx, m, q, b):
    o = res_get("pools", ctx, int(m[1]), int(m[2]), "Resource pool")
    res_update(o, b, "resourcePool")
    return {"success": True, "resourcePool": r_pool(o)}


@route("GET", r"/api/zones/(\d+)/data-stores")
def ds_list(ctx, m, q, b):
    return res_list("datastores", r_ds, "datastores", ctx, int(m[1]), q)


@route("GET", r"/api/zones/(\d+)/data-stores/(\d+)")
def ds_get(ctx, m, q, b):
    return {"datastore": r_ds(res_get("datastores", ctx, int(m[1]), int(m[2]), "Datastore"))}


@route("PUT", r"/api/zones/(\d+)/data-stores/(\d+)", master_only=True)
def ds_update(ctx, m, q, b):
    o = res_get("datastores", ctx, int(m[1]), int(m[2]), "Datastore")
    res_update(o, b, "datastore")
    return {"success": True, "datastore": r_ds(o)}


@route("GET", r"/api/networks")
def nets_list(ctx, m, q, b):
    objs = [n for n in STATE["networks"].values() if shared_visible(n, ctx)]
    if q.get("zoneId"):
        objs = [n for n in objs if n["zoneId"] == int(q["zoneId"])]
    items = flt_name([r_net(n) for n in objs], q)
    items, meta = page(items, q)
    return {"networks": items, "meta": meta}


@route("GET", r"/api/networks/(\d+)")
def nets_get(ctx, m, q, b):
    n = STATE["networks"].get(int(m[1]))
    if not n or not shared_visible(n, ctx):
        raise ApiError(404, "Network not found")
    return {"network": r_net(n)}


@route("PUT", r"/api/networks/(\d+)", master_only=True)
def nets_update(ctx, m, q, b):
    n = STATE["networks"].get(int(m[1]))
    if not n:
        raise ApiError(404, "Network not found")
    check_keys(b, {"network"}, "body")
    nb = obj(b, "network")
    check_keys(nb, {"tenants", "visibility", "resourcePermission", "name", "description"}, "network")
    if "visibility" in nb:
        n["visibility"] = access(nb["visibility"], {"public", "private"}, "network.visibility")
    if "tenants" in nb:
        ids = [ref_id(t, "network.tenants[]") for t in nb["tenants"] or []]
        for t in ids:
            if t not in STATE["accounts"]:
                raise ApiError(400, f"Tenant {t} not found")
        n["tenants"] = sorted(set(ids))
    return {"success": True, "network": r_net(n)}


# --- groups and users (tenant-scoped) ---------------------------------------------------------
@route("GET", r"/api/groups")
def groups_list(ctx, m, q, b):
    items = flt_name([r_group(g) for g in STATE["groups"].values() if g["accountId"] == ctx["acct"]], q)
    items, meta = page(items, q)
    return {"groups": items, "meta": meta}


@route("POST", r"/api/groups")
def groups_create(ctx, m, q, b):
    g = obj(b, "group")
    check_keys(g, {"name", "code", "labels", "location", "config"}, "group")
    name = need(g, "name", "group", [str])
    if any(x["name"].lower() == name.lower() and x["accountId"] == ctx["acct"] for x in STATE["groups"].values()):
        raise ApiError(400, f"A group named '{name}' already exists", {"name": "must be unique"})
    gid = nid()
    STATE["groups"][gid] = {"id": gid, "name": name, "accountId": ctx["acct"], "zones": []}
    return {"success": True, "group": r_group(STATE["groups"][gid])}


@route("GET", r"/api/groups/(\d+)")
def groups_get(ctx, m, q, b):
    return {"group": r_group(owned("groups", int(m[1]), ctx, "Group"))}


@route("DELETE", r"/api/groups/(\d+)")
def groups_delete(ctx, m, q, b):
    gid = int(m[1])
    owned("groups", gid, ctx, "Group")
    del STATE["groups"][gid]
    for r in STATE["roles"].values():
        r["sites"].pop(gid, None)
    return {"success": True}


@route("PUT", r"/api/groups/(\d+)/update-zones")
def groups_zones(ctx, m, q, b):
    g = owned("groups", int(m[1]), ctx, "Group")
    gb = obj(b, "group")
    check_keys(gb, {"zones"}, "group")
    zones = need(gb, "zones", "group", [list])
    ids = []
    for z in zones:
        zid = ref_id(z, "group.zones[]")
        get_zone(zid, ctx)
        ids.append(zid)
    g["zones"] = sorted(set(ids))
    return {"success": True, "group": r_group(g)}


@route("GET", r"/api/users")
def users_list(ctx, m, q, b):
    items = flt_name([r_user(u) for u in STATE["users"].values() if u["accountId"] == ctx["acct"]], q, "username")
    items, meta = page(items, q)
    return {"users": items, "meta": meta}


@route("POST", r"/api/users")
def users_create(ctx, m, q, b):
    u = obj(b, "user")
    roles = validate_user_body(u, ctx["acct"], True)
    uid = nid()
    STATE["users"][uid] = {"id": uid, "username": u["username"], "email": u["email"],
                           "firstName": u.get("firstName"), "lastName": u.get("lastName"), "accountId": ctx["acct"],
                           "password": u["password"], "roles": roles,
                           "passwordExpired": bool(u.get("passwordExpired", False))}
    return {"success": True, "user": r_user(STATE["users"][uid])}


@route("GET", r"/api/users/(\d+)")
def users_get(ctx, m, q, b):
    return {"user": r_user(owned("users", int(m[1]), ctx, "User"))}


@route("DELETE", r"/api/users/(\d+)")
def users_delete(ctx, m, q, b):
    uid = int(m[1])
    owned("users", uid, ctx, "User")
    if uid == ctx["user"]:
        raise ApiError(400, "You cannot delete yourself")
    del STATE["users"][uid]
    return {"success": True}


# --- read-only library ------------------------------------------------------------------------
@route("GET", r"/api/library/instance-types")
def itypes_list(ctx, m, q, b):
    items = list(STATE["instanceTypes"].values())
    if q.get("code"):
        items = [i for i in items if i["code"] == q["code"]]
    items = flt_name(items, q)
    items, meta = page(items, q)
    return {"instanceTypes": items, "meta": meta}


@route("GET", r"/api/library/layouts")
def layouts_list(ctx, m, q, b):
    items = [r_layout(l) for l in STATE["layouts"].values()]
    if q.get("code"):
        items = [i for i in items if i["code"] == q["code"]]
    items = flt_name(items, q)
    items, meta = page(items, q)
    return {"instanceTypeLayouts": items, "meta": meta}


@route("GET", r"/api/library/layouts/(\d+)")
def layouts_get(ctx, m, q, b):
    l = STATE["layouts"].get(int(m[1]))
    if not l:
        raise ApiError(404, "Layout not found")
    return {"instanceTypeLayout": r_layout(l)}


@route("GET", r"/api/virtual-images")
def images_list(ctx, m, q, b):
    items = flt_name([dict(i) for i in STATE["images"].values() if image_visible(i, ctx)], q)
    items, meta = page(items, q)
    return {"virtualImages": items, "meta": meta}


@route("GET", r"/api/virtual-images/(\d+)")
def images_get(ctx, m, q, b):
    i = STATE["images"].get(int(m[1]))
    if not i or not image_visible(i, ctx):
        raise ApiError(404, "Virtual image not found")
    return {"virtualImage": dict(i)}


@route("GET", r"/api/service-plans")
def plans_list(ctx, m, q, b):
    items = flt_name([dict(p, provisionType={"code": "kvm"}) for p in STATE["plans"].values()], q)
    items, meta = page(items, q)
    return {"servicePlans": items, "meta": meta}


@route("GET", r"/api/service-plans/(\d+)")
def plans_get(ctx, m, q, b):
    p = STATE["plans"].get(int(m[1]))
    if not p:
        raise ApiError(404, "Service plan not found")
    return {"servicePlan": dict(p)}


# --- option lists, inputs, catalog items, blueprints -----------------------------------------
def simple_list(coll, key, ctx, q, render=dict):
    items = [render(o) for o in STATE[coll].values() if o["accountId"] == ctx["acct"]]
    if q.get("fieldName"):
        items = [i for i in items if i.get("fieldName") == q["fieldName"]]
    if q.get("code"):
        items = [i for i in items if i.get("code") == q["code"]]
    items = flt_name(items, q)
    items, meta = page(items, q)
    return {key: items, "meta": meta}


def unique_name(coll, name, ctx, label):
    if any(o["name"].lower() == name.lower() and o["accountId"] == ctx["acct"] for o in STATE[coll].values()):
        raise ApiError(400, f"{label} named '{name}' already exists", {"name": "must be unique"})


@route("GET", r"/api/library/option-type-lists")
def ol_list(ctx, m, q, b):
    return simple_list("optionLists", "optionTypeLists", ctx, q)


@route("POST", r"/api/library/option-type-lists")
def ol_create(ctx, m, q, b):
    o = obj(b, "optionTypeList")
    check_keys(o, {"name", "description", "labels", "type", "visibility", "initialDataset", "sourceUrl",
                   "sourceMethod", "realTime", "translationScript"}, "optionTypeList")
    name = need(o, "name", "optionTypeList", [str])
    unique_name("optionLists", name, ctx, "An option list")
    if o.get("type", "manual") == "manual":
        ds = need(o, "initialDataset", "optionTypeList", [str])
        try:
            parsed = json.loads(ds)
            assert isinstance(parsed, list) and all("name" in x and "value" in x for x in parsed)
        except Exception:
            raise ApiError(400, "initialDataset must be a JSON string of [{name, value}]")
    oid = nid()
    STATE["optionLists"][oid] = {"id": oid, "name": name, "description": o.get("description"),
                                 "type": o.get("type", "manual"), "initialDataset": o.get("initialDataset"),
                                 "accountId": ctx["acct"]}
    return {"success": True, "optionTypeList": dict(STATE["optionLists"][oid])}


@route("GET", r"/api/library/option-type-lists/(\d+)")
def ol_get(ctx, m, q, b):
    return {"optionTypeList": dict(owned("optionLists", int(m[1]), ctx, "Option list"))}


@route("PUT", r"/api/library/option-type-lists/(\d+)")
def ol_update(ctx, m, q, b):
    rec = owned("optionLists", int(m[1]), ctx, "Option list")
    o = obj(b, "optionTypeList")
    check_keys(o, {"name", "description", "initialDataset", "visibility"}, "optionTypeList")
    if "initialDataset" in o:
        json.loads(o["initialDataset"])
        rec["initialDataset"] = o["initialDataset"]
    return {"success": True, "optionTypeList": dict(rec)}


@route("DELETE", r"/api/library/option-type-lists/(\d+)")
def ol_delete(ctx, m, q, b):
    oid = int(m[1])
    owned("optionLists", oid, ctx, "Option list")
    if any(t.get("optionListId") == oid for t in STATE["optionTypes"].values()):
        raise ApiError(400, "Option list is used by an input and cannot be deleted")
    if any(p["config"].get("valueListId") in (oid, str(oid)) for p in STATE["policies"].values()):
        raise ApiError(400, "Option list is used by a tag policy and cannot be deleted")
    del STATE["optionLists"][oid]
    return {"success": True}


def r_input(o):
    out = {k: v for k, v in o.items() if k != "optionListId"}
    out["optionList"] = {"id": o["optionListId"]} if o.get("optionListId") else None
    return out


@route("GET", r"/api/library/option-types")
def ot_list(ctx, m, q, b):
    return simple_list("optionTypes", "optionTypes", ctx, q, r_input)


@route("POST", r"/api/library/option-types")
def ot_create(ctx, m, q, b):
    o = obj(b, "optionType")
    check_keys(o, {"name", "description", "labels", "fieldName", "type", "fieldLabel", "placeHolder",
                   "verifyPattern", "defaultValue", "required", "exportMeta", "editable", "optionList",
                   "helpBlock", "displayOrder"}, "optionType")
    name = need(o, "name", "optionType", [str])
    need(o, "fieldName", "optionType", [str])
    t = need(o, "type", "optionType", [str])
    if t not in INPUT_TYPES:
        raise ApiError(400, f"Unknown input type '{t}'")
    unique_name("optionTypes", name, ctx, "An input")
    list_id = None
    if t in ("select", "typeahead", "radio"):
        list_id = ref_id(need(o, "optionList", "optionType"), "optionType.optionList")
        owned("optionLists", list_id, ctx, "Option list")
    if "defaultValue" in o and not isinstance(o["defaultValue"], str):
        raise ApiError(400, "optionType.defaultValue must be a string")
    oid = nid()
    rec = {k: v for k, v in o.items() if k != "optionList"}
    rec.update(id=oid, accountId=ctx["acct"], optionListId=list_id)
    STATE["optionTypes"][oid] = rec
    return {"success": True, "optionType": r_input(rec)}


@route("GET", r"/api/library/option-types/(\d+)")
def ot_get(ctx, m, q, b):
    return {"optionType": r_input(owned("optionTypes", int(m[1]), ctx, "Input"))}


@route("DELETE", r"/api/library/option-types/(\d+)")
def ot_delete(ctx, m, q, b):
    oid = int(m[1])
    owned("optionTypes", oid, ctx, "Input")
    if any(oid in c["optionTypes"] for c in STATE["catalogItems"].values()):
        raise ApiError(400, "Input is used by a catalog item and cannot be deleted")
    del STATE["optionTypes"][oid]
    return {"success": True}


def check_pool_ref(ref, zid, ctx, where):
    mm = re.fullmatch(r"pool-(\d+)", str(ref))
    if not mm:
        raise ApiError(400, f"{where} must look like pool-<id> (got {ref!r})")
    pid = int(mm[1])
    p = STATE["pools"].get(pid)
    if not p or p["zoneId"] != zid or not shared_visible(p, ctx):
        raise ApiError(400, f"{where}: resource pool {pid} is not available to this tenant")


def check_vm_config(c, ctx, where, group_by_name=None, zid=None):
    """Checks the references in an instance provisioning config (catalog item or blueprint cloud entry)."""
    if group_by_name is None:
        gid = ref_id(need(c, "group", where), where + ".group")
        g = STATE["groups"].get(gid)
        if not g or g["accountId"] != ctx["acct"]:
            raise ApiError(400, f"{where}.group: group {gid} does not belong to this tenant")
        zid = as_id(need(c, "zoneId", where), where + ".zoneId")
        if zid not in g["zones"]:
            raise ApiError(400, f"{where}: group '{g['name']}' does not contain cloud {zid}")
    get_zone(zid, ctx)
    inst = need(c, "instance", where, [dict])
    layout = c.get("layout") or inst.get("layout")
    lid = ref_id(layout, where + ".layout")
    if lid not in STATE["layouts"]:
        raise ApiError(400, f"{where}: layout {lid} not found")
    plan = c.get("plan")
    if plan is not None and isinstance(plan, dict) and re.fullmatch(r"\d+", str(plan.get("id"))):
        if int(plan["id"]) not in STATE["plans"]:
            raise ApiError(400, f"{where}: plan {plan['id']} not found")
    cfg = need(c, "config", where, [dict])
    iid = as_id(need(cfg, "imageId", where + ".config"), where + ".config.imageId")
    img = STATE["images"].get(iid)
    if not img or not image_visible(img, ctx):
        raise ApiError(400, f"{where}: image {iid} is not visible to this tenant (make it Public or share it)")
    check_pool_ref(need(cfg, "resourcePoolId", where + ".config"), zid, ctx, where + ".config.resourcePoolId")
    for v in need(c, "volumes", where, [list]):
        ds = v.get("datastoreId")
        if ds not in ("auto", "autoCluster", None):
            d = STATE["datastores"].get(as_id(ds, where + ".volumes[].datastoreId"))
            if not d or d["zoneId"] != zid or not shared_visible(d, ctx):
                raise ApiError(400, f"{where}: datastore {ds} is not available to this tenant")
    for nic in need(c, "networkInterfaces", where, [list]):
        nid_ = ref_id(nic.get("network"), where + ".networkInterfaces[].network")
        n = STATE["networks"].get(nid_)
        if not n or not shared_visible(n, ctx):
            raise ApiError(400, f"{where}: network {nid_} is not available to this tenant")
    for t in c.get("tags", []) or []:
        check_keys(t, {"name", "value"}, where + ".tags[]")


@route("GET", r"/api/catalog-item-types")
def cit_list(ctx, m, q, b):
    return simple_list("catalogItems", "catalogItemTypes", ctx, q)


@route("POST", r"/api/catalog-item-types")
def cit_create(ctx, m, q, b):
    c = obj(b, "catalogItemType")
    check_keys(c, {"name", "code", "category", "description", "labels", "type", "visibility", "layoutCode",
                   "iconPath", "enabled", "featured", "allowQuantity", "config", "blueprint", "appSpec",
                   "formType", "optionTypes", "workflow", "context"}, "catalogItemType")
    name = need(c, "name", "catalogItemType", [str])
    unique_name("catalogItems", name, ctx, "A catalog item")
    code = c.get("code")
    if code and any(o.get("code") == code and o["accountId"] == ctx["acct"] for o in STATE["catalogItems"].values()):
        raise ApiError(400, f"Catalog item code '{code}' is already used", {"code": "must be unique"})
    t = need(c, "type", "catalogItemType", [str])
    inputs = [as_id(x, "catalogItemType.optionTypes[]") for x in c.get("optionTypes") or []]
    for oid in inputs:
        owned("optionTypes", oid, ctx, "Input")
    bp = None
    if t == "instance":
        check_vm_config(need(c, "config", "catalogItemType", [dict]), ctx, "catalogItemType.config")
    elif t == "blueprint":
        bp = ref_id(need(c, "blueprint", "catalogItemType"), "catalogItemType.blueprint")
        owned("blueprints", bp, ctx, "Blueprint")
        need(c, "appSpec", "catalogItemType", [str])
    else:
        raise ApiError(400, "catalogItemType.type must be instance or blueprint in this mock")
    cid = nid()
    rec = {k: v for k, v in c.items()}
    rec.update(id=cid, accountId=ctx["acct"], optionTypes=inputs, blueprintId=bp)
    STATE["catalogItems"][cid] = rec
    return {"success": True, "catalogItemType": dict(rec)}


@route("GET", r"/api/catalog-item-types/(\d+)")
def cit_get(ctx, m, q, b):
    return {"catalogItemType": dict(owned("catalogItems", int(m[1]), ctx, "Catalog item"))}


@route("DELETE", r"/api/catalog-item-types/(\d+)")
def cit_delete(ctx, m, q, b):
    cid = int(m[1])
    owned("catalogItems", cid, ctx, "Catalog item")
    del STATE["catalogItems"][cid]
    for r in STATE["roles"].values():
        r["catalogItemTypes"].pop(cid, None)
    return {"success": True}


@route("GET", r"/api/blueprints")
def bp_list(ctx, m, q, b):
    items = [{"id": o["id"], "name": o["name"], "type": o["type"], "config": o["config"]}
             for o in STATE["blueprints"].values() if o["accountId"] == ctx["acct"]]
    items = flt_name(items, q)
    items, meta = page(items, q)
    return {"blueprints": items, "meta": meta}


@route("POST", r"/api/blueprints")
def bp_create(ctx, m, q, b):
    if not isinstance(b, dict):
        raise ApiError(400, "body must be an object")
    check_keys(b, {"name", "type", "labels", "tiers", "image", "description", "category"}, "blueprint")
    name = need(b, "name", "blueprint", [str])
    if need(b, "type", "blueprint", [str]) != "morpheus":
        raise ApiError(400, "only type morpheus is supported by this mock")
    tiers = need(b, "tiers", "blueprint", [dict])
    unique_name("blueprints", name, ctx, "A blueprint")
    for tname, tier in tiers.items():
        where = f"tiers.{tname}"
        for link in tier.get("linkedTiers", []):
            if link not in tiers:
                raise ApiError(400, f"{where}.linkedTiers references unknown tier '{link}'")
        for i, inst in enumerate(need(tier, "instances", where, [list])):
            w = f"{where}.instances[{i}]"
            need(need(inst, "instance", w, [dict]), "type", w + ".instance", [str])
            for gname, gval in need(inst, "groups", w, [dict]).items():
                g = next((x for x in STATE["groups"].values() if x["name"] == gname and x["accountId"] == ctx["acct"]), None)
                if not g:
                    raise ApiError(400, f"{w}.groups: group '{gname}' not found in this tenant")
                for cname, cval in need(gval, "clouds", f"{w}.groups.{gname}", [dict]).items():
                    z = next((x for x in STATE["zones"].values() if x["name"] == cname and zone_visible(x, ctx)), None)
                    if not z:
                        raise ApiError(400, f"{w}: cloud '{cname}' not visible to this tenant")
                    if z["id"] not in g["zones"]:
                        raise ApiError(400, f"{w}: group '{gname}' does not contain cloud '{cname}'")
                    check_vm_config(cval, ctx, f"{w}.groups.{gname}.clouds.{cname}", group_by_name=gname, zid=z["id"])
    bid = nid()
    STATE["blueprints"][bid] = {"id": bid, "name": name, "type": "morpheus", "accountId": ctx["acct"],
                                "config": {"name": name, "type": "morpheus", "tiers": tiers}}
    return {"success": True, "blueprint": {"id": bid, "name": name, "type": "morpheus",
                                           "config": STATE["blueprints"][bid]["config"]}}


@route("GET", r"/api/blueprints/(\d+)")
def bp_get(ctx, m, q, b):
    o = owned("blueprints", int(m[1]), ctx, "Blueprint")
    return {"blueprint": {"id": o["id"], "name": o["name"], "type": o["type"], "config": o["config"]}}


@route("DELETE", r"/api/blueprints/(\d+)")
def bp_delete(ctx, m, q, b):
    bid = int(m[1])
    owned("blueprints", bid, ctx, "Blueprint")
    if any(c.get("blueprintId") == bid for c in STATE["catalogItems"].values()):
        raise ApiError(400, "Blueprint is used by a catalog item and cannot be deleted")
    del STATE["blueprints"][bid]
    return {"success": True}


# --- policies ---------------------------------------------------------------------------------
@route("GET", r"/api/policy-types")
def ptypes(ctx, m, q, b):
    return {"policyTypes": [dict(t) for t in STATE["policyTypes"]]}


@route("GET", r"/api/policies")
def pol_list(ctx, m, q, b):
    items = flt_name([r_policy(p) for p in STATE["policies"].values() if p["accountId"] == ctx["acct"]], q)
    items, meta = page(items, q)
    return {"policies": items, "meta": meta}


@route("POST", r"/api/policies")
def pol_create(ctx, m, q, b):
    p = obj(b, "policy")
    check_keys(p, {"name", "description", "enabled", "policyType", "config", "refType", "refId", "accounts",
                   "eachUser", "site", "zone", "user", "role"}, "policy")
    name = need(p, "name", "policy", [str])
    unique_name("policies", name, ctx, "A policy")
    pt = need(p, "policyType", "policy", [dict])
    code = pt.get("code")
    if not any(t["code"] == code for t in STATE["policyTypes"]):
        raise ApiError(400, f"Policy type '{code}' is not available on this appliance", {"policyType": "invalid"})
    cfg = need(p, "config", "policy", [dict])
    allowed, required = POLICY_CONFIG.get(code, (set(), set()))
    check_keys(cfg, allowed, "policy.config")
    for k in required:
        need(cfg, k, "policy.config")
    if code == "naming" and cfg["namingType"] not in ("user", "fixed"):
        raise ApiError(400, "config.namingType must be user or fixed")
    if code in ("provisionApproval", "deleteApproval") and str(cfg["accountIntegrationId"]) != "-100":
        raise ApiError(400, "config.accountIntegrationId must be -100 (internal approvals) in this mock")
    if code == "tags" and cfg.get("valueListId") not in (None, ""):
        owned("optionLists", as_id(cfg["valueListId"], "config.valueListId"), ctx, "Option list")
    for k in ("maxVms", "maxCores", "maxMemory", "maxStorage"):
        if k in cfg and not re.fullmatch(r"\d+", str(cfg[k])):
            raise ApiError(400, f"config.{k} must be a whole number")
    ref_type, ref = p.get("refType"), p.get("refId")
    if ref_type is not None:
        if ref_type not in REF_TYPES:
            raise ApiError(400, f"refType must be one of {sorted(REF_TYPES)}")
        rid = as_id(ref, "policy.refId")
        key = REF_TYPES[ref_type]
        if p.get(key) is not None and ref_id(p[key], "policy." + key) != rid:
            raise ApiError(400, f"policy.{key}.id does not match refId")
        if ref_type == "ComputeSite":
            owned("groups", rid, ctx, "Group")
        elif ref_type == "ComputeZone":
            get_zone(rid, ctx)
        elif ref_type == "User":
            owned("users", rid, ctx, "User")
        elif ref_type == "Role":
            role_visible(rid, ctx)
    pid = nid()
    STATE["policies"][pid] = {"id": pid, "name": name, "description": p.get("description"), "code": code,
                              "config": cfg, "enabled": p.get("enabled", True), "refType": ref_type,
                              "refId": as_id(ref, "refId") if ref is not None else None,
                              "eachUser": bool(p.get("eachUser", False)), "accountId": ctx["acct"]}
    return {"success": True, "policy": r_policy(STATE["policies"][pid])}


@route("GET", r"/api/policies/(\d+)")
def pol_get(ctx, m, q, b):
    return {"policy": r_policy(owned("policies", int(m[1]), ctx, "Policy"))}


@route("DELETE", r"/api/policies/(\d+)")
def pol_delete(ctx, m, q, b):
    pid = int(m[1])
    owned("policies", pid, ctx, "Policy")
    del STATE["policies"][pid]
    return {"success": True}


# ---------------------------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------------------------
def oauth_token(form):
    for k, v in (("grant_type", "password"), ("client_id", "morph-api")):
        if form.get(k) != v:
            raise ApiError(400, f"{k} must be {v}")
    username = form.get("username", "")
    password = form.get("password", "")
    if "\\" in username:
        prefix, uname = username.split("\\", 1)
        acct = next((a for a in STATE["accounts"].values()
                     if (a["subdomain"] or "").lower() == prefix.lower() or str(a["id"]) == prefix), None)
        aid = acct["id"] if acct else None
    else:
        uname, aid = username, 1
    user = next((u for u in STATE["users"].values() if u["accountId"] == aid and u["username"] == uname), None)
    if not user or user["password"] != password:
        raise ApiError(400, "invalid_grant: Bad credentials")
    if user.get("passwordExpired"):
        raise ApiError(400, "invalid_grant: Password expired - change it in the UI first")
    token = secrets.token_hex(16)
    STATE["tokens"][token] = user["id"]
    return {"access_token": token, "refresh_token": secrets.token_hex(16), "expires_in": 3600,
            "token_type": "bearer", "scope": "write"}


class Handler(BaseHTTPRequestHandler):
    server_version = "MockMorpheus/1.0"

    def log_message(self, fmt, *args):
        if self.server.verbose:
            sys.stderr.write("mock: " + (fmt % args) + "\n")

    def send_json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.rstrip("/") or "/"
        q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            with LOCK:
                result = self.dispatch(method, path, q, raw)
            self.send_json(200, result)
        except ApiError as e:
            payload = {"success": False, "msg": e.msg, "errors": e.errors}
            if e.status == 401:
                payload = {"error": "invalid_token", "error_description": e.msg}
            self.send_json(e.status, payload)
        except Exception as e:  # pragma: no cover - surfaces mock bugs loudly
            self.send_json(500, {"success": False, "msg": f"mock error: {type(e).__name__}: {e}"})

    def dispatch(self, method, path, q, raw):
        global STATE
        if path.startswith("/__mock/"):
            return self.mock_helper(method, path, q)
        if path == "/oauth/token" and method == "POST":
            if "application/x-www-form-urlencoded" not in (self.headers.get("Content-Type") or ""):
                raise ApiError(400, "oauth/token needs application/x-www-form-urlencoded")
            form = dict(urllib.parse.parse_qsl(raw.decode()))
            STATE["requests"].append({"method": method, "path": path, "body": {k: v for k, v in form.items() if k != "password"}})
            return oauth_token(form)
        auth = self.headers.get("Authorization") or ""
        token = auth[7:] if auth.startswith("Bearer ") else None
        uid = STATE["tokens"].get(token)
        if not uid or uid not in STATE["users"]:
            raise ApiError(401, "Invalid access token")
        user = STATE["users"][uid]
        ctx = {"user": uid, "acct": user["accountId"], "master": user["accountId"] == 1}
        body = None
        if raw:
            if "application/json" not in (self.headers.get("Content-Type") or ""):
                raise ApiError(400, "Content-Type must be application/json")
            try:
                body = json.loads(raw)
            except json.JSONDecodeError:
                raise ApiError(400, "Request body is not valid JSON")
        STATE["requests"].append({"method": method, "path": path, "query": q, "body": body,
                                  "as": "master" if ctx["master"] else f"tenant:{ctx['acct']}"})
        for m_, rx, fn, master_only in ROUTES:
            if m_ != method:
                continue
            mt = rx.match(path)
            if mt:
                if master_only:
                    require_master(ctx)
                return fn(ctx, mt, q, body)
        raise ApiError(404, f"No route for {method} {path}")

    def mock_helper(self, method, path, q):
        global STATE
        if path == "/__mock/state":
            return {k: v for k, v in STATE.items() if k not in ("tokens", "requests")}
        if path == "/__mock/requests":
            return {"requests": STATE["requests"]}
        if path == "/__mock/reset" and method == "POST":
            STATE = seed(MASTER_TOKEN)
            return {"success": True}
        if path == "/__mock/instances" and method == "POST":
            STATE["accounts"][int(q["tenantId"])]["instances"] = int(q.get("count", 1))
            return {"success": True}
        if path == "/__mock/disable-policy-type" and method == "POST":
            STATE["policyTypes"] = [t for t in STATE["policyTypes"] if t["code"] != q["code"]]
            return {"success": True}
        raise ApiError(404, "unknown mock helper")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    global STATE, MASTER_TOKEN
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--cert")
    ap.add_argument("--key")
    ap.add_argument("--token", default="mock-master-token")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    MASTER_TOKEN = a.token
    STATE = seed(MASTER_TOKEN)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    srv.verbose = a.verbose
    if a.cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(a.cert, a.key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"mock morpheus listening on {'https' if a.cert else 'http'}://127.0.0.1:{a.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

# 02 — Code Review Findings (Evaluator's Perspective)

> **Read this first, before you touch anything else.**
>
> This is the review an experienced interviewer will perform on your branch. Findings are ordered by
> the severity with which they will hurt you in the room, not by file. For each one you get:
> **what it is → why it matters → the fix → what to say if it is still unfixed on the day.**

---

## How an evaluator will actually attack this repo

They will do roughly this, in this order, in under fifteen minutes:

1. `git clone` and look at the top-level `README.md`. **Yours is one line: `# br-IaC`.**
2. `terraform init` / `terraform validate` in whatever looks like the root module.
3. `helm lint` and `helm template` the chart.
4. `grep -ri "password\|secret\|key" .` to check for committed credentials.
5. Open the pipeline YAML and trace the promotion path from commit to prod.
6. Cross-check three names that *must* agree: the Kubernetes namespace, the ServiceAccount name, and
   the federated identity credential subject.

Steps 2, 3 and 6 currently fail. Step 1 makes a poor first impression. Everything below flows from that.

---

## Severity legend

| Severity | Meaning |
|---|---|
| **P0 — Blocker** | The code cannot deploy, or a stated requirement is entirely absent. Interviewer will notice within minutes. |
| **P1 — Serious** | Deploys but is functionally wrong, insecure, or contradicts a claim you make in docs. |
| **P2 — Quality** | Works, but a senior reviewer will flag it as sloppiness or missed rigour. |
| **P3 — Polish** | Nice-to-have; mention it yourself to show you know. |

---

# P0 — Blockers

## P0-1. There is no application. `application/` is an empty directory.

**What it is.** The assessment's Part 2 requires: *"Implement `GET /api/shows`: retrieve TVMaze data,
cache it in Blob Storage, and return cached data when appropriate"* and *"Use Azure SDK / managed
identity authentication."* Your repo has `application/` as an **empty folder** — no source, no
`Dockerfile`, no `package.json`.

**Why it matters.** Multiple parts of your own repo depend on it and therefore cannot run:

- `pipelines/templates/stage-validate.yml` → `AppValidate` job does `cd $(appPath) && npm ci` → fails.
- `pipelines/templates/stage-build-image.yml` → `docker build --file $(appPath)/Dockerfile` → fails.
- `pipelines/templates/stage-security.yml` → `trivy fs $(appPath)` and `npm audit` → fails.
- `scripts/smoke-test.sh` expects `/api/shows` to return `{"count":N,"source":"..."}`, `/readyz` to
  return `{"status":"ready"}`, and an `X-Cache: HIT|MISS` header. Nothing implements this contract.
- `charts/.../configmap.yaml` publishes `STORAGE_ACCOUNT_NAME`, `CACHE_CONTAINER`, `CACHE_TTL_SECONDS`,
  `TVMAZE_BASE_URL`, `UPSTREAM_TIMEOUT_MS` — a contract with an application that does not exist.

This is the single most damaging gap, because the assessment explicitly says the app logic is *easy*
and should take almost no time. Its absence reads as "did not finish", not "prioritised platform".

**The fix.** Write it. It is ~120 lines of Node.js honouring every contract your repo already assumes:

```javascript
// application/src/server.js
import express from "express";
import { DefaultAzureCredential } from "@azure/identity";
import { BlobServiceClient } from "@azure/storage-blob";

const {
  STORAGE_ACCOUNT_NAME, CACHE_CONTAINER = "shows-cache",
  CACHE_TTL_SECONDS = "3600", TVMAZE_BASE_URL = "https://api.tvmaze.com",
  UPSTREAM_TIMEOUT_MS = "5000", PORT = 8080
} = process.env;

const CACHE_BLOB = "shows.json";

// DefaultAzureCredential picks up the Workload Identity env vars that the AKS
// mutating webhook injects: AZURE_CLIENT_ID, AZURE_TENANT_ID,
// AZURE_FEDERATED_TOKEN_FILE, AZURE_AUTHORITY_HOST. No secret, no storage key.
const credential = new DefaultAzureCredential();
const container = new BlobServiceClient(
  `https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net`, credential
).getContainerClient(CACHE_CONTAINER);
const blob = container.getBlockBlobClient(CACHE_BLOB);

async function readCache() {
  try {
    const props = await blob.getProperties();
    const ageSeconds = (Date.now() - props.lastModified.getTime()) / 1000;
    if (ageSeconds > Number(CACHE_TTL_SECONDS)) return null;   // stale
    return JSON.parse((await blob.downloadToBuffer()).toString());
  } catch (e) {
    if (e.statusCode === 404) return null;                      // cold cache
    throw e;                                                    // 403 etc. must surface
  }
}

async function fetchUpstream() {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), Number(UPSTREAM_TIMEOUT_MS));
  try {
    const r = await fetch(`${TVMAZE_BASE_URL}/shows?page=0`, { signal: ac.signal });
    if (!r.ok) throw new Error(`TVMaze responded ${r.status}`);
    return await r.json();
  } finally { clearTimeout(t); }
}

const app = express();

app.get("/api/shows", async (_req, res) => {
  try {
    const cached = await readCache();
    if (cached) {
      return res.set("X-Cache", "HIT")
                .json({ count: cached.length, source: "cache", shows: cached });
    }
    const fresh = await fetchUpstream();
    const body = JSON.stringify(fresh);
    // Write-through. A cache-write failure must NOT fail the user's request.
    blob.upload(body, Buffer.byteLength(body), { overwrite: true })
        .catch(err => console.error(JSON.stringify({ level: "error", msg: "cache write failed", err: err.message })));
    return res.set("X-Cache", "MISS")
              .json({ count: fresh.length, source: "upstream", shows: fresh });
  } catch (err) {
    console.error(JSON.stringify({ level: "error", msg: "/api/shows failed", err: err.message }));
    return res.status(502).json({ error: "upstream_unavailable" });
  }
});

// Liveness: is the process alive? Deliberately touches NO dependency — a Storage
// outage must not cause Kubernetes to kill and restart otherwise-healthy pods.
app.get("/healthz", (_req, res) => res.json({ status: "alive" }));

// Readiness: can this pod actually serve? Probes the Azure dependency, so a pod
// with broken Workload Identity is removed from the Service endpoint list.
app.get("/readyz", async (_req, res) => {
  try {
    await container.exists();
    res.json({ status: "ready", dependencies: { blob: "ok" } });
  } catch (e) {
    res.status(503).json({ status: "not-ready", dependencies: { blob: e.code || "error" } });
  }
});

app.listen(PORT, () => console.log(JSON.stringify({ level: "info", msg: `listening on ${PORT}` })));
```

And the `Dockerfile` — distroless, non-root, matching `runAsUser: 65532` in your `values.yaml`:

```dockerfile
# application/Dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src ./src

FROM gcr.io/distroless/nodejs22-debian12:nonroot
WORKDIR /app
COPY --from=build /app /app
# 65532 = the 'nonroot' user in distroless images. This MUST match
# podSecurityContext runAsUser/runAsGroup/fsGroup in values.yaml, or the
# container fails to start with a permission error on /tmp.
USER 65532:65532
EXPOSE 8080
CMD ["src/server.js"]
```

**If it is still unfixed on the day.** Do not hide it. Open with:

> "I deliberately spent my budget on the platform, and the application is the one thing I left as a
> *contract* rather than an implementation. Here is the contract: `/api/shows` returns
> `{count, source, shows}` with an `X-Cache` header; `/healthz` is a pure liveness check that touches
> no dependency; `/readyz` probes Blob Storage so a pod with broken Workload Identity is pulled out of
> the Service. The ConfigMap and the smoke test are both written against that contract. Here's how I'd
> implement it —"

then talk through the code above. **Owning it converts a fail into a design discussion.**

---

## P0-2. Terraform module source paths do not resolve.

**What it is.** [`infra/terraform/main.tf`](../infra/terraform/main.tf) references every module as
`source = "../modules/<name>"`. The root module lives in `infra/terraform/`, so `../modules` resolves
to `infra/modules/` — which does not exist. The modules are at `infra/terraform/modules/`.

**Why it matters.** `terraform init` fails immediately with
`Unreadable module directory ... infra/modules/observability`. Nothing in your IaC can be validated.

**The fix.** One of two, and the choice itself is an interview talking point:

*Option A (minimal):* change every `source` to `./modules/<name>`.

*Option B (what a real platform team does):* make each environment its own root module.
`infra/terraform/environments/nonprod/main.tf` becomes a thin wrapper calling a shared
`../../modules/platform` composition. Then `../../modules/...` is correct, and `terraform init` in the
environment directory works — which is what your **pipeline already assumes**
(`stage-validate.yml` runs `terraform init` with `workingDirectory: $(infraRoot)/environments/${env}`)
and what `scripts/validate.sh` assumes (`terraform -chdir="$env"`).

**Right now the environment directories contain only `terraform.tfvars` and `azurerm.tfbackend` — no
`.tf` files at all — so the pipeline's `terraform init` would find an empty configuration.** Option B
is the coherent fix because it makes the code match the pipeline you already wrote.

**What to say.** "I chose a single root module with per-environment tfvars and backend files. That
maximises DRY — one definition of the platform, two parameter sets. The trade-off is that
`terraform -chdir` has to point at the shared root with `-var-file` and `-backend-config` pointing at
the environment. My pipeline drifted to the other convention — per-environment root modules — and I
didn't reconcile the two. The per-environment-root pattern is the safer one for a bank, because a prod
apply then *physically cannot* touch non-prod state, so that's the direction I'd take it."

---

## P0-3. Terraform dependency cycle: observability ↔ network ↔ DNS.

**What it is.** In [`main.tf`](../infra/terraform/main.tf):

- `module "observability"` consumes `module.network_spoke.private_endpoint_subnet_id` (for the AMPLS
  private endpoint) **and** `module.private_dns.zone_ids` (for the monitor zones).
- `module "network_spoke"` and `module "network_hub"` consume
  `module.observability.log_analytics_workspace_id` (for diagnostics).
- `module "private_dns"` consumes `module.network_spoke.spoke_vnet_id`, `module.network_hub.hub_vnet_id`
  **and** `module.observability.log_analytics_workspace_id`.

That is a three-way cycle. Terraform refuses to build the graph:
`Error: Cycle: module.observability..., module.network_spoke..., module.private_dns...`

**Why it matters.** Even after fixing P0-2, `terraform plan` cannot run. This is the classic
"monitoring wants to observe the network; the network wants to be observed" trap, and being able to
name it and resolve it is exactly the senior signal the rubric's *"Terraform/Bicep design — 15%,
idempotency, validation, maintainability"* line looks for.

**The fix — split observability into two modules along the dependency direction:**

```hcl
# Layer 0: workspace only. Depends on NOTHING. Everything else can reference it.
module "observability_core" {
  source = "./modules/observability-core"     # LAW + App Insights
}

# Layer 1: network (consumes the workspace ID for diagnostics)
module "network_hub"   { log_analytics_workspace_id = module.observability_core.log_analytics_workspace_id }
module "network_spoke" { log_analytics_workspace_id = module.observability_core.log_analytics_workspace_id }
module "private_dns"   { log_analytics_workspace_id = module.observability_core.log_analytics_workspace_id }

# Layer 2: private access FOR monitoring. Depends on network + DNS. Nothing depends on it.
module "observability_private_link" {
  source                       = "./modules/observability-ampls"
  log_analytics_workspace_id   = module.observability_core.log_analytics_workspace_id
  app_insights_id              = module.observability_core.app_insights_id
  private_endpoint_subnet_id   = module.network_spoke.private_endpoint_subnet_id
  monitor_private_dns_zone_ids = [for z in local.monitor_zones : module.private_dns.zone_ids[z]]
}
```

**The general principle to state out loud:** *"A Terraform cycle is always a signal that one module is
doing two jobs at two different layers. The fix is never `depends_on` — it's to split the module along
the dependency boundary. Here, 'create a workspace' is a layer-0 concern and 'give the workspace a
private endpoint' is a layer-2 concern. They don't belong in one module."*

---

## P0-4. Provider pinned to `azurerm ~> 3` but the code is written for `azurerm 4.x`.

**What it is.** [`providers.tf`](../infra/terraform/providers.tf) pins `version = "~> 3"`. The module
code uses arguments that only exist in **AzureRM provider v4**:

| File | Argument used (v4) | v3 equivalent |
|---|---|---|
| `modules/aks/main.tf` | `automatic_upgrade_channel` | `automatic_channel_upgrade` |
| `modules/aks/main.tf` | `auto_scaling_enabled` | `enable_auto_scaling` |
| `modules/aks/main.tf` | `network_data_plane` | (v4 only) |
| every diagnostic setting | `enabled_metric { }` | `metric { category = ..., enabled = true }` |
| `modules/container-registry/main.tf` | `retention_policy_in_days`, `trust_policy_enabled` | `retention_policy { }`, `trust_policy { }` blocks |
| `modules/key-vault/main.tf` | `rbac_authorization_enabled` | `enable_rbac_authorization` |
| `modules/storage-account/main.tf` | `https_traffic_only_enabled` | `enable_https_traffic_only` |
| `modules/storage-account/main.tf` | `azurerm_storage_container.storage_account_id` | `storage_account_name` |
| `modules/governance/main.tf` | `enforce = bool` | `enforcement_mode = "Default" \| "DoNotEnforce"` |

**Why it matters.** Every `terraform validate` produces "Unsupported argument". It also shows the code
was never actually run — which the interviewer will infer, correctly.

**The fix.** Pin to what you wrote:

```hcl
azurerm = {
  source  = "hashicorp/azurerm"
  version = "~> 4.14"          # pessimistic: patch + minor float, major pinned
}
```

Also add `subscription_id` to the provider block — **azurerm v4 requires it explicitly**, it no longer
silently inherits from `az login`:

```hcl
provider "azurerm" {
  subscription_id     = var.subscription_id   # your pipeline already exports TF_VAR_subscription_id
  use_oidc            = true
  storage_use_azuread = true
  features { ... }
}
```

…and declare `variable "subscription_id"` in `variables.tf` — **it is currently exported by the
pipeline (`TF_VAR_subscription_id`) but never declared**, so Terraform warns and ignores it.

**Also commit `.terraform.lock.hcl`.** Its absence is a reproducibility gap a bank cares about: without
the lock file, two runs weeks apart can resolve different provider builds and produce different plans.
Raise this proactively — it's a cheap credibility win.

---

## P0-5. The workload identity is never granted access to Blob Storage.

**What it is.** `modules/storage-account` exposes `data_contributor_principal_ids`, which drives
`azurerm_role_assignment.rbac` (Storage Blob Data Contributor). In
[`main.tf`](../infra/terraform/main.tf), `module "storage"` is called **without that argument**. It
defaults to `[]`, so zero role assignments are created.

Meanwhile `module "identity"` creates the user-assigned identity and its federated credential — and
that identity is granted **nothing, anywhere**.

**Why it matters.** This is the *exact* failure in **Troubleshooting Scenario 1 — "Storage returns 403
AuthorizationFailure"**. Your infrastructure ships with the bug the assessment asks you to diagnose. An
interviewer who spots this and asks "walk me through what happens when the pod calls Blob Storage" is
setting a trap you would walk straight into.

**The fix:**

```hcl
module "storage" {
  source   = "./modules/storage-account"
  for_each = { for i in range(var.storage_account_count) : format("%02d", i + 1) => i }
  # ...
  # Least privilege: the workload reads AND writes cache blobs, so it needs Data
  # Contributor. The pipeline agent gets Data *Reader* only — enough for the smoke
  # test's "does a blob exist" check, not enough to tamper with cached data.
  data_contributor_principal_ids = [module.identity.principal_id]
  data_reader_principal_ids      = var.pipeline_principal_ids
}
```

…and add the matching `data_reader_principal_ids` variable + `azurerm_role_assignment` (role
`Storage Blob Data Reader`) to the module. Note `scripts/smoke-test.sh` already tells the operator
*"the agent lacks Storage Blob Data Reader"* — **your script documents a role assignment your Terraform
never makes.**

**Scoping nuance worth saying out loud:** scope the assignment to the **container**, not the account,
for true least privilege:

```hcl
scope = "${azurerm_storage_account.sa.id}/blobServices/default/containers/${var.cache_container_name}"
```

Account-level is acceptable for a single-purpose account; container-level is what you'd do in a
shared/multi-tenant storage account.

---

## P0-6. Three-way name mismatch breaks Workload Identity federation.

**What it is.** The federated identity credential subject must be an **exact string match** with
`system:serviceaccount:<namespace>:<serviceaccount>`. Yours disagree in three places:

| Source | Namespace | ServiceAccount |
|---|---|---|
| `infra/terraform/variables.tf` (`app_namespace`, `app_service_account_name`) | `banking-api` | `banking-api` |
| `charts/banking-application/values.yaml` (`serviceAccount.name`) | — | `banking-application` |
| `pipelines/variables/common.yml` (`appNamespace`) | `banking-application` | — |
| `scripts/validate.sh` (`--namespace`) | `banking-application` | — |

So Terraform creates a credential for `system:serviceaccount:banking-api:banking-api`, while the pod
presents `system:serviceaccount:banking-application:banking-application`.

**Why it matters.** Entra rejects the token exchange with **`AADSTS70021: No matching federated
identity record found for presented assertion subject`**. The pod starts, passes liveness, fails
readiness — exactly Scenario 5. It is a silent, high-cost failure mode and the single most common
Workload Identity mistake, which is precisely why interviewers ask about it.

**The fix — make one source of truth.** Terraform owns the names; the pipeline reads them from
Terraform outputs. Your `stage-deploy.yml` **already does this correctly**:

```yaml
--namespace "$(targetNamespace)"                    # from tf output app_namespace
--set serviceAccount.name="$(serviceAccountName)"   # from tf output app_service_account_name
```

So the pipeline is right and the defaults are wrong. Three changes:

1. Set `values.yaml` → `serviceAccount.name: ""` so it can never silently disagree (with
   `create: true` the helper falls back to the release fullname, and the pipeline always overrides).
2. Remove the hardcoded `appNamespace` from `common.yml`, or set it to `banking-api` with a comment
   saying *"informational only — the real value comes from the Terraform output."*
3. Fix `scripts/validate.sh` to use `banking-api`.

**Better still — add a guard to the chart** so the mismatch can never ship silently:

```gotemplate
{{/* in _helpers.tpl, called from banking-application.validateValues */}}
{{- if .Values.workloadIdentity.expectedSubject }}
{{-   $actual := printf "system:serviceaccount:%s:%s" .Release.Namespace (include "banking-application.serviceAccountName" .) }}
{{-   if ne $actual .Values.workloadIdentity.expectedSubject }}
{{-     fail (printf "Workload Identity subject mismatch: chart renders %q but the federated credential expects %q" $actual .Values.workloadIdentity.expectedSubject) }}
{{-   end }}
{{- end }}
```

Then pass `--set workloadIdentity.expectedSubject=...` from a new Terraform output. **This is a
brilliant thing to show an interviewer** — it demonstrates that you turn a known runtime failure mode
into a deploy-time error.

---

## P0-7. `azurerm_firewall` resources index `[0]` without `count`.

**What it is.** In [`modules/network-hub/main.tf`](../infra/terraform/modules/network-hub/main.tf):

- `azurerm_subnet.firewall`, `azurerm_public_ip.firewall`, `azurerm_firewall_policy.fwp` and
  `azurerm_firewall.fw` are declared **without** `count`.
- But they are referenced as `azurerm_firewall_policy.fwp[0].id`, `azurerm_subnet.firewall[0].id`,
  `azurerm_public_ip.firewall[0].id`, and in `outputs.tf` as `azurerm_firewall.fw[0]`.

**Why it matters.** `Error: Unsupported attribute — this value does not have any indices`. Also,
`enable_firewall` is honoured on the *rule collection group* and on the outputs but **not on the
firewall itself** — so `enable_firewall = false` would still deploy a firewall (~£700/month) with no
rules, i.e. it would break egress *and* still cost money. The worst of both worlds.

**The fix.** Add `count = var.enable_firewall ? 1 : 0` to the PIP, policy and firewall (the subnet
arguably should always exist), and guard the firewall diagnostic setting the same way.

**Bonus finding to raise yourself:** `var.firewall_name` is declared and passed from `tfvars`
(`firewall_name = "fw-nonprod-iac"`) but the resource hardcodes `name = "fw-hub-${var.environment}"`.
A dead variable that *looks* live is worse than no variable — an operator will think they changed
something when they didn't.

---

## P0-8. AKS `node_resource_group` equals the cluster's own resource group.

**What it is.** In `main.tf`, `module "aks"` receives:

```hcl
resource_group_name      = azurerm_resource_group.rg_infra.name
node_resource_group_name = azurerm_resource_group.rg_infra.name   # same RG
```

**Why it matters.** Azure rejects this: the node resource group is created *and managed* by AKS and
must not already exist. `Error: Node resource group name must be different from the cluster resource
group.` It also breaks isolation — AKS takes near-total control of the node RG, and you do not want
ACR, Key Vault and Storage sitting in a resource group that an AKS upgrade can mutate.

**The fix:**

```hcl
node_resource_group_name = "rg-${var.environment}-${var.name_prefix}-aks-nodes"
```

**What to say.** "The node resource group is AKS-managed. Everything in it — the VMSS, the load
balancers, the managed disks — has a lifecycle owned by the AKS control plane. I keep my own resources
out of it so a cluster recreate never threatens my data plane. It's also why I don't put
`prevent_destroy` on anything in there: I *want* AKS to be able to churn it."

---

# P1 — Serious

## P1-1. AMPLS is enabled but internet ingestion is enabled with it (logic inverted).

In [`modules/observability/main.tf`](../infra/terraform/modules/observability/main.tf):

```hcl
internet_ingestion_enabled = var.enable_private_link   # <-- inverted
```

With `enable_monitor_private_link = true` (your root default), this sets
`internet_ingestion_enabled = true`. So you build the AMPLS, create its private endpoint, set
`ingestion_access_mode = "PrivateOnly"` on the scope — and then leave the workspace itself accepting
public ingestion. The two settings contradict each other, and the *documented* private-only monitoring
model is not what the code produces.

**Fix:** `internet_ingestion_enabled = !var.enable_private_link`.

**Talking point (knowing the difference is senior signal).** These are two different controls:
`internet_ingestion_enabled` is a **resource-level** switch on the workspace; AMPLS
`ingestion_access_mode = PrivateOnly` is a **scope-level** switch meaning "resources in this scope may
only be reached over the private link". You want both. Also note the well-known AMPLS gotcha:
`PrivateOnly` applies to *all* networks reaching Azure Monitor through that private endpoint's DNS —
so one AMPLS in `PrivateOnly` can accidentally cut off other VNets sharing the same private DNS zones.
That is exactly why the `allow_public_query` escape hatch in your module is a sensible design:
**private ingestion, public query from the portal.**

## P1-2. Duplicate/conflicting Private DNS A records.

`modules/storage-account` and `modules/key-vault` both create:

1. an `azurerm_private_endpoint` **with a `private_dns_zone_group`** — Azure automatically creates and
   lifecycle-manages the A record; **and**
2. an explicit `azurerm_private_dns_a_record` for the same name.

Two problems:

- **Conflict.** Both want to own `<name>` in `privatelink.blob.core.windows.net`. The apply either
  fails with "A record already exists" or the two fight on every plan (perpetual diff).
- **Wrong resource group.** The A record uses `resource_group_name = var.resource_group_name`
  (`rg_infra`), but the zones are created in `rg_hub` (`module "private_dns"` receives
  `azurerm_resource_group.rg_hub.name`). The record targets a zone that doesn't exist in that RG.

**Fix: delete the explicit A records.** The `private_dns_zone_group` is the correct, idempotent
mechanism — it binds the record to the endpoint's lifecycle and cleans up automatically on destroy.

**What to say.** "Hand-written A records for private endpoints are an anti-pattern. The DNS zone group
binds the record to the endpoint's lifecycle. If I hand-write the record and the endpoint's NIC gets a
new IP — which happens on a recreate — I get a silent stale record and a connection to a dead IP.
That's a DNS incident that presents as a network incident, and it's one of the hardest to spot."

## P1-3. `private_dns` module: variable name mismatch + broken diagnostics.

- The module declares `variable "private_dns_zones"`; `main.tf` passes **`zone_names = var.private_dns_zones`**
  → `Error: An argument named "zone_names" is not expected here` plus
  `Error: Missing required argument private_dns_zones`.
- `azurerm_monitor_diagnostic_setting.dns` does `for_each = toset(["dns"])` then indexes
  `azurerm_private_dns_zone.dns[each.value]` — i.e. looks up a zone literally named `"dns"`, which
  doesn't exist. Should be `for_each = var.enable_diagnostics ? toset(var.private_dns_zones) : toset([])`.
- Private DNS zones **do not emit resource logs**, so `category_group = "allLogs"` will fail anyway.
  DNS visibility comes from **Azure Firewall DNS proxy logs** (which you *have* enabled —
  `dns { proxy_enabled = true }`) or **Azure DNS Private Resolver query logs**, not from the zone.
  **Say this** — it shows you know where DNS telemetry actually comes from.

## P1-4. NSG rules are defined in `tfvars` but never reach any NSG.

`environments/{nonprod,prod}/terraform.tfvars` define `nsg_rules_aks_nodes`,
`nsg_rules_private_endpoints` and `nsg_rules_pipeline_agents`. But:

- The **root** `variables.tf` does not declare them → Terraform emits
  `Warning: Value for undeclared variable` and ignores them.
- `main.tf`'s `module "network_spoke"` block does not pass them → the module's `[]` defaults apply.

**Net effect: all three NSGs are created completely empty.** Every subnet falls back to Azure's default
rules, which allow all intra-VNet traffic and all outbound. The `deny-internet-in` rule you carefully
wrote at priority 4000 does not exist in Azure.

This directly undercuts your answer to *"How would you prevent accidental public access?"* — so fix it,
or lead with it.

**Fix:** declare the three variables in the root `variables.tf` (copy the `list(object({...}))` type
from the module) and pass them through in `main.tf`.

**Design comment worth making anyway:** priority-4000 `Deny * from Internet` is *belt and braces* —
Azure's built-in `DenyAllInBound` at 65500 already does it, and `AllowVnetInBound` at 65000 sits above
yours. The real value of an explicit deny is that it is **visible in the portal and in policy scans**.
Say that; it shows you understand NSG default rules rather than cargo-culting a deny.

## P1-5. Storage: `shared_access_key_enabled = true` contradicts "no keys".

You state everywhere that the workload uses Workload Identity and no storage keys — but the account
still permits shared-key auth. Anyone who can read the account keys (any Contributor on the RG, or
anything that can call `listKeys`) bypasses your entire Entra RBAC model and every data-plane audit
trail you built.

**Fix:** `shared_access_key_enabled = false`, plus `default_to_oauth_authentication = true`. Then
`az storage` calls must use `--auth-mode login` — which `scripts/smoke-test.sh` already does. Good.

Note the interaction with `provider "azurerm" { storage_use_azuread = true }`, which you already set.
Nice touch — say so.

**Watch out:** disabling shared keys breaks the Terraform **backend** if the backend uses the same
account. It doesn't here (`azurerm.tfbackend` points at a separate state account) and your backend
already sets `use_azuread_auth = true`. **Mention that you checked** — it shows rigour.

## P1-6. Image promotion is broken: prod pulls a tag that was never pushed there.

`stage-build-image.yml` is invoked once, with `acrName: $(nonProdAcrName)` → pushes only to
`acrnonprod`. `stage-deploy.yml` for **prod** sets `--set image.registry="$(acrLoginServer)"` from the
**prod** Terraform outputs → `acrprod.azurecr.io`. That image does not exist there →
**`ImagePullBackOff`**, i.e. Troubleshooting Scenario 3, self-inflicted.

Three valid fixes; pick one and defend it:

| Option | How | Trade-off |
|---|---|---|
| **A. Single shared registry** | One Premium ACR in a platform subscription, private endpoints from both spokes | Simplest; one artifact, one scan result. Blast radius: a compromised registry hits both environments. Common in banks with a "golden registry". |
| **B. `az acr import` promotion** | After prod approval: `az acr import --source acrnonprod.azurecr.io/app@sha256:... --registry <prod-acr-id>` | Server-side copy — no re-pull/re-push, preserves the **digest**, registries stay isolated. **Recommended.** |
| **C. ACR geo-replication** | Premium geo-replication of one registry | Solves region HA, not environment isolation. Different problem — knowing that distinction is the point. |

**Say this regardless:** *"Whatever the mechanism, the promoted artifact must be the same **digest**,
not the same tag. Tags are mutable. `--set image.tag=...` means prod could theoretically run a
different bitstream from the one that passed non-prod. In a bank I'd deploy by digest —
`image.digest: sha256:...` — with the pipeline resolving tag→digest exactly once, in the build stage."*

## P1-7. `imageTag` is not a valid Docker tag.

`azure-pipelines.yml` sets `name: Terraform Infrastructure Provisioning`. In Azure DevOps, the
top-level `name:` **is the build-number format** — so `$(Build.BuildNumber)` literally becomes
`Terraform Infrastructure Provisioning`. Then:

```yaml
- name: imageTag
  value: "$(Build.BuildNumber)-$(Build.SourceVersion)"
```

→ `Terraform Infrastructure Provisioning-a1b2c3...`. Spaces are illegal in an OCI tag; `docker tag`
fails with `invalid reference format`.

**Fix:**

```yaml
name: $(Date:yyyyMMdd)$(Rev:.r)          # -> 20260822.3
# ...
- name: imageTag
  value: "$(Build.BuildNumber)-$(Build.SourceVersion)"   # -> 20260822.3-a1b2c3d
```

Also rename the pipeline: it is called "Terraform Infrastructure Provisioning" but it also builds
images and deploys Helm.

## P1-8. The prod tag set violates your own Azure Policy.

`modules/governance` assigns *Require a tag on resources* for `var.policy_required_tags` — default
`["environment", "owner", "cost_centre"]`.

Your `tfvars` tag maps are:

```hcl
tags = { workload = "...", managedBy = "terraform", owner = "abn-amro", environment = "prod" }
```

**`cost_centre` is missing.** With `enforce = true` (your default) and effect **Deny**, the very next
`terraform apply` into `rg_infra` is denied by your own policy. This is a beautiful self-own and an
interviewer will enjoy finding it.

**Fix:** add `cost_centre` (and ideally `application`, `dataClassification`, `criticality`) to both
tfvars tag maps.

**Also worth fixing:** the governance module only assigns policy to `rg_infra`, so **hub resources are
completely ungoverned**. In reality assign at **subscription** or **management group** scope —
resource-group scope means anyone who can create a new resource group escapes all your policy.
**Say this:** *"Resource-group-scoped policy is a demo convenience. Real governance lives at the
management group so it applies to subscriptions that don't exist yet."*

## P1-9. Ephemeral OS disk on a VM size with no local temp disk.

`modules/aks/main.tf` sets `os_disk_type = "Ephemeral"` with `os_disk_size_gb = 64` on
`Standard_D2s_v5`. The **Dsv5** series has **no local temporary disk**, and D2s_v5's cache is too small
for a 64 GB ephemeral OS disk. AKS will fail node pool creation or silently fall back to Managed.

**Fix:** use `Standard_D2ds_v5` / `Standard_D4ds_v5` (the `d` = local temp disk), or set
`os_disk_type = "Managed"`.

**Talking point (a great one):** *"Ephemeral OS disks are the right default for AKS: node provisioning
and image updates are much faster, there's no managed-disk IOPS charge, and it enforces the discipline
that nodes are cattle — nothing on the OS disk survives a reallocate. The constraint is that the VM SKU
must have local storage large enough for the OS image, which rules out the non-`d` v5 sizes. That's a
real trade-off I got wrong here."*

## P1-10. `only_critical_addons_enabled` is coupled to `enable_user_node_pool`.

```hcl
only_critical_addons_enabled = var.enable_user_node_pool
```

Clever, but it has a nasty edge. `only_critical_addons_enabled` applies the
`CriticalAddonsOnly=true:NoSchedule` taint to the system pool. Changing it on an **existing** cluster
forces node-pool replacement. Worse, if `enable_user_node_pool` is ever flipped to `false` on a live
cluster, the system pool loses its taint and application pods start landing on system nodes — a silent
reliability regression, not an error.

**Fix:** make it an explicit variable `taint_system_pool`, with a `validation` block asserting it can
only be `true` when `enable_user_node_pool` is `true`. **Explicit beats clever in IaC that other people
will operate at 3am.**

## P1-11. Dead configuration: declared but never used.

| Declared | Never used / never wired |
|---|---|
| `var.acr_untagged_retention_days` (root) | not passed to `module.acr` (module default 7 applies) |
| `var.enable_kv_purge_protection` (root) | not passed; KV hardcodes `purge_protection_enabled = true` |
| `var.cache_expiry_days` | passed to storage module, but **no `azurerm_storage_management_policy` exists** — cached blobs are never expired |
| `var.internal_consumer_cidrs` | passed to `network_spoke`, never referenced inside it |
| `var.route_table_name` | passed to both network modules, never used (`rt-aks_nodes` is hardcoded — note the inconsistent underscore) |
| `var.firewall_name` | passed, never used (see P0-7) |
| storage module `var.role_definition_names` | declared, never used |
| storage module `var.enable_infrastructure_encryption` | declared; the resource hardcodes `true` instead |
| observability `var.enable_local_auth` | not passed from root; defaults `false` — correct, but undocumented |
| `var.storage_replication_type` | *is* passed — but both environments leave it at `LRS`, including prod |

Dead variables are a maintainability smell; a senior reviewer reads them as "generated or copied, not
authored". **Delete what you don't use; wire up what you do.** The `cache_expiry_days` one is the worst
because it implies a lifecycle policy that doesn't exist — an operator will believe old cache blobs are
being cleaned up while the container grows forever.

## P1-12. Shell scripts have no shebang.

`scripts/validate.sh`, `scripts/smoke-test.sh` and `scripts/helm-rollback.sh` all begin with a comment,
not `#!/usr/bin/env bash`. They use bash-only syntax (`[[ ]]`, `set -o pipefail`, `$RANDOM`,
`${VAR:?msg}`). Executed from a non-bash shell they break. They are also not marked executable in git —
which is why the pipeline has to `chmod +x` at runtime, a workaround for a missing
`git update-index --chmod=+x`.

**Fix:** add the shebang to all three and commit the executable bit.
*(The shebangs have been added as part of the inline-annotation pass; the executable bit still needs
`git update-index --chmod=+x scripts/*.sh`.)*

## P1-13. `automatic_upgrade_channel = "patch"` with a pinned `kubernetes_version`.

`kubernetes_version = "1.30"` plus channel `patch` means AKS moves you to 1.30.x patches automatically
and Terraform then shows a perpetual diff (state says `1.30`, Azure says `1.30.5`). You handled this
for node counts with `ignore_changes` but not for the version.

**Fix:** add `kubernetes_version` to `lifecycle.ignore_changes`, **or** set
`automatic_upgrade_channel = "none"` and drive upgrades through the pipeline.

**Great talking point.** *"For a bank I want upgrades to be a change-managed event, not a surprise. So:
`node-os` channel on — security patches to the node image are low-risk and land in the maintenance
window I've configured for Sunday 02:00 UTC — and the **control-plane** channel set to `none`, with the
minor version bumped deliberately through a pull request. Automated patching where it's safe, human
approval where it isn't."*

## P1-14. `--atomic` plus a manual rollback step can double-roll-back production.

`stage-deploy.yml` runs `helm upgrade --install --atomic --wait`. **`--atomic` already rolls back
automatically** if the release fails or times out. A separate `condition: failed()` step then runs
`scripts/helm-rollback.sh`, which calls `helm rollback <release> 0` ("previous revision").

If `--atomic` already rolled back, the extra `helm rollback` rolls back *again* — to the revision
before the one `--atomic` restored. **You can end up two revisions behind, in production,
automatically.**

**Fix:** make the choice explicit. Either keep `--atomic` and reduce the failure step to *diagnostics
only* (the `kubectl describe` / `logs` / `events` capture before rollback is genuinely good practice
and worth keeping), or drop `--atomic`, keep `--wait --timeout`, and let the script own the rollback so
you control the target revision.

**Recommended: make the script idempotent** — check whether a rollback already happened:

```bash
CURRENT=$(helm history "$RELEASE" -n "$NS" -o json | jq -r 'last | .revision')
LAST_GOOD=$(helm history "$RELEASE" -n "$NS" -o json | jq -r '[.[]|select(.status=="deployed")]|last|.revision')
[[ "$CURRENT" == "$LAST_GOOD" ]] \
  && echo "already at last-known-good revision $LAST_GOOD, nothing to roll back" \
  || helm rollback "$RELEASE" "$LAST_GOOD" -n "$NS" --wait
```

---

# P2 — Quality

## P2-1. `README.md` is one line.

The submission deliverable says *"Source repository: Clear structure, README, prerequisites,
assumptions and instructions."* A one-line README scores zero on that row and — more importantly — sets
the reviewer's expectations before they read a line of code. **Fix this first: it is the cheapest point
in the whole assessment.** Content to lift is in [08-operational-runbook.md](08-operational-runbook.md).

## P2-2. `docs/architecture.md` mermaid diagrams are not fenced.

The diagrams in your existing `docs/architecture.md` are raw `flowchart TB` / `sequenceDiagram` text
with **no ` ```mermaid ` fence**, so they render as broken plaintext on Azure DevOps and GitHub. One is
also truncated mid-line (`"resolved then routed via` — unterminated string). The assessment lists
*"Architecture diagram"* as an explicit deliverable. Fixed, expanded version in
[01-architecture.md](01-architecture.md).

## P2-3. No Key Vault CSI `SecretProviderClass`, despite enabling the addon.

`modules/aks/main.tf` enables `key_vault_secrets_provider` with 2-minute rotation. The Helm chart never
uses it. Instead `stage-deploy.yml` does:

```bash
kubectl create secret generic banking-application-telemetry \
  --from-literal=APPLICATIONINSIGHTS_CONNECTION_STRING="${CONNECTION_STRING}"
```

It reads a **sensitive Terraform output** and materialises it as a plain Kubernetes Secret (base64, not
encrypted at rest unless you've enabled KMS etcd encryption). That is the *one* place in your design
where a secret transits the pipeline.

**Two fixes, in order of preference:**

1. **Don't use a secret at all.** You already set `local_authentication_enabled = false` on App
   Insights — which means the connection string's ingestion key is **inert**. The app should
   authenticate to App Insights with the same Workload Identity, and the connection string (endpoint +
   a resource GUID) can live in the ConfigMap. **Strong point to make in the room: "I disabled local
   auth, which means the thing I was treating as a secret isn't one."**
2. If you do need real secrets later, use the CSI driver you already enabled:

```yaml
# charts/banking-application/templates/secretproviderclass.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: {{ include "banking-application.fullname" . }}-kv
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"
    clientID: {{ .Values.workloadIdentity.clientId | quote }}   # Workload Identity
    keyvaultName: {{ .Values.keyVault.name | quote }}
    tenantId: {{ .Values.keyVault.tenantId | quote }}
    objects: |
      array:
        - |
          objectName: {{ .Values.keyVault.secretName }}
          objectType: secret
```

Secrets are then mounted, rotated every two minutes by the addon, and **never touch the pipeline**.

## P2-4. `automountServiceAccountToken: false` — correct, but be ready to explain it.

You set this on the ServiceAccount. Many people assume it breaks Workload Identity. **It does not** —
the `azure-wi-webhook` mutating admission webhook injects its *own* projected volume
(`azure-identity-token`, audience `api://AzureADTokenExchange`) into the pod spec, independently of the
default token automount. Turning off the default token is a genuine hardening win: the pod cannot call
the Kubernetes API at all, so a compromised container can't enumerate secrets or other pods.

**Have this ready.** It is a perfect "do you understand the mechanism, or did you copy a blog post"
question — and you will pass it.

## P2-5. NetworkPolicy: the ingress rule has no `from` selector.

```yaml
ingress:
  - ports:
      - port: 8080
```

An ingress rule with `ports` but no `from` allows **any source** to reach that port. Since the pod
selector already isolates the pod, this permits any pod in any namespace plus any VNet IP. Scope it:

```yaml
ingress:
  - from:
      - namespaceSelector: {}
        podSelector: { matchLabels: { app.kubernetes.io/name: ingress-nginx } }
      - ipBlock: { cidr: 10.101.0.0/24 }      # node subnet: internal LB + kube-proxy
      - ipBlock: { cidr: 168.63.129.16/32 }   # Azure LB health probes
    ports: [{ port: 8080, protocol: TCP }]
```

**Miss the health-probe source and the internal LB marks every backend down** — a fun, hard-to-diagnose
outage worth naming out loud.

**Also:** your egress rule excepts `169.254.169.254/32` (IMDS) — that is textbook SSRF / credential-theft
hardening and a strong signal. **Call it out explicitly.** But note the exception list excepts
`10.0.0.0/8` from the internet rule *and* separately allows it via `allowedEgressCidrs`; the net effect
is correct, but the double negative is hard to read. Add a comment.

## P2-6. `resources`: memory limit but no CPU limit — deliberate; say so.

```yaml
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:  { memory: 512Mi }
```

**This is correct. Make sure you say so, because a junior reviewer will try to "fix" it.**

Reasoning: CPU is compressible, memory is not. A CPU limit causes CFS throttling — your p99 latency
spikes even though the node has idle cores. A memory limit is what stops one pod OOM-killing the node.
So: always set both requests, always set a memory limit, and only set a CPU limit when you need hard
multi-tenant isolation or Guaranteed QoS.

**Nuance to add:** with `requests.memory != limits.memory` the pod is **Burstable** QoS and is evicted
before Guaranteed pods under node memory pressure. For a production banking API you may prefer
`requests.memory == limits.memory` to get Guaranteed QoS *while still omitting the CPU limit* — the
best of both. Your prod overlay is `256Mi / 512Mi` → Burstable. Worth a sentence.

## P2-7. HPA scales on CPU/memory for an I/O-bound workload.

This app spends its life waiting on Blob Storage and TVMaze. CPU will barely move while latency degrades
and the request queue grows — so CPU-based HPA under-scales exactly when you need it most.

**Better:** KEDA (an AKS addon you could enable) scaling on **RPS or p95 latency** from Application
Insights or Prometheus. Say this: it shows you scale on the signal that matters rather than the one
that's easy to get.

Also `behavior.scaleDown.stabilizationWindowSeconds: 300` is set but `scaleUp` is not. The default
scale-up is aggressive (100% or 4 pods per 15s), which is usually right — state that you left it
deliberately.

## P2-8. Package the smoke test as a Helm test.

You have a good `scripts/smoke-test.sh`. Ship it *with the chart* so it is versioned alongside it:

```yaml
# charts/banking-application/templates/tests/test-api.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "banking-application.fullname" . }}-test"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: smoke
      image: mcr.microsoft.com/azurelinux/base/core:3.0
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -e
          BASE="http://{{ include "banking-application.fullname" . }}:{{ .Values.service.port }}"
          curl -sf "$BASE/readyz"    | grep -q '"status":"ready"'
          curl -sf "$BASE/api/shows" | grep -q '"count"'
```

Then `helm test <release> -n <ns>` in the pipeline. **Benefit to state:** the test is versioned with the
chart, so a rollback to revision N also rolls back to *that revision's definition of healthy*. A
release and its acceptance criteria should never drift apart.

## P2-9. Both environments are identically sized; prod is not hardened.

`values-prod.yaml` differentiates the *application* nicely (3 replicas, HPA on, PDB `minAvailable: 2`,
`nodeSelector`, internal LB). But the **infrastructure** tfvars are near-identical:

| Setting | nonprod | prod | Should be |
|---|---|---|---|
| `storage_replication_type` | LRS (default) | LRS (default) | **ZRS** (or GZRS) in prod |
| `aks_sku_tier` | Standard | Standard | Standard is right — say why (API-server uptime SLA) |
| `firewall_sku_tier` | Standard | Standard | **Premium** in prod if you want TLS inspection / IDPS |
| `log_retention_days` | 90 | 90 | 90 nonprod, **365+** prod (banking / DORA retention) |
| `kubernetes_policy_effect` | Audit | Audit | Audit nonprod, **Deny** prod |
| agent capacity | 1 VM | 1 VM | VMSS, ≥2 instances across zones (see P2-10) |
| tags | `workload = "iac-hiring-test"` | `workload = "iac"` | one consistent taxonomy |

**These are one-line tfvars changes and they directly serve the "production ready" bar you were asked
about.** Fix them.

## P2-10. The pipeline agent is a single VM = a single point of failure.

`module "pipeline_agent"` is one `azurerm_linux_virtual_machine` with `availability_zone = null`. If it
dies, **you cannot deploy or roll back** — including during an incident. That is the worst possible time
to lose your deployment path.

**Fix / talking points:**

- **Minimum:** a VM Scale Set with 2+ instances across zones, all registered to the same pool.
- **Better:** **Azure DevOps Managed DevOps Pools** (or scale-set agents) — Microsoft manages the image
  and lifecycle; you supply the subnet. Same private connectivity, no pet VM to patch.
- **Best for a Kubernetes shop:** run agents *as pods in AKS* via KEDA-scaled ephemeral agents. The
  agent's identity becomes a Workload Identity, there is no long-lived VM, and the agent is destroyed
  after every job — **no state leakage between builds**, which is a real supply-chain control.
- **Break-glass:** document how to deploy without the agent — see
  [08-operational-runbook.md](08-operational-runbook.md).

## P2-11. The agent bootstraps from a PAT in Key Vault.

`cloud-init.sh.tftpl` reads a PAT from Key Vault via IMDS and runs `config.sh --auth pat`. This is
handled *well*: the PAT never enters Terraform state or git, `set +x` wraps the sensitive block, and the
identity is scoped to `Key Vault Secrets User`. Genuinely good.

But it is still a long-lived, broadly-scoped credential. Improvements to raise:

- Use **Azure DevOps managed-identity agent registration** (or `--auth SP` with a federated credential),
  removing the PAT entirely.
- If the PAT stays: scope it to **Agent Pools (read, manage)** only, set a **7-day expiry**, and automate
  rotation (Key Vault near-expiry event → rotation function). A PAT with default scopes on a build
  machine that also has `docker` group access is **effectively root over your entire DevOps org**.
  **Say this — that kind of threat modelling is what "senior" means.**
- `usermod -aG docker azdevops` is root-equivalent by design. Alternatives: rootless Docker, **Podman**,
  or **buildah/BuildKit** rootless. Or don't build on the agent at all — use **ACR Tasks**
  (`az acr build`) so the build happens inside ACR and the agent never needs a Docker daemon. That last
  one is elegant and removes the entire risk class.

## P2-12. `cloud-init` pulls "latest" for several tools.

`kubelogin` uses `releases/latest/download/...`; `tflint` and Azure CLI use unpinned `curl | bash`
installers; `pip3 install checkov` is unpinned. You pinned Terraform, Helm, kubectl, Trivy, Gitleaks and
kubeconform carefully — then left four unpinned. In a bank, an unpinned `curl | bash` from the internet
**on the machine that deploys to production** is a finding.

**Fix:** pin everything, verify checksums/signatures, and ideally bake a **golden agent image** with
Packer or Azure Image Builder so CI never downloads from the internet at all. Then the firewall can deny
the agent subnet egress entirely except to ACR, ARM and Azure DevOps.

**Note the ordering bug too:** cloud-init `curl`s from `download.docker.com`, `dl.k8s.io`, `github.com`,
`releases.hashicorp.com`, `pypi.org` and `deb.nodesource.com`. The agent subnet has a route table with
**no route to the firewall** (only the AKS subnet has one), so it uses the default internet route —
meaning **your agent egresses to the internet completely unfiltered, outside your Azure Firewall
allow-list.** That contradicts your egress-control story. Either route it through the firewall and
extend the FQDN allow-list, or bake the image.

## P2-13. The pipeline reinstalls tools the agent already has.

`stage-validate.yml` / `stage-security.yml` install tflint, Checkov, Trivy, Gitleaks and kubeconform on
every run — but `cloud-init.sh.tftpl` already installed them, pinned. Your `variables.tf` comments even
say *"Keep in sync with…"*. **Two sources of truth for a version is a drift bug waiting to happen**, and
it adds minutes plus internet dependencies to every build.

**Fix:** in the pipeline, *verify* rather than install:

```bash
command -v trivy >/dev/null || { echo "##vso[task.logissue type=error]agent image is missing trivy"; exit 1; }
trivy --version
```

That turns agent-image drift into a loud, early, unambiguous error.

## P2-14. Security scans do not fail the build consistently.

- **Checkov:** `PublishTestResults` with `failTaskOnFailedTests: false`, but no `--soft-fail` or
  `--hard-fail-on` → the `checkov` command's own exit code fails the job on *any* finding, including
  LOW. Too strict; the first engineer it annoys will disable it.
- **`npm audit`:** `|| echo warning` → never fails.
- **`eslint`:** `|| echo warning` → never fails.
- **Trivy fs/image:** `--exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed` → **correctly** fails.

**Fix:** be deliberate and consistent, and state it as policy:

> **Block** on: HIGH/CRITICAL **with a fix available**; any leaked secret; any IaC finding in a defined
> critical set (public network access, unencrypted storage, wildcard RBAC).
> **Warn** on: everything else, tracked as a work item with an SLA.
> **Every suppression is a file in the repo** — `.trivyignore`, `.checkov.yaml` skip-check — each with a
> justification and an **expiry date**, reviewed in the pull request.

Ungated warnings train people to ignore the pipeline; unconditional blocking trains people to bypass it.
Both are failure modes. The middle path with **expiring, reviewed exceptions** is the answer.

## P2-15. No visible branch protection / PR-only path to prod.

The pipeline triggers on `main` and gates prod on
`condition: eq(Build.SourceBranch, 'refs/heads/main')` plus an ADO Environment approval — reasonable.
But the repo shows no branch policy (required reviewers, build validation, no direct push to `main`), no
`CODEOWNERS`, and no signed-commit requirement.

Since these live in Azure DevOps rather than in the repo, **document them** — the assessor cannot see
your ADO org. Add to the README: *"Branch policy: 2 reviewers, build validation on Validate+Security, no
force push, linear history, CODEOWNERS on `infra/` and `pipelines/`."*

## P2-16. Terraform plan artifact handling — good, with two refinements.

**Good, and worth highlighting:** you publish `tfplan.binary`, gate `apply` on an ADO Environment, and
apply **the saved plan** rather than re-planning. That is the correct pattern — it closes the
time-of-check-to-time-of-use gap where the plan an approver reviewed differs from the plan that runs.

Two refinements:

- **The plan file can contain sensitive values in plaintext.** It is published as a pipeline artifact
  that anyone with repo read access can download. Mitigation: restrict artifact retention, or keep the
  plan on the agent between Plan and Apply by making them one job with an ADO **manual validation**
  step. **Raise this yourself — it's a subtle one that separates seniors.**
- **`tfplan.json` is generated and never used.** Feed it to **Conftest/OPA** or
  `checkov --file tfplan.json` to run policy against the *plan* rather than the source. That is a
  genuinely advanced gate: it catches "this apply would **destroy** the production storage account" in a
  way source scanning never can. Add a rule like *"fail if any `delete` action targets a resource tagged
  `criticality: high`."*

## P2-17. `prevent_destroy` is used broadly — know the consequences.

`prevent_destroy = true` on both resource groups, ACR, Storage, Key Vault, LAW, AKS and the hub→spoke
peering. Good safety instinct for a bank. Two things to know:

1. It blocks `terraform destroy` **and** any plan that would *replace* the resource. If you later change
   an immutable attribute (e.g. `infrastructure_encryption_enabled` on a storage account — your own
   variable description notes this forces a new account), you get a hard error and have to edit code to
   proceed. That's intended — but it also means **`terraform destroy` for the assessment cleanup will
   fail**, and the assessment explicitly says *"clean up resources after the assessment."* Document the
   two-step cleanup (remove the lifecycle blocks, or `terraform state rm` + delete the RGs).
2. It does **not** protect against portal deletion. Pair it with **Azure resource locks**
   (`azurerm_management_lock`, `lock_level = "CanNotDelete"`) for defence in depth. Mention this.

---

# P3 — Polish (raise these yourself; they're free credibility)

- **ACR name `acr${var.environment}`** → `acrnonprod` / `acrprod`. These are **globally unique across
  all of Azure** and will collide. Use a `random_string` suffix or a hash of the subscription ID. Same
  for `sa${environment}01` → `sanonprod01` is almost certainly taken.
- **ACR is not zone-redundant.** Set `zone_redundancy_enabled = true` (Premium) for prod.
- **ACR `data_endpoint_enabled`.** With private endpoints, enabling dedicated data endpoints gives
  stable per-region FQDNs (`<registry>.<region>.data.azurecr.io`) — important if you ever need to
  allow-list registry FQDNs on a firewall, and directly relevant to the ImagePullBackOff scenario.
- **No `azurerm_storage_management_policy`** despite `cache_expiry_days` (see P1-11).
- **Key Vault contains no secrets/keys/certs** — correct (they're created out of band), but *say so
  explicitly* so it doesn't read as unfinished.
- **`private_endpoint_network_policies = "Enabled"`** on the PE subnet is the newer default and means
  **NSGs actually apply to private endpoint traffic**. Historically PE traffic bypassed NSGs entirely.
  Being able to say *"I enabled network policies on the PE subnet so my NSG is genuinely enforced"* is a
  strong, current-knowledge signal.
- **Commented-out `azurerm_route` stubs** in the PE and agent subnets. Delete them before submitting —
  commented-out code reads as unfinished. Then explain *why* the PE subnet has no UDR: private endpoints
  must **not** be forced-tunnelled through the firewall (it breaks the Private Link data path), and
  Azure's system route for the PE `/32` takes precedence anyway. **Turn the omission into a deliberate
  decision.**
- **`allow_forwarded_traffic = true` on both peerings** — required for the firewall hairpin, and
  correct. Know *why*: without it, traffic that has been routed via the firewall (and therefore arrives
  with a source outside the peered VNet's address space) is dropped.
- **No AKS `disk_encryption_set_id`** (CMK for node disks) and no `key_management_service` (CMK etcd
  encryption). For a bank these are likely mandatory. Mention as a known next step.
- **Microsoft Defender for Containers / Defender for Cloud not enabled.** One block of Terraform, large
  security value — runtime threat detection, image vulnerability assessment integrated into ACR.
- **`sampling_percentage = 100`** on App Insights — fine for a demo, an ingestion-cost problem at scale.
  Say you'd move to adaptive sampling with a fixed floor on failures and exceptions.
- **`.github/workflows` exists and is empty.** Delete it — an empty GitHub CI directory in a repo whose
  CI is Azure DevOps is confusing.
- **Commit messages all start with `#`** (`# Added architecture Document`). Cosmetic, but `#` is a
  comment character to some git tooling. Minor; a reviewer may notice.

---

# Priority fix list — if you only have four hours

Do them in this order. Each unblocks the next or buys the most credibility per minute.

| # | Fix | Time | Why in this position |
|---|---|---|---|
| 1 | Write `README.md`: structure, prerequisites, assumptions, deploy instructions, **known limitations** | 45 min | First impression; a scored deliverable; the "known limitations" section pre-empts every finding above |
| 2 | Fix module `source` paths (P0-2), pin provider `~> 4` (P0-4), declare `subscription_id` | 20 min | Makes `terraform init` / `validate` run at all |
| 3 | Break the observability cycle (P0-3) | 30 min | Makes `terraform plan` run at all |
| 4 | Grant the workload identity **Storage Blob Data Contributor** (P0-5) | 10 min | It's literally the bug the assessment asks you to debug |
| 5 | Reconcile namespace / ServiceAccount names (P0-6) | 15 min | The classic Workload Identity failure |
| 6 | Add `count` to firewall resources (P0-7); fix `node_resource_group` (P0-8) | 15 min | Removes the remaining hard errors |
| 7 | Write the application + Dockerfile (P0-1) | 90 min | Largest single scored gap |
| 8 | Fix `internet_ingestion_enabled` inversion; delete duplicate A records; wire NSG rules; add `cost_centre` | 30 min | P1s that actively contradict your own documentation |
| 9 | Run `terraform fmt -recursive`, `validate`, `helm lint`, `helm template`; capture output as **evidence** | 25 min | The "Evidence" deliverable; proves it works |

**Everything not on this list goes into the README's "Known limitations & next steps" section.**

> A documented gap is engineering judgement. An undocumented gap is an oversight.
> The difference is entirely in whether you wrote it down.

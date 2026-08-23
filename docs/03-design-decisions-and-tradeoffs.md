# 03 — Design Decisions & Trade-offs, Module by Module

> The assessment says: *"Where an implementation choice has trade-offs, state your assumptions and
> explain why you chose it."* This document is that answer, for every module.
>
> **The structure to use verbally, every single time.** Four sentences, in this order:
>
> 1. **What I chose.** ("I used Azure CNI Overlay.")
> 2. **Why — the forcing constraint.** ("Because VNet IP space is a governed, scarce resource in a bank.")
> 3. **What I gave up.** ("Pods aren't directly addressable from the VNet.")
> 4. **When I'd choose differently.** ("If an appliance needed per-pod IP policy, I'd go back to traditional CNI.")
>
> A senior engineer is not someone with the right answer. A senior engineer is someone who can name the
> cost of their answer. **Never give a decision without a cost.**

---

## Table of contents

- [A. Network — hub/spoke topology](#a-network--hubspoke-topology)
- [B. Network — egress control](#b-network--egress-control)
- [C. Network — NSGs and route tables](#c-network--nsgs-and-route-tables)
- [D. AKS — cluster architecture](#d-aks--cluster-architecture)
- [E. AKS — node pools](#e-aks--node-pools)
- [F. Identity — Workload Identity vs alternatives](#f-identity--workload-identity-vs-alternatives)
- [G. Private DNS](#g-private-dns)
- [H. Container Registry](#h-container-registry)
- [I. Storage](#i-storage)
- [J. Key Vault](#j-key-vault)
- [K. Observability and AMPLS](#k-observability-and-ampls)
- [L. Governance / Azure Policy](#l-governance--azure-policy)
- [M. Terraform structure and state](#m-terraform-structure-and-state)
- [N. Helm chart design](#n-helm-chart-design)
- [O. Pipeline design](#o-pipeline-design)
- [P. Pipeline agent](#p-pipeline-agent)
- [Q. Application-level decisions](#q-application-level-decisions)

---

## A. Network — hub/spoke topology

**Chosen:** Classic hub/spoke with bidirectional VNet peering. Hub in its own resource group
(`rg-<env>-<prefix>-hub`) holding only the firewall; spoke holding the workload.

**Why:** It separates *connectivity/security* concerns from *workload* concerns, so the two have
independent blast radii, independent RBAC and independent change cadences. A platform team owns the hub;
an application team owns the spoke. It is also the shape every Azure Landing Zone assumes, so it grows
into a real estate without rework.

**Trade-offs accepted:**

| Cost | Detail | Mitigation / when it bites |
|---|---|---|
| Peering charges | Inter-VNet data transfer is billed both directions | Negligible at this volume; material at high egress |
| Extra hop for all egress | Every outbound packet crosses the peering to the firewall | ~1 ms. Unacceptable only for latency-critical east-west |
| `allow_forwarded_traffic` required | Without it, firewall-routed traffic is dropped because its source is outside the peered VNet's range | Set to `true` on both peerings — **know why this is needed, it's a common gotcha** |
| Non-transitive peering | Spoke A cannot reach Spoke B through the hub via peering alone | Needs UDRs via the firewall, or Azure Virtual WAN |

**When I'd choose differently:**

- **Azure Virtual WAN** once there are more than about 5–10 spokes, or once branch/ExpressRoute
  connectivity enters the picture. vWAN gives managed transitive routing so you stop hand-maintaining a
  UDR matrix. The cost is less control over the routing fabric and a higher price floor.
- **A single flat VNet** for a genuinely small, single-team, single-workload estate. Hub/spoke here would
  be ceremony with no payoff — but it wouldn't survive the second workload.

**Assumption stated:** *"I assumed the hub is dedicated to this platform. In a real bank it would be a
shared, centrally-owned connectivity subscription, and my spoke would peer into it rather than deploying
its own firewall. That changes who owns the firewall rules and adds a change-request process to every
new egress FQDN — which is a real operational cost worth naming up front."*

---

## B. Network — egress control

**Chosen:** Azure Firewall (Standard) with a **policy-driven** FQDN allow-list, DNS proxy enabled,
threat intelligence in `Deny` mode, zone-redundant. AKS configured with
`outbound_type = "userDefinedRouting"`.

### Firewall vs NAT Gateway

Full comparison table is in [01-architecture.md §6](01-architecture.md#6-egress-path--how-a-private-workload-reaches-tvmaze).
The one-line answer: **NAT Gateway solves connectivity; Firewall solves policy. In a bank, the
requirement is policy.**

### `outbound_type = userDefinedRouting` — this is the important one

**Chosen** over the default `loadBalancer`.

**Why:** With `outbound_type = loadBalancer`, AKS provisions a Standard Load Balancer with a public IP
and uses it for outbound SNAT. That is a **default outbound internet path that bypasses your firewall
entirely**. You would have a firewall, a UDR, an allow-list — and a second, unmonitored door standing
open. `userDefinedRouting` tells AKS "I own egress; do not create an outbound path," and then the UDR is
the *only* way out.

**Trade-offs accepted:**

| Cost | Why it matters |
|---|---|
| **The UDR must exist before the cluster is created.** | AKS validates it at create time and fails otherwise. This is a hard ordering dependency in Terraform — your `depends_on` in `modules/aks` is doing real work |
| The control-plane identity needs `Network Contributor` on the route table | Your `azurerm_role_assignment.aks_role_assignment_route_table` — required, and a common cause of "cluster creation failed" |
| Egress is now **hard-coupled to firewall availability** | Firewall down = no egress. Mitigated by zone-redundancy; the app degrades to serving stale cache rather than failing |
| Every new outbound dependency is a firewall change | This is the *point* — it makes egress a governed change — but it is friction the app team will feel |

**The required allow-list (know these).** A private AKS cluster with forced tunnelling cannot function
without a defined set of egress rules. Your firewall policy has:

- **Application rule:** `api.tvmaze.com` on HTTPS/443 — the actual business dependency.
- **Application rule:** `destination_fqdn_tags = ["AzureKubernetesService"]` — Microsoft's curated tag
  covering `mcr.microsoft.com`, `*.data.mcr.microsoft.com`, `management.azure.com`,
  `login.microsoftonline.com`, `packages.microsoft.com`, `acs-mirror.azureedge.net` and more. **Using
  the FQDN tag rather than hand-listing these is the right call** — Microsoft maintains it, and a missed
  FQDN is a node that fails to join.
- **Network rule:** UDP/123 NTP — nodes with skewed clocks fail TLS and certificate validation. A
  classic, maddening failure.
- **Network rule:** `AzureCloud.<region>` on 443/1194/9000 — the tunnel between nodes and the AKS
  control plane.

> **Great thing to say:** *"The AKS FQDN tag is the difference between a cluster that provisions and one
> that hangs at 'creating'. I've seen teams hand-maintain that list and then break every node pool
> upgrade when Microsoft adds an endpoint. Using the tag delegates that maintenance to Microsoft, which
> is the correct trade — I lose visibility into precisely what's allowed, and I accept that."*

**When I'd choose differently:**

- **Firewall Premium** if the risk appetite requires **TLS inspection** (seeing *inside* HTTPS to the
  external API) or **IDPS**. Cost roughly doubles, latency rises, and TLS inspection requires
  distributing a CA certificate into every container — which is a real operational burden and a new
  key-management problem. For a read-only public API like TVMaze, Standard is proportionate.
- **NAT Gateway behind the firewall** if SNAT port exhaustion becomes the constraint (a firewall gives
  2,496 SNAT ports per public IP; a NAT Gateway gives 64,512).
- **No egress at all** — if TVMaze data could be pre-loaded into Blob by a separate, isolated ingestion
  job, the serving path would need zero internet access. **This is genuinely the most secure design and
  is worth raising unprompted**: it converts a live internet dependency into a batch one, and the API
  becomes fully air-gapped. The cost is data freshness and a second component to operate.

---

## C. Network — NSGs and route tables

**Chosen:** A per-subnet NSG with rules supplied as **typed `list(object)` variables from tfvars**, plus
a route table on the node subnet only.

**Why the data-driven NSG pattern:** rules become environment configuration rather than module code, so
you can differ nonprod from prod without forking the module, and a rule change is a tfvars diff that
shows up cleanly in a plan and in code review.

**Trade-offs accepted:**

| Cost | Detail |
|---|---|
| **Weaker type safety** | The module accepts any priority/protocol string; a typo becomes an apply-time Azure error, not a plan-time Terraform error. Fixable with `validation` blocks |
| Verbosity in tfvars | Every environment repeats the rule set — real duplication between your nonprod and prod files today |
| Priority as the map key | `for_each = { for nsg in var.nsg_rules... : nsg.priority => nsg }` means **two rules with the same priority silently collide** and one disappears. A `precondition` asserting uniqueness would catch it |

⚠️ **Note the live defect (P1-4):** these variables are defined in tfvars but **never declared in the
root `variables.tf` and never passed to the module**, so all three NSGs deploy empty. Fix it or lead
with it.

**Why the PE subnet has no route table entries** (the commented-out stub in your code): private endpoint
traffic must **not** be forced-tunnelled through the firewall. Azure installs a `/32` system route for
each private endpoint that takes precedence over a `0.0.0.0/0` UDR anyway, and forcing PE traffic
through an NVA breaks the Private Link data path (asymmetric routing — the return path doesn't traverse
the firewall). **Delete the commented stub and state this as a deliberate decision.**

**Why NSGs matter on the PE subnet at all:** historically, private endpoint traffic **bypassed NSGs
entirely**. Setting `private_endpoint_network_policies = "Enabled"` (which you did) turns NSG
enforcement on for PE traffic. Without it, your carefully-written "only the AKS and agent subnets may
reach 443" rule would be decorative. **Knowing this is a strong current-knowledge signal — raise it.**

---

## D. AKS — cluster architecture

### Private cluster

**Chosen:** `private_cluster_enabled = true`, `private_cluster_public_fqdn_enabled = false`,
`private_dns_zone_id` pointing at a customer-managed zone.

**Why `public_fqdn_enabled = false` specifically:** by default AKS *also* publishes a public FQDN for the
private cluster (resolvable from anywhere, though the API is only reachable privately). Disabling it
removes the resolvable name entirely. It is defence in depth against reconnaissance — an attacker
enumerating DNS finds nothing.

**Why a customer-managed private DNS zone rather than `System`:** a system-managed zone lives in the
AKS-managed node resource group and cannot be linked to other VNets you control. A customer-managed zone
lets you link the hub, other spokes, and eventually an on-prem resolver. **This is what makes the private
cluster reachable from a peered agent subnet.**

**Trade-off:** the control-plane identity needs `Private DNS Zone Contributor` on that zone before
cluster creation, and the zone name must be exactly
`privatelink.<region>.azmk8s.io` — hardcoded as `privatelink.westeurope.azmk8s.io` in your tfvars, which
means **the region is baked into the DNS zone list**. Deploying to `northeurope` would silently fail to
find the key. **Fix:** derive it — `"privatelink.${var.location}.azmk8s.io"`.

### Azure RBAC for Kubernetes vs Kubernetes RBAC

**Chosen:** `azure_rbac_enabled = true` with `local_account_disabled = true`.

This is an explicit assessment question — full answer in
[04-assessment-answers.md](04-assessment-answers.md#explain-the-distinction-between-azure-rbac-and-kubernetes-rbac).
The trade-offs:

| | Azure RBAC for Kubernetes (chosen) | Native Kubernetes RBAC |
|---|---|---|
| Where policy lives | Azure role assignments — visible in the portal, in Azure Policy, in access reviews, in PIM | `Role`/`RoleBinding` objects inside the cluster |
| Audit trail | **Azure Activity Log** — a central, tamper-evident, exportable record | Kubernetes audit log only, per-cluster |
| Lifecycle | Entra group membership; a leaver loses cluster access when HR disables the account | Bindings must be manually reconciled with identity |
| Granularity | Four built-in roles (Reader/Writer/Admin/Cluster Admin) + custom Azure roles | **Full Kubernetes verb/resource/namespace granularity** |
| Latency | Role assignment propagation can take **~5 minutes** | Instant |
| Availability | Depends on Entra reachability at authorisation time | Cluster-local |

**Why I chose Azure RBAC:** in a bank, the audit and joiner/mover/leaver story dominates. "Who could
access production Kubernetes on 3 March?" must be answerable from a central system, not by diffing
cluster YAML. And PIM gives me **time-bound, approval-gated, just-in-time cluster-admin** — which native
RBAC cannot do at all.

**What I gave up:** fine-grained authorisation. If I need "this team may `get` pods and `create`
portforward but never `exec`, only in namespace X, only on resources with label Y", Azure's built-in
roles can't express it. **The answer is that they compose** — Azure RBAC gates entry, and native RBAC
still applies inside. I'd use Azure RBAC for coarse access and add native `Role`/`RoleBinding` for
fine-grained exceptions, delivered through the Helm chart or a separate platform chart.

**`local_account_disabled = true`** removes the `clusterAdmin` certificate-based local account —
otherwise anyone with the Azure `Azure Kubernetes Service Cluster Admin Role` can fetch a kubeconfig with
a client certificate that **completely bypasses Entra, MFA, Conditional Access and your entire RBAC
model**, and whose use is nearly invisible in logs. **Turning this off is one of the highest-value
single settings in the whole cluster.** Say it exactly that way.

**Trade-off:** you lose the break-glass path. If Entra is unavailable, nobody can reach the API server.
Mitigation: a documented, monitored, PIM-gated procedure to temporarily re-enable it — which is itself a
change requiring approval. **Document that in the runbook** ([08](08-operational-runbook.md)).

### Calico network policy + `network_data_plane = "azure"`

**Chosen:** `network_policy = "calico"`.

**Trade-off worth knowing:** Azure now offers **Cilium** (`network_data_plane = "cilium"`) as the
recommended data plane — eBPF-based, better performance, `CiliumNetworkPolicy` supports L7 rules and FQDN
egress policy *inside* the cluster. Calico is mature and well-understood but is the older choice, and
**Azure has announced Calico's retirement path in favour of Azure CNI powered by Cilium.**

> **Say this:** *"I used Calico because it's the well-trodden option and I know its failure modes. If I
> were starting today I'd use Azure CNI powered by Cilium — eBPF instead of iptables, so policy
> enforcement scales better, plus FQDN-based egress policy at the pod level, which would let me push some
> of my firewall allow-list down into the cluster and get per-workload egress control rather than
> per-subnet."*

---

## E. AKS — node pools

**Chosen:** A tainted system pool (`only_critical_addons_enabled`) plus a separate user pool labelled
`workload=application`, both with cluster autoscaler and spread across three zones.

**Why separate pools:** the system pool runs CoreDNS, `metrics-server`, the Workload Identity webhook and
the OMS agent. If an application pod with a memory leak lands on a system node and triggers eviction,
**you lose cluster DNS** — and a DNS outage looks like a total, inexplicable failure of everything. The
`CriticalAddonsOnly` taint makes that impossible.

**Trade-offs:**

| Cost | Detail |
|---|---|
| Minimum 4 nodes (2 system + 2 user) even when idle | Real money. In non-prod I'd drop system to 1 node and accept no system-pool HA |
| Bin-packing efficiency drops | Two pools means two sets of headroom |
| Changing `only_critical_addons_enabled` later **recreates the node pool** | See finding P1-10 — this is why it should be an explicit variable, not derived |

**Zones (`["1","2","3"]`):** the cluster autoscaler balances across zones, so a single-AZ failure removes
roughly a third of capacity rather than all of it. Combined with `topologySpreadConstraints` in the chart
and `PodDisruptionBudget`, that gives real zone resilience.

**Trade-off to name:** zone-redundant node pools mean **cross-zone data transfer charges** for pod-to-pod
and pod-to-PE traffic, and slightly higher intra-cluster latency. For a bank, availability wins — but say
you know the bill exists.

**`os_disk_type = "Ephemeral"`:** faster node provisioning and image updates, no managed-disk IOPS cost,
and it enforces "nodes are cattle" (nothing on the OS disk survives a reallocate). ⚠️ **The trade-off is a
hard constraint you got wrong** (P1-9): the VM SKU must have local temp storage, and `Standard_D2s_v5`
does not. Use `Standard_D2ds_v5`. **Own this one — it's a specific, factual detail that proves you
understand ephemeral disks rather than copying them.**

**`max_surge = "33%"`:** upgrades one third of the pool at a time. Faster than the default 1 node, but
consumes a third of capacity during the upgrade and burns quota. For prod I'd use `33%` on the user pool
and `1` on the system pool — you never want a third of your CoreDNS capacity gone at once.

**`sku_tier = "Standard"`:** the free tier has **no API server SLA and no uptime guarantee**, and the
control plane is not scaled for load. For anything production-like, Standard (99.95% with AZs) is the
minimum. Say the number.

---

## F. Identity — Workload Identity vs alternatives

**Chosen:** Microsoft Entra Workload ID — a user-assigned managed identity with a federated identity
credential bound to `system:serviceaccount:<ns>:<sa>`.

### The alternatives, and why each loses

| Option | How it works | Why not |
|---|---|---|
| **Service principal + client secret** | Secret in a K8s Secret or Key Vault | A long-lived, exfiltratable credential. Must be rotated. Appears in logs, env dumps, crash reports. **This is exactly what the assessment forbids.** |
| **AAD Pod Identity (v1)** | A DaemonSet (NMI) intercepts IMDS calls per pod | **Deprecated**, retired Sept 2023. Node-level interception, race conditions on pod start, needed elevated cluster permissions |
| **Kubelet identity** | Pods share the node's managed identity | **No workload isolation.** Every pod on the node gets the same identity — one compromised sidecar has your storage permissions |
| **Key Vault CSI + a secret** | Mount a client secret from Key Vault | Better than a K8s Secret, but it's still a secret; you've moved the problem, not removed it |
| **Workload Identity (chosen)** | Projected OIDC JWT exchanged for an Entra token | Short-lived (~1h, kubelet-rotated), audience-scoped, per-ServiceAccount, **nothing to steal that lasts** |

**Trade-offs accepted:**

| Cost | Detail |
|---|---|
| **Brittle exact-string coupling** | The FIC subject must equal `system:serviceaccount:<ns>:<sa>` character for character. A namespace rename silently breaks auth. **This is finding P0-6, and it is the #1 real-world Workload Identity failure** |
| Failure mode is opaque | `AADSTS70021` surfaces as a generic auth error deep in an SDK stack trace, often only on the *first* Azure call — so a pod starts fine and fails minutes later |
| SDK version floor | Requires reasonably recent Azure SDKs (`@azure/identity` ≥ 3.x for Node) |
| 20 FIC limit per identity | Fine at this scale; matters if you federate many ServiceAccounts to one identity |

**Design decision: one identity per workload, not one shared identity.** Your `modules/identity` takes a
`map(object)` of ServiceAccounts, which allows *many* SAs to federate to *one* identity. That is
convenient and wrong at scale — it means every federated workload shares the same Azure permissions.

> **Say this:** *"The module supports multiple ServiceAccounts on one identity because it's convenient for
> a demo, but the right model is one managed identity per workload, so RBAC grants are per-workload and
> the blast radius of a compromise is one service. I'd invert the module: `for_each` over workloads,
> creating an identity plus its FIC for each."*

**User-assigned vs system-assigned:** user-assigned, deliberately. A system-assigned identity is tied to
a resource's lifecycle — delete and recreate the resource and you get a *new* principal ID, so **every
role assignment silently breaks**. User-assigned identities are independent, so RBAC survives resource
recreation and you can grant permissions *before* the consuming resource exists (which breaks a
dependency cycle in Terraform). The trade-off is one more object to manage and to clean up.

---

## G. Private DNS

**Chosen:** Customer-created zones in the **hub** resource group, linked to **both** hub and spoke VNets,
with A records managed by each private endpoint's `private_dns_zone_group`.

**Why zones live in the hub:** DNS is a shared connectivity service. Zones in the hub can be linked to
every current and future spoke, and their lifecycle is decoupled from any one workload. If the spoke's
resource group is torn down and rebuilt, DNS survives.

**Why link to both VNets:** the spoke link is what makes pods resolve private IPs. The hub link is what
makes the firewall's DNS proxy resolve them too — and if you ever put a jumpbox or DNS resolver in the
hub, it needs the link as well. **A zone linked to the wrong VNet is the single most common Private Link
failure.**

**Why `registration_enabled = false`:** auto-registration adds A records for every VM NIC in the linked
VNet into that zone. In a `privatelink.*` zone that is pure pollution and a potential conflict. Only
enable it on a zone you're deliberately using for VM name registration — and note **a VNet may only have
one auto-registration link across all zones.**

**Trade-off:** zones in the hub RG mean the workload's Terraform must have permission to create private
endpoints that write records into a *different* resource group — a cross-RG RBAC grant, and in a real
bank, a cross-team dependency. Worth naming: *"In a real organisation the hub is owned by a network team,
so 'add a private DNS zone' becomes a ticket, and my pipeline needs a delegated role on that RG. That's
an organisational cost of the pattern, not just a technical one."*

⚠️ **Live defects:** the `zone_names` vs `private_dns_zones` variable mismatch, the broken diagnostic
setting, and the duplicate manual A records — findings P1-2 and P1-3.

**Alternative considered — Azure DNS Private Resolver:** not used, because both VNets link directly to
the zones and there is no on-prem or custom-DNS requirement. **Add it the moment on-prem clients need to
resolve these names**, because on-prem cannot reach `168.63.129.16`; you need a resolver inbound endpoint
as a conditional-forwarder target. That's the standard hub design and worth stating so it's clear you
omitted it deliberately rather than not knowing about it.

---

## H. Container Registry

**Chosen:** Premium SKU, `public_network_access_enabled = false`, private endpoint,
`admin_enabled = false`, `network_rule_bypass_option = "AzureServices"`, untagged-manifest retention.

**Why Premium:** **Private Link requires Premium.** Basic and Standard cannot have private endpoints at
all. The assessment calls this out explicitly. Premium also brings geo-replication, content trust,
customer-managed keys and repository-scoped tokens.

**Trade-off:** roughly $1.67/day vs $0.17/day for Basic — a 10× cost step you cannot avoid if you need
private connectivity. **That's the honest answer: the requirement dictates the SKU.**

**Why `admin_enabled = false`:** the admin account is a **shared username/password with full push/pull
rights**, unattributable in logs, un-rotatable without breaking every consumer. Its existence defeats
your entire identity model. Off, always.

**Trade-off:** every consumer must authenticate with Entra. `az acr login` exchanges an Entra token for
an ACR refresh token; AKS uses the kubelet identity's `AcrPull`. Any tool that only speaks
`docker login -u -p` needs a different integration path.

**Why the kubelet identity gets `AcrPull`, not the control-plane identity:** the **kubelet** pulls
images, and it runs under `kubelet_identity` — a separate managed identity from the cluster's
control-plane identity. Your `outputs.tf` comment says exactly this and it is correct. **This is a
frequent interview trap: "which identity pulls the image?" The answer is the kubelet identity.**

**`network_rule_bypass_option = "AzureServices"`:** allows trusted Azure services (ACR Tasks, Defender
image scanning, geo-replication) through despite public access being off. Without it, ACR Tasks and
Defender vulnerability assessment stop working. **Trade-off:** it is a broad category, not a specific
service — you are trusting Microsoft's definition of "trusted".

**What's missing (raise it):** `zone_redundancy_enabled` for prod HA; `data_endpoint_enabled` for stable
per-region data FQDNs; geo-replication for multi-region; and **image signing** (`trust_policy_enabled` is
a variable defaulting to `false`, and Notary v2 / `cosign` + a Ratify admission policy would be the
modern answer). Also **a globally-unique name** — `acrnonprod` will collide (finding P3).

---

## I. Storage

**Chosen:** StandardV2, LRS, Hot tier, public access disabled, private endpoint on the `blob`
subresource, `default_action = "Deny"`, infrastructure encryption, versioning + soft delete, TLS 1.2 min.

**Why Blob rather than Redis/Cosmos for the cache:**

| Option | Latency | Cost | Why not chosen |
|---|---|---|---|
| **Blob (chosen)** | 10–50 ms | ~£0.02/GB/month | Slowest, but **durable, cheap, shared across replicas with no extra tier to operate**, and the assessment specified it |
| Azure Cache for Redis | <1 ms | ~£40/month minimum | Right for a hot path; here it's a whole extra service, a private endpoint and a failure domain for a 1-hour TTL |
| In-memory in the pod | µs | free | **Not shared** — N replicas means N cache misses and N upstream calls, and everything is lost on restart |
| Cosmos DB | ~5 ms | expensive | Massive overkill for one JSON document |

> **Say this:** *"For a 1-hour TTL on a public dataset, Blob's latency is irrelevant next to the ~200 ms
> upstream call it replaces. I'd move to Redis the moment the TTL drops below about a minute or the read
> rate makes per-request Blob latency the dominant term — at which point I'd probably do both: Redis as
> L1, Blob as durable L2."*

**`account_replication_type = "LRS"`:** three copies within one datacentre. ⚠️ **For prod this should be
ZRS** (three availability zones) — your cluster is zone-redundant but its cache is not, so a single-zone
storage failure takes out the cache for all zones. Finding P2-9. **GZRS** if you need regional
durability, though note that geo-redundant reads require RA-GZRS and failover is a manual, hours-long
operation with potential data loss.

**`infrastructure_encryption_enabled = true`:** double encryption at rest (service-level plus
infrastructure-level). **Trade-off: it is immutable — it cannot be changed after creation, only replaced.
Combined with `prevent_destroy`, changing your mind means a manual migration.** Your own variable
description notes this, which is good documentation practice — say so.

**Versioning + soft delete:** protects against accidental or malicious deletion of cached data, and gives
you a recovery path. **Trade-off: every overwrite creates a version, so a frequently-refreshed cache
grows storage cost silently.** This is exactly why you need the lifecycle management policy that
`cache_expiry_days` implies but doesn't create (finding P1-11) — it should expire both current blobs and
old versions.

⚠️ **`shared_access_key_enabled = true` contradicts the whole design** — finding P1-5. Set it to `false`.

---

## J. Key Vault

**Chosen:** Standard SKU, **RBAC authorisation** (not access policies), purge protection on, soft delete
90 days, public access disabled, private endpoint.

**Why RBAC over access policies:**

| | RBAC (chosen) | Access policies (legacy) |
|---|---|---|
| Granularity | Per-vault, per-secret, per-key scoping | Per-vault only |
| Management | Standard Azure role assignments — PIM, access reviews, `az role assignment list` | A bespoke ACL model that no other Azure service uses |
| Audit | Azure Activity Log | Vault-specific |
| Limit | Unlimited assignments | **Hard cap of 1,024 access policy entries** |
| Propagation | Up to ~10 minutes | Near-immediate |

**Trade-off:** RBAC propagation delay bites in CI/CD — Terraform creates a role assignment and
immediately tries to write a secret, getting a 403. The standard fix is a retry or a `time_sleep`, which
is ugly. **Mention it; it shows you've actually done this.**

**`purge_protection_enabled = true`:** a deleted vault (or secret) cannot be permanently purged until the
soft-delete window expires. **This is irreversible — it cannot be turned off once on.** It exists to stop
an attacker with Contributor rights from destroying your keys and, with them, everything they encrypt.
**Trade-off, and this one is practical: for an assessment sandbox, purge protection means your Key Vault
name is reserved for 90 days after `terraform destroy`, and re-running with the same name fails.** Your
`provider "azurerm" { features { key_vault { recover_soft_deleted_key_vaults = true } } }` handles the
recovery path — good, and worth pointing out.

**`network_acls { bypass = "AzureServices" }`:** needed for the Key Vault CSI driver, disk encryption and
ARM template deployments. Same broad-trust trade-off as ACR.

**The design point to make:** *"There are deliberately no secrets in this Key Vault in source control.
Terraform never writes a secret value — the only secret in the design is the agent PAT, created
out-of-band with `az keyvault secret set` and read at boot by the VM's managed identity. The vault is
provisioned by IaC; the secrets are not. That separation is the whole point."*

---

## K. Observability and AMPLS

**Chosen:** Log Analytics + Application Insights (workspace-based), AMPLS with `PrivateOnly` ingestion and
configurable query access, `local_authentication_enabled = false`, Container Insights via `oms_agent`
with `msi_auth_for_monitoring_enabled`, diagnostic settings on every resource.

**Why workspace-based App Insights:** classic App Insights is retired. Workspace-based means all telemetry
lands in one Log Analytics workspace, so you can join application traces against AKS container logs and
Azure resource logs **in a single KQL query**. That correlation ability is the entire answer to the
assessment's *"how logs correlate across AKS, Azure resources and the application."*

**Why `local_authentication_enabled = false`:** disables instrumentation-key-based ingestion, forcing
Entra-authenticated telemetry. Otherwise anyone with the key can inject arbitrary telemetry into your
production workspace — **poisoning the exact data you'd use during an incident**. Nice control; say it.

**Trade-off:** every telemetry producer must support Entra auth. Some older agents and SDKs don't. And —
as finding P2-3 notes — **it makes the App Insights connection string a non-secret**, so the Kubernetes
Secret your pipeline creates for it is unnecessary.

**Why AMPLS:** the assessment says *"if private-only monitoring is implemented, use AMPLS."* Without it,
the OMS agent and the App Insights SDK send telemetry to public Azure Monitor endpoints — an egress path
out of your private network carrying, potentially, sensitive log content.

**The AMPLS trade-offs, which are significant and worth knowing:**

| Cost | Detail |
|---|---|
| **It needs five private DNS zones** | `monitor.azure.com`, `oms.opinsights.azure.com`, `ods.opinsights.azure.com`, `agentsvc.azure-automation.net`, `blob.core.windows.net`. Your tfvars has all of them — good |
| **`PrivateOnly` is global in effect** | Once a VNet resolves Azure Monitor through an AMPLS private endpoint, *all* Azure Monitor resources it reaches are subject to the scope's access mode. **One AMPLS in `PrivateOnly` can silently cut off other workspaces**, including ones another team owns |
| It shares the blob zone with Storage | `privatelink.blob.core.windows.net` is needed by both AMPLS and your storage account — an unexpected coupling |
| Limits | 300 resources per AMPLS, 10 AMPLS per resource, 10 private endpoints per AMPLS |
| Portal experience degrades | With `query_access_mode = PrivateOnly`, engineers cannot query logs from a laptop — only from inside the network |

**Your design's `allow_public_query` escape hatch is the right compromise**: private ingestion (the data
never leaves the network on the way in) with public query (engineers can still investigate at 3am from a
laptop over Conditional-Access-protected Entra auth). **Say exactly that — it is a mature, defensible
position, and the fact you made it a variable means the risk owner can decide.**

⚠️ **The inversion bug (P1-1) means the code doesn't currently do what this paragraph claims.** Fix it.

---

## L. Governance / Azure Policy

**Chosen:** Built-in policy definitions assigned at **resource-group** scope: allowed locations, required
tags (`for_each`), deny public network access on Storage and ACR, require private AKS, plus two
Gatekeeper policies (no privileged containers, no privilege escalation) with a configurable effect.

**Why built-in definitions:** they are maintained by Microsoft, map to compliance frameworks (CIS, NIST,
PCI, ISO 27001), and appear in Defender for Cloud's regulatory compliance dashboard for free. **Custom
policy is a maintenance liability — write it only when nothing built-in fits.**

**Why `kubernetes_policy_effect` defaults to `Audit`:** applying `Deny` Gatekeeper constraints to an
existing cluster instantly blocks deployments that were previously fine — including, potentially, system
components. **The correct rollout is Audit → measure → remediate → Deny.** Your variable description says
exactly this. **That progression is a genuinely senior answer and you should volunteer it.**

**Trade-offs:**

| Cost | Detail |
|---|---|
| **Resource-group scope is far too narrow** | Anyone who can create a new RG escapes every policy. Hub resources are entirely ungoverned today. Real governance belongs at **management group** scope so it applies to subscriptions that don't exist yet |
| Deny policies break emergency changes | A genuine incident fix can be blocked by policy. You need a documented, audited **exemption** process (`azurerm_resource_policy_exemption` with an expiry) — not "turn the policy off" |
| Gatekeeper adds admission latency and a failure mode | If the admission webhook is unhealthy, pod creation can fail cluster-wide |
| No `DeployIfNotExists` / remediation | Your policies detect and deny; they don't fix. Adding DINE (e.g. auto-enable diagnostic settings) requires a managed identity on the assignment and a remediation task |

⚠️ **Live defect (P1-8):** your required-tags policy demands `cost_centre` and your tfvars don't set it —
so **your own policy will deny your own apply.**

**What I'd add for a bank:** a full **Azure Landing Zone policy initiative** at management-group scope,
`Deny` on public IP creation, mandatory diagnostic settings via DINE, `Deny` on non-approved VM SKUs and
regions, and Defender for Cloud with a regulatory compliance standard attached.

---

## M. Terraform structure and state

**Chosen:** One shared root module (`infra/terraform`), per-environment `terraform.tfvars` and
`azurerm.tfbackend`, remote state in an Azure Storage backend with `use_oidc` and `use_azuread_auth`,
modules under `modules/`.

**Why per-environment backend files rather than workspaces:**

| | Separate state files (chosen) | Terraform workspaces |
|---|---|---|
| Blast radius | prod state is a different file, in a different **storage account and subscription** | One backend; a mistake can touch the wrong workspace |
| Access control | Prod state can be RBAC-locked so only the prod pipeline identity reads it | Same backend credentials for all workspaces |
| Config divergence | Natural — different tfvars per environment | Awkward — `terraform.workspace` conditionals leak everywhere |
| Cognitive load | Explicit: the backend file names the environment | Implicit: `terraform workspace show` and hope |

> **The sentence to use:** *"Workspaces are for ephemeral variations of the same thing — a feature-branch
> copy. They are not an environment isolation boundary, because they share a backend and therefore share
> credentials. For prod vs non-prod in a bank I want two state files in two storage accounts in two
> subscriptions, so that a compromised non-prod pipeline identity literally cannot read prod state — and
> prod state contains secrets."*

**Why `use_oidc = true` everywhere:** workload identity federation for the service connection. **There is
no client secret in Azure DevOps at all** — the OIDC token is issued per-run and lives for minutes. This
is the single most important CI/CD security control in the repo. **Lead with it.**

**Why remote state at all:** locking (concurrent applies corrupt state), durability, and team access.
Azure blob leases give you state locking for free.

**⚠️ State security — an important point to raise unprompted:** *"Terraform state contains secrets in
plaintext — connection strings, generated passwords, certificate data. So state is a crown-jewel asset.
It needs: a dedicated storage account, private endpoint, `shared_access_key_enabled = false`, Entra-only
access, versioning + soft delete, diagnostic logging on every read, and RBAC scoped so that only the
pipeline identity for that environment can read that container. I'd also enable customer-managed keys.
Most teams get this wrong — they lock down every resource and leave state in a public storage account."*

**Structural trade-offs:**

| Choice | Cost |
|---|---|
| One root module for everything | **A single `terraform apply` touches network, cluster, data and policy.** A 40-minute apply, one lock, and a blast radius covering the whole platform |
| | **Alternative:** layered state (`00-network`, `10-platform`, `20-workload`) wired with `terraform_remote_state` or data sources. Smaller blast radius, faster applies, independent cadence — at the cost of orchestration complexity and cross-layer version skew. **For a bank, I'd layer it.** |
| `prevent_destroy` widely applied | Blocks cleanup and blocks legitimate replacement (finding P2-17) |
| `create_before_destroy` on VNets/subnets | Sound instinct, but **subnets cannot be created before destroy while an address range is in use** — the CIDR conflicts with itself. Likely to fail in practice on a replacement |
| No `.terraform.lock.hcl` committed | Reproducibility gap (finding P0-4) |
| No `precondition` / `postcondition` blocks | You use `validation` on some variables — good. `precondition` on resources (e.g. "assert the firewall private IP is non-empty when forced tunnelling is on") would catch misconfiguration at plan time rather than apply time |

---

## N. Helm chart design

**This is the strongest part of your repository. Present it with confidence.**

**Chosen:** A single chart with `values.yaml` as the safe base plus `values-nonprod.yaml` /
`values-prod.yaml` overlays, `_helpers.tpl` for naming/labels, and a `validateValues` fail-fast guard.

**Why overlays rather than separate charts / Kustomize:**

| | Helm values overlays (chosen) | Kustomize | Separate charts per env |
|---|---|---|---|
| Drift risk | Low — one template set | Low | **High** — templates diverge silently |
| Env differences | Explicit and diffable in a small file | Explicit patches | Buried in duplicated templates |
| Rollback | `helm rollback` — first-class, atomic | Manual (re-apply previous manifests) | Per-chart |
| Complexity | Template logic can get gnarly | Simpler templates, more files | Simplest per chart, worst overall |

Helm wins here specifically because of **release semantics**: `helm history`, `helm rollback`,
`helm status` and `--atomic` give you a versioned, revertible unit of deployment. Kustomize has no
concept of a release, so rollback is "re-apply the old YAML and hope" — and the assessment explicitly
asks you to demonstrate rollback.

**The specific chart decisions worth defending:**

| Decision | Rationale | Trade-off |
|---|---|---|
| `checksum/config` annotation on the pod template | ConfigMap changes trigger a rolling restart. Without it, Kubernetes updates the ConfigMap and pods keep the old values until something else restarts them — a silent, extremely confusing config drift | Every ConfigMap change causes a rollout, even a trivial one |
| `maxUnavailable: 0, maxSurge: 1` | **Never lose capacity during a rollout.** Add one, verify, remove one | Slower rollouts; needs headroom for +1 pod |
| Memory limit, **no CPU limit** | CPU is compressible; a CPU limit causes CFS throttling and p99 latency spikes on an idle node. Memory is incompressible, so its limit is what protects the node | Burstable QoS → evicted before Guaranteed pods under pressure. See P2-6 |
| `readOnlyRootFilesystem: true` + `emptyDir` on `/tmp` | Container escape hardening; nothing can be written to the image layer | Must know every writable path the app needs. `sizeLimit: 64Mi` prevents an emptyDir from filling the node — good detail |
| `runAsNonRoot`, `runAsUser: 65532`, `drop: ALL`, `seccompProfile: RuntimeDefault` | Full Pod Security Standards *restricted* compliance | The image must actually support it — 65532 must match the Dockerfile's `USER` |
| `automountServiceAccountToken: false` | The pod cannot call the Kubernetes API at all. **Does not break Workload Identity** — the webhook projects its own token volume | Breaks anything that legitimately needs the API (it doesn't here) |
| Startup probe separate from liveness | Slow starts don't trigger liveness restarts. `12 × 5s = 60s` grace | One more probe to reason about |
| `topologySpreadConstraints` with `ScheduleAnyway` | Prefers zone spread; **degrades placement rather than blocking scheduling** during a zone outage | Under pressure you may get a skewed distribution and not know |
| PDB `minAvailable: 2` in prod (of 3 replicas) | Node drains can only take one pod at a time | ⚠️ **A PDB that can never be satisfied blocks node drains forever.** With `minAvailable: 2` and HPA `minReplicas: 3` this is safe — but if replicas ever drop to 2, cluster upgrades stall. `maxUnavailable: 1` is the safer formulation |
| `fail` on missing `workloadIdentity.clientId` | Turns a silent runtime auth failure into a loud template failure | Only catches what you check — extend it to the SA subject (see P0-6) |

**What I'd add:** the Helm test hook (P2-8), a `SecretProviderClass` if real secrets appear (P2-3),
`priorityClassName` so the API outranks batch workloads under pressure, and **deployment by digest rather
than tag** (P1-6).

---

## O. Pipeline design

**Chosen:** One multi-stage YAML pipeline with reusable stage templates, stage order
Validate → Security → BuildImage → Infra_nonProd → Deploy_nonProd → Infra_Prod → Deploy_Prod, ADO
Environment approval gates, and OIDC service connections.

**Why one pipeline rather than several:**

| | Single multi-stage (chosen) | Separate infra/app pipelines |
|---|---|---|
| Promotion visibility | **One view from commit to prod** — the assessment asks for a clear promotion flow | Correlating runs across pipelines is manual |
| Coupling | App and infra must move together, even when only one changed | Independent cadence |
| Run time | Full pipeline every time | Only what changed |

> **The honest trade-off to state:** *"For this assessment a single pipeline makes the promotion flow
> obvious, which is what was asked. In production I'd split them: infrastructure changes are rare,
> high-risk and change-managed; application changes are frequent, low-risk and should deploy many times a
> day. Coupling them means either the app waits for infra approvals or infra inherits the app's cadence —
> both are bad. I'd keep the infra pipeline as the platform's, and have the app pipeline consume the
> platform's outputs from state or from a published artifact."*

**Why templates:** `stage-terraform.yml` is used twice with different parameters, `stage-deploy.yml`
twice. That is the DRY win — but the deeper reason is **consistency of controls**: prod cannot
accidentally skip a security step, because it runs the same template as non-prod. Say that; it reframes
templating as a security control rather than a tidiness preference.

**Why plan → publish → approve → apply-the-saved-plan:** closes the TOCTOU gap. Re-planning at apply time
means the approver approved something that may no longer be what runs. ⚠️ But the plan artifact can
contain plaintext secrets — see P2-16.

**Why security scanning runs before build:** you don't want to spend build minutes on a commit containing
a leaked credential, and Gitleaks with `fetchDepth: 0` scans the whole history.

**Why `az acr login` rather than `docker login -u -p`:** `az acr login` exchanges the current Entra token
for a short-lived ACR refresh token. **No password exists anywhere.** The alternative requires the ACR
admin account, which you correctly disabled.

**Trade-offs / weaknesses (see [02](02-code-review-findings.md)):** single build target registry (P1-6),
mutable tag rather than digest, `--atomic` plus manual rollback (P1-14), inconsistent scan gating
(P2-14), and tool installation duplicated with the agent image (P2-13).

---

## P. Pipeline agent

**Chosen:** A self-hosted Linux VM in the spoke, no public IP, cloud-init bootstrap, PAT from Key Vault
via IMDS, Entra SSH login, unprivileged `azdevops` service account.

**Why self-hosted at all:** the assessment states it, and the reason is concrete — **Microsoft-hosted
agents have no route to `10.101.1.x` and no link to your private DNS zones.** They would resolve
`acrnonprod.azurecr.io` to a public IP and get connection-refused, because public access is disabled.

**Alternatives, ranked:**

| Option | Verdict |
|---|---|
| **Microsoft-hosted + self-hosted gateway/VPN** | Fragile, and you've re-created the private agent with extra steps |
| **Self-hosted VM (chosen)** | Works. Full control. But it's a **pet**: patch it, monitor it, and it's a SPOF (P2-10) |
| **VMSS agents** | Same model, autoscaled, zone-redundant, image-refreshed. **The minimum for prod** |
| **Managed DevOps Pools** | Microsoft manages image + lifecycle, you supply the subnet. Best VM-based option today |
| **Agents as AKS pods (KEDA-scaled)** | **Best for a Kubernetes shop.** Ephemeral per-job, Workload Identity instead of a PAT, no long-lived host, no state leakage between builds. Cost: agents run in the cluster they deploy to — a circularity you must break for cluster-level changes |

**Security decisions that are genuinely good here, and worth pointing at:**

- No public IP; access via `az ssh vm` with **Entra login** (`AADSSHLoginForLinux`), so SSH access is
  governed by Conditional Access and MFA rather than a key file.
- The PAT is read at boot from Key Vault via IMDS and never touches Terraform state or git.
- `set +x` wraps the sensitive block so the PAT never reaches the cloud-init log.
- The agent runs as an unprivileged user, not root.
- The VM's managed identity has **exactly one** permission: `Key Vault Secrets User`.

**Weaknesses to acknowledge:** the PAT itself (P2-11); `docker` group membership is root-equivalent;
unpinned `curl | bash` installs (P2-12); and **the agent subnet has no route to the firewall, so it
egresses to the internet unfiltered** — which contradicts the egress-control story. **Raise that one
yourself. Nothing signals seniority like finding the hole in your own security model.**

---

## Q. Application-level decisions

Even though the app isn't written yet (P0-1), the contract encoded in your ConfigMap, chart and smoke
test implies these decisions. **Own them as decisions.**

| Decision | Rationale | Trade-off |
|---|---|---|
| **Cache-aside with write-through, TTL from blob `lastModified`** | No extra metadata write, no clock-skew problem | Coarse; no per-entry TTL; two concurrent misses both fetch |
| **Cache write is async and non-fatal** | A Storage blip degrades caching, it doesn't fail the API | Last-writer-wins; a persistent write failure is invisible unless you alert on it — **so alert on it** |
| **`X-Cache` header** | Makes cache behaviour externally observable; the smoke test asserts on it | Leaks internal detail; strip at an external edge |
| **`/healthz` touches no dependency** | A Storage outage must not cause a cluster-wide crashloop | A permanently-broken pod stays running (readiness handles it — correctly) |
| **`/readyz` does touch Blob** | A pod with broken Workload Identity is pulled from the Service | A global Storage outage empties the endpoint list. Mitigate with a failure threshold and consider serving stale |
| **Structured JSON logs to stdout** | Container Insights ingests stdout; JSON is queryable in KQL without regex parsing | Slightly larger log volume |
| **`UPSTREAM_TIMEOUT_MS` with `AbortController`** | A hung upstream must not exhaust the connection pool and cascade | Too short = spurious failures. 5s against a public API is reasonable |
| **All config via env from a ConfigMap** | Twelve-factor; no rebuild to change environment | Config changes need a rollout (which the `checksum/config` annotation ensures) |
| **`DefaultAzureCredential`** | Works unchanged locally (`az login`), in CI, and in-cluster (Workload Identity) | It tries credentials in order, so a misconfiguration produces a slow, confusing failure. In prod, `WorkloadIdentityCredential` explicitly is faster and fails loudly — **a good, specific point to make** |

**What I'd add for production:** retry with exponential backoff and jitter on transient Azure errors (the
Azure SDK does this by default — know that); a circuit breaker on TVMaze; a **stale-while-revalidate**
mode so a cache miss during an upstream outage serves expired data rather than a 502; graceful shutdown
on SIGTERM draining in-flight requests within `terminationGracePeriodSeconds: 30`; and distributed
tracing with the OpenTelemetry Azure Monitor exporter so a slow request can be attributed to Blob vs
TVMaze vs the app itself.

---

## The universal fallback answer

When you are asked about a trade-off you have genuinely not considered, do not bluff. Use this shape:

> "I hadn't weighed that explicitly. Thinking about it now — the forcing constraint would be *[name the
> constraint: cost / latency / blast radius / operability / compliance]*. Given a bank's priorities I'd
> lean *[X]*, because *[reason]*, and I'd accept *[cost]*. What I'd actually do first is *[measure the
> thing that decides it]*, because right now I'd be guessing, and this is exactly the kind of decision
> that should be made on data rather than instinct."

**That answer scores better than a confident wrong one, every single time.** Interviewers are testing
your reasoning process, not your recall.

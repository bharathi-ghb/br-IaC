# 09 — Production Readiness: Security, Reliability, HA, Scalability

> Your stated expectation: *"production ready consistent solution considering more security, reliability,
> High availability, Scalable."*
>
> The assessment itself says candidates are **not** expected to build a production-ready banking
> platform — but a senior interview will absolutely ask *"what would it take to run this for real?"*
> **The gap between what you built and what production needs is the most senior conversation available in
> the room.** This document is the map of that gap.
>
> **How to use it:** never say "this is production ready" (it isn't, and neither is anyone's assessment
> submission). Say: *"Here's what's production-grade already, here's what's deliberately scoped down for a
> sandbox, and here's what's genuinely missing — in the order I'd fix it."* That answer is stronger than
> a claim of completeness.

---

## The scorecard

| Pillar | Current | Target | Biggest single gap |
|---|---|---|---|
| **Security** | 🟢 Strong design, 🔴 gaps in wiring | Production-grade | NSGs deploy empty; Storage RBAC never granted |
| **Reliability** | 🟡 Good shape | Needs testing + degradation modes | No chaos/DR testing; no stale-while-revalidate |
| **High availability** | 🟡 Zone-redundant compute, single-zone data | Multi-zone throughout | Storage is LRS in prod; the pipeline agent is a SPOF |
| **Scalability** | 🟡 HPA + autoscaler present | Right signals, right limits | HPA scales on CPU for an I/O-bound workload |
| **Operability** | 🟡 Good runbooks, thin automation | Self-healing where safe | One alert rule in code; no synthetic monitoring |
| **Disaster recovery** | 🔴 Not addressed | RTO/RPO defined and tested | No backup, no DR region, no tested restore |
| **Cost** | 🟡 Sensible SKUs | Governed and observable | No budgets, no anomaly alerting, no non-prod shutdown |

---

## 1. Security

### Already production-grade — lead with these

- **No public inbound anywhere.** Resource-level `public_network_access_enabled = false`, private cluster
  with no public FQDN, internal load balancer only.
- **Controlled egress with an FQDN allow-list**, plus `outbound_type = userDefinedRouting` closing the
  default public egress path.
- **No secrets in the workload.** Workload Identity for the app, workload identity federation for the
  pipeline, OIDC for Terraform. One real secret in the entire system.
- **`local_account_disabled = true`** — removes the certificate-based cluster-admin bypass.
- **`admin_enabled = false`** on ACR.
- **Pod Security Standards *restricted*** — non-root, read-only root filesystem, all capabilities dropped,
  seccomp `RuntimeDefault`, `automountServiceAccountToken: false`.
- **Defence in depth on public access:** resource → policy → pipeline → network → detection.
- **Diagnostic settings on every resource**, consistently, into one workspace.

### Gaps, ranked by risk

| # | Gap | Risk | Fix |
|---|---|---|---|
| 1 | 🔴 **NSG rules never wired** (P1-4) | Network layer of defence-in-depth does not exist | Declare the variables in the root module; pass them to `network_spoke` |
| 2 | 🔴 **Workload identity has no Storage RBAC** (P0-5) | The app cannot work; also the exact bug the assessment asks about | `data_contributor_principal_ids = [module.identity.principal_id]` |
| 3 | 🔴 **`shared_access_key_enabled = true`** (P1-5) | Escalation path from control-plane Contributor to full data access, bypassing all RBAC and audit | Set `false`; add `default_to_oauth_authentication = true` |
| 4 | 🔴 **Policy at resource-group scope** (P1-8) | Anyone creating a new RG escapes all governance; hub is ungoverned | Move to management-group scope; attach a regulatory initiative |
| 5 | **No image signing** | Nothing proves the running image is the one CI built | `cosign` + **Ratify** admission enforcement |
| 6 | **No Defender for Containers** | No runtime threat detection, no registry vulnerability assessment | One Terraform block; highest security value per line in the list |
| 7 | **No CMK** | Storage and etcd encrypted with Microsoft-managed keys | `disk_encryption_set_id`, `key_management_service` for etcd, CMK on Storage — likely mandatory for a bank |
| 8 | **Agent egresses unfiltered** (P2-12) | The machine that deploys to production has unrestricted internet access | Route the agent subnet through the firewall, or bake a golden image |
| 9 | **PAT-based agent registration** (P2-11) | A long-lived credential on a host with `docker` group (root-equivalent) access | Managed-identity registration, or ephemeral agents |
| 10 | **No PIM configured** | Standing cluster-admin | PIM-eligible groups + access reviews (outside the repo — **document it**) |

---

## 2. Reliability

### What's already right

| Control | Where | Why it matters |
|---|---|---|
| `--atomic --wait --timeout` | `stage-deploy.yml` | A failed release never leaves a half-deployed state |
| `maxUnavailable: 0, maxSurge: 1` | `deployment.yaml` | Capacity never drops during a rollout |
| Separate liveness / readiness / startup probes | `deployment.yaml` | A dependency failure stops traffic; it doesn't restart the process |
| `checksum/config` annotation | `deployment.yaml` | ConfigMap changes actually take effect — no silent config drift |
| `PodDisruptionBudget` | `pdb.yaml` | Node drains and upgrades can't take out the service |
| Smoke test gates the release | `stage-deploy.yml` | A broken deploy is caught by the pipeline, not by users |
| Diagnostics captured before rollback | `stage-deploy.yml` | The evidence survives the mitigation |
| `prevent_destroy` on stateful resources | Terraform | An accidental destroy is blocked |
| Blob versioning + soft delete | `storage-account` | Data recovery path exists |

### Gaps

| Gap | Impact | Fix |
|---|---|---|
| **No graceful degradation on upstream failure** | A cache miss during a TVMaze outage returns 502 | **Stale-while-revalidate**: serve the expired blob with a staleness header. Converts an availability incident into a freshness one |
| **No circuit breaker on TVMaze** | A slow upstream queues requests until the pool exhausts | Circuit breaker: fail fast after N consecutive failures, half-open probe to recover |
| **Readiness has no failure tolerance** | A brief Blob blip takes **every** pod out of the Service simultaneously | `failureThreshold` tuned, and consider readiness that tolerates a degraded-but-serving state |
| **No `preStop` hook** | Pods can be killed with in-flight requests | `preStop: sleep 5` so the endpoint is removed from the LB before SIGTERM |
| **No `priorityClassName`** | Under node pressure the API can be evicted before a batch job | `system-cluster-critical`-adjacent priority for the API |
| **PDB `minAvailable: 2` is brittle** | If replicas ever fall to 2, node drains deadlock forever | Use `maxUnavailable: 1` instead — it scales with replica count |
| **`revisionHistoryLimit: 5` vs Helm's 10** | You can't roll back further than the ReplicaSets retained | Align them, or accept and document the limit |
| **Nothing is tested** | Every control above is a hypothesis | **Game days** — see §7 |

> **The single best reliability sentence available to you:** *"Every one of those controls is untested. An
> untested control is a hypothesis, not a control. Before I'd call this production ready I'd run a game
> day: kill a zone, revoke the Storage role assignment, block TVMaze at the firewall, and take the agent
> pool offline — and see whether the system degrades the way I designed it to, and whether the runbook
> actually works when someone follows it under pressure."*

---

## 3. High availability

### Current state, layer by layer

| Layer | HA today | Verdict |
|---|---|---|
| AKS control plane | `sku_tier = "Standard"` — 99.95% SLA with AZs | 🟢 |
| Node pools | Autoscaled across zones 1/2/3 | 🟢 |
| Application pods | 3 replicas + topology spread + PDB | 🟢 |
| Azure Firewall | `zones = ["1","2","3"]` | 🟢 |
| ACR | Premium, but **not zone-redundant** | 🟡 |
| **Storage** | **LRS — single datacentre** | 🔴 |
| Key Vault | Zone-redundant by default in supported regions | 🟢 |
| Log Analytics | Regional | 🟡 |
| **Pipeline agent** | **One VM, no zone** | 🔴 |
| Region | **Single region, no DR** | 🔴 |

### The three fixes that matter

**1. Storage must be ZRS in production.** One line:
```hcl
# environments/prod/terraform.tfvars
storage_replication_type = "ZRS"
```
> "Right now my compute is spread across three zones and its cache lives in one. A single-zone storage
> failure takes the cache out for every zone — so I've built zone redundancy where it's cheap and skipped
> it where it counts. ZRS costs roughly 25% more and it's the obvious fix."

**2. The pipeline agent is a single point of failure.** Losing it means you cannot deploy **or roll back**
— during an incident, which is exactly when you need to. Minimum: a VMSS with 2+ instances across zones.
Better: Managed DevOps Pools. Best: KEDA-scaled agent pods in AKS.

**3. Single region, no DR.** Currently there is no answer at all to "the West Europe region is down."

### The DR conversation — have RTO/RPO ready

> "First I'd ask what the business actually needs, because that decides the architecture and the cost. For
> an internal read-only API serving cached public data, I'd argue for a modest tier:
>
> | Metric | Target | Justification |
> |---|---|---|
> | **RTO** | 4 hours | Internal consumers, read-only, non-transactional |
> | **RPO** | 1 hour | The cache is derived data — worst case, it repopulates from TVMaze |
>
> That's a **warm standby**, not active-active: infrastructure defined as code and deployable to a second
> region on demand, ACR geo-replicated so the images are already there, storage GZRS so the cached data is
> already replicated, and DNS or Front Door to shift traffic.
>
> The key insight is that **the cache is derived data**. I don't need to replicate it — I need to be able
> to rebuild it. So my RPO is really governed by how long a cold cache takes to warm, not by data
> replication. That's a much cheaper DR posture than a stateful system would need, and being able to
> reason that way is more valuable than reciting DR tiers.
>
> If this were a **transactional** banking service, the answer would be completely different:
> active-active across paired regions, synchronous replication, and an RPO near zero — with all the cost
> and complexity that implies. Matching the DR tier to the data's actual criticality is the job."

**What I'd add for DR:** Velero or Azure Backup for AKS (cluster state), an ACR geo-replica in the paired
region, GZRS storage, and — critically — a **tested failover runbook**. An untested DR plan has an RTO of
infinity.

---

## 4. Scalability

### Present

| Mechanism | Config | Assessment |
|---|---|---|
| HPA | 3→12 replicas, CPU 65% / memory 75% | 🟡 Wrong signal — see below |
| Cluster autoscaler | 2→6 user nodes | 🟢 |
| CNI Overlay | Pods don't consume VNet IPs | 🟢 **The most important scaling decision in the design** |
| Blob cache | Shared across all replicas | 🟢 Scaling out doesn't multiply upstream load |

### The scalability critique to make yourself

> "**HPA on CPU is the wrong signal for this workload.** This app spends its life waiting on Blob Storage
> and TVMaze — it's I/O-bound. Under load, latency degrades and the request queue grows while CPU barely
> moves. So CPU-based HPA under-scales exactly when I need it most, and over-scales during an unrelated
> CPU spike.
>
> The right signal is **requests per second or p95 latency**. I'd use **KEDA** — an AKS addon — scaling on
> a metric from Application Insights or Prometheus. That's the difference between scaling on a proxy and
> scaling on the thing you actually care about."

### Bottleneck analysis — walk the layers

| Layer | Ceiling | Symptom | Mitigation |
|---|---|---|---|
| Pods | HPA `maxReplicas: 12` | Latency rises with HPA pinned at max | Raise the ceiling; alert when sustained at max |
| Nodes | `user_node_max_count: 6` | Pods `Pending`, autoscaler at limit | Raise; watch regional vCPU quota |
| **VNet IPs** | `/24` node subnet ≈ 251 nodes | Node provisioning fails | **CNI Overlay already solved the pod side** — this is why it matters |
| **Firewall SNAT** | **2,496 ports per public IP** | Intermittent connection failures under load | Add public IPs, or a NAT Gateway behind the firewall |
| Blob | ~20,000 req/s per account | 503 `ServerBusy` throttling | Partition across accounts (`storage_account_count` exists for this — good foresight) |
| TVMaze | Their rate limit, not yours | 429s | **The cache is the mitigation** — raise the TTL |
| Log Analytics | Ingestion quota | Missing telemetry | `daily_quota_gb`, adaptive sampling |

> "**SNAT port exhaustion is the one people miss**, and it's the failure mode most likely to bite this
> design at scale. Azure Firewall gives 2,496 SNAT ports per public IP; a NAT Gateway gives 64,512. So my
> choice of firewall for policy reasons has a scaling cost, and the mitigation is either more public IPs
> on the firewall or a NAT Gateway on the AzureFirewallSubnet behind it. The symptom is nasty:
> intermittent, load-correlated connection failures that look like an upstream problem."

**Note the good foresight:** `var.storage_account_count` with `for_each` means the storage tier can be
partitioned without restructuring the module. Point that out — it shows you thought about the scaling
ceiling before hitting it.

---

## 5. Operability

| Gap | Fix |
|---|---|
| Only one alert rule in code | Codify the full set from [07](07-observability.md) as `azurerm_monitor_scheduled_query_rules_alert_v2` |
| No dashboards in code | `azurerm_application_insights_workbook` |
| No synthetic monitoring | An availability test or in-cluster CronJob — **catches outages when there's no traffic** |
| No alert routing by severity | Action groups per severity, wired to PagerDuty/ServiceNow |
| No progressive delivery | Flagger or Argo Rollouts — canary with automated metric analysis, so 5% of traffic sees a bad release, not 100% |
| No self-healing | Alerts that trigger a runbook (Azure Automation) for well-understood, safe remediations |

---

## 6. Cost

| Component | Indicative monthly | Optimisation |
|---|---|---|
| **Azure Firewall Standard** | **~$950** | By far the largest line. Non-prod: `enable_firewall = false` + NAT Gateway (~$35) |
| AKS nodes (4 × D2s_v5) | ~$280 | Spot instances for non-prod; scale to zero out of hours |
| AKS control plane (Standard) | ~$73 | `Free` tier in non-prod |
| ACR Premium | ~$50 | Required for Private Link — not optional |
| Storage LRS | ~$5 | Lifecycle policy to expire cache blobs (🔴 currently missing, P1-11) |
| Log Analytics | ~$2.30/GB | `daily_quota_gb`, adaptive sampling, tiered retention |
| Agent VM (D4s_v5) | ~$140 | Ephemeral agents; auto-shutdown out of hours |
| Private endpoints (5+) | ~$40 | Consolidate where possible |

**Missing:** budgets, anomaly alerting, cost tags on everything (🔴 `cost_centre` isn't even set — P1-8),
and a non-prod shutdown schedule.

> "Cost is a production-readiness concern, not an afterthought. The firewall is roughly 60% of the bill,
> and I chose it for a security reason I can defend — but I should be able to say what it costs and what
> the cheaper posture would give up. Being unable to answer 'what does this cost?' is a failure mode of its
> own. And a **cost anomaly alert is also a security control** — cryptomining in a compromised cluster
> shows up on the bill before it shows up anywhere else."

---

## 7. Testing — the thing nobody does

> "Everything above is unvalidated. Before calling this production ready I'd run **game days**:"

| Test | What it validates | Expected behaviour |
|---|---|---|
| Delete the Storage role assignment | Scenario 1 runbook; alerting | Readiness fails, pods leave the Service, the 403 alert fires within 5 min |
| Unlink a private DNS zone | Scenario 2 runbook | Resolution falls back to public, connections fail, alert fires |
| Push a deliberately broken image | `--atomic` rollback; smoke-test gating | Release rolls back automatically; no user impact |
| Stop the agent VM | Deployment SPOF | **You can't deploy — proves the case for a VMSS** |
| Block TVMaze at the firewall | Graceful degradation | Cache serves; **currently a 502 on miss — proves the case for stale-while-revalidate** |
| Cordon and drain a zone's nodes | PDB, topology spread, autoscaler | Pods reschedule; service stays up; PDB doesn't deadlock |
| Scale TVMaze traffic 10× | HPA responsiveness | **Expect it to under-scale — proves the case for KEDA** |
| Delete a namespace | Recovery time | Full redeploy from pipeline within RTO |

> "Notice that half of those are designed to **fail** in a way that proves a point. A game day whose
> purpose is to confirm everything works is a waste of a day. The value is in finding the gap between the
> design in your head and the system on the cluster — and then fixing either the system or your head."

---

## 8. The prioritised roadmap

**This ordering is the answer.** It's what a senior engineer is actually being assessed on.

### Phase 0 — Make it work (days)
1. Fix all P0 blockers ([02](02-code-review-findings.md)) — module paths, provider pin, dependency cycle,
   Storage RBAC, name mismatches, firewall `count`, node resource group.
2. Write the application and Dockerfile.
3. Deploy end to end, run the smoke test, **capture evidence**.

### Phase 1 — Make it correct (1 week)
4. Wire the NSG rules; add `cost_centre`; fix the AMPLS inversion; delete the duplicate A records.
5. `shared_access_key_enabled = false`; ZRS in prod; `Standard_D2ds_v5` for ephemeral OS disks.
6. Fix image promotion (`az acr import` by digest); fix the `imageTag` format.
7. Make the rollback script idempotent.

### Phase 2 — Make it safe (2 weeks)
8. Move Azure Policy to management-group scope; attach a regulatory initiative.
9. Enable Defender for Cloud + Defender for Containers.
10. Image signing (`cosign`) + Ratify admission enforcement.
11. Codify the full alert set and the workbook as Terraform.
12. PIM on the admin groups; access reviews.

### Phase 3 — Make it resilient (1 month)
13. Agent pool → VMSS or ephemeral agents; retire the PAT.
14. Stale-while-revalidate; circuit breaker; `preStop`; `priorityClassName`.
15. KEDA autoscaling on RPS/latency.
16. Backup (Velero), an ACR geo-replica, and a **tested** DR runbook.
17. **Run the first game day.**

### Phase 4 — Make it scale (ongoing)
18. Layered Terraform state (`00-network` / `10-platform` / `20-workload`).
19. Progressive delivery (Flagger/Argo Rollouts).
20. Cost budgets, anomaly alerting, non-prod shutdown automation.
21. Managed Prometheus + Grafana for high-cardinality metrics.

---

## The closing statement

> "Is this production ready? **No — and I'd be suspicious of anyone who said their assessment submission
> was.** What it is, is a production-*shaped* design: the hard architectural decisions are right and
> defensible, and the security model is the right one for a bank.
>
> What it isn't, yet: it has blocking defects I've documented rather than hidden; its zone-redundancy is
> inconsistent — compute is spread across three zones and its cache is in one; the deployment path is a
> single VM; and every reliability control in it is untested.
>
> The distance from here to production is roughly six weeks of the work in that roadmap, and the order
> matters more than the list. **Make it work, then correct, then safe, then resilient, then scalable** —
> because a resilient system with a broken RBAC grant is just an elaborate way to fail consistently."

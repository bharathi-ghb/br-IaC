# 06 — Security & Governance Notes

> A submission deliverable in its own right: *"RBAC model, identities, policies, tagging and
> public-access controls."* Also your script for the security round.
>
> **The frame to use throughout:** this is a banking platform, so the operating assumption is
> **assume breach**. Every control below is judged by one question — *if the layer above it fails, does
> this one still hold?*

---

## 1. The identity model — every principal in the system

There are seven distinct identities. Being able to enumerate them, and say what each can and cannot do,
is the fastest way to demonstrate you designed the security model rather than assembled it.

| # | Identity | Type | What it can do | What it deliberately cannot do | Defined in |
|---|---|---|---|---|---|
| 1 | **AKS control-plane identity** | User-assigned MI | `Network Contributor` on the node subnet and route table; `Private DNS Zone Contributor` on the AKS zone | Cannot read Storage, ACR or Key Vault | `modules/aks` |
| 2 | **AKS kubelet identity** | System-created MI | `AcrPull` on the registry | Cannot push images, cannot read Storage | AKS-created; granted in `modules/container-registry` |
| 3 | **Application workload identity** | User-assigned MI + federated credential | `Storage Blob Data Contributor` on the cache 🔴 *(not currently wired — P0-5)* | Cannot read Key Vault, cannot touch ACR, has no ARM control-plane rights at all | `modules/identity` |
| 4 | **Pipeline service connection** | Entra app, **workload identity federation — no secret** | `AcrPush`; `AKS RBAC Writer` + `Cluster User`; ARM rights for `terraform apply`; `Key Vault Secrets User` | **Not Owner. Not Contributor at subscription scope. Cannot create RoleBindings in the cluster** | Azure DevOps + `var.pipeline_principal_ids` |
| 5 | **Agent VM managed identity** | User-assigned MI | `Key Vault Secrets User` — one secret, at boot | Cannot deploy anything, cannot reach ACR or AKS as itself | `modules/pipeline-agent` |
| 6 | **Human admins** | Entra group | `AKS RBAC Cluster Admin`, `Key Vault Secrets Officer` | Should be **PIM-eligible, not permanently assigned** | `var.aks_admin_group_object_ids` |
| 7 | **Human readers** | Entra group | `AKS RBAC Reader` + `Cluster User` | Cannot mutate anything | `var.aks_reader_group_object_ids` |

### The three separations that matter most

> **1. The kubelet pulls images; the control plane does not.** These are two different managed
> identities. Granting `AcrPull` to the control-plane identity is a very common mistake — everything
> provisions cleanly and no image ever pulls.
>
> **2. The pipeline gets `AKS RBAC Writer`, not `Admin`.** Writer can deploy workloads. It **cannot create
> `RoleBinding` or `ClusterRoleBinding` objects.** That is the specific privilege-escalation path being
> closed: a compromised pipeline cannot grant itself cluster-admin.
>
> **3. The agent host's identity can read exactly one secret and deploy nothing.** The deployment identity
> is the *service connection*, which is federated and has no stored credential. So compromising the agent
> host yields a PAT scoped to agent pools — not a path into the subscription.
>
> The honest caveat, which I'd volunteer: a host compromise *would* also expose the currently-running
> job's OIDC token for its lifetime. That's the strongest argument for ephemeral, per-job agents.

---

## 2. The RBAC model — least privilege in practice

### Azure RBAC (control plane)

| Scope | Role | Principal | Why this role and not a broader one |
|---|---|---|---|
| Storage account/container | `Storage Blob Data Contributor` | App workload identity | **Data-plane** role. `Contributor` (control-plane) would allow `listKeys` — i.e. bypassing RBAC entirely |
| ACR | `AcrPull` | Kubelet identity | Read-only. `AcrPush` on a node is an attacker's dream: overwrite the image everyone pulls |
| ACR | `AcrPush` | Pipeline | Push + pull. Not `Owner`, which could disable the registry firewall |
| Key Vault | `Key Vault Secrets User` | Pipeline, agent VM | Read secret *values*. Not `Officer`, which can write and delete |
| Key Vault | `Key Vault Secrets Officer` | Admin group (PIM) | Manage secrets. Note: **not `Key Vault Administrator`**, which also manages access |
| AKS | `AKS RBAC Writer` | Pipeline | Deploy workloads. **Cannot create RoleBindings** |
| AKS | `AKS RBAC Reader` | Reader group | Read-only, and notably **cannot read Secrets** |
| AKS | `Cluster User` | Pipeline + both groups | Permits `get-credentials`. Grants **no** in-cluster rights on its own |
| Node subnet + route table | `Network Contributor` | AKS control-plane identity | Required for the internal load balancer and `userDefinedRouting`. Scoped to two resources, not the VNet |
| AKS private DNS zone | `Private DNS Zone Contributor` | AKS control-plane identity | To register the API server's A record |

### The distinctions worth stating explicitly

**Control-plane vs data-plane roles.** `Contributor` on a storage account is a *control-plane* role: it
does not grant blob read access directly — but it **does** grant `listKeys`, and the account key grants
unrestricted data access, bypassing every RBAC check and every data-plane audit trail. That is why
`shared_access_key_enabled = false` matters as much as the role assignment does: **it closes the
escalation path from control-plane Contributor to full data access.**

> That single sentence is one of the strongest things you can say in an Azure security interview.

**`Cluster User` vs `RBAC Writer`.** `Cluster User` only lets you *download a kubeconfig*. Having it alone
gives you a working kubeconfig and 403 on every command — which reliably looks like a network problem for
the first twenty minutes.

**`RBAC Reader` cannot read Secrets.** A deliberate carve-out in the built-in role, and a good detail to
know.

### Kubernetes RBAC (in-cluster)

Azure RBAC handles coarse-grained access. Native RBAC still applies for anything it can't express:

```yaml
# Example: a support role that can read logs and exec for debugging,
# but can never read Secrets or mutate workloads.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: app-support, namespace: banking-api }
rules:
  - apiGroups: [""]     resources: ["pods", "pods/log"]           verbs: ["get","list"]
  - apiGroups: [""]     resources: ["pods/exec"]                  verbs: ["create"]
  - apiGroups: ["apps"] resources: ["deployments","replicasets"]  verbs: ["get","list"]
  # NOTE: no "secrets", no "create"/"update"/"delete" on workloads.
```

> **The composition point:** *"Azure RBAC gates entry to the cluster and gives me the central audit trail
> and the PIM story. Native RBAC gives me the verb-level granularity Azure's four built-in roles can't
> express. They're additive authorisers — a request is allowed if either grants it — so I use Azure RBAC
> for the coarse grant and native `Role` objects for fine-grained exceptions, delivered through a platform
> Helm chart so they're versioned like everything else."*

### Privileged access — the PIM answer

> "In production, **nobody holds standing cluster-admin.** `var.aks_admin_group_object_ids` should point
> at a **PIM-eligible** group, so `AKS RBAC Cluster Admin` is activated just-in-time: time-bound to a few
> hours, requiring MFA, a justification, and — for production — approval by a second person. Activation
> generates an Entra audit event, so 'who had admin, when, and why' is answerable centrally.
>
> This is exactly why I chose Azure RBAC over native Kubernetes RBAC as the primary model: native
> `ClusterRoleBinding` has no concept of time-bound, approval-gated access. You either have it or you
> don't, forever, and revocation is a manual YAML change nobody remembers to make."

---

## 3. Public access controls — the five layers

Full narrative answer in [04-assessment-answers.md](04-assessment-answers.md#-explain-how-you-would-prevent-accidental-public-access).

| Layer | Control | What it stops | Gap in the current code |
|---|---|---|---|
| **1. Resource** | `public_network_access_enabled = false` on ACR, KV, Storage; `private_cluster_enabled` + `public_fqdn_enabled = false` on AKS; `default_action = Deny` on storage | Direct internet reachability | — |
| **2. Policy** | Azure Policy in `Deny`: deny public storage, deny public ACR, require private AKS | Anything created **outside Terraform** — portal, CLI, another pipeline | 🔴 **Resource-group scope only.** New RGs and the entire hub RG escape it (P1-8) |
| **3. Pipeline** | Checkov on the Terraform; Conftest/OPA on the plan JSON | The change reaching `main` at all | 🔴 Plan JSON is generated and never evaluated (P2-16) |
| **4. Network** | NSGs per subnet; `private_endpoint_network_policies = "Enabled"` | Lateral movement; unintended intra-VNet reachability | 🔴 **NSG rules never wired — all three NSGs deploy empty** (P1-4) |
| **5. Detection** | Diagnostic settings everywhere; Activity Log alert on `publicNetworkAccess` changes | Nothing — it tells you when 1–4 failed | Alert not defined in code |

> "The design intent is that no single layer is trusted. Terraform is *corrective* — it only fixes drift
> when it next runs. **Azure Policy in Deny mode is the only layer that is genuinely preventive**, because
> it rejects the ARM request before it takes effect, regardless of who made it or how. That's why policy
> scope matters so much, and why resource-group scope is the weakest thing in my current governance
> module."

---

## 4. Secrets — the inventory

**The strongest security property of this design is how few secrets exist.** Present it that way.

| Thing people assume is a secret | Actually | Why |
|---|---|---|
| Storage account key | **Not used** | Workload Identity. And `shared_access_key_enabled` should be `false` (🔴 currently `true` — P1-5) |
| Storage connection string | **Not used** | Same |
| ACR credentials | **Do not exist** | `admin_enabled = false`; `az acr login` exchanges an Entra token |
| Pipeline service principal secret | **Does not exist** | Workload identity federation on the service connection |
| Terraform backend key | **Not used** | `use_oidc` + `use_azuread_auth` |
| App Insights connection string | **Not a secret** | `local_authentication_enabled = false` makes the ingestion key inert (🔴 pipeline still treats it as one — P2-3) |
| AKS cluster admin certificate | **Does not exist** | `local_account_disabled = true` |
| **Azure DevOps agent PAT** | ⚠️ **A real secret** | Created out-of-band, stored in Key Vault, read at boot via IMDS. The only one |
| Agent VM SSH private key | ⚠️ Real, but unused in practice | Access is via `az ssh vm` with Entra login |

### The one real secret — how it's handled, and how it should be

**Today:** created manually with `az keyvault secret set`; never in Terraform state or git; read at boot
by the VM's user-assigned identity via IMDS; `set +x` in cloud-init keeps it out of the boot log.

**Improvements to raise (P2-11):**
- Scope the PAT to **Agent Pools (read, manage)** only. **A default-scoped PAT on a build host that also
  has `docker` group membership is effectively root over the entire Azure DevOps organisation.**
- Set a 7-day expiry and automate rotation via a Key Vault near-expiry event.
- Better: eliminate it — Azure DevOps supports **managed-identity agent registration**, removing the
  secret from the design entirely.

### Rules for secrets in Helm values

1. **Nothing secret in a values file, ever.** Values files are in git. Yours contain only configuration —
   log level, cache TTL, replica counts, the TVMaze base URL. Good.
2. Environment-derived values come from `--set`, sourced from **Terraform outputs**, at deploy time.
3. Terraform outputs carrying sensitive data are marked `sensitive = true` (yours is, for the App Insights
   connection string) so they're redacted from logs.
4. If a genuine secret is ever needed: **Key Vault CSI driver**, not a Kubernetes Secret. A Kubernetes
   Secret is base64 in etcd, **not encrypted** unless you have KMS etcd encryption, and readable by anyone
   with `get secrets` in the namespace.
5. Never `helm install --set password=...` — it lands in shell history, in the pipeline log, **and in the
   Helm release object stored in the cluster**, where `helm get values` will print it back to anyone with
   read access to that Secret.

---

## 5. Supply-chain security

| Stage | Control today | Gap / next step |
|---|---|---|
| Source | Gitleaks with `fetchDepth: 0` — scans full history | Add pre-commit hooks; require signed commits |
| Dependencies | `npm audit`, Trivy `fs` with the secret scanner | Gate consistently (P2-14); add Dependabot/Renovate; **generate an SBOM** |
| Build | Docker build on a private agent | **Rootless build or ACR Tasks** — `docker` group is root-equivalent |
| Image | Trivy image scan, fails on HIGH/CRITICAL with a fix | **No signing.** Add `cosign` + **Ratify** admission enforcement |
| Registry | Private, Premium, no admin account, untagged retention | Enable **content trust**; **Defender for Containers** scanning; **image quarantine** |
| Deploy | Helm with pinned chart version | **Deploy by digest, not tag** (P1-6) |
| Runtime | Restricted pod security, NetworkPolicy, read-only root FS | **Defender for Containers** runtime threat detection |
| IaC | Checkov | Add **Conftest/OPA on the plan JSON**; commit `.terraform.lock.hcl` |

### The signing answer, if asked

> "Right now I have a *scanned* image but nothing proves the image running in production is the one my
> pipeline built. Scanning tells me the artifact was clean when I looked at it; it says nothing about
> whether that's the artifact that got deployed.
>
> The fix is signing plus admission enforcement: `cosign sign` in the build stage using a key in Key Vault
> — or better, keyless with the pipeline's OIDC identity — and then **Ratify** as a Gatekeeper external
> data provider, so the cluster rejects any image without a valid signature from my pipeline's identity.
> That closes the gap where someone with `AcrPush` overwrites a tag, and it closes the registry-compromise
> case too. It's the difference between 'we scan our images' and 'only our images can run'."

---

## 6. Azure Policy — the governance model

### Assigned today (`modules/governance`)

| Policy | Effect | Purpose |
|---|---|---|
| Allowed locations | Deny | Data residency — EU only |
| Require a tag (×N, `for_each`) | Deny | Tagging standard enforcement |
| Storage: deny public network access | Deny | Layer 2 of public-access control |
| ACR: deny public network access | Deny | Same |
| AKS: require private cluster | Deny | Same |
| Kubernetes: no privileged containers | Audit → Deny | Container escape prevention (Gatekeeper) |
| Kubernetes: no privilege escalation | Audit → Deny | Same |

### The rollout methodology — volunteer this

> "The variable `kubernetes_policy_effect` defaults to `Audit`, deliberately. Applying a `Deny` Gatekeeper
> constraint to an existing cluster instantly blocks deployments that were previously fine — including,
> potentially, system components in namespaces you forgot to exclude. The correct rollout is
> **Audit → measure compliance → remediate the findings → promote to Deny**, per environment, with
> non-prod leading production. That's also why `enforce` is a variable: I can assign a policy in
> `DoNotEnforce` mode to see what it *would* block before it blocks anything.
>
> And you need an **exemption** process, not an off switch. `azurerm_resource_policy_exemption` with a
> stated justification and an **expiry date**, reviewed like code. The failure mode I'm avoiding is the one
> where a genuine incident fix gets blocked by policy at 3am and someone disables the assignment — and
> then nobody re-enables it."

### Gaps to acknowledge

1. 🔴 **Resource-group scope.** Should be management-group. Anyone who can create a new RG escapes
   everything, and the hub resource group is entirely ungoverned today.
2. **No `DeployIfNotExists`.** Your policies detect and deny; they don't remediate. The highest-value DINE
   policies for this platform: *Configure private endpoints to use private DNS zones* (auto-fixes
   Scenario 2 across the estate), and *Deploy diagnostic settings to Log Analytics* (guarantees telemetry
   on resources created outside Terraform).
3. **No initiative/policy set.** Individual assignments don't roll up into a compliance score. Attach a
   built-in regulatory initiative — CIS Azure Foundations, or PCI-DSS — and Defender for Cloud gives you a
   compliance dashboard for free.
4. **No Defender for Cloud / Defender for Containers.** Runtime threat detection, registry vulnerability
   assessment, and Kubernetes-specific detections. Small Terraform change, large value.

---

## 7. Tagging standard

| Tag | Purpose | Enforced |
|---|---|---|
| `environment` | nonprod / prod — drives alert routing and access policy | ✅ Policy |
| `owner` | The team accountable | ✅ Policy |
| `cost_centre` | Chargeback | ✅ Policy — 🔴 **but not actually set in tfvars (P1-8)** |
| `application` | Service name | Recommended, not enforced |
| `managedBy` | `terraform` — flags anything created by hand | Present, not enforced |
| `workload` | Free-text descriptor | 🔴 Inconsistent: `iac-hiring-test` vs `iac` between environments |

**For a bank, extend with:** `dataClassification` (public/internal/confidential/restricted),
`criticality` (tier-1/2/3), and `businessService`. These aren't cosmetic — they drive automated decisions:
backup and retention policy, alert severity and paging rules, DR tier, and access review cadence.

**Mechanism:** a single `var.tags` map threaded through every module, so tags are set once per environment
and inherited. In a larger estate, add the *Inherit a tag from the resource group* policy in `Modify` mode
with a remediation task, so existing non-compliant resources get backfilled rather than merely flagged.

---

## 8. Diagnostic settings and audit logs

Every module takes `enable_diagnostics` + `log_analytics_workspace_id` and creates a diagnostic setting.
**That consistency is a genuine strength — call it out.**

| Resource | Log categories | The security question it answers |
|---|---|---|
| AKS | `allLogs` incl. `kube-audit`, `kube-audit-admin`, `guard` | Who did what in the cluster? `guard` shows Entra/Azure RBAC decisions |
| Key Vault | `AuditEvent` | Who read which secret, from where, and was it allowed? |
| Storage (blob) | `StorageRead/Write/Delete` | Who accessed which blob, with which auth type, from which IP? |
| ACR | `ContainerRegistryLoginEvents`, `RepositoryEvents` | Who pushed or pulled what? |
| Azure Firewall | `AZFWApplicationRule`, `AZFWNetworkRule`, `AZFWDnsQuery` | What tried to leave the network, and was it allowed? |
| VNets | `allLogs` + metrics | Flow-level visibility |
| **Activity Log** | Subscription-level | Control-plane changes — role assignments, network ACLs, resource deletion |

> **The design point:** *"All of this lands in one Log Analytics workspace, which is what makes
> cross-layer correlation possible during an incident. A pod's 403 in `AppRequests` can be joined to the
> exact `StorageBlobLogs` entry showing which principal ID was presented and why it was denied. Splitting
> telemetry across workspaces to save money is the decision people most regret at 3am."*

🔴 **Note two defects:** the `private_dns` module's diagnostic setting is broken (P1-3), and private DNS
zones don't emit resource logs anyway — DNS telemetry comes from the **firewall's DNS proxy logs**.

**Retention:** 90 days is set for both environments. For a bank, production should be **365+ days** in the
workspace with archive beyond that, driven by regulatory retention requirements (DORA, local banking
regulation). Also consider **immutable, append-only export to a locked storage account** so an attacker
with subscription access cannot delete the evidence of their own activity.

---

## 9. Threat model — the attacks this design defends against

Framing your controls as *attacks defeated* rather than *boxes ticked* is what makes a security answer
sound senior.

| Attack | Defence | Residual risk |
|---|---|---|
| Internet attacker scans for exposed services | No public inbound anywhere; no public FQDN on AKS | Depends on config not drifting → Policy is layer 2 |
| Stolen storage key | No keys in use; `shared_access_key_enabled` should be `false` | 🔴 Currently `true` (P1-5) |
| Compromised container exfiltrates data | Firewall FQDN allow-list; only `api.tvmaze.com` resolves and connects | An attacker could exfiltrate *to TVMaze* — DNS-tunnel style. Firewall Premium with TLS inspection would catch it |
| Compromised container steals node credentials | NetworkPolicy blocks `169.254.169.254`; `automountServiceAccountToken: false`; no privileged containers | Kernel-level escape → Defender for Containers is the answer |
| Compromised pipeline escalates to cluster-admin | `AKS RBAC Writer` cannot create RoleBindings; separate identity per environment; branch policy on pipeline YAML | A malicious PR to pipeline YAML → CODEOWNERS + required reviewers |
| Compromised agent host | Its identity holds one Key Vault permission and can deploy nothing | The running job's OIDC token → ephemeral agents |
| Insider disables public-access controls | Azure Policy `Deny`; Activity Log alerts | 🔴 RG-scoped policy is escapable (P1-8) |
| Tampered container image | Trivy scan; private registry; no admin account | **No signing** — add `cosign` + Ratify |
| Compromised admin account | Entra Conditional Access + MFA; PIM just-in-time; `local_account_disabled = true` removes the cert bypass | Requires PIM to actually be configured, which is outside the repo — **document it** |
| Ransomware on the data | Blob versioning + soft delete; Key Vault purge protection; `prevent_destroy`; resource locks | Cross-region backup for the truly critical case |

---

## 10. What I would add next, in priority order

Ask yourself this in the interview before they do. The order *is* the answer.

1. **Fix the P0/P1 findings** — especially the missing Storage RBAC and the unwired NSG rules. *"A
   security model that isn't actually deployed is a document, not a control."*
2. **Move Azure Policy to management-group scope** and attach a regulatory compliance initiative.
3. **Enable Microsoft Defender for Cloud + Defender for Containers.** Highest security value per line of
   Terraform in the whole list.
4. **Image signing with `cosign` + Ratify admission enforcement.**
5. **Customer-managed keys** — CMK on Storage and etcd encryption via `key_management_service`. Likely
   mandatory for a bank.
6. **PIM for all privileged roles**, with access reviews on the admin groups.
7. **Ephemeral, per-job pipeline agents** — eliminates the PAT, the pet VM and cross-build state leakage
   in one change.
8. **Immutable log export** to a locked storage account, so audit evidence survives an attacker with
   subscription access.
9. **A game day.** *"An untested control is a hypothesis. Rehearse a Helm rollback, an agent-pool outage,
   and a Storage 403 before they happen for real."*

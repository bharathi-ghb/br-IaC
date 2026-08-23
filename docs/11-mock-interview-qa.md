# 11 — Mock Interview: Rapid-Fire Q&A

> Work through these **out loud**, ideally with someone else asking. Time yourself: most answers should
> land in 60–120 seconds.
>
> Difficulty: **●** foundational · **●●** solid senior · **●●●** distinguishing · **●●●●** the ones that
> separate candidates.

---

## A. Networking & Private Link

**● Q1. Why is `AzureFirewallSubnet` named exactly that?**
It's a reserved name — Azure requires it verbatim and it must be `/26` or larger. Same class of rule as
`GatewaySubnet` and `AzureBastionSubnet`. It also can't have an NSG attached; the firewall manages its own.

**●● Q2. What does `outbound_type = userDefinedRouting` actually change?**
By default (`loadBalancer`), AKS provisions a Standard Load Balancer with a public IP and uses it for
outbound SNAT — a public egress path that bypasses your firewall entirely. `userDefinedRouting` tells AKS
"I own egress; don't create one," so the UDR is the only way out. **Without it you have a firewall, a
route table, an allow-list — and a second door standing open.** The costs: the route table must exist
*before* cluster creation, the control-plane identity needs `Network Contributor` on it, and egress is now
hard-coupled to firewall availability.

**●● Q3. Why is `allow_forwarded_traffic = true` needed on the peerings?**
Traffic returning from the firewall arrives at the spoke with a source address outside the peered VNet's
range. Without `allow_forwarded_traffic`, the peering drops it. It's the setting that makes the firewall
hairpin work, and it's a very common cause of "the route is right but nothing gets through."

**●●● Q4. Why doesn't the private endpoint subnet have a UDR to the firewall?**
Deliberate. Private endpoint traffic must not be forced-tunnelled through an NVA — it breaks the Private
Link data path with asymmetric routing, because the return path doesn't traverse the firewall. Azure also
installs a `/32` system route per private endpoint that takes precedence over `0.0.0.0/0` anyway. So the
UDR would be both harmful and largely ineffective.

**●●● Q5. NSGs used to have no effect on private endpoint traffic. What changed?**
Historically PE traffic bypassed NSGs entirely. Setting `private_endpoint_network_policies = "Enabled"` on
the subnet — which I did — turns NSG enforcement on for it. Without that, my "only the AKS and agent
subnets may reach 443" rule would be decorative.

**●●●● Q6. Walk me through what happens if I put a private endpoint's DNS record in a zone that isn't linked to the pod's VNet.**
Resolution falls through to public DNS. The public record for `<account>.blob.core.windows.net` is a CNAME
to `<account>.privatelink.blob.core.windows.net`, but with no linked private zone there's nothing to
resolve that target, so Azure returns the **public** storage IP. The pod then connects to a public
endpoint that has `public_network_access_enabled = false` and gets refused — or, if the account still
allowed public access, it would silently work *over the internet*, which is worse, because the control
looks fine while the traffic isn't private. That's why I run negative tests, not just positive ones.

**●●● Q7. Firewall vs NAT Gateway. Convince me either way.**
NAT Gateway wins on cost (~$35 vs ~$950), simplicity, and SNAT scale (64,512 ports per IP vs 2,496). It
solves outbound *connectivity* better. Firewall wins on **policy**: FQDN allow-listing, threat
intelligence, and full L7 egress logging. For a bank, the deciding factor is data exfiltration control — a
compromised container with an open NAT Gateway can post customer data anywhere and I'd have no log of it.
If SNAT exhaustion became the constraint I wouldn't swap them; I'd put a NAT Gateway on the
AzureFirewallSubnet **behind** the firewall and get both.

**●●● Q8. Why Azure CNI Overlay?**
It decouples pod scale from IP-address-management scale. Traditional Azure CNI consumes a VNet IP per pod
— a 50-node cluster at 50 pods/node needs ~2,500 IPs, roughly a /21 per cluster. In a bank, RFC1918 space
is governed and contended, so that becomes an IPAM negotiation and eventually a renumbering exercise. With
Overlay, my node subnet is a /24 forever. The cost: pods aren't directly addressable from the VNet, which
is fine because ingress is via a Service and egress SNATs to the node IP — and it's why my NSG and firewall
rules target the node subnet, not pod IPs.

**●●●● Q9. When would you NOT use CNI Overlay?**
If something outside the cluster needs to dial a pod directly — an appliance doing per-pod IP-based
policy, a legacy service that requires direct pod addressability, or a Windows workload with a constraint
Overlay doesn't support. Also if you need Virtual Nodes / ACI integration. In those cases traditional CNI
is the answer and you plan the IP allocation properly up front.

---

## B. AKS & Kubernetes

**● Q10. Liveness vs readiness.**
Liveness answers *"should Kubernetes restart this process?"* Readiness answers *"should this pod receive
traffic?"* A dependency failure is never a reason to restart — it's a reason to stop routing. **Putting a
dependency check in a liveness probe is how you turn a downstream blip into a cluster-wide crashloop.** So
my `/healthz` touches nothing and `/readyz` checks Blob Storage.

**●● Q11. Why a startup probe as well?**
It suspends liveness until the app has started, so a slow start doesn't get misread as a hang and
restarted. Without it you either set `initialDelaySeconds` generously — which delays detection of real
hangs forever after — or you accept restart loops on slow starts. The startup probe lets you have a tight
liveness probe *and* a generous start window.

**●●● Q12. You set a memory limit but no CPU limit. Justify it.**
CPU is compressible, memory isn't. A CPU limit causes CFS throttling: your p99 latency spikes even when
the node has idle cores, because the container is throttled against a quota rather than against actual
contention. A memory limit is what stops one pod OOM-killing the node. So: both requests always, memory
limit always, CPU limit only for hard multi-tenant isolation or Guaranteed QoS. The trade-off is that
`requests.memory != limits.memory` makes the pod Burstable, so it's evicted before Guaranteed pods — for
production I'd consider setting them equal to get Guaranteed QoS while still omitting the CPU limit.

**●●● Q13. Azure RBAC vs Kubernetes RBAC.**
Authentication is always Entra. Authorisation differs: Azure RBAC delegates the decision to Azure role
assignments; native RBAC decides inside the cluster from `Role`/`RoleBinding` objects. **Both authorisers
run, and a request is allowed if either grants it** — so they compose. I chose Azure RBAC as primary
because in a bank the audit trail and the joiner/mover/leaver story dominate: access lives in the Azure
Activity Log, follows Entra group membership, and gets PIM's time-bound just-in-time elevation, which
native RBAC cannot do at all. I gave up verb-level granularity, which I'd add back with native `Role`
objects where needed.

**●●● Q14. What does `local_account_disabled = true` protect against?**
AKS otherwise keeps a `clusterAdmin` account authenticated by a client certificate. Anyone with the Azure
Cluster Admin role can fetch that kubeconfig, and it **bypasses Entra, MFA, Conditional Access and your
entire RBAC model** — and its use is nearly invisible in logs because there's no Entra sign-in event. It's
one of the highest-value single settings in the cluster. The cost is losing break-glass, so the runbook
documents a PIM-gated, alerted, two-person procedure to temporarily re-enable it.

**●●●● Q15. Your PDB is `minAvailable: 2` with 3 replicas. What's the failure mode?**
If replicas ever drop to 2 — a scale-down, or an HPA change — the PDB can never be satisfied and **node
drains block forever**, which means cluster upgrades stall silently. `maxUnavailable: 1` is safer because
it scales with the replica count instead of being an absolute floor. It's a good example of a control
that protects availability in the normal case and destroys operability in the edge case.

**●●● Q16. Why a separate system node pool?**
The system pool runs CoreDNS, metrics-server, the Workload Identity webhook and the OMS agent. If an
application pod with a memory leak lands there and triggers eviction, you lose cluster DNS — and a DNS
outage presents as a total, inexplicable failure of everything. The `CriticalAddonsOnly` taint makes that
impossible. The cost is a minimum of four nodes even when idle, and worse bin-packing.

**●●● Q17. `automountServiceAccountToken: false` — doesn't that break Workload Identity?**
No, and this is a good test of whether someone understands the mechanism. The `azure-wi-webhook` injects
its **own** projected token volume with audience `api://AzureADTokenExchange`, independently of the
default automount. Turning off the default token means the pod can't call the Kubernetes API at all, so a
compromised container can't enumerate secrets or other pods. Pure hardening win.

---

## C. Identity & Workload Identity

**●● Q18. Why user-assigned rather than system-assigned managed identity?**
A system-assigned identity is tied to its resource's lifecycle — recreate the resource and you get a new
principal ID, so **every role assignment silently breaks**. User-assigned identities are independent, so
RBAC survives recreation, and you can grant permissions *before* the consuming resource exists, which
breaks dependency cycles in Terraform. Cost: one more object to manage and clean up.

**●●● Q19. Walk me through the token exchange.**
The webhook injects `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_AUTHORITY_HOST`,
`AZURE_FEDERATED_TOKEN_FILE` and a projected ServiceAccount token. `DefaultAzureCredential` reads that
JWT and presents it to Entra as a **client assertion**. Entra fetches the cluster's JWKS from the OIDC
issuer URL, verifies the signature, and checks issuer, audience and — critically — the `sub` claim against
the federated identity credential's `subject`. If they match, it issues an Entra access token for the
requested scope. The projected token is ~1 hour and kubelet-rotates it, so an exfiltrated token is
short-lived, single-audience, and only usable from that exact ServiceAccount.

**●●●● Q20. `AADSTS70021`. What is it and what's the fix?**
"No matching federated identity record found for presented assertion subject." The `sub` claim in the
projected token doesn't exactly match the federated credential's `subject`. It's an exact string match on
`system:serviceaccount:<namespace>:<name>` — a namespace rename or a Helm `serviceAccount.name` default
that disagrees with Terraform breaks it silently. **This is a live defect in my repo**: Terraform says
`banking-api/banking-api`, my chart's default says `banking-application`, and my pipeline variable says a
third thing. The pipeline actually overrides both correctly from Terraform outputs, so the defaults are
what's wrong — but the right fix is to make it impossible: I'd add a `fail` guard in `_helpers.tpl` that
compares the rendered subject against an expected value passed from a Terraform output, so a mismatch
becomes a template error at deploy time instead of an auth error at runtime.

**●●● Q21. The pod authenticates fine but Blob returns 403. What's the difference?**
Federation is **authentication**; the role assignment is **authorisation**. A valid Entra token with no
`Storage Blob Data Contributor` gives you `403 AuthorizationPermissionMismatch`. And that's exactly the
state my repo ships in — the storage module accepts a `data_contributor_principal_ids` variable and
`main.tf` never passes the identity's principal ID to it. My infrastructure contains the precise bug the
assessment asks me to debug, which I'd fix first.

**●●●● Q22. `Contributor` on a storage account — does that let you read blobs?**
Not directly. `Contributor` is a control-plane role, and blob data access requires a data-plane role like
`Storage Blob Data Reader`. **But** `Contributor` grants `listKeys`, and the account key gives
unrestricted data access that bypasses every RBAC check and every data-plane audit entry. So in practice
yes — which is why `shared_access_key_enabled = false` matters as much as the role assignment does: it
closes the escalation path from control-plane Contributor to full data access. And that's another live
defect in my code; I have it set to `true`.

---

## D. Terraform

**●● Q23. Workspaces or separate state files?**
Separate state files, per environment, in separate storage accounts in separate subscriptions.
**Workspaces are for ephemeral variations of the same thing, not an isolation boundary** — they share a
backend and therefore share credentials. I want a compromised non-prod pipeline identity to be physically
unable to read prod state, and prod state contains secrets in plaintext.

**●●● Q24. You have a dependency cycle. How do you fix it?**
Not with `depends_on`. **A cycle always means one module is doing two jobs at two different layers.** Mine
is observability: "create a Log Analytics workspace" is a layer-0 concern that everything depends on, and
"give that workspace a private endpoint" is a layer-2 concern that depends on network and DNS. They're in
one module, so the graph closes. The fix is to split it along the dependency boundary — `observability-core`
and `observability-ampls`.

**●●● Q25. What's in Terraform state and why does that matter?**
Everything, including secrets, in plaintext — connection strings, generated passwords, certificate data.
So state is a crown-jewel asset that most teams under-protect: they lock down every resource and leave
state in a storage account with keys enabled. It needs a dedicated account, a private endpoint,
`shared_access_key_enabled = false`, Entra-only access, versioning and soft delete, diagnostic logging on
reads, and per-environment RBAC.

**●●● Q26. `prevent_destroy` — what does it actually block?**
`terraform destroy`, **and any plan that would replace the resource**. So if you later change an immutable
attribute — like `infrastructure_encryption_enabled` on a storage account — you get a hard error and have
to edit code to proceed. It's intended, but it means my assessment cleanup is a deliberate two-step: remove
the guards in a reviewed commit, then destroy. It also doesn't protect against portal deletion, so I'd pair
it with `azurerm_management_lock` at `CanNotDelete`.

**●●●● Q27. How would you catch "this apply will delete the production database"?**
Not with source scanning — Checkov reads the code, and deletion is a property of the *plan*. I already
generate `tfplan.json` and don't use it, which is a missed opportunity. I'd run **Conftest/OPA against the
plan JSON** with a rule like "deny if any `delete` action targets a resource tagged `criticality: high`."
That catches a whole class of problem static analysis structurally cannot see.

**●● Q28. Your provider is pinned `~> 3` but you're using v4 syntax. What happens?**
Every `terraform validate` fails with "Unsupported argument" — `enabled_metric`, `auto_scaling_enabled`,
`rbac_authorization_enabled`, `enforce` on policy assignments. It's a real defect and it tells you the
code was never run. The fix is to pin `~> 4.14` and add `subscription_id` to the provider block, since v4
requires it explicitly. I'd also commit `.terraform.lock.hcl`, which I haven't — without it, two runs weeks
apart can resolve different provider builds and produce different plans.

---

## E. Helm & delivery

**●● Q29. Helm or Kustomize?**
Helm, for **release semantics**. `helm history`, `helm rollback`, `helm status` and `--atomic` give a
versioned, revertible unit of deployment. Kustomize has no concept of a release, so rollback is "find the
old YAML and re-apply it and hope." Since rollback is a stated requirement, that decided it. Kustomize's
advantage is simpler templates — Helm's Go templating gets genuinely unpleasant at scale.

**●●● Q30. Why the `checksum/config` annotation?**
Kubernetes doesn't restart pods when a ConfigMap changes — it updates the ConfigMap and the pods keep
serving with the old values until something else restarts them. That's silent, extremely confusing config
drift. Hashing the ConfigMap into a pod template annotation makes any config change produce a new pod spec
and therefore a rolling restart. Cost: every trivial config change causes a rollout.

**●●● Q31. `--atomic` and a manual rollback step. What's wrong with that?**
`--atomic` **already rolls back** on failure. So if my smoke test then fails and my script runs
`helm rollback <rel> 0`, it rolls back *again* — to the revision before the one `--atomic` restored.
That's an automated double-rollback in production. It's a real bug in my pipeline. The fix is to make the
script idempotent: compare the current revision against the last one with status `deployed`, and do
nothing if they match.

**●●● Q32. What does `helm rollback` NOT recover?**
Anything outside the release. Database migrations, data written to Blob by the new version, Azure resources
Terraform changed, deleted PVC data. And you can't roll back further than `revisionHistoryLimit` retains
ReplicaSets. That's why anything with irreversible state needs expand/contract migrations — never a schema
change the previous version can't read — and why rollback isn't always the safe option.

**●●●● Q33. Fix forward or roll back?**
The default is roll back, and the burden of proof is on fixing forward — rollback restores a state known to
work, fixing forward ships an untested change into a degraded system under time pressure. I roll back when
customers are impacted, when I don't understand the cause, or when the fix would take more than about
fifteen minutes. I fix forward only when the cause is understood and the fix is genuinely one line — **or
when rollback is unsafe**, which is the important case: a migration the old code can't read. And there's a
third option people forget: if `--atomic` already rolled back, or the old ReplicaSet is still serving,
there may be no active impact, in which case the right move is to stop and diagnose rather than take
another action under pressure. Whichever I choose, **I capture evidence first** — my pipeline dumps pod
state, logs and events before rolling back, because the moment you roll back the evidence is gone.

---

## F. Azure DevOps & DevSecOps

**●● Q34. Why can't a Microsoft-hosted agent deploy to your cluster?**
It runs in Microsoft's network with no route to my private endpoint subnet and no link to my private DNS
zones. It resolves `acrnonprod.azurecr.io` to a public IP and gets connection-refused, because public
access is disabled. The agent connection itself is fine — it's agent-initiated outbound long-polling on
443 — the problem is purely the path from agent to private endpoint.

**●●● Q35. How does the pipeline authenticate without a secret?**
Workload identity federation on the service connection. Azure DevOps mints an OIDC token per run, Entra
validates it against a federated credential on the app registration, and returns an access token. There is
no client secret stored anywhere, and nothing durable to steal. That's the single most important CI/CD
security control in the design.

**●●●● Q36. What stops a malicious pull request from deploying to production?**
Several layers. The pipeline YAML is in the repo and protected by branch policy — no direct push to
`main`, required reviewers, CODEOWNERS on `pipelines/` and `infra/`. The prod stage is conditioned on
`Build.SourceBranch == refs/heads/main`. The prod ADO Environment requires two human approvers. The prod
service connection is a separate identity in a separate subscription, restricted to this pipeline. And
`AKS RBAC Writer` **can't create RoleBindings**, so even a compromised pipeline can't grant itself
cluster-admin. The gap is that these are configured in Azure DevOps, not in the repo, so a reviewer can't
see them — which is why I'd document them explicitly in the README.

**●●● Q37. Should a security scan fail the build?**
It depends, and being deliberate about it is the point. **Block** on HIGH/CRITICAL *with a fix available*,
any leaked secret, and a defined critical set of IaC findings. **Warn** on everything else, tracked with an
SLA. Every suppression is a file in the repo with a justification and an **expiry date**, reviewed in the
PR. Ungated warnings train people to ignore the pipeline; unconditional blocking trains people to bypass
it — and the second is worse because it's invisible. My current pipeline is inconsistent here: Trivy fails
correctly, `npm audit` and `eslint` never fail, and Checkov fails on any severity.

**●●●● Q38. You scan your images. Does that mean production runs a safe image?**
No — and that's the distinction that matters. Scanning tells me the artifact was clean **when I looked at
it**. It says nothing about whether that's the artifact that got deployed. Anyone with `AcrPush` could
overwrite the tag. The fix is signing plus admission enforcement: `cosign sign` keyless with the
pipeline's OIDC identity, then **Ratify** as a Gatekeeper external data provider so the cluster rejects
any image without a valid signature from that identity. And deploy by **digest**, not tag, so "the same
release" always means the same bits.

---

## G. Security & governance

**●●● Q39. Your Azure Policy is at resource-group scope. What's wrong with that?**
Anyone who can create a **new** resource group escapes every policy — and my hub resource group is
completely ungoverned today. Real governance belongs at management-group scope, so it applies to
subscriptions that don't exist yet. Resource-group scope is a demo convenience, not a control.

**●●● Q40. Why does `kubernetes_policy_effect` default to `Audit`?**
Applying a `Deny` Gatekeeper constraint to an existing cluster instantly blocks deployments that were
previously fine, potentially including system components in namespaces you forgot to exclude. The correct
rollout is Audit → measure → remediate → Deny, per environment, non-prod first. You also need an
**exemption** process with expiry dates, not an off switch — the failure mode is a genuine incident fix
being blocked at 3am and someone disabling the assignment permanently.

**●●●● Q41. How many secrets are in this design?**
One: the Azure DevOps agent registration PAT. Everything else is architecturally eliminated — Workload
Identity for the app, federated credentials for the pipeline, OIDC for Terraform, no ACR admin account, no
AKS local account. And I'd argue the App Insights connection string my pipeline treats as a secret isn't
one either, because I set `local_authentication_enabled = false`, which makes the ingestion key inert. The
PAT itself I'd eliminate too, via managed-identity agent registration.

**●●● Q42. If someone compromises the agent VM, what do they get?**
Its managed identity holds exactly one permission — `Key Vault Secrets User` — so they get the agent
registration PAT, which is scoped to agent pools. They cannot deploy anything as that identity. **But**
they'd also get the currently-running job's OIDC token for its lifetime, and the VM has `docker` group
membership, which is root-equivalent. That's the strongest argument for ephemeral per-job agents: it
removes the long-lived host, the PAT, and cross-build state leakage in one change.

---

## H. Observability

**●●● Q43. Why one Log Analytics workspace?**
Cross-layer correlation. App traces, container stdout, Kubernetes audit, Storage data-plane logs, firewall
flows and the Activity Log all in one place means I can take a single failing request, follow its
`operation_Id` into `AppDependencies` to see a Blob 403, then join to `StorageBlobLogs` at the same
timestamp to see the exact principal ID that was denied. Split across workspaces that's four
investigations and a spreadsheet. The counter-argument is one RBAC boundary and one cost centre — at
scale you use a shared workspace with resource-context RBAC.

**●●● Q44. What would you alert on for Blob access failures?**
**Any** 403 — not a rate. In a correctly functioning system the count is exactly zero: the app either has
the role assignment or it doesn't. So a single 403 means RBAC changed, the federated credential broke, or
someone is probing. A rate-based threshold would have hidden exactly the failure this platform is most
likely to have.

**●●●● Q45. Your team gets too many alerts. What do you change?**
Move from threshold alerts to **SLO-based, multi-window multi-burn-rate alerting**. Define what "working"
means — 99.9% availability, p95 under 500ms — then alert on error budget consumption: 14.4× burn over an
hour pages, 6× over six hours pages at lower urgency, 1× over three days raises a ticket. That fixes both
failure modes at once: pages on a 30-second blip nobody noticed, and *silence* on a 2% error rate quietly
eating the whole monthly budget. Everything else becomes a dashboard you consult after you've been paged.

---

## I. The hard ones

**●●●● Q46. What's the weakest part of your design?**
Two candidates. Operationally, the **single-VM pipeline agent** — if it dies I can't deploy or roll back,
which is precisely what I need during an incident. Architecturally, that **my security model is designed
but not fully deployed**: my NSG rules exist in tfvars but were never declared in the root module, so all
three NSGs deploy empty. A security layer that isn't actually applied is a document, not a control — and
that's a worse failure than not having designed it, because it creates false confidence.

**●●●● Q47. If you had one more day, what would you do?**
Not add features. I'd make it **run** — fix the module paths, the provider pin and the dependency cycle so
`terraform plan` works, wire the Storage RBAC, reconcile the ServiceAccount names, write the application,
deploy it end to end, and capture the evidence. A design that has never been applied has unknown unknowns
in it, and the first real apply always finds them. Everything else on my roadmap is worth less than
finding out which of my assumptions are wrong.

**●●●● Q48. What did you get wrong that you'd do differently from the start?**
Structurally, I'd have built **per-environment root modules** from the beginning instead of a shared root
with tfvars. It's what my own pipeline assumes, and more importantly it means a prod apply *physically
cannot* touch non-prod state, which is the isolation a bank actually wants. And I'd have **deployed
incrementally** — network, then cluster, then workload — rather than writing the whole platform and
discovering at the end that it doesn't `init`. The defects in my repo are almost all the kind you find in
the first thirty seconds of an apply, and I never got to that thirty seconds.

**●●●● Q49. How do you know your rollback actually works?**
I don't, and that's the honest answer. Every reliability control in this design is untested — `--atomic`,
the PDB, the topology spread, the readiness probe, the smoke-test gate. **An untested control is a
hypothesis.** Before calling this production ready I'd run a game day: kill a zone, revoke the Storage role
assignment, block TVMaze at the firewall, take the agent pool offline, and push a deliberately broken
image. Half of those I'd expect to *fail* in an instructive way — I know the TVMaze one will return a 502
rather than serving stale, which proves the case for stale-while-revalidate.

**●●●● Q50. Is this production ready?**
No — and I'd be sceptical of anyone who said their assessment submission was. It's production-*shaped*:
the hard architectural decisions are right and defensible, and the security model is the right one for a
bank. But it has blocking defects I've documented rather than hidden, its zone redundancy is inconsistent
— compute across three zones, its cache in one — the deployment path is a single VM, and nothing has been
tested. The distance to production is about six weeks: make it work, then correct, then safe, then
resilient, then scalable. In that order — because a resilient system with a broken RBAC grant is just an
elaborate way to fail consistently.

---

## Rapid-fire drill — one sentence each, no thinking time

| Q | A |
|---|---|
| Minimum `AzureFirewallSubnet` size? | /26 |
| Which identity pulls images from ACR? | The **kubelet** identity, not the control-plane identity |
| Which ACR SKU supports Private Link? | Premium only |
| What IP is Azure's VNet DNS? | 168.63.129.16 |
| Where must `dns_service_ip` sit? | Inside `service_cidr` |
| What does `AADSTS70021` mean? | Federated credential subject mismatch |
| What audience does Workload Identity use? | `api://AzureADTokenExchange` |
| Which Azure role lets you `get-credentials` but nothing else? | Cluster User |
| Which AKS role can't create RoleBindings? | RBAC Writer |
| What does `--atomic` do? | Rolls back automatically on failed or timed-out upgrade |
| What does `helm rollback` create? | A new forward revision, not a rewind |
| SNAT ports per firewall public IP? | 2,496 (NAT Gateway: 64,512) |
| Which zones does AMPLS need? | monitor, oms/ods.opinsights, agentsvc.azure-automation, blob |
| What breaks if `allow_forwarded_traffic` is false? | The firewall hairpin — return traffic is dropped |
| Why `Standard_D2ds_v5` not `D2s_v5`? | The `d` means a local temp disk, required for Ephemeral OS |
| Kubernetes Secret encryption at rest? | **None** by default — base64 in etcd unless KMS is enabled |

---

## The two things to say if you say nothing else

> **On the design:** *"Three hard boundaries — no public inbound, allow-listed outbound through a firewall
> with `userDefinedRouting` so there's no second door, and no credentials in the workload because
> everything federates. Every other decision follows from those three."*
>
> **On yourself:** *"Here are six defects I found reviewing my own work, what each one breaks, and what the
> fix is."*
>
> The first shows you can design. **The second shows you can be trusted with production.**

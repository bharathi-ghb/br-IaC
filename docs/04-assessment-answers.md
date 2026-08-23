# 04 — Model Answers to Every Question in the Assessment

> The assessment PDF contains explicit "explain…" instructions scattered through Parts 1–6. Each one is
> a scripted interview question. This document answers every single one, in the order they appear.
>
> **How to use it:** read an answer, close the document, say it out loud, then compare. If you can't say
> it without reading, you don't know it yet.
>
> Answers marked 🔴 relate to something your code currently gets wrong — see
> [02-code-review-findings.md](02-code-review-findings.md).

---

## Scenario framing

### "Private does not mean isolated from the Internet. Explain your choice of outbound path and its security implications."

> "There are two separate requirements hiding in the word 'private', and conflating them is the mistake
> the question is testing for.
>
> The first is **no public inbound**. That's absolute here: the AKS API server is private with no public
> FQDN published, the application is exposed only through an internal load balancer restricted to
> internal CIDRs, and ACR, Key Vault, Storage and Azure Monitor all have public network access disabled
> at the resource level with private endpoints for access.
>
> The second is **controlled outbound**. TVMaze is a public internet dependency, so I need a way out —
> but it must be a governed one. I chose **Azure Firewall** in the hub, with the AKS node subnet carrying
> a UDR sending `0.0.0.0/0` to the firewall's private IP, and — critically — AKS itself configured with
> `outbound_type = userDefinedRouting` so that AKS does **not** create its own public load balancer for
> outbound. Without that setting you get a second, unmonitored exit that bypasses the firewall entirely.
>
> The firewall policy allows exactly one application FQDN, `api.tvmaze.com` on 443, plus Microsoft's
> `AzureKubernetesService` FQDN tag for platform traffic and a couple of network rules for NTP and the
> node-to-control-plane tunnel. Everything else is denied, with threat intelligence set to `Deny`.
>
> **The security implications, positive and negative.**
>
> Positive: I have a single, known egress IP, so an upstream can allow-list me. I have a full log of every
> outbound connection attempt, so 'denied egress' becomes a detection signal — if a compromised container
> tries to phone home, I see it and it fails. And I have a genuine data-exfiltration control, which is the
> real reason a bank puts a firewall there.
>
> Negative: the firewall is now in the critical path for all egress, so it's a shared failure domain —
> mitigated by deploying it zone-redundant. It costs around $950 a month, which is not nothing. It has
> much tighter SNAT port limits than a NAT Gateway — 2,496 per public IP versus 64,512. And it adds
> operational friction: every new outbound dependency becomes a firewall change request, which in a real
> bank is a ticket to another team.
>
> I considered **NAT Gateway** and rejected it. NAT Gateway actually solves outbound connectivity better —
> it's cheaper, simpler, has no rules to break, and handles SNAT exhaustion far better. But it applies no
> policy at all. With a NAT Gateway, a malicious dependency in my container can post customer data to any
> host on the internet and I'd have no log of it and no way to stop it. For a banking platform that
> trade-off doesn't work.
>
> If SNAT exhaustion ever became the binding constraint, the answer isn't to swap the firewall out — it's
> to put a **NAT Gateway on the AzureFirewallSubnet, behind the firewall**. That's a supported pattern
> that gives you the firewall's policy with the NAT Gateway's port scale."

**Follow-up they will ask: "What happens if the firewall goes down?"**

> "All egress fails, so a cache miss returns a 502. But the cache *read* path doesn't traverse the
> firewall — it goes to a private endpoint inside the VNet — so the app keeps serving cached data. That's
> a deliberate property of putting the cache on the private side of the boundary: a firewall outage
> degrades freshness, not availability. I'd make it explicit by adding a stale-while-revalidate mode so a
> cache miss during an upstream outage serves expired data with a header rather than an error."

---

## Part 2 — AKS Platform & Application

### Explain the distinction between Azure RBAC and Kubernetes RBAC

This is the single most likely question in the whole interview. Give the layered answer.

> "They operate at different layers and they compose rather than compete.
>
> **Authentication** always goes through Entra ID when the cluster has Entra integration enabled. You
> run `az aks get-credentials`, `kubelogin` obtains an Entra token, and that token is presented to the API
> server. So *who you are* is always Entra.
>
> **Authorisation** is where they differ. With `azure_rbac_enabled = true`, the API server delegates the
> authorisation decision to Azure — it asks 'does this principal have an Azure role assignment that
> permits this verb on this resource?' The Azure roles are `Azure Kubernetes Service RBAC Reader`,
> `Writer`, `Admin` and `Cluster Admin`, and they are ordinary Azure role assignments scoped to the
> cluster or to a namespace.
>
> With native Kubernetes RBAC, authorisation is decided inside the cluster by `Role`, `ClusterRole`,
> `RoleBinding` and `ClusterRoleBinding` objects, evaluated against the identity in the token.
>
> **Critically, both authorisers run.** Azure RBAC is an additional authoriser, not a replacement. A
> request is allowed if *either* grants it. So you can use Azure RBAC for coarse-grained access control
> and still write native `Role` objects for fine-grained cases Azure's built-in roles can't express."

**Then the "why did you choose it" part:**

> "I enabled Azure RBAC because in a bank the dominant requirements are **audit** and **identity
> lifecycle**. With Azure RBAC, 'who could access production Kubernetes on the third of March' is
> answerable from the Azure Activity Log — one central, tamper-evident, exportable record — rather than
> by archaeology on cluster YAML. Access is granted through Entra group membership, so when someone
> leaves the organisation and HR disables their account, their cluster access disappears with it. And I
> get **PIM**: cluster-admin becomes time-bound, approval-gated and just-in-time. Native Kubernetes RBAC
> cannot do any of that.
>
> What I gave up is granularity. Azure's four built-in roles can't express 'may `get` pods and `create`
> portforward but never `exec`, only in namespace X'. For that I'd add native `Role` objects on top —
> which is fine, because they compose.
>
> Two other trade-offs worth naming. Azure role-assignment propagation can take up to five minutes, so a
> pipeline that grants a role and immediately uses it can fail — you need a retry. And authorisation now
> depends on Entra being reachable; there is a cached-decision fallback but it's finite."

**And the setting that matters most:**

> "The related decision is `local_account_disabled = true`. AKS otherwise keeps a local `clusterAdmin`
> account using a client certificate. Anyone with the Azure `Cluster Admin` role can fetch that
> kubeconfig, and it **completely bypasses Entra, MFA, Conditional Access and your entire RBAC model** —
> and its use is nearly invisible in logs, because there's no Entra sign-in event. Disabling it is one of
> the highest-value single settings in the cluster.
>
> The cost is that I've removed my break-glass path. If Entra is unavailable, nobody can reach the API
> server. So the runbook documents a PIM-gated, monitored procedure to temporarily re-enable it, and
> re-enabling it fires an alert."

### "Deploy the API with a Kubernetes ServiceAccount mapped to the Azure identity" — walk me through it

> "Five things have to line up, and if any one is wrong the failure is silent or confusing.
>
> **One**, the cluster needs `oidc_issuer_enabled = true`. That makes AKS publish an OIDC discovery
> document and a JWKS endpoint at a public, unauthenticated URL — which is fine, it only contains public
> keys — so that Entra can verify tokens the cluster signs.
>
> **Two**, `workload_identity_enabled = true` installs the `azure-wi-webhook` mutating admission webhook.
>
> **Three**, on the **pod template** — not the Deployment — the label
> `azure.workload.identity/use: "true"`. That's what the webhook selects on. If you put it on the
> Deployment's own labels instead of the pod template's, nothing is injected and the SDK silently falls
> through its credential chain to a confusing failure. In my chart it's inside `spec.template.metadata.labels`.
>
> **Four**, on the ServiceAccount, the annotation `azure.workload.identity/client-id` with the managed
> identity's client ID.
>
> **Five**, in Azure, a **federated identity credential** on that managed identity, where `issuer` is the
> cluster's OIDC issuer URL, `audience` is `api://AzureADTokenExchange`, and `subject` is the exact string
> `system:serviceaccount:<namespace>:<serviceaccountname>`.
>
> At admission time the webhook injects four environment variables — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
> `AZURE_AUTHORITY_HOST` and `AZURE_FEDERATED_TOKEN_FILE` — plus a projected ServiceAccount token volume
> with that audience. At runtime `DefaultAzureCredential` reads the token file, presents it to Entra as a
> client assertion, Entra fetches the cluster's JWKS, verifies the signature, issuer, audience and
> subject, and returns an Entra access token. The pod then calls Blob Storage with a bearer token.
>
> The token is short-lived — about an hour — and the kubelet rotates it. So even if it's exfiltrated,
> it's valid for one audience, for a short window, and only for a pod running under that exact
> ServiceAccount in that exact namespace.
>
> **And then there's the sixth thing that isn't about federation at all**: the Azure RBAC role assignment.
> Federation gets the pod *authenticated*. It still needs `Storage Blob Data Contributor` on the storage
> account to be *authorised*. Missing that gives you a 403 — which is exactly Troubleshooting Scenario 1."

🔴 **Own the gap here:** *"And I'll flag it before you find it — in my current code that role assignment
is missing. The storage module accepts a `data_contributor_principal_ids` variable and I never pass the
identity's principal ID to it. So my platform ships with precisely the bug the assessment asks me to
debug. It's a one-line fix and it's the first thing on my list."*

### "Support at least separate development and production-like configuration"

> "I used Helm values overlays: `values.yaml` holds a safe, conservative base, and
> `values-nonprod.yaml` / `values-prod.yaml` override only what differs. The pipeline passes
> `--values values-<env>.yaml`, and anything that comes from infrastructure — the ACR login server, the
> workload identity client ID, the storage account name, the namespace, the ServiceAccount name — is
> injected with `--set` from **Terraform outputs**, so it's never hardcoded anywhere.
>
> The concrete differences: non-prod runs 1 replica, `debug` logging, a 60-second cache TTL so you can
> actually see cache behaviour while testing, no HPA and no PDB. Production runs 3 replicas, HPA from 3 to
> 12, PDB `minAvailable: 2`, topology spread across zones, a node selector pinning it to the application
> node pool, an internal load balancer, and a one-hour cache TTL.
>
> I chose overlays over separate charts because separate charts drift. Two template sets diverge silently
> until prod behaves differently from the thing you tested. With one chart and two small values files,
> every environmental difference is visible in a short, reviewable diff.
>
> I chose Helm over Kustomize specifically for **release semantics** — `helm history`, `helm rollback`,
> `--atomic`. Kustomize has no concept of a release, so rollback is 'find the old YAML and re-apply it'.
> Since the assessment asks me to demonstrate rollback, that decided it."

---

## Part 3 — Private Networking & DNS

### "Demonstrate that AKS workloads resolve service FQDNs to private IP addresses"

Have the exact commands ready — and be able to read the output.

```bash
# 1. From inside the cluster, in the app namespace, using a debug pod
kubectl run dnstest -n banking-api --rm -it --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 -- bash

# 2. Resolve the storage FQDN — expect a CNAME to privatelink.* and a 10.101.1.x answer
nslookup sanonprod01.blob.core.windows.net
# Non-authoritative answer:
# sanonprod01.blob.core.windows.net  canonical name = sanonprod01.privatelink.blob.core.windows.net.
# Name:    sanonprod01.privatelink.blob.core.windows.net
# Address: 10.101.1.4          <-- PRIVATE. This is the proof.

# 3. Same for ACR — note ACR returns TWO names: registry + data endpoint
nslookup acrnonprod.azurecr.io
nslookup acrnonprod.westeurope.data.azurecr.io

# 4. And the AKS API server itself
nslookup aks-nonprod-iac-xxxx.privatelink.westeurope.azmk8s.io

# 5. Prove it actually connects, not just resolves
curl -sv https://sanonprod01.blob.core.windows.net/ 2>&1 | grep -E "Connected to|subject:"
# Connected to sanonprod01.blob.core.windows.net (10.101.1.4) port 443
```

> "The two things I'd point at in that output. First, the **CNAME chain** — the application asks for the
> normal public name and Azure's public DNS returns a CNAME to the `privatelink` name; only then does the
> linked private zone answer. The app never has to know about Private Link. Second, the **certificate is
> still issued for the public name**, which is exactly why the CNAME indirection exists rather than a
> rewritten hostname: TLS validation continues to work unchanged.
>
> The negative test matters just as much: if I run the same `nslookup` from a machine outside the VNet,
> I get a public IP — and a connection to it is refused, because `public_network_access_enabled` is
> `false`. Resolution and reachability are two separate controls and I have both."

### "Explain the DNS path from pod → CoreDNS → VNet/Azure DNS → Private DNS zone → Private Endpoint"

Full narrated version with diagram: [01-architecture.md §4](01-architecture.md#4-dns-resolution-path--pod-to-private-endpoint).
The five-step spoken version:

> "One. The pod's `/etc/resolv.conf` points at the kube-dns ClusterIP, `172.16.0.10` — which is the
> `dns_service_ip`, and it has to sit inside the `service_cidr`; AKS validates that at create time.
>
> Two. CoreDNS answers anything matching the cluster domain itself. Everything else hits the `forward`
> plugin in the Corefile, which forwards to the node's resolver: **168.63.129.16**. That's Azure's
> per-VNet DNS virtual IP — it isn't routable, it isn't an internet address, and it's reachable from
> inside any VNet by definition.
>
> Three. Azure DNS looks up the name. The public record for `sanonprod01.blob.core.windows.net` is a
> **CNAME to `sanonprod01.privatelink.blob.core.windows.net`**. This is the key mechanic and the one
> people get wrong: the application never asks for the privatelink name — Azure redirects it there.
>
> Four. Because the zone `privatelink.blob.core.windows.net` is **linked to this VNet**, Azure resolves
> that CNAME target from the private zone and returns the A record that the private endpoint's DNS zone
> group created — `10.101.1.4`. If the zone weren't linked, resolution would fall through to public DNS
> and return the public storage IP.
>
> Five. The pod connects to the private IP over TLS, and the certificate still validates because it's
> issued for the public name.
>
> And I should say what I *didn't* build: there's no custom DNS server and no DNS Private Resolver,
> because both VNets that need resolution are linked directly to every zone. I'd add a resolver the
> moment on-premises clients needed to resolve these names — they can't reach 168.63.129.16 over
> ExpressRoute, so you need a resolver inbound endpoint as a conditional-forwarder target. That's a
> deliberate omission, not an oversight."

### "Explain outbound connectivity to TVMaze, including routing, egress control and failure handling"

> "**Routing.** The pod has an overlay IP from `192.168.0.0/16`, which is not routable in the VNet. When
> it egresses, the CNI SNATs it to the node's IP in `10.101.0.0/24`. The node subnet has a route table
> with `0.0.0.0/0` next-hopping to `VirtualAppliance` at the firewall's private IP in the hub. Traffic
> crosses the VNet peering — which needs `allow_forwarded_traffic = true` on both sides, or the return
> path is dropped because its source is outside the peered VNet's range.
>
> **Egress control.** At the firewall, DNS proxy is enabled, so the firewall resolves `api.tvmaze.com`
> itself and sees the same answer the client did — that closes a DNS-rebinding gap where a client could
> resolve a name to one IP and connect to another. An application rule allows `api.tvmaze.com` on HTTPS
> 443 from the spoke address space. Threat intelligence is in `Deny` mode. Everything else is denied and
> logged to Log Analytics. The firewall SNATs to its public IP, which is a single stable address — so
> the upstream could allow-list us if it ever needed to.
>
> **Failure handling — and I'd split this into four layers.**
>
> *In the application:* an `AbortController` timeout from `UPSTREAM_TIMEOUT_MS`, so a hung upstream can't
> exhaust the connection pool and cascade. The Azure SDKs retry transient errors with exponential backoff
> and jitter by default. For TVMaze I'd add a circuit breaker so a sustained outage fails fast rather
> than queueing.
>
> *In the cache:* a cache miss during an upstream outage currently returns 502. I'd add
> **stale-while-revalidate** — serve the expired blob with a header indicating staleness rather than
> failing. That converts an upstream outage from an availability incident into a freshness incident,
> which is the correct trade for this data.
>
> *In the platform:* the firewall is zone-redundant, so a single-zone failure doesn't take egress down.
> The cache read path goes to a private endpoint and never traverses the firewall, so even total firewall
> loss leaves the API serving cached data.
>
> *In observability:* I alert on firewall denies for the spoke source range, because a spike means either
> an application change nobody told me about or a compromise. And I alert on cache write failures,
> because the app deliberately swallows those to protect the request path — which means without an alert
> they'd be invisible."

### 🔴 "Explain how you would prevent accidental public access"

> "Five layers, and the point is that no single one is trusted.
>
> **Layer one — the resource itself.** Every service has `public_network_access_enabled = false` set in
> Terraform: ACR, Key Vault, Storage. The storage account additionally has `network_rules.default_action
> = "Deny"`. AKS is `private_cluster_enabled = true` with `private_cluster_public_fqdn_enabled = false`,
> so there isn't even a resolvable public name.
>
> **Layer two — Azure Policy in Deny mode.** This is the one that actually prevents *accidents*, because
> layer one only covers what Terraform manages. My governance module assigns built-in policies that deny
> storage accounts and container registries with public network access, and deny non-private AKS
> clusters. If someone flips a switch in the portal or deploys outside Terraform, the ARM request is
> rejected before it takes effect. Policy is preventive; Terraform is only corrective — and only when it
> next runs.
>
> **Layer three — the pipeline.** Checkov scans the Terraform on every commit, so 'someone set
> `public_network_access_enabled = true`' fails at pull-request time. And I'd extend that by running
> policy against the **plan JSON** with Conftest, not just the source, which catches things static
> analysis can't — like an apply that would delete a resource tagged as critical.
>
> **Layer four — the network.** NSGs on every subnet, and `private_endpoint_network_policies = "Enabled"`
> on the private endpoint subnet. That last one matters more than it sounds: historically private
> endpoint traffic bypassed NSGs entirely, so without it my 'only the AKS and agent subnets may reach
> 443' rule would be decorative.
>
> **Layer five — detection.** Diagnostic settings on every resource into Log Analytics, and an alert on
> the Activity Log for any change to `publicNetworkAccess` or to a network ACL. Because eventually
> something will get through the first four layers, and the difference between an incident and a breach
> is how fast you notice.
>
> **And I have to be honest about a gap.** Two, actually. My policy assignments are at **resource-group**
> scope — which means anyone who can create a new resource group escapes all of them, and my hub resource
> group is entirely ungoverned. Real governance belongs at management-group scope so it applies to
> subscriptions that don't exist yet. And separately, my NSG rules are defined in `tfvars` but the
> variables were never declared in the root module, so the NSGs currently deploy empty. Layer four isn't
> actually enforced in my code right now."

**Why volunteering that lands well:** the interviewer was probably about to find it. Saying it first
converts a defect into evidence that you review your own work critically.

---

## Part 4 — Azure DevOps Pipeline

### "Demonstrate how you would perform a Helm rollback if an application release fails"

Have the commands cold.

```bash
NS=banking-api; REL=banking-application

# 1. What's the current state?
helm status  "$REL" -n "$NS"
helm history "$REL" -n "$NS" --max 10
# REVISION  UPDATED   STATUS      CHART      APP VERSION  DESCRIPTION
# 3         ...       deployed    ...-1.0.0  1.0.0        Build 20260822.3 / commit a1b2c3d
# 4         ...       failed      ...-1.1.0  1.1.0        Upgrade "banking-application" failed

# 2. Roll back to the last KNOWN-GOOD revision (not blindly to "previous")
LAST_GOOD=$(helm history "$REL" -n "$NS" -o json | jq -r '[.[]|select(.status=="deployed")]|last|.revision')
helm rollback "$REL" "$LAST_GOOD" -n "$NS" --wait --timeout 5m --cleanup-on-fail

# 3. Verify
helm history "$REL" -n "$NS" --max 5     # new revision 5, status deployed, describing a rollback to 3
kubectl -n "$NS" rollout status deploy/"$REL"
./scripts/smoke-test.sh "$NS" "$REL"
```

> "Three things I'd want to say about that.
>
> **First, Helm rollback creates a new forward revision.** It doesn't rewind history — rolling back to
> revision 3 creates revision 5 whose content is revision 3's. That's important because it means the
> audit trail is complete and you can roll back the rollback.
>
> **Second, I don't roll back to `0` — 'previous' — blindly.** If the last three deploys failed, the
> previous revision is also broken. I query the history for the last revision whose status is `deployed`
> and target that explicitly. My current script takes `0` as a default, and that's something I'd tighten.
>
> **Third, my pipeline actually has a subtle bug here that I found reviewing it.** I run
> `helm upgrade --install --atomic`, and `--atomic` *already* rolls back automatically on failure. Then I
> have a separate `condition: failed()` step that runs my rollback script. So if `--atomic` already rolled
> back, my script rolls back **again** — to the revision before the one `--atomic` restored. In production
> that means an automated double-rollback. The fix is to make the script idempotent: check whether the
> current revision already equals the last-known-good before doing anything.
>
> The diagnostics capture in that failure step is worth keeping though — it grabs pod state, deployment
> description, container logs and recent events *before* rolling back. Because the moment you roll back,
> the evidence disappears. That's the part people forget."

**What Helm rollback does NOT do — say this unprompted, it's a strong point:**

> "Helm rollback reverts Kubernetes objects. It does **not** revert anything outside the release: a
> database migration, a change to blob data, an Azure resource Terraform created. So for anything with
> irreversible state I need forward-only fixes and expand/contract migrations — never a schema change
> that the previous application version can't read. And I should note `helm rollback` doesn't restore
> deleted PVC data either.
>
> There's also a `revisionHistoryLimit` interaction: my Deployment sets 5, and Helm keeps 10 releases by
> default. If I try to roll back further than the retained history, the ReplicaSet is gone and the
> rollback fails."

### "The pipeline agent must have network line-of-sight. Document agent placement, DNS resolution and identity"

Full answer with diagram: [01-architecture.md §7](01-architecture.md#7-cicd-path--how-a-commit-reaches-a-private-cluster).
Condensed spoken version:

> "**Placement.** A Linux VM with no public IP on a dedicated subnet, `snet-pipeline-agents`
> (10.101.2.0/26), inside the spoke — the same VNet as the private endpoints. Its connection to Azure
> DevOps is **agent-initiated outbound long-polling on 443**, so there's no inbound rule and no listener.
> A Microsoft-hosted agent physically cannot work here: it runs in Microsoft's network with no route to
> 10.101.1.x and no link to my private DNS zones, so `acrnonprod.azurecr.io` would resolve to a public IP
> and the connection would be refused, because public access is disabled.
>
> **DNS.** The VM uses the VNet's default DNS at 168.63.129.16. Every `privatelink.*` zone is linked to
> **both** the hub and the spoke VNet, so the agent resolves ACR, Key Vault and the AKS API server to
> private IPs by exactly the same mechanism the pods use. That 'link to both VNets' decision in my
> private-dns module is what makes this work — link only the spoke and the agent is fine but a hub
> jumpbox isn't; link only the hub and the pods break.
>
> **Identity — and there are deliberately two.** The **service connection** is an Entra app federated to
> the Azure DevOps organisation using workload identity federation, so there is **no client secret stored
> anywhere**; each run gets a short-lived OIDC token. That identity holds `AcrPush` on the registry,
> `AKS RBAC Writer` plus `Cluster User` on the cluster, and the ARM permissions Terraform needs — notably
> **not** Owner or Contributor at subscription scope. Separately, the **VM's own user-assigned managed
> identity** has exactly one permission: `Key Vault Secrets User`, to read its registration PAT at boot.
>
> The point of separating them is blast radius. If someone compromises the agent host, they get a PAT
> scoped to agent pools — not a path into my subscription. Though I should be honest: they'd also get
> whatever the currently-running job's OIDC token grants, for its lifetime. That's the argument for
> ephemeral per-job agents, which is where I'd take this.
>
> **And the weaknesses I'd fix.** It's a single VM, so it's a single point of failure — and losing your
> deployment path during an incident is the worst possible time. Minimum fix is a scale set across zones;
> better is Managed DevOps Pools; best for a Kubernetes shop is KEDA-scaled agent pods in the cluster with
> Workload Identity and no PAT at all. Also, the agent subnet has no route to the firewall, so it egresses
> to the internet unfiltered — which contradicts my own egress-control story and needs fixing either by
> routing it through the firewall or by baking a golden image."

### "Push to private ACR using an appropriate non-secret authentication pattern"

> "`az acr login --name <registry>` under an `AzureCLI@2` task using the federated service connection.
> What that does under the hood is exchange the current Entra access token for an **ACR refresh token**,
> then write it into the Docker config. So there is no password anywhere — not in a variable, not in a
> variable group, not on the agent's disk beyond a short-lived token file.
>
> The alternative would be `docker login -u -p` with the ACR **admin account**, and that's exactly what I
> disabled with `admin_enabled = false`. The admin account is a shared username and password with full
> push and pull rights, it's unattributable in the audit log — every push looks identical — and rotating
> it breaks every consumer simultaneously. Its existence would defeat the entire identity model.
>
> On the pull side it's a different identity: the **kubelet identity** holds `AcrPull`. That catches
> people out — it's not the cluster's control-plane identity that pulls images, it's the kubelet's, and
> they're separate managed identities. In my Terraform I wire `module.aks.kubelet_identity_object_id` into
> the ACR module's `pull_principal_ids` for exactly that reason.
>
> The thing I'd add is **signing**. Right now I have a scanned image, but nothing proves the image in
> production is the one my pipeline built. I'd sign with `cosign` in the build stage and enforce it at
> admission with **Ratify** as a Gatekeeper external data provider, so an unsigned or tampered image is
> rejected by the cluster regardless of who pushed it."

---

## Part 5 — Security & Governance

### "Explain how you would prevent privilege escalation and secret leakage in CI/CD and Helm values"

This is the meatiest security question. Structure it as **identity → pipeline → Helm → detection**.

> "**Preventing privilege escalation in CI/CD.**
>
> It starts with what the pipeline identity *is*. I use workload identity federation, so there's no
> long-lived secret to steal in the first place — the credential is an OIDC token minted per run, valid
> for minutes, and bound to a specific pipeline. Compare that to a service principal secret in a variable
> group, which is a durable credential that anyone who can edit a pipeline can exfiltrate with one
> `echo`.
>
> Then it's about what that identity *holds*. My service connection has `AcrPush`,
> `AKS RBAC Writer`, `Cluster User` and the ARM roles Terraform needs — deliberately **not** Owner or
> Contributor at subscription scope. The distinction that matters most: `AKS RBAC Writer` can deploy
> workloads but **cannot create RoleBindings**, so a compromised pipeline can't grant itself
> cluster-admin. That's the specific escalation path I'm closing.
>
> There are separate identities per environment — a non-prod service connection and a prod one, in
> separate subscriptions — so a compromised non-prod pipeline has no reach into production. And the prod
> service connection is restricted to the prod ADO Environment, which requires human approval.
>
> Then it's about what can *run* as that identity. Pipeline definitions live in the repo and are protected
> by branch policy: no direct push to `main`, required reviewers, CODEOWNERS on `infra/` and `pipelines/`.
> That closes the classic attack — open a PR that modifies the pipeline YAML to dump credentials, and have
> it run against production. In Azure DevOps I'd also restrict the service connection to specific
> pipelines rather than leaving it open to any pipeline in the project.
>
> **Preventing secret leakage.**
>
> The strongest control is architectural: **there are almost no secrets in this design.** The workload
> uses Workload Identity, so no storage key and no connection string. The pipeline uses OIDC, so no client
> secret. Terraform authenticates with OIDC. The only secret in the whole system is the agent's
> registration PAT, and it lives in Key Vault, is read at boot by the VM's managed identity, and never
> enters Terraform state or source control.
>
> On top of that: Gitleaks scans the full history on every run with `fetchDepth: 0`, so a secret committed
> and then removed is still caught. Trivy's secret scanner runs on the filesystem and on the image layers,
> which catches a secret baked into an image layer even if it was deleted in a later layer. Terraform
> outputs that carry sensitive values are marked `sensitive = true` so they're redacted in logs. And in
> Azure DevOps, secret variables are masked in output — though I'd never rely on that alone, because it's
> a substring match that's trivially defeated by base64-encoding.
>
> **Helm values specifically.**
>
> Values files are in source control, so **nothing secret ever goes in a values file** — that's the rule,
> and my values files hold only configuration: log level, cache TTL, replica counts, the TVMaze base URL.
> Anything sensitive or environment-derived comes from `--set` at deploy time, sourced from Terraform
> outputs. My chart's ConfigMap contains the storage account *name*, which is not a secret — access to it
> is governed by RBAC, not by knowing the name.
>
> The one place I break my own rule is the App Insights connection string: the pipeline reads it from a
> Terraform output and creates a Kubernetes Secret. And reviewing it, that's unnecessary — I set
> `local_authentication_enabled = false` on App Insights, which makes the ingestion key in that connection
> string inert. So I'm treating a non-secret as a secret. The right fix is to authenticate telemetry with
> the same Workload Identity and put the endpoint in the ConfigMap.
>
> And I'd note what a Kubernetes Secret actually is: base64 in etcd, **not encrypted** unless you've
> enabled KMS etcd encryption. Anyone with `get secrets` in the namespace can read it. So if I did need a
> real secret, the right mechanism is the **Key Vault CSI driver** — which I enabled on the cluster with
> two-minute rotation but didn't actually use in the chart. Then the secret is mounted from Key Vault,
> rotated automatically, and never passes through the pipeline at all.
>
> **Detection, because prevention fails.** Key Vault diagnostic logs alert on `SecretGet` from an
> unexpected principal. Storage diagnostics alert on authentication failures. Activity Log alerts on
> role-assignment changes — because 'someone granted themselves Owner' is the signal that matters most and
> it's cheap to watch for."

### "Apply a consistent tagging standard"

> "My standard is `environment`, `owner`, `application` and `cost_centre`, applied at the resource group
> and inherited by every resource through a `var.tags` map that every module accepts. I enforce it with
> the built-in 'Require a tag on resources' policy, assigned once per required tag using `for_each`.
>
> Three things worth adding about how I'd do this properly.
>
> **One**, `Require` denies non-compliant *new* resources but doesn't fix existing ones. In a real estate
> I'd pair it with the `Inherit a tag from the resource group` policy in `Modify` mode plus a remediation
> task, so existing resources get backfilled rather than just flagged.
>
> **Two**, a tag standard that isn't enforced is a suggestion. Deny mode is what makes it real — but it
> also means a missing tag blocks a deployment, so the rollout has to be Audit first, measure, remediate,
> then Deny. Same pattern as the Gatekeeper policies.
>
> **Three, and I'll flag this because it's a genuine bug in my code**: my policy requires `cost_centre`,
> and my tfvars tag map doesn't set it. So the policy would deny my own apply. It's a good illustration of
> why you run policy in Audit mode first — I'd have caught it in the compliance report rather than in a
> failed deployment.
>
> For a bank I'd extend the taxonomy with `dataClassification`, `criticality` and `businessService`,
> because those drive automated decisions: backup policy, retention, alert routing and who gets paged."

---

## Part 6 — Observability

### "Define the minimum dashboards/alerts you would create"

Full detail in [07-observability.md](07-observability.md). The spoken summary:

> "I'd frame it as **SLO-driven alerting**, not resource-driven. Most monitoring setups alert on every
> metric that has a threshold, and the result is alert fatigue and ignored pages. So: a small number of
> alerts that page a human, tied to user-visible impact, and everything else as a dashboard you look at
> during an investigation.
>
> **The alerts that page, mapped to what the assessment asked for:**
>
> *Availability* — availability of `GET /api/shows` below 99.5% over 5 minutes, and separately, zero
> Ready replicas, which is the total-outage signal.
>
> *Latency* — p95 above 1 second for 10 minutes. p95, not average, because an average hides the tail that
> users actually feel.
>
> *Failed requests* — 5xx rate above 1% over 5 minutes.
>
> *Pod health* — CrashLoopBackOff, or any pod restarting more than 3 times in 15 minutes, or
> `OOMKilled` — which is its own signal, because it means my memory limit is wrong rather than my code.
>
> *Image pulls* — `ImagePullBackOff` or `ErrImagePull` on any pod. This is high-signal: it means the
> registry, the identity or the tag is broken and no deployment will succeed.
>
> *Storage access* — Blob 403s at all. Not a rate — **any** 403 is an alert, because in a working system
> the count is exactly zero, so one means RBAC or the federated credential has broken.
>
> *Authentication failures* — `AADSTS70021` or `AADSTS700016` in application logs, and Key Vault
> `SecretGet` denials.
>
> **Plus two the question didn't ask for but a bank would want:** a spike in firewall denies from the
> spoke source range, because that's either an undeclared application change or a compromise; and any
> Activity Log change to `publicNetworkAccess` or a network ACL, because that's my public-exposure
> tripwire.
>
> **Dashboards** — a single Azure Workbook with four sections: the golden signals for the API, cluster
> health from Container Insights, dependency health showing Blob and TVMaze latency and error rate
> separately so you can tell which one is broken, and a deployment timeline overlaying Helm revisions on
> the metrics — because the first question in any incident is 'what changed?'"

### "Document what an operator should check first during an incident and how logs correlate"

Full runbook in [07-observability.md](07-observability.md) and
[08-operational-runbook.md](08-operational-runbook.md). The headline:

> "**First five minutes, in this order.** Is it real — check the availability metric and actually curl
> the endpoint, because 'the alert fired' and 'users are affected' aren't the same thing. Then: what
> changed — `helm history` and the Activity Log, because the overwhelming majority of incidents are
> caused by a change in the last hour. Then: how bad — how many replicas are Ready, is it one zone or all
> of them. Then: which layer — application, platform, or dependency.
>
> **How logs correlate.** Everything lands in one Log Analytics workspace, which is the single most
> important design decision for incident response. Application traces from App Insights are in
> `AppRequests` and `AppDependencies`; container stdout is in `ContainerLogV2`; cluster events are in
> `KubeEvents`; the Kubernetes audit log and API server logs are in `AKSAuditAdmin`; Azure resource
> operations are in `AzureDiagnostics` and `StorageBlobLogs`; firewall flows are in
> `AZFWApplicationRule` and `AZFWNetworkRule`.
>
> Because they're all in one workspace I can join them. The join key that matters is **`operation_Id`** —
> the App Insights correlation ID that flows through a request and its dependencies. Secondary keys are
> the **pod name**, which links `AppRequests` to `ContainerLogV2` and `KubeEvents`, and **time plus
> resource ID** for the Azure-side logs.
>
> The concrete win: I can take a single failing request, follow its `operation_Id` into
> `AppDependencies` to see that the Blob call returned 403, then jump to `StorageBlobLogs` at the same
> timestamp to see the exact `AuthorizationPermissionMismatch` and which principal ID was presented — and
> that tells me immediately whether it's the wrong identity or a missing role. That's a two-minute
> diagnosis instead of an hour of guessing, and it only works because everything is in one workspace."

---

## Section 7 — Assumptions & Constraints

The assessment says: *"If you cannot deploy a specific component because of subscription/tenant
limitations, provide the intended IaC/design and clearly document what was not validated."*

**This clause is your safety net. Use it deliberately and honestly.** Put a section exactly like this in
your README:

> ### What was and was not validated
>
> **Validated:** `terraform fmt`, `terraform validate`, `tflint`, `helm lint`, `helm template` against
> both overlays, `kubeconform` on the rendered manifests, and `shellcheck` on the scripts. Output
> captured in `docs/evidence/`.
>
> **Not deployed to Azure.** The design was not applied end-to-end against a live subscription. The
> components most likely to need adjustment on a first real apply, and why:
> - **Ephemeral OS disk sizing** — requires a VM SKU with local temp storage; `Standard_D2s_v5` does not
>   qualify and must become `Standard_D2ds_v5`.
> - **Global name uniqueness** — the ACR and storage account names are deterministic and will collide;
>   they need a random or subscription-derived suffix.
> - **AMPLS `PrivateOnly`** — this affects every VNet resolving Azure Monitor through the shared private
>   DNS zones, so it needs validating against the wider tenant, not just this platform.
> - **Azure Policy in Deny mode** — needs an Audit-mode compliance pass before enforcement.
>
> **Known defects**, with severity and intended fix: *[link to docs/02-code-review-findings.md]*.

> **Why this section is worth more than it costs.** Every engineer's first real apply of a design this
> size surfaces things. Saying which things you *expect* to surface, and why, demonstrates that you
> understand the system deeply enough to predict its failure points. Claiming it all works when it
> doesn't is the only version of this that actually hurts you.

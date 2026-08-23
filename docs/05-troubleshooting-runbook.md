# 05 — Troubleshooting Scenarios

> The assessment demands a specific structure for each: **symptoms → hypotheses → evidence/commands →
> root cause → remediation → prevention.** Use exactly that structure in the room. It signals discipline
> before you've said anything technical.
>
> **The meta-skill being tested is bisection.** For every scenario, the interviewer wants to see you
> split the problem space in half with one decisive test rather than checking twenty things at random.
> Before you type a command, say what it will tell you *either way*:
>
> > "I'll run `nslookup` first. If it returns a 10.x address, DNS is fine and this is identity or
> > network policy. If it returns a public IP, it's DNS and I stop looking anywhere else."
>
> That one sentence is worth more than the command.

---

## The universal opening

Whatever the scenario, start here:

1. **Blast radius.** One pod, one node, one zone, or everything? A single pod points at scheduling or
   identity; everything points at a shared dependency or a change.
2. **Timeline.** When did it start, and what changed just before? `helm history`, the Activity Log, and
   `kubectl get events --sort-by=.lastTimestamp`. The large majority of incidents are caused by a change
   in the preceding hour.
3. **Did it ever work?** A brand-new deployment that never worked is a *configuration* problem. A
   working system that broke is a *change* or a *dependency* problem. These have almost no diagnostic
   overlap, and picking the wrong one wastes the first twenty minutes.

---

# Scenario 1 — Storage returns `403 AuthorizationFailure`

> *"The application can resolve the Storage FQDN and reaches the service, but Blob operations return 403.
> Explain how you distinguish identity/RBAC issues from network/private-endpoint issues and what you
> would verify first."*

## The key insight — lead with this

> "The premise already tells me a great deal. If the app **resolves the FQDN and reaches the service**,
> and the service **returns a 403**, then the network path is working. A 403 is an *application-layer HTTP
> response from Azure Storage* — to produce one, the TCP connection completed, TLS completed, and the
> request was parsed. A network or private-endpoint fault does not produce 403s; it produces connection
> timeouts, connection refused, or DNS failures. **So this is an identity or authorisation problem, and I
> can deprioritise the entire network layer immediately.**
>
> The one exception I'd rule out fast, because it's the only way network config produces a 403: the
> storage firewall. If `default_action = "Deny"` and the request arrives from an IP that isn't permitted —
> for example over a public path rather than the private endpoint — Azure returns
> `403 AuthorizationFailure` with the reason `IPAuthorizationFailure`. **So the very first thing I check
> is the error subcode, because it splits network-ACL from RBAC in one step.**"

## The distinguishing table — memorise this

| Error code in the 403 body | What it actually means | Where to look |
|---|---|---|
| `AuthorizationPermissionMismatch` | Identity is valid, **RBAC role is missing or wrong scope** | Azure role assignments |
| `AuthorizationFailure` / `IPAuthorizationFailure` | **Network ACL** rejected the source IP | Storage `network_rules`, private endpoint, source path |
| `InvalidAuthenticationInfo` | Malformed or expired token, or clock skew on the node | Token acquisition, node NTP |
| `AuthenticationFailed` | Token audience/issuer wrong | Wrong resource scope requested |
| `KeyBasedAuthenticationNotPermitted` | Shared key used while `shared_access_key_enabled = false` | The app is using a connection string, not Entra |
| `AccountIsDisabled` | Account-level | Rare; check the account state |

## Hypotheses, most to least likely

| # | Hypothesis | Cheapest test |
|---|---|---|
| **H1** | **No RBAC role assignment on the workload identity** | `az role assignment list --assignee <clientId> --scope <storageId>` — empty means found it |
| H2 | Wrong role — e.g. `Reader` (control plane) instead of `Storage Blob Data Contributor` (data plane) | Same command, check the role name |
| H3 | Role assigned at the wrong scope — e.g. on a different container, or on the RG when the account is elsewhere | Same command with `--all` |
| H4 | Federated credential subject mismatch → the pod never got a valid token at all | Look for `AADSTS70021` in pod logs |
| H5 | RBAC propagation delay (up to ~5 min, occasionally longer) | Was the assignment created in the last 10 minutes? |
| H6 | Storage network ACL rejecting the source | Error subcode is `IPAuthorizationFailure` |
| H7 | App is using a shared key that has been disabled | Error subcode is `KeyBasedAuthenticationNotPermitted` |

## Evidence — the exact commands

**Step 1 — get the real error, not the SDK's paraphrase.**

```bash
NS=banking-api; POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=banking-application -o name | head -1)
kubectl -n $NS logs $POD --tail=200 | grep -iE "403|Authoriz|AADSTS|ErrorCode"
```

The SDK usually wraps the real code. `x-ms-error-code` in the response header is the ground truth.

**Step 2 — confirm the identity the pod actually has.** This is the step people skip.

```bash
# Is the webhook injection present at all?
kubectl -n $NS get pod ${POD#pod/} -o jsonpath='{.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep AZURE
# Expect: AZURE_CLIENT_ID  AZURE_TENANT_ID  AZURE_FEDERATED_TOKEN_FILE  AZURE_AUTHORITY_HOST
# MISSING => the pod label azure.workload.identity/use is absent. Stop here; that's the bug.

kubectl -n $NS exec ${POD#pod/} -- printenv AZURE_CLIENT_ID

# Decode the projected token and read its claims — sub, aud, iss must match the FIC exactly
kubectl -n $NS exec ${POD#pod/} -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud, iss, exp}'
# sub MUST equal system:serviceaccount:banking-api:banking-api
# aud MUST equal api://AzureADTokenExchange
```

**Step 3 — check Azure's side.**

```bash
SA_ID=$(az storage account show -n sanonprod01 -g rg-nonprod-iac --query id -o tsv)
CLIENT_ID=$(kubectl -n $NS exec ${POD#pod/} -- printenv AZURE_CLIENT_ID)
PRINCIPAL_ID=$(az identity list --query "[?clientId=='$CLIENT_ID'].principalId" -o tsv)

# THE decisive command
az role assignment list --assignee "$PRINCIPAL_ID" --scope "$SA_ID" --include-inherited -o table
# Expect: Storage Blob Data Contributor. Empty output = H1 confirmed.

# And check the federated credential matches the token's sub claim
az identity federated-credential list --identity-name id-aks-nonprod-iac -g rg-nonprod-iac \
  --query "[].{name:name, subject:subject, issuer:issuer}" -o table
```

**Step 4 — the authoritative server-side evidence (KQL).**

```kusto
StorageBlobLogs
| where TimeGenerated > ago(30m)
| where StatusCode == 403
| project TimeGenerated, OperationName, StatusText, AuthenticationType,
          RequesterObjectId, CallerIpAddress, Uri
| order by TimeGenerated desc
```

> "This query is the one that ends the argument. `RequesterObjectId` tells me **exactly which principal
> Azure saw** — so I can compare it against the identity I *think* the pod is using.
> `AuthenticationType` tells me whether it presented OAuth or a shared key. `CallerIpAddress` tells me
> whether it arrived via the private endpoint (a 10.101.x address) or over a public path. Those three
> fields distinguish all my hypotheses in one query."

**Step 5 — prove the network is fine (only if you still doubt it).**

```bash
kubectl -n $NS exec ${POD#pod/} -- getent hosts sanonprod01.blob.core.windows.net   # expect 10.101.1.x
kubectl run nettest -n $NS --rm -it --restart=Never --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
  -- curl -sv --max-time 5 https://sanonprod01.blob.core.windows.net/ 2>&1 | grep -E "Connected|HTTP/"
# "Connected to ... (10.101.1.4)" + any HTTP status => network fine, it IS authorisation
```

## Root cause (most likely, and the one in your repo today)

🔴 **The workload identity has no `Storage Blob Data Contributor` role assignment.**
`modules/storage-account` accepts `data_contributor_principal_ids`, but `main.tf` never passes
`module.identity.principal_id` to it, so the list is empty and zero role assignments are created.

The pod authenticates successfully (federation works), gets a valid Entra token, and is then correctly
denied because it has no data-plane permission. **Authentication succeeded; authorisation failed.**

## Remediation

**Immediate (minutes):**
```bash
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$SA_ID"
# Wait up to 5 minutes for propagation, then restart pods so the SDK re-acquires cleanly
kubectl -n $NS rollout restart deploy/banking-application
```

**Permanent — fix it in code, not in the portal:**
```hcl
module "storage" {
  # ...
  data_contributor_principal_ids = [module.identity.principal_id]
}
```

> **Always say this:** *"The portal fix is the incident response. The Terraform fix is the resolution.
> If I only do the first one, the next `terraform apply` doesn't remove it — role assignments made outside
> Terraform aren't in state — but the next fresh environment has the same bug. Config drift where the
> running system is more correct than the code is its own incident waiting to happen."*

## Prevention

1. **Make the role assignment part of the identity module**, so an identity is never created without its
   grants — you can't forget what's structurally coupled.
2. **Scope to the container, not the account**, for genuine least privilege:
   `scope = "${sa.id}/blobServices/default/containers/${var.cache_container_name}"`.
3. **A readiness probe that checks Blob** (which the design has) turns this from "users get 500s" into
   "the pod never becomes Ready and the deployment fails" — the failure surfaces at deploy time, not in
   production traffic.
4. **A smoke test that asserts `X-Cache: HIT` on the second call** (which the design has) proves the
   *write* path works too, not just the read.
5. **Alert on any Blob 403.** Not a rate — any. In a healthy system the count is exactly zero.
6. **A Terraform `check` block** asserting every workload identity has at least one data-plane role
   assignment.
7. **`shared_access_key_enabled = false`** so a "fix" by falling back to a connection string is
   impossible.

---

# Scenario 2 — Storage DNS resolves incorrectly

> *"A Private Endpoint exists, but an AKS pod cannot resolve the expected Storage private address.
> Explain how you verify CoreDNS, VNet DNS settings, Private DNS zone existence/linking, A records and
> any custom DNS/forwarding."*

## The key insight

> "There are two distinct failure shapes and they need different investigations.
>
> **Shape A: it resolves, but to a public IP.** That means DNS worked end to end — it just didn't hit the
> private zone. So it's a zone linkage, zone name, or A record problem. This is by far the most common.
>
> **Shape B: it doesn't resolve at all — NXDOMAIN or timeout.** That's CoreDNS, the forward path, or a
> custom DNS server. Very different.
>
> So my first command isn't a check, it's a **classifier**. And critically, I need to know what the
> *correct* answer looks like: a private endpoint lookup should return a **CNAME to the `privatelink`
> name**, then an A record with a 10.x address. If I see the public name resolving straight to a public IP
> with no CNAME, that's not a private endpoint problem — that private endpoint doesn't exist."

## Follow the resolution path in order, and stop at the first break

```bash
NS=banking-api; POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=banking-application -o name | head -1)
SA=sanonprod01
```

**Step 0 — classify.**
```bash
kubectl -n $NS exec ${POD#pod/} -- nslookup $SA.blob.core.windows.net
# Shape A: returns a public IP (e.g. 20.x / 52.x)     -> go to Step 3
# Shape B: NXDOMAIN or timeout                        -> go to Step 1
# Correct: CNAME -> $SA.privatelink.blob.core.windows.net, A 10.101.1.x
```

**Step 1 — the pod's own resolver config.**
```bash
kubectl -n $NS exec ${POD#pod/} -- cat /etc/resolv.conf
# nameserver 172.16.0.10   <- must equal dns_service_ip, and be inside service_cidr
# search banking-api.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
```
> "`ndots:5` is worth knowing about. Any name with fewer than 5 dots gets the search domains appended
> first, so `sanonprod01.blob.core.windows.net` — four dots — generates four failed lookups before the
> absolute one. That's a latency problem, not a correctness one, but it's why people see slow DNS in
> Kubernetes and it's fixed with a trailing dot or a `dnsConfig` override."

**Step 2 — is CoreDNS healthy and where does it forward?**
```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide       # all Running, spread across nodes?
kubectl -n kube-system get cm coredns -o yaml                     # custom overrides?
kubectl -n kube-system get cm coredns-custom -o yaml 2>/dev/null  # AKS's supported override point
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100 | grep -iE "SERVFAIL|error|timeout"

# Ask CoreDNS directly, bypassing the app
kubectl run dnstest -n $NS --rm -it --restart=Never --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
  -- bash -c "dig +short @172.16.0.10 $SA.blob.core.windows.net; \
              dig +short @168.63.129.16 $SA.blob.core.windows.net"
```
> "**This is the decisive bisection.** If Azure DNS at `168.63.129.16` returns the private IP but CoreDNS
> at `172.16.0.10` doesn't, the problem is inside the cluster — a `coredns-custom` override or a stub
> domain. If **both** return the public IP, CoreDNS is innocent and the problem is at the Azure DNS layer:
> zone linkage. That's one command that eliminates half the possibilities."

**Step 3 — VNet DNS settings.**
```bash
az network vnet show -g rg-nonprod-iac -n vnet-spoke-nonprod --query dhcpOptions.dnsServers
# [] or null  = Azure-provided DNS (168.63.129.16) -> correct for this design
# ["10.x.x.x"] = CUSTOM DNS. This is the #1 cause of Shape A in real estates.
```
> "If the VNet has custom DNS servers set — a corporate DNS estate, a domain controller, a Palo Alto —
> then the nodes forward there instead of to Azure DNS. That custom server has **no visibility of Azure
> private DNS zones**, so it returns the public record. The fix is a **conditional forwarder** on the
> custom server for `privatelink.blob.core.windows.net` pointing at either `168.63.129.16` (only works
> from inside a VNet) or, properly, an **Azure DNS Private Resolver inbound endpoint**. This is the single
> most common private endpoint failure in enterprises, and I'd check it early precisely because it's
> environmental rather than something in my code."

**Step 4 — does the zone exist, and is it linked to *this* VNet?**
```bash
az network private-dns zone list -g rg-nonprod-iac-hub -o table
# Must be exactly: privatelink.blob.core.windows.net
# A typo, or the non-privatelink name, silently does nothing.

az network private-dns link vnet list \
  -g rg-nonprod-iac-hub -z privatelink.blob.core.windows.net -o table
# MUST include a link to vnet-spoke-nonprod. Hub-only linkage is a classic miss:
# the agent resolves fine, the pods don't.
```

**Step 5 — is there an A record, and does it point at the right IP?**
```bash
az network private-dns record-set a list \
  -g rg-nonprod-iac-hub -z privatelink.blob.core.windows.net -o table
# Expect a record named 'sanonprod01' -> 10.101.1.x

# Cross-check against the actual private endpoint NIC
az network private-endpoint show -g rg-nonprod-iac -n pe-blob-sanonprod01 \
  --query "customDnsConfigs[].{fqdn:fqdn, ips:ipAddresses}" -o json
```

**Step 6 — is the private endpoint connection actually approved?**
```bash
az network private-endpoint-connection list --id "$SA_ID" \
  --query "[].{name:name, state:properties.privateLinkServiceConnectionState.status}" -o table
# Must be "Approved". A Pending manual connection resolves fine and refuses traffic.
```

## Likely root causes, ranked

| Rank | Root cause | Signature |
|---|---|---|
| 1 | **Private DNS zone not linked to the spoke VNet** | Resolves to public IP; zone exists; link list missing the spoke |
| 2 | **Custom DNS on the VNet with no conditional forwarder** | `dhcpOptions.dnsServers` non-empty; public IP returned |
| 3 | **A record missing** because the PE was created without a `private_dns_zone_group` | Zone linked, record-set list empty |
| 4 | 🔴 **Duplicate/conflicting A records** — see finding P1-2: your storage and KV modules create both a `private_dns_zone_group` **and** a manual `azurerm_private_dns_a_record`, in a **different resource group** from the zone | Apply fails, or a stale record points at a dead IP after a PE recreate |
| 5 | Zone name typo, or the wrong regional zone (e.g. `privatelink.westeurope.azmk8s.io` hardcoded while deploying to `northeurope`) | 🔴 Also present in your tfvars |
| 6 | Stale DNS cache in the app process or CoreDNS (TTL 300s) | Fixed itself after 5 minutes |
| 7 | CoreDNS pods unhealthy or evicted onto a saturated node | Intermittent SERVFAIL across many services, not just storage |

## Remediation

```bash
# Root cause 1 — link the zone
az network private-dns link vnet create -g rg-nonprod-iac-hub \
  -z privatelink.blob.core.windows.net -n link-spoke \
  -v /subscriptions/.../virtualNetworks/vnet-spoke-nonprod -e false

# Root cause 3 — attach a DNS zone group to the existing private endpoint (do NOT hand-write the record)
az network private-endpoint dns-zone-group create -g rg-nonprod-iac \
  --endpoint-name pe-blob-sanonprod01 -n dns-blob \
  --private-dns-zone privatelink.blob.core.windows.net --zone-name blob
```
Then force re-resolution: `kubectl -n kube-system rollout restart deploy/coredns` and restart the app
pods (many SDKs cache DNS for the process lifetime).

**Terraform fix for root cause 4:** delete the `azurerm_private_dns_a_record` resources from
`modules/storage-account` and `modules/key-vault` entirely. The `private_dns_zone_group` on the private
endpoint is the correct, lifecycle-bound mechanism.

## Prevention

1. **Never hand-write A records for private endpoints.** Always `private_dns_zone_group`. It survives PE
   recreation; a manual record silently goes stale and points at a dead IP.
2. **Link every zone to every VNet that needs it**, driven by a map — as `modules/private-dns` does — so
   adding a spoke can't forget a zone.
3. **Azure Policy: `Configure private endpoints to use private DNS zones`** in `DeployIfNotExists` mode.
   This auto-remediates every private endpoint in the estate. **It is the single highest-value control
   for this failure class** and worth naming specifically.
4. **A synthetic DNS check** in the readiness probe or as a CronJob: resolve each dependency FQDN and
   assert the answer is RFC1918. Alert if not. That turns a silent misconfiguration into a page.
5. **Derive the regional zone name** — `"privatelink.${var.location}.azmk8s.io"` — never hardcode it.
6. **Alert on Azure Firewall DNS proxy logs** for resolutions of your own service FQDNs returning public
   addresses.

---

# Scenario 3 — `ImagePullBackOff`

> *"Explain how you verify the AKS identity/permissions, ACR network access, Private DNS,
> registry/data endpoint connectivity and the image reference. Include the checks you would use to
> isolate identity vs network vs image/tag problems."*

## The key insight

> "`ImagePullBackOff` is a *symptom*, and the real information is in the event message — the four common
> causes have completely distinct signatures. So the first command isn't a check of anything, it's just
> reading the error properly. And the three-way split the question asks for maps directly onto the three
> things that must succeed in order: **resolve → connect → authenticate → find the tag.** I test them in
> that order because each one is a precondition for the next."

## Read the error first — it usually names the cause

```bash
kubectl -n banking-api describe pod <pod> | sed -n '/Events:/,$p'
```

| Message contains | Category | Meaning |
|---|---|---|
| `401 Unauthorized` / `unauthorized: authentication required` | **Identity** | The kubelet has no `AcrPull` |
| `403 Forbidden` / `denied: requested access to the resource is denied` | **Identity** | Authenticated but not authorised, or repo-scoped token limits |
| `dial tcp ... i/o timeout` / `connection refused` | **Network** | Private endpoint, NSG, firewall, or route |
| `no such host` / `server misbehaving` | **DNS** | Zone not linked, or wrong registry name |
| `manifest unknown` / `not found` | **Image/tag** | Tag doesn't exist in *this* registry |
| `failed to pull and unpack ... 404` on a `*.data.` host | **Network** | Registry endpoint OK, **data endpoint** blocked |
| `ErrImageNeverPull` | **Config** | `imagePullPolicy: Never` with no local image |

> "That last-but-one row is the subtle one. ACR splits pulls across two endpoints: `<registry>.azurecr.io`
> for the manifest and `<registry>.<region>.data.azurecr.io` for the blob layers. Both are covered by the
> `privatelink.azurecr.io` zone, but if the private endpoint or DNS only handles the registry endpoint,
> you get a very confusing failure where the manifest resolves fine and the layer download times out.
> That is the ACR private-link gotcha and it's worth naming unprompted."

## Isolate: identity vs network vs image

**Test A — Identity.** Ask Azure directly, no cluster involved.
```bash
KUBELET_ID=$(az aks show -g rg-nonprod-iac -n aks-nonprod-iac \
  --query identityProfile.kubeletidentity.objectId -o tsv)
ACR_ID=$(az acr show -n acrnonprod --query id -o tsv)

az role assignment list --assignee "$KUBELET_ID" --scope "$ACR_ID" -o table
# Expect: AcrPull. Empty = identity problem, confirmed. Stop here.
```
> "Note this is the **kubelet** identity, not the cluster's control-plane identity. They're different
> managed identities and granting `AcrPull` to the wrong one is an extremely common mistake — the cluster
> creates fine, everything looks right, and images never pull."

Azure's own diagnostic, which does the whole chain server-side:
```bash
az aks check-acr --resource-group rg-nonprod-iac --name aks-nonprod-iac --acr acrnonprod.azurecr.io
```

**Test B — Network + DNS.** From a pod on the same node, in the same network position as the kubelet.
```bash
kubectl run acrtest -n banking-api --rm -it --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 -- bash

getent hosts acrnonprod.azurecr.io                       # expect 10.101.1.x
getent hosts acrnonprod.westeurope.data.azurecr.io       # expect 10.101.1.x  <- the one people miss
curl -sv --max-time 5 https://acrnonprod.azurecr.io/v2/ 2>&1 | grep -E "Connected|HTTP/"
# "Connected to ... (10.101.1.x)" + "HTTP/1.1 401 Unauthorized"
#   -> 401 here is GOOD: network and DNS work, and /v2/ requires auth as expected.
```
> "A 401 from `/v2/` is the *success* condition for this test. It proves resolve-and-connect worked. If I
> get a timeout, it's network; if I get `no such host`, it's DNS; if I get 401, both layers are fine and
> I go back to identity."

**Test C — Image/tag.**
```bash
kubectl -n banking-api get deploy banking-application \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# e.g. acrprod.azurecr.io/banking-application:20260822.3-a1b2c3d

# Does that tag exist in THAT registry?
az acr repository show-tags -n acrprod --repository banking-application -o table
az acr manifest list-metadata -n acrprod -r banking-application:20260822.3-a1b2c3d
```

**The infrastructure-level checks:**
```bash
az acr show -n acrnonprod --query "{public:publicNetworkAccess, sku:sku.name, admin:adminUserEnabled}"
az network private-endpoint-connection list --id "$ACR_ID" \
  --query "[].properties.privateLinkServiceConnectionState.status" -o tsv   # Approved
az network private-dns record-set a list -g rg-nonprod-iac-hub -z privatelink.azurecr.io -o table
# ACR creates TWO records: acrnonprod AND acrnonprod.westeurope.data
```

**And the firewall — a genuinely subtle one:**
```kusto
AZFWApplicationRule
| where TimeGenerated > ago(1h)
| where Fqdn has "mcr.microsoft.com" or Fqdn has "azurecr.io"
| where Action == "Deny"
| project TimeGenerated, SourceIp, Fqdn, Action
```
> "The images that fail may not be mine. If the *node image* or an AKS system pod can't pull from
> `mcr.microsoft.com`, that's the `AzureKubernetesService` FQDN tag missing from the firewall policy, and
> the symptom is `ImagePullBackOff` on kube-system pods rather than on my app. Different root cause,
> identical symptom."

## Root cause (the one in your repo today)

🔴 **The image was never pushed to the prod registry.** Finding P1-6: `stage-build-image.yml` runs once
with `acrName: $(nonProdAcrName)`, so the image exists only in `acrnonprod`. The prod deploy sets
`image.registry` from the **prod** Terraform outputs → `acrprod.azurecr.io/banking-application:<tag>`,
which does not exist. Signature: `manifest unknown` — an image/tag problem, not identity or network.

Secondary candidate: the `imageTag` containing spaces (finding P1-7) produces an invalid reference and
fails at `docker tag` time in the build, so nothing is pushed at all.

## Remediation

```bash
# Immediate: promote by digest (preserves the exact bitstream that passed non-prod)
DIGEST=$(az acr manifest list-metadata -n acrnonprod -r banking-application \
  --query "[?tags[?@=='20260822.3-a1b2c3d']].digest | [0]" -o tsv)
az acr import --name acrprod \
  --source "acrnonprod.azurecr.io/banking-application@${DIGEST}" \
  --image "banking-application:20260822.3-a1b2c3d"

kubectl -n banking-api rollout restart deploy/banking-application

# If it's identity instead:
az role assignment create --assignee-object-id "$KUBELET_ID" \
  --assignee-principal-type ServicePrincipal --role AcrPull --scope "$ACR_ID"
# then delete the stuck pods so kubelet retries immediately rather than waiting out the backoff
```

## Prevention

1. **Add an `az acr import` promotion step** to the pipeline before the prod deploy — server-side copy,
   no re-push, **digest preserved**.
2. **Deploy by digest, not tag.** Tags are mutable; a digest is the artifact. Resolve tag→digest once in
   the build stage and pass `image.digest` through Helm.
3. **A pre-deploy gate:** `az acr manifest list-metadata` on the target registry before running
   `helm upgrade`. Fail loudly and early with a clear message rather than as `ImagePullBackOff` twelve
   minutes later.
4. **Wire `AcrPull` in Terraform** from `module.aks.kubelet_identity_object_id` — which your ACR module
   already does correctly. Point that out as something you got right.
5. **Alert on `ImagePullBackOff`/`ErrImagePull`** from `KubeEvents`. It is always actionable and never a
   false positive.
6. **Run `az aks check-acr` as a pipeline smoke test** after infrastructure changes.
7. **`--atomic` on `helm upgrade`** means a failed image pull rolls the release back automatically
   instead of leaving a half-deployed state — you already have this.

---

# Scenario 4 — Deployment pipeline cannot reach AKS

> *"The Azure DevOps pipeline can authenticate to Azure but kubectl/Helm cannot reach the private AKS
> API. Explain the network path, agent placement, DNS and identity checks you would perform."*

## The key insight

> "The premise splits the problem for me: **authentication to Azure works, connection to the API server
> doesn't.** `az aks get-credentials` is an ARM call against `management.azure.com` — a public control
> plane endpoint — so it succeeds from anywhere. `kubectl` then talks to
> `<cluster>.privatelink.westeurope.azmk8s.io`, which is only resolvable and reachable from inside a
> linked VNet. **So 'az works but kubectl doesn't' is the exact signature of a networking or DNS problem,
> not an identity one** — and the single most likely cause is that the job ran on a Microsoft-hosted
> agent instead of the private pool.
>
> There is one identity-shaped failure that hides here though, so I'd rule it out early: a **403 from the
> API server** rather than a timeout. That means the network is fine and Azure RBAC is missing —
> completely different fix. So my first question is: *timeout or 403?*"

## The network path, stated plainly

```
Agent VM (10.101.2.x, snet-pipeline-agents)
  -> NSG on agent subnet: outbound 443 allowed
  -> resolves <cluster>.privatelink.westeurope.azmk8s.io via 168.63.129.16
       -> private DNS zone privatelink.westeurope.azmk8s.io, LINKED to the spoke VNet
       -> A record -> private endpoint IP in snet-private-endpoints (10.101.1.x)
  -> NSG on the private-endpoint subnet: inbound 443 from the agent subnet allowed
  -> AKS API server
```

Every arrow is a place it can break, and each has a distinct test.

## Checks, in bisection order

**Check 1 — which agent actually ran the job?** (Answers it 80% of the time.)
```yaml
pool:
  name: $(privatePoolName)     # NOT vmImage: ubuntu-latest
```
```bash
# In the job:
echo "Agent: $(Agent.Name)  Pool: $(Agent.MachineName)"
hostname -I     # must be 10.101.2.x
```
> "A Microsoft-hosted agent has no route to 10.101.1.x and no link to my private DNS zones. It resolves
> the cluster's privatelink name via public DNS, gets NXDOMAIN or a public address, and times out. If the
> `pool:` was overridden — or a template default leaked through, or someone added a job without a `pool`
> block — that's the entire bug."

**Check 2 — timeout or 403?**
```bash
kubectl cluster-info 2>&1 | head -5
kubectl get nodes -v=6 2>&1 | tail -20     # -v=6 shows the URL and status code
```
| Symptom | Layer | Next step |
|---|---|---|
| `dial tcp 10.101.1.x:443: i/o timeout` | Network — resolves but can't connect | Check 4 (NSG/route) |
| `no such host` / `server misbehaving` | DNS | Check 3 |
| `Unable to connect to the server: ... Forbidden` / `User cannot list resource "nodes"` | **Identity/RBAC** | Check 5 |
| `error: You must be logged in` / `AADSTS` | Token acquisition | Check 5 |

**Check 3 — DNS.**
```bash
API_FQDN=$(az aks show -g rg-nonprod-iac -n aks-nonprod-iac --query privateFqdn -o tsv)
nslookup "$API_FQDN"                 # expect 10.101.1.x
cat /etc/resolv.conf                 # expect nameserver 168.63.129.16
az network private-dns link vnet list -g rg-nonprod-iac-hub \
  -z privatelink.westeurope.azmk8s.io -o table    # must include the SPOKE vnet
```
> "Also check `az aks show --query fqdn` — if `privateFqdn` is empty but a public `fqdn` exists, the
> cluster isn't actually private. And if `privateFqdn` resolves to a **public** address, the DNS zone
> isn't linked and it fell through to public resolution."

**Check 4 — connectivity and routing.**
```bash
nc -zv 10.101.1.x 443              # or: timeout 5 bash -c '</dev/tcp/10.101.1.x/443' && echo open
ip route get 10.101.1.4            # which interface/next hop?
curl -sk --max-time 5 https://$API_FQDN/version
```
Azure-side:
```bash
# Effective NSG rules on the agent NIC — the authoritative answer, not the rule list
az network nic list-effective-nsg --ids <agent-nic-id> -o json | jq '.value[].effectiveSecurityRules[]
  | select(.destinationPortRange=="443" or .destinationPortRange=="0-65535")'
# Effective routes — is 10.101.1.0/24 being forced to the firewall by mistake?
az network nic show-effective-route-table --ids <agent-nic-id> -o table
```
> "Two specific traps here. First, my **private-endpoint NSG** allows inbound 443 only from the AKS and
> agent subnets — if the agent subnet CIDR changed, or the rule was never applied (which in my repo it
> wasn't, finding P1-4), that inbound is denied. Second, a `0.0.0.0/0` UDR to the firewall on the *agent*
> subnet would break private endpoint traffic if it caught the PE range — though Azure's `/32` system
> route for the PE normally takes precedence, so the more likely version of this is asymmetric routing."

**Check 5 — identity and kubelogin.**
```bash
az account show --query "{user:user.name, type:user.type, sub:id}"
kubectl config current-context
kubectl config view --minify -o jsonpath='{.users[0].user.exec.args}' ; echo
# Must show kubelogin with 'azurecli' (or workloadidentity) mode

SP_ID=$(az account show --query user.name -o tsv)
CLUSTER_ID=$(az aks show -g rg-nonprod-iac -n aks-nonprod-iac --query id -o tsv)
az role assignment list --assignee "$SP_ID" --scope "$CLUSTER_ID" -o table
# Expect BOTH:
#   Azure Kubernetes Service Cluster User Role   <- permits get-credentials
#   Azure Kubernetes Service RBAC Writer         <- permits deploying
```
> "That two-role requirement catches people. **Cluster User** lets you download a kubeconfig; it grants no
> in-cluster permissions at all. **RBAC Writer** grants the actual Kubernetes verbs. Having only the first
> gives you a working kubeconfig and 403 on every command — which looks like a network problem until you
> read the error carefully. My Terraform assigns both, via `deployer_principal_ids`.
>
> And `kubelogin convert-kubeconfig -l azurecli` is mandatory here. Without it the kubeconfig contains a
> device-code auth flow that prompts for interactive login — which in a pipeline means the job hangs until
> it times out. That's a very recognisable failure: no error, just a hang."

## Root causes, ranked

| Rank | Root cause | Signature |
|---|---|---|
| 1 | Job ran on a Microsoft-hosted agent | `Agent.Name` is a hosted image; `no such host` or timeout |
| 2 | AKS private DNS zone not linked to the agent's VNet | `privateFqdn` resolves to public or NXDOMAIN |
| 3 | NSG blocking agent→PE subnet on 443 | Resolves to 10.x, TCP timeout |
| 4 | Missing `Cluster User` **or** `RBAC Writer` role | **403**, not a timeout |
| 5 | `kubelogin convert-kubeconfig` not run | Job hangs on interactive login prompt |
| 6 | `local_account_disabled = true` + `--admin` flag used | `az aks get-credentials --admin` fails outright |
| 7 | Agent VM down (SPOF, finding P2-10) | Job never starts; queued forever |
| 8 | Role assignment propagation delay | Worked 10 minutes later with no change |

## Remediation & prevention

**Immediate:** correct the `pool:`, link the DNS zone, or add the missing role assignment.

**Prevention — and these are the answers worth giving:**

1. **A pre-flight job** at the start of every deploy stage: assert `hostname -I` is in the expected CIDR,
   `nslookup` the private FQDN and assert an RFC1918 answer, and `kubectl auth can-i create deployments
   -n <ns>`. Three cheap checks that fail in 5 seconds with a clear message instead of timing out in 10
   minutes with a confusing one.
2. **Never allow `vmImage:` anywhere in these templates** — enforce it with a pipeline decorator or a
   policy check on the YAML.
3. **Make the agent pool highly available** — VMSS across zones, or Managed DevOps Pools. A single agent
   VM means an incident where you cannot deploy the fix.
4. **Document the break-glass path**: how to deploy from a jumpbox in the VNet, or via Azure Cloud Shell
   with VNet integration, if the agent pool is entirely unavailable. See
   [08-operational-runbook.md](08-operational-runbook.md).
5. **Alert on agent pool health** — offline agents, queue depth.

---

# Scenario 5 — Helm deployment succeeds but the application is unhealthy

> *"The pipeline reports a successful Helm release, but the API pods are restarting or never become
> Ready. Explain how you would use Helm status/history, rendered manifests, Kubernetes events, pod logs,
> readiness/liveness probes, configuration values, ServiceAccount/Workload Identity configuration and
> Azure dependency checks to isolate the issue. Describe how you would decide between fixing forward and
> rolling back the Helm release."*

## The key insight

> "'Helm reported success' is itself a diagnostic clue. Without `--wait`, Helm's definition of success is
> 'the API server accepted my manifests' — it says nothing about whether the pods ever started. My
> pipeline uses `--wait --atomic`, so a genuinely stuck rollout should have *failed* and auto-rolled-back.
> If Helm reported success **and** the pods are unhealthy, that narrows it sharply to:
>
> - the pods became Ready and then degraded afterwards — so this is a **runtime** problem, not a startup
>   one; or
> - the readiness probe is too permissive and reports Ready when the app can't actually serve; or
> - `--wait` isn't actually applied on this path.
>
> That distinction — *did it ever become Ready?* — is my first question, because it splits config errors
> from runtime dependency failures, and those have almost no diagnostic overlap."

## Investigation, in order

**Step 1 — the release itself.**
```bash
NS=banking-api; REL=banking-application
helm status "$REL" -n "$NS"
helm history "$REL" -n "$NS" --max 10
helm get values "$REL" -n "$NS"            # the values ACTUALLY applied — merged, post --set
helm get manifest "$REL" -n "$NS" > /tmp/live.yaml
helm get notes "$REL" -n "$NS"
```
> "`helm get values` is the one people skip and it's the most valuable. It shows the **merged, effective**
> values — base plus overlay plus every `--set`. A huge proportion of 'it works in non-prod' incidents are
> a `--set` that silently didn't apply, or applied with an empty string because a pipeline variable was
> unset. `--set config.storageAccountName=""` renders a ConfigMap with an empty value and the app fails on
> its first Azure call with a confusing error. Diffing `helm get values` against what I expected is a
> thirty-second check that ends a lot of investigations."

**Step 2 — is the deployed manifest what I intended?**
```bash
helm template "$REL" charts/banking-application -n "$NS" \
  --values charts/banking-application/values-prod.yaml \
  --set image.registry=acrprod.azurecr.io --set image.tag=... \
  --set workloadIdentity.clientId=... > /tmp/expected.yaml
diff <(yq -P 'sort_keys(..)' /tmp/expected.yaml) <(yq -P 'sort_keys(..)' /tmp/live.yaml)
```

**Step 3 — pod state, and read it precisely.**
```bash
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" describe pod <pod>
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -40
```

| What you see | What it means |
|---|---|
| `Pending` + `FailedScheduling` | No node matches — `nodeSelector: workload=application` with no user pool, taints, insufficient resources, zone constraints |
| `ContainerCreating` stuck | Volume mount, CSI driver, or `SecretProviderClass` failing |
| `CrashLoopBackOff` + high restart count | The app is exiting. **Logs, and `--previous`** |
| `Running` but `0/1 Ready` | **Readiness probe failing** — the app is up but says it can't serve |
| `OOMKilled` in `lastState` | Memory limit too low, or a leak |
| `Error` exit code 1 immediately | Config error at startup — missing env var, bad value |
| `CreateContainerConfigError` | Referenced Secret or ConfigMap doesn't exist |

**Step 4 — logs, including the crashed instance.**
```bash
kubectl -n "$NS" logs <pod> --tail=200
kubectl -n "$NS" logs <pod> --previous --tail=200     # THE crash, not the current attempt
kubectl -n "$NS" logs -l app.kubernetes.io/instance="$REL" --all-containers --tail=50
```

**Step 5 — probes. Test them by hand.**
```bash
kubectl -n "$NS" port-forward <pod> 8080:8080 &
curl -sv http://localhost:8080/readyz   # what does it ACTUALLY return?
curl -sv http://localhost:8080/healthz
```
> "This is where the liveness/readiness distinction pays off. If `/healthz` returns 200 and `/readyz`
> returns 503, the process is fine and a **dependency** is broken — which is exactly what those probes are
> designed to tell me, and it means my design is working. The pod isn't crashlooping, it's correctly
> refusing traffic. If instead the pod is being *restarted* because of a dependency failure, that means
> the liveness probe is touching a dependency, which is a design bug that turns a downstream blip into a
> cluster-wide crashloop."

Also check the probe *configuration*, not just the endpoints: `initialDelaySeconds` too short for a slow
JVM/Node start, `timeoutSeconds: 3` too aggressive under load, `failureThreshold` too low for a flaky
dependency.

**Step 6 — Workload Identity, since that's this design's most likely failure.**
```bash
POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=banking-application -o name | head -1)

# a) Did the webhook fire? (Depends on the POD TEMPLATE label, not the Deployment label.)
kubectl -n "$NS" get pod ${POD#pod/} -o jsonpath='{.metadata.labels}' | jq
kubectl -n "$NS" get pod ${POD#pod/} -o jsonpath='{.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep AZURE

# b) SA annotation present and correct?
kubectl -n "$NS" get sa banking-api -o jsonpath='{.metadata.annotations}' | jq

# c) Token subject vs federated credential — THE mismatch check
kubectl -n "$NS" exec ${POD#pod/} -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | cut -d. -f2 | base64 -d | jq '{sub, aud, iss}'
az identity federated-credential list --identity-name id-aks-prod-iac -g rg-prod-iac \
  --query "[].{subject:subject, issuer:issuer}" -o table
# These two MUST match character for character.

# d) The webhook itself
kubectl -n kube-system get pods -l azure-workload-identity.io/system=true
kubectl -n "$NS" logs ${POD#pod/} | grep -E "AADSTS7002[0-9]|AADSTS700016"
```

| Error | Meaning |
|---|---|
| `AADSTS70021` | 🔴 **Subject mismatch** — finding P0-6 |
| `AADSTS700016` | Client ID wrong / app not found in tenant |
| `AADSTS700213` | Audience wrong (must be `api://AzureADTokenExchange`) |
| No `AZURE_*` env vars at all | Pod template label missing → webhook never fired |
| Valid token, then `403` from Storage | Federation fine, **RBAC missing** → Scenario 1 |

**Step 7 — Azure dependencies.**
```bash
kubectl -n "$NS" exec ${POD#pod/} -- getent hosts sanonprod01.blob.core.windows.net
az role assignment list --assignee "$PRINCIPAL_ID" --scope "$SA_ID" -o table
az storage account show -n sanonprod01 --query "{public:publicNetworkAccess, state:statusOfPrimary}"
```

## Fix forward or roll back? — the decision framework

**Say this as a framework, not a rule. That's what makes it a senior answer.**

> "The default is **roll back**, and the burden of proof is on fixing forward. Rolling back restores a
> state that is *known* to work; fixing forward ships an *untested* change into an already-degraded
> system, under time pressure, with a tired engineer. That asymmetry is the whole argument.
>
> **I roll back when** — and any one of these is sufficient — customers are impacted right now; I don't yet
> understand the root cause; the fix would take more than about fifteen minutes; the previous revision is
> known good; or it's outside business hours with a thin on-call.
>
> **I fix forward when** — and I want *all* of these to hold — the root cause is understood and the fix is
> genuinely one line, like a wrong environment variable; **or rollback is impossible or unsafe**, which is
> the important case. That happens when the release included an irreversible change: a database migration
> the old version can't read, a change to data in Blob, or an Azure resource change Terraform made that
> Helm can't revert. `helm rollback` only reverts Kubernetes objects — it does not touch state outside the
> release.
>
> **There's a third option people forget: neither.** If `--atomic` already rolled back, or if the pods are
> correctly refusing traffic via readiness while the old ReplicaSet still serves, I may have no active
> customer impact at all — in which case the right move is to *stop*, preserve evidence, and diagnose
> properly rather than take another action under pressure.
>
> **And whatever I choose, I capture evidence first.** My pipeline's failure step does this — pod state,
> deployment description, container logs and recent events — before it rolls anything back. The moment you
> roll back, the broken pods are gone and so is your ability to explain what happened. That's the step
> people skip and then regret in the post-mortem."

## Deciding matrix

| Situation | Action | Why |
|---|---|---|
| Pods CrashLoop, no traffic served, cause unknown | **Roll back now** | Impact is live, understanding is not |
| Readiness failing, old ReplicaSet still serving | **Pause, diagnose** | `maxUnavailable: 0` means no impact yet — use the time |
| Single wrong env var, understood, one-line fix | **Fix forward** | Faster than a rollback + re-deploy cycle |
| Release included a DB migration | **Fix forward** — rollback is unsafe | Old code can't read the new schema |
| `--atomic` already rolled back | **Neither — investigate** | System is already at last-known-good |
| Rolled back and *still* broken | **Escalate** — it's not the release | Look at a dependency or an infrastructure change |

## Prevention

1. **`--atomic --wait --timeout`** on every upgrade — you have this. Failure never leaves a half-state.
2. **Smoke tests gate the release**, and a failure rolls back — you have this too.
3. **Package the smoke test as a Helm test** (finding P2-8) so the acceptance criteria are versioned with
   the chart and a rollback restores that revision's definition of healthy.
4. **Chart-level `fail` guards** for invalid value combinations — you have one for `clientId`; extend it
   to assert the Workload Identity subject matches (finding P0-6). **Turn runtime failures into
   template-time failures.**
5. **A readiness probe that genuinely checks dependencies** so a broken deployment fails at deploy time
   rather than in production traffic.
6. **Progressive delivery** for real production: Flagger or Argo Rollouts doing a canary with automated
   metric analysis, so 5% of traffic sees the problem instead of 100%.
7. **Deploy by digest**, so "the same release" always means the same bits.
8. **Practise the rollback.** A rollback path you've never executed is a hypothesis, not a control. Run a
   game day.

---

# Quick reference — one-liners for the room

```bash
# What changed, and when?
helm history banking-application -n banking-api --max 10
az monitor activity-log list --resource-group rg-prod-iac --start-time 2026-08-22T00:00:00Z -o table

# Effective, merged Helm values (the #1 skipped check)
helm get values banking-application -n banking-api

# Did Workload Identity inject?
kubectl -n banking-api get pod <pod> -o jsonpath='{.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep AZURE

# What subject is the token actually presenting?
kubectl -n banking-api exec <pod> -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | cut -d. -f2 | base64 -d | jq .sub

# Is DNS returning a private IP?
kubectl -n banking-api exec <pod> -- getent hosts <resource>.blob.core.windows.net

# Bisect CoreDNS vs Azure DNS in one shot
dig +short @172.16.0.10 X ; dig +short @168.63.129.16 X

# Does the identity have the role?
az role assignment list --assignee <principalId> --scope <resourceId> --include-inherited -o table

# Full ACR pull-path diagnostic, server-side
az aks check-acr -g rg-prod-iac -n aks-prod-iac --acr acrprod.azurecr.io

# Can the pipeline identity actually do the thing?
kubectl auth can-i create deployments -n banking-api

# The crash, not the current attempt
kubectl -n banking-api logs <pod> --previous
```

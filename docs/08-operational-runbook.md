# 08 — Operational Runbook

> A named submission deliverable: *"Deployment, validation, common failure modes, Helm rollback/recovery
> and cleanup."*
>
> This doubles as the source material for your top-level `README.md` — which is currently one line and is
> the cheapest scored point in the assessment ([P2-1](02-code-review-findings.md#p2-1-readmemd-is-one-line)).
>
> **The success criterion the assessment states:** *"another engineer should be able to understand how the
> platform works, why it is secure, how it is deployed, how the application is packaged and released with
> Helm, and how to troubleshoot or roll back the platform without relying on undocumented tribal
> knowledge."* Everything below is written to satisfy exactly that sentence.

---

## 1. Prerequisites

### Tooling

| Tool | Version | Why pinned |
|---|---|---|
| Terraform | 1.9.5 | Matches the agent image and `pipelines/variables/common.yml` |
| Azure CLI | ≥ 2.60 | `az aks check-acr`, federated credential commands |
| kubectl | 1.30.5 | Within ±1 minor of the cluster |
| kubelogin | ≥ 0.1.4 | Entra auth to the private API server |
| Helm | 3.16.2 | Matches the agent image |
| jq, yq | any recent | Runbook commands below |

### Azure prerequisites

- A subscription per environment (recommended) with **Owner** on the target resource groups for the
  bootstrap, then reduced.
- **Entra groups** created and their object IDs supplied:
  `aks_admin_group_object_ids`, `aks_reader_group_object_ids`, `kv_admin_group_object_ids`.
- A **Terraform state storage account** per environment (referenced by `azurerm.tfbackend`) with
  versioning, soft delete, a private endpoint, `shared_access_key_enabled = false`, and Entra-only access.
- Sufficient **vCPU quota** in the target region for the node pools plus the agent VM.
- The features used require a **Premium ACR** — Basic/Standard cannot have private endpoints.

### Azure DevOps prerequisites

| Item | Setting |
|---|---|
| Service connections | `subscription-non-prod`, `subscription-prod` — **Workload Identity Federation**, not a secret |
| Agent pool | `private-selfhosted-linux`, matching `var.agent_pool_name` |
| Environments | `nonprod-environment`, `prod-environment` — prod with **2 required approvers** and a business-hours window |
| Branch policy on `main` | 2 reviewers, build validation on Validate + Security, no direct push, linear history |
| CODEOWNERS | `infra/` and `pipelines/` owned by the platform team |
| Service connection scoping | Restricted to this pipeline only, not open to the project |

### The one out-of-band secret

```bash
# The agent registration PAT. Terraform NEVER writes this value.
# Scope: Agent Pools (read, manage). Expiry: 7 days, with rotation automated.
az keyvault secret set \
  --vault-name kv-nonprod-iac \
  --name ado-agent-pat \
  --value "<PAT>" \
  --expires "$(date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ)"
```

---

## 2. Deployment

### 2.1 First-time bootstrap (chicken-and-egg)

> **Name this problem explicitly in the interview — it shows you've actually deployed private
> infrastructure rather than only written it.**

The circularity: the pipeline needs a self-hosted agent inside the VNet; the agent needs the VNet, the
Key Vault and the PAT secret; those are created by the pipeline. Something has to run first.

**Bootstrap sequence:**

```bash
# Step 1 — from an operator workstation with line of sight to ARM (the control plane is public),
#          deploy network + Key Vault + the agent, with the agent module DISABLED initially.
cd infra/terraform
terraform init -backend-config=environments/nonprod/azurerm.tfbackend
terraform apply -var-file=environments/nonprod/terraform.tfvars \
  -target=module.observability_core \
  -target=module.network_hub \
  -target=module.network_spoke \
  -target=module.private_dns \
  -target=module.key_vault

# Step 2 — create the PAT secret out of band (see §1). Requires network line of sight to the
#          Key Vault private endpoint: use a jumpbox, a temporary public-access window with an
#          IP allow-list, or Azure Cloud Shell with VNet integration.

# Step 3 — deploy the agent VM. cloud-init reads the PAT and registers the agent.
terraform apply -var-file=environments/nonprod/terraform.tfvars -target=module.pipeline_agent

# Step 4 — confirm the agent is online in Azure DevOps -> Project Settings -> Agent pools.
#          From here on, everything runs through the pipeline.

# Step 5 — run the full pipeline. It applies the remainder (AKS, ACR, Storage, identity, governance).
```

> "`-target` is a break-glass tool, not a workflow. It's correct here because bootstrap is genuinely
> sequential and one-off, but any `-target` in a routine pipeline is a smell — it means your module
> dependency graph is wrong. After bootstrap, every apply is a full, untargeted plan."

**Alternative worth mentioning:** run the bootstrap from a **Microsoft-hosted agent** with the Key Vault
temporarily allowing a public IP range, then close it. Faster, but it opens a window — so it needs to be
a deliberate, time-boxed, logged decision rather than a habit.

### 2.2 Routine deployment

Everything goes through `pipelines/azure-pipelines.yml` on a merge to `main`:

```
Validate -> Security -> BuildImage -> Infra_nonProd -> Deploy_nonProd -> Infra_Prod -> Deploy_Prod
                                          ^gate            ^gate            ^gate         ^gate
```

**There is no supported manual deployment path to production.** That is the control, not an omission.

### 2.3 Local validation before pushing

```bash
./scripts/validate.sh
```
Runs `terraform fmt -check`, per-environment `terraform validate`, `tflint`, `helm lint`,
`helm template` for both overlays, and `shellcheck`. Run it before every push — it catches the majority of
pipeline failures in about thirty seconds.

### 2.4 Manual Helm deployment (break-glass only)

```bash
NS=banking-api; REL=banking-application; ENV=nonprod

az aks get-credentials -g "rg-${ENV}-iac" -n "aks-${ENV}-iac" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

cd infra/terraform
CLIENT_ID=$(terraform output -raw workload_identity_client_id)
SA_NAME=$(terraform output -raw storage_account_name)
ACR=$(terraform output -raw acr_login_server)
CONTAINER=$(terraform output -raw cache_container_name)
cd -

helm upgrade --install "$REL" charts/banking-application \
  --namespace "$NS" --create-namespace \
  --values charts/banking-application/values-${ENV}.yaml \
  --set image.registry="$ACR" \
  --set image.tag="<immutable-tag-or-digest>" \
  --set workloadIdentity.clientId="$CLIENT_ID" \
  --set config.storageAccountName="$SA_NAME" \
  --set config.cacheContainer="$CONTAINER" \
  --atomic --wait --timeout 10m \
  --description "MANUAL: <incident ref> by <name>"
```

> **Always set `--description` on a manual deploy.** `helm history` then shows *who* and *why*, so a
> manual intervention is visible in the release record rather than an unexplained revision. Small habit,
> disproportionate payoff during a post-mortem.

---

## 3. Validation — proving it works

Run these after any infrastructure change. **Capture the output as the assessment's "Evidence"
deliverable.**

### 3.1 Infrastructure

```bash
# Private endpoints all Approved
for pe in $(az network private-endpoint list -g rg-nonprod-iac --query "[].name" -o tsv); do
  printf '%-40s %s\n' "$pe" \
    "$(az network private-endpoint show -g rg-nonprod-iac -n "$pe" \
       --query 'privateLinkServiceConnections[0].privateLinkServiceConnectionState.status' -o tsv)"
done

# Public access is OFF everywhere
az storage account show -n sanonprod01 -g rg-nonprod-iac --query publicNetworkAccess
az acr show          -n acrnonprod                       --query publicNetworkAccess
az keyvault show     -n kv-nonprod-iac                   --query properties.publicNetworkAccess
az aks show -g rg-nonprod-iac -n aks-nonprod-iac \
  --query "{private:apiServerAccessProfile.enablePrivateCluster, publicFqdn:fqdn, privateFqdn:privateFqdn, localAccounts:disableLocalAccounts}"

# Every private DNS zone is linked to BOTH VNets
for z in $(az network private-dns zone list -g rg-nonprod-iac-hub --query "[].name" -o tsv); do
  echo "== $z"
  az network private-dns link vnet list -g rg-nonprod-iac-hub -z "$z" --query "[].name" -o tsv
done

# The egress route exists and points at the firewall
az network route-table route list -g rg-nonprod-iac --route-table-name rt-aks_nodes -o table
```

### 3.2 DNS resolves to private IPs (an explicit assessment ask)

```bash
kubectl run dnstest -n banking-api --rm -it --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 -- bash -c '
    for h in sanonprod01.blob.core.windows.net \
             kv-nonprod-iac.vault.azure.net \
             acrnonprod.azurecr.io \
             acrnonprod.westeurope.data.azurecr.io; do
      printf "%-50s %s\n" "$h" "$(getent hosts $h | awk "{print \$1}")"
    done'
# Every address must be 10.101.1.x. Anything else is Scenario 2.
```

### 3.3 Workload Identity

```bash
POD=$(kubectl -n banking-api get pod -l app.kubernetes.io/name=banking-application -o name | head -1)

kubectl -n banking-api get ${POD#pod/} -o jsonpath='{.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep AZURE
kubectl -n banking-api exec ${POD#pod/} -- cat /var/run/secrets/azure/tokens/azure-identity-token \
  | cut -d. -f2 | base64 -d | jq '{sub, aud, iss}'
# sub MUST equal system:serviceaccount:banking-api:banking-api
```

### 3.4 Application

```bash
./scripts/smoke-test.sh banking-api banking-application sanonprod01 shows-cache
```
Asserts: rollout completed; `GET /api/shows` returns 200 with a non-zero count; the **second** call
returns `X-Cache: HIT` (proving the Blob write path works via Workload Identity); a blob exists in the
container; and `/readyz` reports all dependencies healthy.

### 3.5 Negative tests — prove the controls actually block

**These matter more than the positive tests. Anyone can show a thing working; showing a thing correctly
*refusing* is what demonstrates the control exists.**

```bash
# 1. From OUTSIDE the VNet, storage must refuse
curl -sv --max-time 5 https://sanonprod01.blob.core.windows.net/shows-cache/shows.json
# Expect: connection timeout / refused, or 403 AuthorizationFailure. NOT 200, NOT 404.

# 2. From outside, the AKS API must be unreachable
nslookup aks-nonprod-iac-xxxx.privatelink.westeurope.azmk8s.io   # NXDOMAIN from outside the VNet

# 3. From INSIDE the cluster, a non-allow-listed FQDN must be denied by the firewall
kubectl run egresstest -n banking-api --rm -it --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
  -- curl -sv --max-time 8 https://example.com
# Expect: blocked. Then confirm the firewall logged it:
#   AZFWApplicationRule | where Action == "Deny" and Fqdn has "example.com"

# 4. ACR admin account must be disabled
az acr show -n acrnonprod --query adminUserEnabled    # false

# 5. AKS local accounts must be disabled
az aks get-credentials -g rg-nonprod-iac -n aks-nonprod-iac --admin
# Expect: failure — "Getting static credential is not allowed"
```

> "Test 3 is the one I'd show first. It proves the egress control is real rather than aspirational, **and**
> it proves the detection works, because the denial appears in Log Analytics. A control you can't see
> working is a control you can't be sure exists."

---

## 4. Common failure modes — quick index

Full investigations in [05-troubleshooting-runbook.md](05-troubleshooting-runbook.md).

| Symptom | Most likely cause | First command |
|---|---|---|
| Blob returns 403 | Missing `Storage Blob Data Contributor` on the workload identity | `az role assignment list --assignee <principalId> --scope <saId>` |
| DNS resolves to a public IP | Private DNS zone not linked to the spoke VNet | `az network private-dns link vnet list -z <zone>` |
| `ImagePullBackOff` | Image not present in *this* registry, or kubelet lacks `AcrPull` | `az aks check-acr -g <rg> -n <aks> --acr <registry>` |
| Pipeline can't reach AKS | Job ran on a Microsoft-hosted agent | `hostname -I` in the job — must be 10.101.2.x |
| Pods never Ready | Workload Identity subject mismatch → `AADSTS70021` | Decode the projected token's `sub` claim |
| Pods `Pending` | `nodeSelector: workload=application` with no user node pool | `kubectl describe pod` → `FailedScheduling` |
| `terraform apply` denied by policy | Missing required tag (`cost_centre`) | Read the policy error; check `var.tags` |
| Helm release stuck `pending-upgrade` | A previous run was cancelled mid-upgrade | `helm rollback <rel> <lastGood>` — see §5.3 |
| Agent offline, pipeline queued forever | Single agent VM is down | See §6 break-glass |

---

## 5. Helm rollback and recovery

### 5.1 Automatic

`helm upgrade --install --atomic --wait --timeout 10m` — if the release fails or times out, Helm rolls
back automatically. If the **smoke test** subsequently fails, `stage-deploy.yml` captures diagnostics and
then invokes `scripts/helm-rollback.sh`.

🔴 **Known defect (P1-14):** if `--atomic` already rolled back, the script's `helm rollback <rel> 0` rolls
back *again* — potentially two revisions. Make the script idempotent:

```bash
CURRENT=$(helm history "$RELEASE" -n "$NS" -o json | jq -r 'last | .revision')
LAST_GOOD=$(helm history "$RELEASE" -n "$NS" -o json | jq -r '[.[]|select(.status=="deployed")]|last|.revision')
if [[ "$CURRENT" == "$LAST_GOOD" ]]; then
  echo "Already at last-known-good revision $LAST_GOOD — nothing to do."
else
  helm rollback "$RELEASE" "$LAST_GOOD" -n "$NS" --wait --timeout 5m --cleanup-on-fail
fi
```

### 5.2 Manual rollback

```bash
NS=banking-api; REL=banking-application

# 1. CAPTURE EVIDENCE FIRST — a rollback destroys it
mkdir -p /tmp/incident && cd /tmp/incident
kubectl -n $NS get pods -o wide            > pods.txt
kubectl -n $NS describe deploy $REL        > deploy.txt
kubectl -n $NS logs -l app.kubernetes.io/instance=$REL --all-containers --tail=500 > logs.txt
kubectl -n $NS logs -l app.kubernetes.io/instance=$REL --previous --tail=500 > logs-previous.txt 2>/dev/null
kubectl -n $NS get events --sort-by=.lastTimestamp > events.txt
helm get values $REL -n $NS                > values.txt
helm get manifest $REL -n $NS              > manifest.txt

# 2. Identify the last KNOWN-GOOD revision — not blindly "previous"
helm history $REL -n $NS --max 10
LAST_GOOD=$(helm history $REL -n $NS -o json | jq -r '[.[]|select(.status=="deployed")]|last|.revision')

# 3. Roll back
helm rollback $REL "$LAST_GOOD" -n $NS --wait --timeout 5m --cleanup-on-fail

# 4. Verify
kubectl -n $NS rollout status deploy/$REL
./scripts/smoke-test.sh $NS $REL
helm history $REL -n $NS --max 5
```

**Remember:** rollback creates a **new forward revision** whose content is the old one's. History is never
rewound, so the audit trail stays complete and you can roll back the rollback.

### 5.3 Stuck release (`pending-upgrade` / `pending-rollback`)

Caused by a cancelled or crashed Helm process leaving the release lock set.

```bash
helm status $REL -n $NS          # confirm the stuck status
helm history $REL -n $NS --max 5
helm rollback $REL "$LAST_GOOD" -n $NS --wait --cleanup-on-fail    # usually sufficient

# Last resort ONLY if rollback also refuses — edit the release Secret's status label
kubectl -n $NS get secret -l owner=helm,name=$REL \
  --sort-by=.metadata.creationTimestamp -o name | tail -1
# then patch label status=superseded on that Secret, and rollback again.
```
> "That last step is genuinely a last resort — you're hand-editing Helm's state. Do it with a second
> engineer watching, and record it in the incident."

### 5.4 What rollback does NOT recover

| Not recovered | Why | What to do instead |
|---|---|---|
| Database / schema migrations | Outside the release | **Expand/contract migrations** — never a change the previous version can't read |
| Blob data written by the new version | Outside the release | Blob versioning + soft delete; restore explicitly |
| Azure resources changed by Terraform | Different tool, different state | `terraform apply` the previous commit |
| Deleted PVC data | Helm doesn't restore volumes | Backup (Velero / Azure Backup for AKS) |
| Revisions older than `revisionHistoryLimit` | ReplicaSet is gone | Deployment limit is 5; Helm keeps 10 releases. Beyond that, redeploy the image explicitly |

### 5.5 Infrastructure rollback

```bash
git revert <commit> && git push        # then let the pipeline plan + apply
```
> "There is **no `terraform rollback`.** Rolling back infrastructure means applying the previous
> *desired state*, and for anything stateful that is not symmetric — a storage account destroyed by a
> revert doesn't come back with its data. That asymmetry is exactly why `prevent_destroy` is on the
> stateful resources, why the plan is reviewed before apply, and why the plan artifact — not a fresh plan
> — is what gets applied."

---

## 6. Break-glass procedures

| Scenario | Procedure | Guard rails |
|---|---|---|
| **Agent pool entirely down** | Deploy from an operator workstation on the corporate network with connectivity to the VNet (VPN/ExpressRoute), or a jumpbox in the spoke. Use the §2.4 commands | Requires PIM activation. Every action logged. Retro-fit into git afterwards |
| **Entra unavailable → no cluster access** | Temporarily set `local_account_disabled = false` and use `az aks get-credentials --admin` | **Two-person approval. Fires an alert. Reverted within the same change window** |
| **Key Vault unreachable → agent can't register** | Register the agent manually over `az ssh vm` with a PAT supplied interactively | PAT never written to disk; revoked immediately after |
| **Firewall down → no egress** | The app continues serving cached data. Do **not** add a public egress path as a workaround | Serving stale is the designed degradation. Adding a bypass creates a permanent hole |
| **Need to reach a private endpoint from outside** | Azure Bastion to a jumpbox in the spoke | Never temporarily enable public network access on a data resource |

> "The pattern in all of these: break-glass is **documented, approved, time-boxed, alerted and reverted**.
> An undocumented break-glass path is just a vulnerability with good intentions. And note what's *not*
> here — 'temporarily enable public access' is never the answer, because temporary changes made under
> pressure are the ones that become permanent."

---

## 7. Routine operations

### Scaling

```bash
# Application: HPA handles it. To change bounds, change values-prod.yaml and deploy.
kubectl -n banking-api get hpa banking-application -w

# Nodes: cluster autoscaler handles it. To change bounds:
#   var.user_node_min_count / var.user_node_max_count -> terraform apply
kubectl get nodes -L agentpool -L topology.kubernetes.io/zone
kubectl -n kube-system logs -l app=cluster-autoscaler --tail=100
```

### Kubernetes upgrades

```bash
az aks get-upgrades -g rg-prod-iac -n aks-prod-iac -o table
# Change var.kubernetes_version -> PR -> plan -> approval -> apply
# Control plane first, then node pools. max_surge = 33% on the user pool, 1 on the system pool.
```
> "Upgrade the control plane first, then node pools, never more than one minor version at a time. The PDB
> is what makes node drains safe — and it's also what will *block* the drain if it can never be satisfied,
> so check `kubectl get pdb` before starting. `minAvailable: 2` with 3 replicas is fine; `minAvailable: 2`
> with 2 replicas deadlocks the upgrade."

### Certificate and secret rotation

```bash
# AKS cluster certificates (control plane + kubelet), rolling
az aks rotate-certs -g rg-prod-iac -n aks-prod-iac

# Agent PAT — set a new value, then reimage/restart the agent so cloud-init re-registers
az keyvault secret set --vault-name kv-prod-iac --name ado-agent-pat --value "<new>" \
  --expires "$(date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ)"
```

### Cost management

```bash
az consumption usage list --start-date 2026-08-01 --end-date 2026-08-31 \
  --query "[?contains(instanceName,'iac')].{name:instanceName, cost:pretaxCost}" -o table
```
**Main cost drivers:** Azure Firewall (~$950/month, by far the largest), AKS nodes, Premium ACR,
Log Analytics ingestion. **Non-prod savings:** `enable_firewall = false` with a NAT Gateway instead,
`aks_sku_tier = "Free"`, a single system node pool, `log_daily_quota_gb` capped, and scale the cluster to
zero outside business hours.

---

## 8. Cleanup

⚠️ **`terraform destroy` will fail as written.** `prevent_destroy = true` is set on both resource groups,
ACR, Storage, Key Vault, Log Analytics, AKS and the hub→spoke peering (finding P2-17). That is intentional
protection — but it means cleanup is a deliberate two-step.

```bash
# Step 1 — remove the guards. A separate, reviewable commit; never a silent edit.
grep -rn "prevent_destroy" infra/terraform/
#   ... set each to false, or comment out the lifecycle blocks ...
git commit -am "chore: disable prevent_destroy for assessment teardown"

# Step 2 — destroy, non-prod first
cd infra/terraform
terraform init -backend-config=environments/nonprod/azurerm.tfbackend
terraform destroy -var-file=environments/nonprod/terraform.tfvars

# Step 3 — Key Vault soft delete + purge protection: the NAME is reserved for 90 days.
az keyvault list-deleted -o table
# With purge_protection_enabled = true you CANNOT purge before the retention window expires.
# Plan for it: use a random suffix in the vault name for throwaway environments.

# Step 4 — verify nothing is left billing
az resource list --tag workload=iac -o table
az group list --query "[?starts_with(name,'rg-nonprod-iac')].name" -o tsv
```

> **Say this:** *"Purge protection is the one that catches people out. It's irreversible once enabled and
> it reserves the vault name for the full soft-delete window — so re-running the same Terraform with the
> same name fails for 90 days. It's the right setting for production and the wrong one for an ephemeral
> environment, which is a genuine argument for making it a variable — which I did declare
> (`enable_kv_purge_protection`) and then never wired up. That's on my fix list."*

---

## 9. README skeleton — lift this straight into `README.md`

```markdown
# Secure Internal Banking API Platform on AKS

Private AKS platform serving `GET /api/shows` from a Blob Storage cache of the TVMaze API,
with no public inbound endpoint and controlled, allow-listed outbound egress.

## Architecture
See [docs/01-architecture.md](docs/01-architecture.md). One paragraph:
Hub/spoke topology. Azure Firewall in the hub controls all egress via UDR; AKS uses
`outbound_type=userDefinedRouting` so no Azure-managed public egress path exists. The AKS API
server, ACR, Key Vault, Storage and Azure Monitor are all private-endpoint-only with public
network access disabled. The application authenticates to Blob Storage with Entra Workload ID —
no keys, no secrets, anywhere in the workload. A self-hosted Azure DevOps agent inside the spoke
provides deployment line-of-sight to the private endpoints.

## Repository layout
| Path | Contents |
|---|---|
| `infra/terraform/` | Root module, 10 reusable modules, per-environment tfvars + backends |
| `charts/banking-application/` | Helm chart, values + nonprod/prod overlays |
| `pipelines/` | Azure DevOps multi-stage YAML + stage templates |
| `application/` | API source and Dockerfile |
| `scripts/` | Local validation, smoke test, Helm rollback |
| `docs/` | Architecture, decisions, security, observability, runbooks |

## Prerequisites
[§1 above]

## Deploy
[§2 above]

## Validate
[§3 above]

## Rollback
[§5 above]

## Cleanup
[§8 above]

## Assumptions
- Hub is dedicated to this platform; in a real estate it would be a shared connectivity subscription.
- One subscription per environment; Entra groups pre-created and their object IDs supplied as variables.
- The Azure DevOps agent PAT is created out-of-band; Terraform never writes a secret value.
- Non-production SKUs throughout, per the assessment's constraints.

## Security posture
[link to docs/06-security-and-governance.md]

## Known limitations & next steps
[YOUR HONEST LIST — see docs/02-code-review-findings.md]
This section is not optional. A documented gap is engineering judgement;
an undocumented gap is an oversight.

## What was and was not validated
[see docs/04-assessment-answers.md §7]
```

---

## 10. Runbook quality — the standard to hold yourself to

> "A runbook is good when a competent engineer who has never seen this platform can use it at 3am,
> under pressure, without waking anyone. That means: **copy-pasteable commands with real values, not
> placeholders**; the expected output next to each command, so they know whether it worked; a decision
> point at every branch; and an explicit statement of when to stop and escalate.
>
> The section people skip is 'what to do when the runbook doesn't work'. Every one of my procedures ends
> with an escalation path, because the honest failure mode of a runbook is that reality doesn't match it —
> and an engineer who believes the runbook must be right will keep trying it instead of thinking."

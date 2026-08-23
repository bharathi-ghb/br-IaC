# 10 — DevSecOps & Best Practices

> Your focus area 5. This document covers the practices that make the difference between "we have a
> pipeline with a security scanner in it" and "we have a supply chain we can attest to."
>
> **The framing that lands:** DevSecOps is not a set of tools bolted onto CI. It is **moving the decision
> point earlier**, so that the cheapest possible moment to catch a problem is the moment you catch it.
> A misconfiguration caught in an IDE costs seconds. In a PR, minutes. In production, an incident.

---

## 1. The shift-left ladder

For each control, the earlier you can enforce it, the better. Map every control to its earliest
enforceable point.

| Stage | Cost to fix | Controls that belong here | Present in your repo? |
|---|---|---|---|
| **IDE** | seconds | `terraform fmt` on save, `tflint` extension, Helm schema validation | ✗ — add `.vscode/settings.json`, `.editorconfig` |
| **Pre-commit** | seconds | `gitleaks protect`, `terraform fmt`, `helm lint`, `shellcheck`, commit message format | ✗ — add `.pre-commit-config.yaml` |
| **Pull request** | minutes | Full scan suite, `terraform plan`, policy-on-plan, required reviewers, CODEOWNERS | 🟡 Partial — pipeline runs on PR; branch policy undocumented |
| **CI (main)** | minutes | Image build + scan + sign, chart render + validate | 🟢 Mostly present |
| **Pre-deploy** | minutes | Plan approval gate, digest existence check, drift detection | 🟡 Approval present; other checks missing |
| **Admission** | seconds | Gatekeeper/Azure Policy, image signature verification (Ratify) | 🟡 Gatekeeper in `Audit`; no signature check |
| **Runtime** | hours→days | Defender for Containers, NetworkPolicy, falco-style detection | 🔴 NetworkPolicy only |
| **Post-incident** | days | Blameless post-mortem → a new control at the earliest possible stage | — |

> **The sentence to use:** *"Every incident should end by asking 'what's the earliest stage that could
> have caught this?' — and then adding the control **there**, not at the stage where it actually got
> caught. Otherwise your pipeline slowly accumulates checks for things that should never have reached it."*

### Add a pre-commit config — it's ten minutes and it shows discipline

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.1
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
      - id: terraform_checkov
        args: ["--args=--quiet --compact"]
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
  - repo: https://github.com/koalaman/shellcheck-precommit
    rev: v0.10.0
    hooks:
      - id: shellcheck
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-merge-conflict
      - id: detect-private-key
```

> "Pre-commit isn't a security boundary — anyone can `--no-verify`. It's a **feedback loop**. Its job is to
> stop developers wasting fifteen minutes waiting for CI to tell them about a formatting error. The
> security boundary is server-side branch policy, which can't be bypassed."

---

## 2. Supply chain security — the SLSA framing

| SLSA level | Requirement | Your status |
|---|---|---|
| **L1** | Scripted build, provenance available | 🟢 Pipeline builds; labels record commit + source |
| **L2** | Version-controlled source, hosted build service, signed provenance | 🟡 Build is hosted; **provenance not signed** |
| **L3** | Hardened build platform, non-falsifiable provenance | 🔴 Agent is a long-lived shared VM |
| **L4** | Two-party review, hermetic reproducible builds | 🔴 |

**The path from L1 to L3, concretely:**

**L2 — sign the artifact and its provenance:**
```yaml
- task: AzureCLI@2
  displayName: "Sign image with cosign (keyless, pipeline OIDC identity)"
  inputs:
    azureSubscription: $(serviceConnection)
    scriptType: bash
    scriptLocation: inlineScript
    addSpnToEnvironment: true
    inlineScript: |
      set -euo pipefail
      DIGEST=$(az acr manifest list-metadata -n $(acrName) -r $(imageRepository) \
        --query "[?tags[?@=='$(imageTag)']].digest | [0]" -o tsv)
      # Keyless signing: the signing identity IS the pipeline's federated identity.
      # No signing key to store, rotate or steal.
      COSIGN_EXPERIMENTAL=1 cosign sign --yes "$(acrLoginServer)/$(imageRepository)@${DIGEST}"
      # SBOM as an attestation, attached to the digest
      syft "$(acrLoginServer)/$(imageRepository)@${DIGEST}" -o spdx-json > sbom.json
      cosign attest --yes --predicate sbom.json --type spdxjson \
        "$(acrLoginServer)/$(imageRepository)@${DIGEST}"
      echo "##vso[task.setvariable variable=imageDigest]${DIGEST}"
```

**Then enforce it at admission**, which is the half that actually matters:
```yaml
# Ratify as a Gatekeeper external data provider; a ConstraintTemplate rejects
# any image without a valid signature from the pipeline's identity.
# Effect: even someone with AcrPush cannot get an unsigned image to run.
```

> "Scanning tells me the artifact was clean **when I looked at it**. Signing plus admission enforcement
> tells me the artifact running in production is **the one my pipeline produced**. Those are completely
> different guarantees, and only the second one survives a registry compromise or a malicious insider with
> push rights."

**L3 — ephemeral build agents:**
> "A long-lived shared agent is the weak link. Build N can leave state that build N+1 picks up — a poisoned
> cache, a modified tool on the PATH, a lingering credential. Ephemeral per-job agents make each build
> start from a known image and disappear afterwards. That's the single change that moves you from L2 to
> L3, and it also solves my single-point-of-failure problem — one fix, two benefits."

---

## 3. Policy as code

You have three distinct policy layers. Knowing which one to use for which control is a senior distinction.

| Layer | Tool | Enforces | Runs at |
|---|---|---|---|
| **IaC source** | Checkov / tfsec | "Storage must not allow public access" in the `.tf` | PR time |
| **IaC plan** | **Conftest / OPA on `tfplan.json`** | "This apply must not **delete** a resource tagged `criticality: high`" | Pre-apply |
| **Azure control plane** | Azure Policy | "No resource anywhere may have public access", regardless of tool | ARM request time |
| **Kubernetes admission** | Gatekeeper / Azure Policy for AKS | "No privileged containers", "images must be signed" | Pod creation |

### The plan-policy layer — your biggest missed opportunity (P2-16)

You already generate `tfplan.json` and never use it. Source scanning cannot see *actions*; plan scanning
can.

```rego
# policy/terraform/no-destroy-critical.rego
package terraform.destroy

deny[msg] {
  rc := input.resource_changes[_]
  rc.change.actions[_] == "delete"
  rc.change.before.tags.criticality == "high"
  msg := sprintf("Plan would DELETE a critical resource: %s", [rc.address])
}

deny[msg] {
  rc := input.resource_changes[_]
  rc.type == "azurerm_storage_account"
  rc.change.after.public_network_access_enabled == true
  msg := sprintf("Plan would enable public network access on %s", [rc.address])
}
```
```bash
conftest test --policy policy/terraform tfplan.json
```

> "**Source scanning tells me what the code says. Plan scanning tells me what will actually happen.** They
> catch different classes of problem. Checkov can't see that a refactor will cause a storage account to be
> replaced — losing its data — because that's a property of the plan, not the source. That's a genuinely
> advanced gate and it takes about an hour to add."

### Gate policy, stated as policy

> **Block** on: HIGH/CRITICAL vulnerabilities **with a fix available**; any leaked secret; any IaC finding
> in a defined critical set (public access, unencrypted storage, wildcard RBAC); any plan that deletes a
> resource tagged critical.
>
> **Warn** on: everything else, tracked as a work item with an SLA.
>
> **Every suppression is a file in the repo** — `.trivyignore`, `.checkov.yaml` skip-check — each carrying
> a justification and an **expiry date**, reviewed in the PR like any other change.

> "Ungated warnings train people to ignore the pipeline. Unconditional blocking trains people to bypass
> it. Both are failure modes, and the second is worse because it's invisible. The middle path —
> **expiring, reviewed exceptions** — is the only one that survives contact with a delivery deadline.
> 🔴 My current pipeline is inconsistent here: Trivy fails correctly, but `npm audit` and `eslint` are
> `|| echo warning`, and Checkov fails on any severity. That inconsistency is itself the problem."

---

## 4. Secret hygiene

**The best control is architectural: don't have secrets.** Full inventory in
[06-security-and-governance.md](06-security-and-governance.md#4-secrets--the-inventory) — the summary is
that this design has exactly **one** real secret.

| Control | Status |
|---|---|
| Workload identity federation on the service connection (no client secret) | 🟢 |
| Workload Identity for the app (no storage key) | 🟢 |
| `use_oidc` for Terraform (no backend key) | 🟢 |
| `admin_enabled = false` on ACR | 🟢 |
| `local_account_disabled = true` on AKS | 🟢 |
| Gitleaks with `fetchDepth: 0` (full history) | 🟢 |
| Trivy secret scanner on fs **and image layers** | 🟢 |
| `sensitive = true` on Terraform outputs | 🟢 |
| Nothing sensitive in Helm values files | 🟢 |
| `shared_access_key_enabled = false` | 🔴 P1-5 |
| Key Vault CSI instead of a `kubectl create secret` | 🔴 P2-3 |
| PAT eliminated / rotated | 🔴 P2-11 |

**The two rules to state:**

1. **Never `--set` a secret.** It lands in shell history, in the pipeline log, **and in the Helm release
   Secret stored in the cluster** — where `helm get values` prints it back to anyone with read access to
   that namespace. Use the Key Vault CSI driver.
2. **A Kubernetes Secret is base64 in etcd, not encryption.** Anyone with `get secrets` in the namespace
   reads it in plaintext. If you must use one, enable **KMS etcd encryption** with a customer-managed key.

---

## 5. Pipeline security — the attack surface people forget

> "The pipeline is the most privileged thing in the estate. It can deploy to production. So the question
> isn't 'is my code secure' — it's **'who can make my pipeline do something, and what can they make it
> do?'**"

| Attack | Defence | Status |
|---|---|---|
| Malicious PR modifies pipeline YAML to exfiltrate credentials | Branch policy: no direct push, required reviewers, **CODEOWNERS on `pipelines/`**; service connection restricted to specific pipelines; PRs from forks don't get secrets | 🟡 Not documented — **put it in the README** |
| Compromised dependency runs at build time (`npm install` scripts) | `npm ci --ignore-scripts`; build in a container; ephemeral agents | 🔴 |
| Compromised agent host steals a credential | Federated identity — no stored secret; short-lived per-run token | 🟢 (residual: the running job's token) |
| Stolen pipeline identity deploys to prod | Separate identity per environment, separate subscriptions; prod requires human approval | 🟢 |
| Pipeline escalates itself to cluster-admin | `AKS RBAC Writer` **cannot create RoleBindings** | 🟢 |
| Tampered artifact between build and deploy | Digest-based deploy + signature verification | 🔴 P1-6 |
| Poisoned agent tool cache | Golden image; pinned tools; ephemeral agents | 🔴 P2-12 |

**The specific hardening to name:**
- Restrict the service connection to **this pipeline only**, not open to the project.
- **Disable "Allow scripts to access the OIDC token"** on jobs that don't need it.
- **Fork PRs must not receive secrets** — the Azure DevOps default, but verify it.
- **Require a comment before running PR builds** from external contributors.
- **Audit pipeline permission changes** — an Activity Log alert on service connection modifications.

---

## 6. IaC best practices — the checklist

| Practice | Status | Note |
|---|---|---|
| Reusable, parameterised modules | 🟢 | 10 modules, consistent variable interfaces |
| Every variable has `description` and `type` | 🟢 | Genuinely well done — many descriptions explain *why*, not just *what* |
| `validation` blocks on constrained inputs | 🟡 | Present on `firewall_subnet_prefix`, `firewall_sku_tier`, `kubernetes_policy_effect`. Extend to CIDRs, VM sizes, NSG priorities |
| `precondition` / `postcondition` on resources | 🔴 | e.g. assert `firewall_private_ip != ""` when forced tunnelling is on |
| Remote state with locking | 🟢 | Azure backend, OIDC, Entra auth |
| State isolated per environment | 🟢 | Separate backend files/accounts — **the right call over workspaces** |
| `.terraform.lock.hcl` committed | 🔴 | P0-4 — a reproducibility gap |
| Provider version pinned pessimistically | 🔴 | P0-4 — pinned to a major version the code doesn't target |
| No hardcoded values | 🟡 | `rt-aks_nodes`, `fw-hub-*`, the regional DNS zone name |
| No dead variables | 🔴 | P1-11 — ten declared-but-unused |
| Consistent naming | 🟡 | `rt-aks_nodes` (underscore) vs `rt-private-endpoints` (hyphen) |
| Meaningful outputs | 🟢 | Well chosen; the pipeline consumes them properly |
| Tags applied uniformly | 🟢 | Single `var.tags` map threaded through |
| `prevent_destroy` on stateful resources | 🟢 | With the cleanup caveat (P2-17) |
| Modules do one thing | 🟡 | `observability` does two — hence the dependency cycle (P0-3) |
| No commented-out code | 🔴 | Route stubs in `network-spoke` — delete them |
| README per module | 🔴 | `terraform-docs` auto-generates these; worth ten minutes |
| Automated `terraform fmt` check | 🟢 | In the pipeline and in `validate.sh` |
| Drift detection | 🔴 | A scheduled `terraform plan` alerting on non-empty diffs |

### Add drift detection — high value, low effort

```yaml
schedules:
  - cron: "0 6 * * *"
    displayName: Daily drift check
    branches: { include: [main] }
    always: true
# Runs terraform plan with -detailed-exitcode.
# Exit code 2 => drift => raise a work item and alert.
```
> "Drift detection is how you find out that someone made a change in the portal at 2am during an incident
> and never told anyone. In a bank that's an audit finding waiting to happen — and it's a ten-line
> addition."

---

## 7. Kubernetes best practices — status

| Practice | Status |
|---|---|
| Resource requests on every container | 🟢 |
| Memory limit, no CPU limit | 🟢 **Deliberate and correct** — see [03](03-design-decisions-and-tradeoffs.md#n-helm-chart-design) |
| Liveness / readiness / startup probes, correctly differentiated | 🟢 |
| `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ALL`, seccomp | 🟢 Full PSS *restricted* |
| `automountServiceAccountToken: false` | 🟢 |
| NetworkPolicy, default-deny shaped | 🟡 Ingress rule has no `from` selector (P2-5) |
| PodDisruptionBudget | 🟢 (with the `minAvailable` brittleness caveat) |
| Topology spread across zones | 🟢 |
| `maxUnavailable: 0` rollout | 🟢 |
| `checksum/config` annotation | 🟢 |
| No `latest` tags | 🟢 Immutable build tags |
| Pinned image digests | 🔴 P1-6 |
| `preStop` hook for graceful shutdown | 🔴 |
| `priorityClassName` | 🔴 |
| Helm test hook | 🔴 P2-8 |
| Namespace-level `ResourceQuota` / `LimitRange` | 🔴 |
| Pod Security Admission label on the namespace | 🔴 — `pod-security.kubernetes.io/enforce: restricted` is one label and enforces PSS cluster-side |

---

## 8. The DevSecOps maturity model — where you are and where to go

| Level | Characteristics | You |
|---|---|---|
| **1 — Ad hoc** | Manual deploys, security at the end, secrets in config | |
| **2 — Automated** | CI/CD pipeline, some scanning, IaC | |
| **3 — Integrated** | Scanning gates the pipeline, IaC for everything, no secrets in code, policy as code | **← Here** |
| **4 — Measured** | SLOs, error budgets, DORA metrics, signed artifacts, admission enforcement, drift detection | ← Target |
| **5 — Self-improving** | Chaos engineering, automated remediation, security champions, every incident produces an earlier-stage control | |

**To reach level 4, in priority order:**
1. Image signing + admission enforcement (Ratify).
2. Policy on the Terraform plan (Conftest/OPA).
3. Drift detection on a schedule.
4. SLOs + error-budget alerting ([07](07-observability.md)).
5. **DORA metrics**: deployment frequency, lead time, change failure rate, MTTR — measured from pipeline
   and incident data.

> "The DORA metrics point is worth making explicitly. **You cannot improve delivery without measuring it**,
> and the four DORA metrics are the ones that correlate with organisational performance. They also settle
> the perennial security-versus-velocity argument with data — the research consistently shows the two are
> *correlated*, not traded off: teams that deploy more often have lower change failure rates, because small
> changes are safer changes. That reframing is often the most useful thing you can say to a sceptical
> stakeholder."

---

## 9. The five things to say in a DevSecOps round

1. **"The best security control is architectural."** The strongest thing about this design isn't a
   scanner — it's that there's almost nothing to steal. Workload Identity, federated pipeline
   credentials, OIDC for Terraform, no ACR admin account, no AKS local account. One real secret in the
   whole system.

2. **"Scanning and signing are different guarantees."** Scanning says the artifact was clean when I looked
   at it. Signing plus admission enforcement says the artifact in production is the one my pipeline built.
   Only the second survives a registry compromise.

3. **"Gates need expiring exceptions, not on/off switches."** Ungated warnings get ignored; unconditional
   blocks get bypassed. Reviewed, expiring suppressions in the repo are the only version that survives a
   deadline.

4. **"Policy at the plan, not just the source."** Source scanning sees what the code says; plan scanning
   sees what will actually happen — including that a refactor is about to replace a storage account and
   lose its data.

5. **"Every incident should produce a control at an earlier stage."** Not at the stage where it was
   caught. That's the whole discipline in one sentence, and it's why the pipeline doesn't grow
   indefinitely.

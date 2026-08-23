# Interview Preparation Bundle — Senior Azure Infrastructure & DevOps Engineer

This folder is the **complete preparation pack** for the technical interview that follows the
"Banking Platform Engineering" assessment. It is written from an **evaluator's point of view**:
what a senior interviewer will actually probe, what your code currently proves, where it does not,
and exactly what to say.

## How to use this bundle

Read in this order. Each document builds on the previous one.

| # | Document | What it is for | Read when |
|---|---|---|---|
| 00 | [00-preparation-plan.md](00-preparation-plan.md) | Day-by-day study plan, what to fix vs. what to explain, drill schedule | First. Sets the strategy. |
| 01 | [01-architecture.md](01-architecture.md) | End-to-end architecture + all flow diagrams with narrated explanation | Second. This is your whiteboard script. |
| 02 | [02-code-review-findings.md](02-code-review-findings.md) | Honest, severity-ranked review of your repo vs. the assessment | Third. **The highest-value document.** |
| 03 | [03-design-decisions-and-tradeoffs.md](03-design-decisions-and-tradeoffs.md) | Every module: what you chose, alternatives, why, when you'd choose differently | Before any "why did you..." question |
| 04 | [04-assessment-answers.md](04-assessment-answers.md) | Model answers to every explicit question/clarification in the assessment PDF | Core revision material |
| 05 | [05-troubleshooting-runbook.md](05-troubleshooting-runbook.md) | The 5 scenarios: symptoms → hypotheses → commands → root cause → fix → prevention | Drill until fluent |
| 06 | [06-security-and-governance.md](06-security-and-governance.md) | RBAC model, identity map, policy, tagging, CI/CD supply-chain security | Security deep-dive rounds |
| 07 | [07-observability.md](07-observability.md) | Telemetry model, SLOs, alerts, dashboards, KQL, incident first-five-minutes | Observability round |
| 08 | [08-operational-runbook.md](08-operational-runbook.md) | Deploy, validate, rollback, break-glass, cleanup — the ops deliverable | Ops/SRE round + a submission deliverable |
| 09 | [09-production-readiness.md](09-production-readiness.md) | Security / reliability / HA / scalability / DR gap analysis with target state | "Is this production ready?" |
| 10 | [10-devsecops-best-practices.md](10-devsecops-best-practices.md) | Supply chain, shift-left, policy-as-code, secret hygiene, maturity model | DevSecOps round |
| 11 | [11-mock-interview-qa.md](11-mock-interview-qa.md) | ~50 graded questions with model answers + rapid-fire drill | Final week, out loud |

## The one-paragraph summary of where you stand

Your repository shows **strong architectural instinct**: hub/spoke with Azure Firewall egress control,
private AKS with CNI Overlay and `userDefinedRouting`, Workload Identity federation, private endpoints
for every data plane service, AMPLS for private monitoring, a self-hosted agent inside the VNet, a
multi-stage pipeline with real security gates, and a genuinely well-built Helm chart. That is a
senior-level *design*.

It is **not yet a working deployment**. There is no application source code, module source paths do
not resolve, there is a Terraform dependency cycle, the provider version pin contradicts the syntax
used, the workload identity is never granted access to Blob Storage, and the namespace/ServiceAccount
names disagree across three files. An interviewer who runs `terraform init` will find this in ninety
seconds.

**Your strategy is therefore: own the gaps first, then sell the design.** Document 02 tells you how.

## Inline code annotations

Every significant source file in this repository now carries inline explanatory comments covering
*why this choice*, *what it cost*, and *what breaks* — with known defects flagged against their
finding ID in [02-code-review-findings.md](02-code-review-findings.md). Files annotated:

- `infra/terraform/` — root (`main.tf`, `providers.tf`, `outputs.tf`) and all 10 modules
- `charts/banking-application/` — all 7 templates, `_helpers.tpl`, `values.yaml`, `values-prod.yaml`
- `pipelines/` — root pipeline, variables, and all 5 stage templates
- `scripts/` — all 3 scripts (shebangs also added, see finding P1-12)

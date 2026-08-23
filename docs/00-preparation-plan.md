# 00 — Interview Preparation Plan

> Written from an evaluator's perspective. You are pitching at **senior** level with **intermediate**
> current depth, so the plan is built around closing that specific gap.
>
> **The gap, precisely:** an intermediate engineer can explain *what* a component does. A senior engineer
> explains *why this one and not the alternative*, *what it cost*, and *how it fails*. Your repository
> already contains senior-level decisions. What's missing is that you can articulate them as decisions —
> and that you've caught your own defects before someone else does.

---

## 1. The honest assessment of where you stand

### What is genuinely strong

| Area | Evidence |
|---|---|
| **Network architecture** | Hub/spoke, `outbound_type = userDefinedRouting`, firewall FQDN allow-list, DNS proxy, threat intel Deny, zone-redundant firewall. This is a *correct* private-AKS egress design, and most candidates get `userDefinedRouting` wrong |
| **Identity design** | Workload Identity federation, separate control-plane/kubelet/workload/pipeline/agent identities, `local_account_disabled`, `admin_enabled = false`, OIDC everywhere. Almost no secrets exist |
| **Helm chart** | Genuinely production-shaped: `checksum/config`, `maxUnavailable: 0`, PSS *restricted*, startup probe, topology spread, PDB, a `fail` guard on invalid values. **This is your strongest artefact** |
| **Pipeline structure** | Reusable stage templates, plan→approve→apply-the-saved-plan, security scanning before build, environment gates |
| **Terraform hygiene** | Consistent module interfaces, every variable typed and described — several descriptions explain the *reasoning*, which is rare and reads well |
| **Variable descriptions as documentation** | e.g. *"Kept as a boolean rather than a null check so the count stays known at plan time"* — that single sentence tells a reviewer you understand Terraform's evaluation model |

### What will hurt you, in the order they'll find it

1. **`README.md` is one line.** First impression, and a scored deliverable.
2. **`application/` is empty.** The assessment's easiest requirement, unmet.
3. **`terraform init` fails** — module paths don't resolve.
4. **`terraform plan` would fail** — dependency cycle, plus provider version vs syntax mismatch.
5. **The workload identity has no Storage RBAC** — the platform ships with the bug the assessment asks
   you to debug.
6. **Namespace/ServiceAccount names disagree across three files** — the classic Workload Identity failure.

Full detail: [02-code-review-findings.md](02-code-review-findings.md).

### The strategy in one line

> **Own the gaps in the first two minutes, then spend the rest of the interview on the design.**

If you open with *"Before we start, let me tell you what I'd fix first and why"*, three things happen:
the interviewer stops hunting, you control the narrative, and you have demonstrated the single most
valuable senior trait — **critically reviewing your own work**. Candidates who defend broken code lose.
Candidates who found it first, and know exactly how to fix it, win.

---

## 2. Fix or explain? — the triage

You will not fix everything. Decide deliberately.

### Fix (highest return per hour)

| Priority | Fix | Time | Why |
|---|---|---|---|
| 1 | **Write `README.md`** — structure, prereqs, assumptions, deploy, validate, rollback, **known limitations** | 45 min | Cheapest scored point; the limitations section pre-empts every finding |
| 2 | Module `source` paths + provider pin `~> 4` + declare `subscription_id` | 20 min | Makes `terraform init`/`validate` run |
| 3 | Break the observability dependency cycle | 30 min | Makes `terraform plan` run |
| 4 | Grant the workload identity `Storage Blob Data Contributor` | 10 min | It is the bug the assessment asks about |
| 5 | Reconcile namespace / ServiceAccount names | 15 min | Classic Workload Identity failure |
| 6 | `count` on the firewall resources; fix `node_resource_group` | 15 min | Remaining hard errors |
| 7 | **Write the application + Dockerfile** | 90 min | Largest single scored gap |
| 8 | AMPLS inversion; delete duplicate A records; wire NSG rules; add `cost_centre` | 30 min | P1s that contradict your own docs |
| 9 | Run fmt/validate/lint/template; **capture output as evidence** | 25 min | The "Evidence" deliverable |

**Total: ~5 hours.** That converts the submission from "doesn't run" to "runs and is documented."

### Explain (don't fix — have the answer ready)

- Single-VM pipeline agent → *"SPOF; I'd use a VMSS or ephemeral agents in AKS."*
- HPA on CPU for an I/O-bound app → *"Wrong signal; KEDA on RPS or p95 latency."*
- LRS storage in prod → *"Inconsistent with zone-redundant compute; should be ZRS."*
- Ephemeral OS disk on `D2s_v5` → *"Dsv5 has no local temp disk; needs `D2ds_v5`."*
- Policy at RG scope → *"Escapable; belongs at management group."*
- No image signing → *"Scanning ≠ provenance; `cosign` + Ratify."*
- No DR → *"RTO 4h / RPO 1h warm standby; the cache is derived data, so I rebuild rather than replicate."*

**Every one of these is a *stronger* answer as an acknowledged gap with a specific fix than as a silent
omission.** They demonstrate range beyond what you had time to build.

---

## 3. The study plan

Scale to the time you have. If you have less, do Days 1, 2 and 7.

### Day 1 — Own your own code (4 hours)

- [ ] Read [02-code-review-findings.md](02-code-review-findings.md) end to end. **Verify each finding
      yourself** — don't take it on faith; you must be able to defend it as your own analysis.
- [ ] Open every file and, for each resource, ask: *why this setting? what breaks if I change it?*
      (The inline annotations in the code answer most of this — but say it in your own words.)
- [ ] Write your own one-page "known limitations" list from memory. Compare against the findings doc.
- [ ] **Exercise:** explain `outbound_type = userDefinedRouting` out loud in 60 seconds, including what
      goes wrong without it.

### Day 2 — Architecture fluency (3 hours)

- [ ] Read [01-architecture.md](01-architecture.md).
- [ ] **Draw all six diagrams from memory.** On paper. Repeat until fluent.
- [ ] Rehearse the [90-second opening statement](01-architecture.md#0-the-90-second-opening-statement)
      until it's natural, not recited.
- [ ] **Exercise:** trace a `GET /api/shows` request end to end, out loud, naming every component it
      touches and every identity involved.

### Day 3 — Trade-offs (3 hours)

- [ ] Read [03-design-decisions-and-tradeoffs.md](03-design-decisions-and-tradeoffs.md).
- [ ] For each of the 17 sections, say the four-sentence structure aloud: **chose / why / gave up /
      when I'd differ**.
- [ ] **Exercise:** have someone ask "why did you choose X?" for ten random components. You must name a
      cost every time. **A decision without a cost is not a senior answer.**

### Day 4 — Troubleshooting drills (3 hours)

- [ ] Read [05-troubleshooting-runbook.md](05-troubleshooting-runbook.md).
- [ ] For each of the five scenarios, work through symptoms → hypotheses → commands → root cause → fix →
      prevention **without looking**.
- [ ] Memorise the quick-reference commands at the end.
- [ ] **Exercise:** for each scenario, state your *first* command and — critically — **what it tells you
      either way**. That bisection sentence is what's actually being assessed.

### Day 5 — Security, governance, DevSecOps (3 hours)

- [ ] Read [06-security-and-governance.md](06-security-and-governance.md) and
      [10-devsecops-best-practices.md](10-devsecops-best-practices.md).
- [ ] **Memorise the seven-identity table.** Being able to enumerate every principal and what it can't do
      is the fastest way to show you designed the security model.
- [ ] **Exercise:** answer "how do you prevent privilege escalation and secret leakage in CI/CD?" in
      three minutes, structured as identity → pipeline → Helm → detection.

### Day 6 — Observability & operations (2 hours)

- [ ] Read [07-observability.md](07-observability.md) and
      [08-operational-runbook.md](08-operational-runbook.md).
- [ ] Memorise the first-five-minutes incident sequence.
- [ ] Understand the cross-layer KQL query well enough to explain what each `union` block contributes.
- [ ] **Exercise:** "walk me through a Helm rollback" — commands, and what rollback does *not* recover.

### Day 7 — Mock interview (3 hours)

- [ ] Work through [11-mock-interview-qa.md](11-mock-interview-qa.md) **out loud**, ideally with someone
      else asking.
- [ ] Time yourself. Most answers should be 60–120 seconds. **Rambling is the most common way senior
      candidates underperform** — they know a lot and say all of it.
- [ ] Rehearse the opening statement and the closing question one final time.

---

## 4. How senior interviews are actually scored

Map your preparation to the published rubric.

| Rubric area | Weight | What they're listening for | Where you're covered |
|---|---|---|---|
| AKS architecture | 20% | Private cluster, CNI Overlay reasoning, identity integration, node pool design, operational reasoning | [01](01-architecture.md), [03 §D–F](03-design-decisions-and-tradeoffs.md) |
| Azure networking & DNS | 20% | Private Link/DNS mechanics, controlled egress, route/NSG reasoning, systematic troubleshooting | [01 §4, §6](01-architecture.md), [05 Scenarios 1–2](05-troubleshooting-runbook.md) |
| Terraform/Bicep design | 15% | Reusable modules, state strategy, idempotency, validation, maintainability | [03 §M](03-design-decisions-and-tradeoffs.md), [10 §6](10-devsecops-best-practices.md) |
| Helm & Kubernetes delivery | 10% | Chart structure, values-driven config, probes, Workload Identity, rollback | [03 §N](03-design-decisions-and-tradeoffs.md), [05 Scenario 5](05-troubleshooting-runbook.md) |
| Azure DevOps | 15% | Multi-stage YAML, gates, identity, private agent connectivity | [01 §7–8](01-architecture.md), [04](04-assessment-answers.md) |
| Security & governance | 10% | Least privilege, Workload ID, Policy, tagging, no public exposure, secure CI/CD | [06](06-security-and-governance.md) |
| Troubleshooting & operations | 10% | Evidence-driven diagnosis, real commands, remediation, prevention | [05](05-troubleshooting-runbook.md), [08](08-operational-runbook.md) |

**Networking + AKS = 40%.** If time is short, over-invest in [01](01-architecture.md) and
[05](05-troubleshooting-runbook.md).

---

## 5. Interview technique — what actually separates levels

### The four-part answer

Every technical answer should have this shape. It takes 60–90 seconds.

1. **The direct answer.** One sentence. Don't warm up.
2. **The mechanism.** How it actually works — this is where depth shows.
3. **The trade-off.** What it costs. **Never skip this.**
4. **The boundary.** When you'd choose differently.

> *"I used Azure Firewall for egress. [1] It sits in the hub with a UDR from the node subnet, and AKS is
> set to `userDefinedRouting` so there's no Azure-managed public egress path at all. [2] The cost is about
> $950 a month, an extra hop, and much tighter SNAT limits than a NAT Gateway. [3] For a
> throughput-heavy, low-sensitivity workload I'd use a NAT Gateway with strict NSG service tags instead,
> and accept losing the egress logs. [4]"*

### Own your gaps — the specific phrasing

**Bad:** *"I ran out of time."* (Sounds like poor estimation.)
**Bad:** *"That should work, I think."* (Sounds like you don't know your own code.)

**Good:** *"That's a real defect and I'd fix it first. Here's what happens and here's the fix —"*
**Good:** *"I deliberately scoped that out for a sandbox. In production I'd do X, because Y."*

**The distinction that matters: a *deliberate* omission is judgement; an *unnoticed* one is an oversight.
Make every gap the first kind by naming it before they do.**

### When you don't know

Never bluff. Use this:

> *"I haven't worked with that directly. What I'd reason from is — [related thing you do know]. I'd expect
> it to behave like [X] because [Y], but I'd verify before relying on it. How does it actually work?"*

That answer scores **better** than a confident wrong one. It shows calibrated confidence, which is
precisely what you want in someone with production access. And asking the follow-up turns it into a
conversation.

### Manage your length

Intermediate engineers under-answer. Senior candidates **over**-answer — they know a lot and say all of
it, and the interviewer loses the thread.

**Answer the question, name one trade-off, then stop.** Let them ask the follow-up. The follow-up tells
you what they actually care about, and it turns a monologue into a dialogue. Silence after a complete
answer is fine — it is not your job to fill it.

### Bring the conversation back to evidence

When you can, refer to something concrete in your repo: *"That's `modules/aks/main.tf`, the
`outbound_type` line."* It grounds the discussion in work you actually did.

---

## 6. The opening statement

If given any opening — "tell me about your solution" — use this. Then stop.

> "I'll give you the shape first and then flag what I'd fix, because I'd rather we spend our time on the
> design than on the defects.
>
> It's a hub-and-spoke platform with three hard boundaries. **No public inbound anywhere** — private AKS
> API, internal load balancer only, and public network access disabled at the resource level on ACR, Key
> Vault, Storage and Azure Monitor, all reached through private endpoints. **Controlled outbound** —
> Azure Firewall in the hub with an FQDN allow-list of exactly one application destination, and AKS set
> to `userDefinedRouting` so there's no second, unmonitored exit. **No credentials in the workload** —
> Entra Workload ID for the app, workload identity federation for the pipeline, OIDC for Terraform.
> There is exactly one real secret in the whole design.
>
> Delivery matches those boundaries: a self-hosted agent inside the spoke, because a Microsoft-hosted
> agent has no route to a private endpoint, deploying with `helm upgrade --install --atomic` so a failed
> release rolls itself back.
>
> Now — what I'd fix. I have a set of defects I found reviewing this myself. The most important: the
> workload identity is never actually granted Storage RBAC, so the platform ships with exactly the 403
> the assessment asks me to troubleshoot; the namespace and ServiceAccount names disagree between my
> Terraform and my chart, which is the classic Workload Identity failure; and I have a Terraform
> dependency cycle between the observability and network modules. I know what each fix is and why the
> mistake happened. Happy to start wherever's most useful."

**Why this works:** it's structured, it demonstrates the design, and it disarms the audit. You have now
framed the rest of the conversation as *design discussion* rather than *defect hunt*.

---

## 7. Questions to ask them

Have three ready. They're assessed too.

1. *"How is the platform team structured relative to application teams — do app teams own their spokes,
   or is it a fully centralised platform?"* → Shows you think about Conway's Law and operating models.
2. *"What's the current approach to Kubernetes upgrades and change management? I'm curious how you balance
   automated patching against change control in a regulated environment."* → Shows you know that's a
   genuine tension, not a solved problem.
3. *"How mature is the policy-as-code estate — are you at management-group-scope initiatives with
   remediation, or still per-subscription assignments?"* → Signals you know what good looks like.

**Avoid:** anything answerable from the job description; anything about salary or hours in a technical
round.

---

## 8. The final checklist

**48 hours before:**
- [ ] `README.md` written, including "Known limitations & next steps"
- [ ] `terraform fmt -recursive && terraform validate` passes — **output saved as evidence**
- [ ] `helm lint && helm template` passes for both overlays — output saved
- [ ] Evidence captured in `docs/evidence/`
- [ ] Repository pushed; the branch you'll discuss is the one they can see

**24 hours before:**
- [ ] All six architecture diagrams drawable from memory
- [ ] Opening statement rehearsed aloud, three times
- [ ] All five troubleshooting scenarios worked through without notes
- [ ] Your own defect list memorised — **you should be able to name six defects before they name one**

**On the day:**
- [ ] Repo open in an editor, on the correct branch
- [ ] [01-architecture.md](01-architecture.md) and
      [05-troubleshooting-runbook.md](05-troubleshooting-runbook.md) open in a second window
- [ ] Paper and pen for diagramming
- [ ] Your three questions written down

---

## 9. The thing to remember

> The assessment says: *"We evaluate engineering quality and reasoning, not the number of Azure resources
> created. A concise implementation with strong explanations is preferable to a large, fragile
> deployment."*
>
> **Read that twice.** They have told you, explicitly, that your explanation matters more than your
> resource count. You have built a large, thoughtful, currently-fragile deployment. The work between now
> and the interview is almost entirely about the *explanation* — making every decision in it a decision
> you can defend, and every defect one you found first.
>
> You are not being assessed on whether the code deploys. You are being assessed on whether you are
> someone they would trust with production access. That person knows what their system costs, how it
> fails, and what's wrong with it — before anyone else has to tell them.

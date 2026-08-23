# Architecture

> **This document has been superseded by [01-architecture.md](01-architecture.md)**, which contains the
> same material with correctly fenced Mermaid diagrams (the versions here were unfenced and rendered as
> plaintext), plus narrated explanations of every flow, the address plan, and the reasoning behind each
> topology decision.
>
> Start at [docs/README.md](README.md) for the full documentation bundle.

## Quick links

| Topic | Document |
|---|---|
| Full architecture, all diagrams, address plan | [01-architecture.md](01-architecture.md) |
| Component inventory | [01-architecture.md §1](01-architecture.md#1-component-inventory--what-exists-and-where-it-lives-in-the-repo) |
| Hub/spoke topology | [01-architecture.md §2](01-architecture.md#2-the-whole-platform-one-diagram) |
| `GET /api/shows` request flow | [01-architecture.md §3](01-architecture.md#3-request-flow--get-apishows) |
| DNS resolution path | [01-architecture.md §4](01-architecture.md#4-dns-resolution-path--pod-to-private-endpoint) |
| Workload Identity token flow | [01-architecture.md §5](01-architecture.md#5-identity-and-token-flow--workload-identity-end-to-end) |
| Egress path and firewall trade-offs | [01-architecture.md §6](01-architecture.md#6-egress-path--how-a-private-workload-reaches-tvmaze) |
| CI/CD network path | [01-architecture.md §7](01-architecture.md#7-cicd-path--how-a-commit-reaches-a-private-cluster) |
| Promotion flow | [01-architecture.md §8](01-architecture.md#8-promotion-flow) |
| Why Azure CNI Overlay | [01-architecture.md §9](01-architecture.md#9-address-plan-and-why-each-choice-was-made) |
| Per-module design trade-offs | [03-design-decisions-and-tradeoffs.md](03-design-decisions-and-tradeoffs.md) |
| Known defects in this repository | [02-code-review-findings.md](02-code-review-findings.md) |

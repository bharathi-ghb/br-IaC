# Architecture & Flow

This document explains how the platform in this repository is put together:

## 1. Component overview

| Layer | What's deployed | Where in the repo |
|---|---|---|
| Hub VNet | Azure Firewall (Premium/Standard SKU, policy-driven), public IP, hub RG | [infra/terraform/modules/network-hub](../infra/terraform/modules/network-hub) |
| Spoke VNet | AKS node subnet, private-endpoint subnet, pipeline-agent subnet, NSGs, route tables, peering to hub | [infra/terraform/modules/network-spoke](../infra/terraform/modules/network-spoke) |
| AKS | Private cluster, Azure CNI Overlay, Entra + Azure RBAC, OIDC issuer, Workload ID, system + user node pools | [infra/terraform/modules/aks](../infra/terraform/modules/aks) |
| ACR | Premium SKU (required for Private Link), public access disabled | [infra/terraform/modules/container-registry](../infra/terraform/modules/container-registry) |
| Storage | Blob Storage for the TVMaze response cache, public access disabled | [infra/terraform/modules/storage-account](../infra/terraform/modules/storage-account) |
| Key Vault | RBAC-authorised, public access disabled | [infra/terraform/modules/key-vault](../infra/terraform/modules/key-vault) |
| DNS | Private DNS zones for every Private Link resource, linked to hub + spoke | [infra/terraform/modules/private-dns](../infra/terraform/modules/private-dns) |
| Identity | User-assigned managed identity federated to the app's Kubernetes ServiceAccount via OIDC | [infra/terraform/modules/identity](../infra/terraform/modules/identity) |
| Pipeline agent | Linux VM in `rg_infra`, on `snet-pipeline-agents`, no public IP, CI/CD toolchain pre-installed | [infra/terraform/modules/pipeline-agent](../infra/terraform/modules/pipeline-agent) |
| Observability | Log Analytics, Application Insights, optional AMPLS, alert rules | [infra/terraform/modules/observability](../infra/terraform/modules/observability) |
| Governance | Azure Policy assignments (locations, tags, public-access denial, AKS hardening) | [infra/terraform/modules/governance](../infra/terraform/modules/governance) |
| Application | Helm chart, values-nonprod/prod, ServiceAccount + Workload ID annotations, probes, NetworkPolicy | [charts/banking-application](../charts/banking-application) |
| CI/CD | Multi-stage Azure DevOps YAML pipeline on a private self-hosted pool | [pipelines](../pipelines) |

## 2. Hub/spoke network topology

flowchart TB
    subgraph HUB["Hub VNet — 10.100.0.0/22"]
        FW["Azure Firewall\nAzureFirewallSubnet 10.100.0.0/26\n(policy: allow TVMaze FQDN, deny else)"]
        FWPIP["Public IP\n(single egress address)"]
        FW --- FWPIP
    end

    subgraph SPOKE["Spoke VNet — 10.101.0.0/22"]
        AKSNET["snet-aks-nodes 10.101.0.0/24\nNSG: deny Internet inbound"]
        PENET["snet-private-endpoints 10.101.1.0/24\nNSG: allow only AKS + agent subnets on 443"]
        AGENTNET["snet-pipeline-agents 10.101.2.0/26\n(self-hosted Azure DevOps agent)"]
    end

    AKSNET -- "0.0.0.0/0 route via UDR\nnext hop = firewall private IP" --> FW
    FW -- "allow-listed FQDN only\n(api.tvmaze.com)" --> INTERNET(("TVMaze API\napi.tvmaze.com"))

    AKSNET -- "private endpoint, TLS 443" --> PENET
    AGENTNET -- "private endpoint, TLS 443" --> PENET
    AGENTNET -- "kube-apiserver, TLS 443" --> AKSNET

    PENET --- PE_ACR["PE: ACR"]
    PENET --- PE_KV["PE: Key Vault"]
    PENET --- PE_BLOB["PE: Storage Blob"]
    PENET --- PE_AKS["PE: AKS API server"]
    PENET --- PE_AMPLS["PE: AMPLS\n(Log Analytics / App Insights)"]

    HUB <-- "VNet peering" --> SPOKE

## 3. Request flow — `GET /api/shows`

sequenceDiagram
    participant Client as Internal consumer
    participant Pod as banking-application pod
    participant Blob as Blob Storage (Private Endpoint)
    participant FW as Azure Firewall
    participant TVMaze as TVMaze API

    Client->>Pod: GET /api/shows (ClusterIP or internal LB)
    Pod->>Blob: Check cache (Workload ID token, no keys)
    alt cache hit and fresh
        Blob-->>Pod: cached JSON
        Pod-->>Client: 200 OK (X-Cache: HIT)
    else cache miss or expired
        Pod->>FW: HTTPS to api.tvmaze.com
        FW->>TVMaze: allow-listed FQDN, deny everything else
        TVMaze-->>FW: show data
        FW-->>Pod: show data
        Pod->>Blob: write cache blob (Workload ID token)
        Pod-->>Client: 200 OK (X-Cache: MISS)
    end

The pod never holds a storage key or a TVMaze credential. It authenticates to
Blob Storage using the Azure identity federated to its ServiceAccount
(Workload ID) and the Azure SDK's default credential chain — see
[charts/banking-application/templates/serviceaccount.yaml](../charts/banking-application/templates/serviceaccount.yaml)
and [infra/terraform/modules/identity/main.tf](../infra/terraform/modules/identity/main.tf).
The smoke test in [scripts/smoke-test.sh](../scripts/smoke-test.sh) exercises
exactly this flow, including checking for a cache `HIT` on the second call.

## 4. DNS resolution path

flowchart LR
    P["Pod\n(app container)"] --> CD["CoreDNS\n(cluster DNS)"]
    CD -->|"not *.svc.cluster.local"| AZDNS["Azure-provided VNet DNS\n(168.63.129.16)"]
    AZDNS -->|"zone match:\nprivatelink.blob.core.windows.net etc."| PDNS["Private DNS zone\n(linked to spoke + hub VNets)"]
    PDNS -->|"A record"| PEIP["Private Endpoint\nprivate IP in snet-private-endpoints"]
    AZDNS -->|"no private zone match"| PUBLIC["Public DNS\n(only for api.tvmaze.com,\nresolved then routed via 

Walking it end to end for a Blob Storage lookup:

1. The pod issues a DNS query for `sa<env>01.blob.core.windows.net`.
2. CoreDNS in AKS forwards anything outside the cluster domain to the
   Azure-provided DNS resolver (168.63.129.16) that every VNet gets by
   default — no custom DNS forwarder was needed for this design because both
   AKS and the private endpoints live in VNets linked to the same private DNS
   zones.
3. Azure DNS recognises the query matches a linked private zone
   (`privatelink.blob.core.windows.net`) and returns the zone's A record
   instead of the public one.
4. That A record — created automatically alongside the private endpoint in
   [modules/storage-account/main.tf](../infra/terraform/modules/storage-account/main.tf)
   — points at the private endpoint's NIC address inside
   `snet-private-endpoints`.
5. The pod connects to that private IP over TLS.

## 5. CI/CD network path
flowchart LR
    subgraph Agent["Self-hosted agent VM — snet-pipeline-agents (rg_infra)"]
        A["Azure Pipelines agent\n(vm-agent-*, Terraform-managed)"]
    end
    KV["Key Vault (Private Endpoint)\nagent PAT secret"] -.->|"Key Vault Secrets User\n(agent's own managed identity)"| A
    A -->|"az acr login / helm push\nprivate DNS + PE"| ACR["ACR (Private Endpoint)"]
    A -->|"kubectl / helm upgrade\nprivate DNS + PE"| AKSAPI["AKS API server (Private Endpoint)"]
    A -->|"terraform apply\nARM control plane, public mgmt API"| ARM["Azure Resource Manager"]
    A -->|"OIDC federated credential\nno stored secret"| ENTRA["Microsoft Entra ID"]

## 6. Environment promotion flow

flowchart LR
    Validate --> Security --> BuildImage --> Infra_nonProd --> Deploy_nonProd --> Infra_Prod --> Deploy_Prod
    Infra_Prod -.->|"manual approval gate"| ManualGate1(("Approval"))
    Deploy_Prod -.->|"manual approval gate"| ManualGate2(("Approval"))

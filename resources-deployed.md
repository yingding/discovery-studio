# Resources deployed

Exhaustive inventory of every Azure resource you'll see after `./deploy.sh all`, grouped by who creates it and which stage triggers it. Use this to answer "what is this resource doing in my RG?" or "why are there two storage accounts?"

Companion to [architecture.md](architecture.md) (design / rationale) and [quickstart.md](quickstart.md) (operational reference).

## Contents

- [Resources in your deployment RG (`$RG`)](#resources-in-your-deployment-rg-rg)
- [Sibling resource groups (outside `$RG`)](#sibling-resource-groups-outside-rg)
- [Subscription-scope artifacts](#subscription-scope-artifacts)
- [Lifecycle matrix — what `pause` / `teardown` / re-`2` do to each](#lifecycle-matrix--what-pause--teardown--re-2-do-to-each)
- [How to discover what's actually there](#how-to-discover-whats-actually-there)

## Resources in your deployment RG (`$RG`)

`$RG` defaults to `rg-<PREFIX>` (e.g. `rg-disc-yw`). All examples below use `disc-yw`.

### Created by your Bicep

| Resource | Type | Stage | Purpose |
|---|---|---|---|
| `vnet-disc-yw` | `Microsoft.Network/virtualNetworks` | 1 | Top-level VNet `10.0.0.0/16` carrying all Discovery traffic |
| `vnet-disc-yw/aksSubnet` | subnet | 1 | Cluster control plane and system pool |
| `vnet-disc-yw/supercomputerNodepoolSubnet` | subnet | 1 | User GPU node pool (`np1`) VMSS |
| `vnet-disc-yw/workspaceSubnet` | subnet (delegated `Microsoft.App`) | 1 | Workspace container apps |
| `vnet-disc-yw/agentSubnet` | subnet (delegated `Microsoft.App`) | 1 | Foundry agent runtime |
| `vnet-disc-yw/privateEndpointSubnet` | subnet | 1 | Private endpoints for storage / Foundry |
| `vnet-disc-yw/searchSubnet` | subnet (delegated `Microsoft.App`) | 1 | Search / index runtime |
| `uami-disc-yw` | `Microsoft.ManagedIdentity/userAssignedIdentities` | 2 | Cluster, kubelet, workload identity for the supercomputer (and workspace identity in Stage 3) |
| `stg<prefix><hash>` (e.g. `stgdiscywliizk2ih`) | `Microsoft.Storage/storageAccounts` | 2 | Customer-owned blob storage backing the Discovery Storage Container; AAD-only auth |
| `stg…/default` | `blobServices` | 2 | CORS rules for Discovery Studio + VS Code |
| `stg…/default/discoveryoutputs` | `containers` | 2 | The blob container Discovery writes project outputs to |
| 3× role assignments | `Microsoft.Authorization/roleAssignments` | 2 | Storage Blob Data Contributor + Discovery Platform Contributor + AcrPull on the UAMI (see [roleconcept.md](roleconcept.md#resource-group-scope--uami-uami-prefix)) |
| `sc-disc-yw` | `Microsoft.Discovery/supercomputers` | 2 | Managed cluster (AKS-like) where Discovery jobs run |
| `sc-disc-yw/np1` | `Microsoft.Discovery/supercomputers/nodePools` | 2 | GPU/CPU user node pool (default `Standard_NC4as_T4_v3`, scale 0–1) |
| `ws-disc-yw` | `Microsoft.Discovery/workspaces` | 3 | User-facing workspace bound to the SC + delegated subnets |
| `ws-disc-yw/<chatModelName>` | `chatModelDeployments` | 3 | E.g. `gpt-5-mini`. Skip with `CHAT_MODEL_NAME=""` |
| `ws-disc-yw/default` | `projects` | 3 | Default project linked to the storage container |
| `stc-disc-yw` | `Microsoft.Discovery/storageContainers` | 3 | Logical Discovery handle pointing at `stg…` storage account |

### Auto-created by the Discovery resource provider (NOT in your Bicep)

You'll see these in the portal even though no template asked for them. Don't try to delete them manually.

| Resource | Type | Created in | Purpose | Notes |
|---|---|---|---|---|
| `act<random>` (e.g. `actdiscoveryuno`) | `Microsoft.Storage/storageAccounts` | Stage 3 (when the workspace is provisioned) | Workspace internal **act**ivity / artifact store — run history, intermediate artifacts, system bookkeeping | Opaque; lets Microsoft evolve storage shape without breaking your `stg…` |
| `act<random>-<guid>` | `Microsoft.EventGrid/systemTopics` | auto | Blob change events for the `act…` storage account | Free for system topics |
| `stg<prefix><hash>-<guid>` | `Microsoft.EventGrid/systemTopics` | auto | Blob change events for your customer storage | Free |
| `mobr-dscmp-sc-<prefix>-<random>` | `microsoft.resources/moboBrokers` | Stage 2 | Lifecycle broker that links the SC ARM resource to its managed-RG infrastructure (NSP, system pool, broker) | One per supercomputer |
| `mobr-dwsp-ws-<prefix>-<random>` | `microsoft.resources/moboBrokers` | Stage 3 | Lifecycle broker for the workspace's Foundry-managed RG | One per workspace |

## Sibling resource groups (outside `$RG`)

Discovery's RP creates additional resource groups in your subscription that you didn't create. They're not in `$RG` but they're part of your deployment.

| Resource group | Created in | What's inside | Cost impact |
|---|---|---|---|
| `mrg-dscmp-sc-<prefix>-<random>` | Stage 2 | Discovery's managed infra for the SC: the **NSP** (`nsp-sc-<prefix>-<random>`), an AKS control plane, plus pointers to the AKS-created MC_* RG | None directly (control plane) |
| `MC_mrg-dscmp-sc-<prefix>-<random>_aks-dscmp-<random>_<region>` | Stage 2 | The **system node pool VMSS** (`aks-system-<id>-vmss`, default `Standard_D4s_v6`) and the user node pool VMSS (`aks-np1-<id>-vmss`, your GPU SKU); Standard Load Balancer; route table; NSGs | **This is where the bulk of your bill comes from** — see [README → Estimated cost](README.md#estimated-cost-default-sweden-central-deployment) |
| `mrg-<workspaceName>-<region>-<random>` (e.g. `mrg-ws-disc-yw-swedencentral-7f5e`) | Stage 3 | Foundry account + Foundry project + chat model deployment runtime resources | Idle cost negligible (consumption / PAYG for token use) |

> The workspace managed RG (`mrg-<workspaceName>-…`) is what `./deploy.sh 4` targets — it assigns `Foundry User` there so Discovery Studio can open the workspace.

## Subscription-scope artifacts

Outside any single RG.

| Artifact | Type | Created by | Purpose |
|---|---|---|---|
| `Discovery NSP Perimeter Joiner` | custom RBAC role | `./deploy.sh prereqs` | Lets the Discovery first-party SP enroll the sub into its managed NSP. See [roleconcept.md](roleconcept.md#subscription-scope--discovery-first-party-sp) |
| Reader on Discovery SP | built-in RBAC | `./deploy.sh prereqs` | Required for NSP associations in Enforced mode |
| Discovery NSP Joiner + Reader role assignments on the Discovery first-party SP | role assignments | `./deploy.sh prereqs` | Where the two roles above get bound |
| `discovery-mcapsgov-<prefix>-MCAPSGovDenyPolicies` etc. | `Microsoft.Authorization/policyExemptions` | `./deploy.sh mcaps-exempt` (opt-in / MCAPS sub auto) | Lets the GPU VMSS bypass MCAPSGov deny policies on Microsoft tenant subs |

## Lifecycle matrix — what `pause` / `teardown` / re-`2` do to each

| Resource family | `./deploy.sh 2` re-run | `./deploy.sh pause` | `./deploy.sh teardown` |
|---|---|---|---|
| VNet + subnets (Stage 1) | no-op (Bicep idempotent) | kept | deleted (RG-wide delete) |
| UAMI / Storage / RBAC (Stage 2 user resources) | no-op | kept | deleted |
| `sc-<prefix>` + `np1` | recreated if `Failed`, else no-op | **deleted** | deleted |
| `mrg-dscmp-*` + `MC_mrg-dscmp-*` sibling RGs | recreated | **deleted** (release the always-on D4s_v6) | deleted |
| `mobr-dscmp-*` broker | no-op | deleted with the SC | deleted |
| `ws-<prefix>` + chat model + project + `stc-<prefix>` (Stage 3) | no-op | kept (Stage 3 not redeployed by `2`) | deleted |
| `act…` workspace storage + EG system topic | kept | kept (workspace untouched by `pause`) | deleted |
| `mrg-<workspaceName>-…` sibling RG (Foundry) | n/a | kept | deleted |
| Subscription-scope NSP/Reader/MCAPS role artifacts | no-op | kept (no reason to remove) | kept (cross-deployment) |

## How to discover what's actually there

```bash
RG=rg-discovery-yw-uno
PREFIX=disc-yw
SUB=$(az account show --query id -o tsv)

# Everything in your deployment RG
az resource list -g "$RG" -o table

# Sibling managed RGs that Discovery created in this sub
az group list --query "[?starts_with(name, 'mrg-') || starts_with(name, 'MC_mrg-')].name" -o tsv

# What's inside the SC managed infra RG
SCMRG=$(az group list --query "[?starts_with(name, 'mrg-dscmp-sc-${PREFIX}-')].name | [0]" -o tsv)
az resource list -g "$SCMRG" -o table
az vmss list -g "MC_${SCMRG}_aks-dscmp-$(echo $SCMRG | awk -F- '{print $NF}')_swedencentral" \
  --query "[].{name:name, sku:sku.name, capacity:sku.capacity}" -o table

# Workspace's Foundry-managed RG (target of ./deploy.sh 4)
az resource show -g "$RG" \
  --resource-type Microsoft.Discovery/workspaces \
  --name "ws-${PREFIX}" \
  --query properties.managedResourceGroup -o tsv

# Policy exemptions visible at sub scope
az rest --method get --uri "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview&\$filter=atScope()" \
  --query "value[].{name:name, category:properties.exemptionCategory, displayName:properties.displayName}" -o table
```

## Why this split (customer data vs system data)

Discovery follows a clean "customer-owned vs Microsoft-owned" split:

- **Customer-owned** (named with your `PREFIX`, tagged `purpose=discovery`, declared in [02-supercomputer.bicep](02-supercomputer.bicep) / [03-workspace.bicep](03-workspace.bicep)): you control CORS, identity, retention, RBAC. Safe to read/write directly.
- **Microsoft-owned** (`act…` storage, `mobr-…` brokers, `mrg-dscmp-*` and `mrg-<workspaceName>-…` sibling RGs): managed by the Discovery RP, schema-stable from your perspective. Microsoft can rotate / upgrade these without breaking your `stg…` / `ws-…` / `sc-…` ARM resources.

This is why you see "two storage accounts" — one is your data, the other is the workspace's internal bookkeeping. Same for the managed RGs: they isolate Microsoft-evolved infra from your declared resources so neither side breaks the other on upgrades.

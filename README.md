# Minimalistic Microsoft Discovery deployment (staged Bicep)

Three-stage Bicep deployment based on the official [Azure quickstart](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.discovery/discovery-infra-deployment).

| Stage | File | What it deploys |
|---|---|---|
| 1 | [01-network.bicep](01-network.bicep) | VNet + 6 subnets |
| 2 | [02-supercomputer.bicep](02-supercomputer.bicep) | UAMI · Storage · RBAC · Supercomputer · Node Pool |
| 3 | [03-workspace.bicep](03-workspace.bicep) | Workspace · Chat Model · Project · Discovery Storage Container |

For deep dives see [architecture.md](architecture.md) (resource graph, RBAC, network model), [roleconcept.md](roleconcept.md) (every RBAC role used and why), and [quickstart.md](quickstart.md) (full helper-script reference).

## Contents

- [Minimal quickstart](#minimal-quickstart)
- [Prerequisites](#prerequisites)
- [Helper scripts](#helper-scripts)
- [Estimated cost (default Sweden Central deployment)](#estimated-cost-default-sweden-central-deployment)
- [Customising each stage](#customising-each-stage)
- [Local validation](#local-validation)
- [Connect](#connect)

## Minimal quickstart

```bash
export RG=rg-discovery-yw-uno
export LOCATION=swedencentral

./deploy.sh prereqs            # one-time per sub (~1 min) — registers RPs, creates RG, assigns NSP/Reader roles
./deploy.sh 1                  # Stage 1: networking            (~1 min)
./deploy.sh 2                  # Stage 2: SC + node pool        (~20-35 min)
./deploy.sh 3                  # Stage 3: workspace + project   (~15-30 min)
```

Or run all stages in one shot with `./deploy.sh all`.

When idle: `./deploy.sh pause` (drops idle cost to ~$0). Resume with `./deploy.sh 2`.

See [quickstart.md](quickstart.md) for the full subcommand reference, customisation knobs, and troubleshooting.

## Prerequisites

1. **Platform/IT admin** persona roles. Quick way: run [`Set-DiscoveryRoleAssignments.ps1`](https://learn.microsoft.com/en-gb/azure/microsoft-discovery/how-to-assign-persona-roles).
2. **Discovery NSP Perimeter Joiner** custom role + Reader role on the Discovery first-party SP. ✅ **`./deploy.sh prereqs` handles both automatically** (idempotent). Requires **Owner** or **User Access Administrator** on the subscription. Background and reference: [roleconcept.md → subscription-scope](roleconcept.md#subscription-scope--discovery-first-party-sp), [quickstart.md → setup](quickstart.md#setup), and [Microsoft Discovery NSP docs](https://learn.microsoft.com/en-gb/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#assign-the-nsp-perimeter-joiner-role).
3. Quota in target region (`Microsoft.Compute` for the node pool SKU you pick).
4. Required Azure resource providers — `./deploy.sh prereqs` registers the core 6; full list in [Discovery quickstart prerequisites](https://learn.microsoft.com/en-us/azure/microsoft-discovery/quickstart-infrastructure-portal#prerequisites).

> ARM API: `Microsoft.Discovery/*@2026-06-01`.

## Helper scripts

| Script | Purpose |
|---|---|
| [deploy.sh](deploy.sh) | All lifecycle commands: `prereqs`, `1`/`2`/`3`/`all`, `pause`, `teardown`, `roles`, `outputs`, `build` |
| [poll.sh](poll.sh) | Color-coded real-time watcher for the latest deployment + SC + np1 |
| [cost.sh](cost.sh) | Live monthly cost estimate from the Azure Retail Prices API |

Every `deploy.sh` stage prints `START` / `END` / elapsed-minute banners. Watch a long stage in a second terminal:

```bash
RG=rg-discovery-yw-uno ./poll.sh                 # default: watches Stage 2
STAGE=3 ./poll.sh                                # watch Stage 3
```

## Estimated cost (default Sweden Central deployment)

Numbers from `./cost.sh` for the default scope (1× `Standard_D4s_v6` system pool + 1× `Standard_NC4as_T4_v3` T4 node pool, scale 0–1):

| Scenario | Monthly | Notes |
|---|---|---|
| **Idle** (`np1` scaled to 0) | **~$156** | Managed system pool D4s_v6 always on — unavoidable while SC exists |
| **Active** (`np1` at max=1, 24×7) | **~$564** | Adds T4 on-demand (~$0.56/hr × 730 h) |
| **Spot** (`NODE_POOL_PRIORITY=Spot`) | **~$279** | T4 spot ≈ 30 % of on-demand; eviction-tolerant workloads only |
| **`./deploy.sh pause`** | **~$0** | Deletes SC + managed `mrg-dscmp-*` RG; keeps VNet/UAMI/storage/RBAC. Resume in 10–30 min |
| **`./deploy.sh teardown`** | **~$0** | Full RG delete; redeploy in 40–60 min |

> Excludes egress, support plans, chat-model token usage, AKS-internal traffic, and reservations / savings plans. Run `./cost.sh` for live numbers against your actual deployment.

## Customising each stage

Edit the matching `*.parameters.json` file or pass `--parameters key=value` flags. Full env-var table in [quickstart.md → customisation](quickstart.md#customisation).

- **Stage 1 — networking:** `vnetAddressPrefix`, `aksSubnetPrefix`, `workspaceSubnetPrefix`, `agentSubnetPrefix`, `privateEndpointSubnetPrefix`, `searchSubnetPrefix`, `supercomputerNodepoolSubnetPrefix`.
- **Stage 2 — supercomputer:** `nodePoolVmSize` (e.g. `Standard_NC4as_T4_v3`, `Standard_NC24ads_A100_v4`), `nodePoolMinNodeCount`, `nodePoolMaxNodeCount`, `nodePoolScaleSetPriority` (`Regular` | `Spot`).
- **Stage 3 — workspace:** `chatModelName` (set to `""` to skip the chat model deployment), `chatModelFormat`.

## Local validation

```bash
./deploy.sh build              # compiles all 3 stages with `az bicep build` (no Azure calls)
```

## Connect

After Stage 3, sign in to <https://studio.discovery.microsoft.com/>, select the workspace `ws-<PREFIX>`, create a project investigation, and start a chat.

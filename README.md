# Minimalistic Microsoft Discovery deployment (staged Bicep)

Three-stage Bicep deployment based on the official [Azure quickstart](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.discovery/discovery-infra-deployment).

| Stage | File | What it deploys |
|---|---|---|
| 1 | [01-network.bicep](01-network.bicep) | VNet + 6 subnets |
| 2 | [02-supercomputer.bicep](02-supercomputer.bicep) | UAMI · Storage · RBAC · Supercomputer · Node Pool |
| 3 | [03-workspace.bicep](03-workspace.bicep) | Workspace · Chat Model · Project · Discovery Storage Container |

See [architecture.md](architecture.md) for diagrams and per-resource details.

## Prerequisites

1. **Platform/IT admin** persona roles. Quick way: run [`Set-DiscoveryRoleAssignments.ps1`](https://learn.microsoft.com/en-gb/azure/microsoft-discovery/how-to-assign-persona-roles).
2. **Discovery NSP Perimeter Joiner** custom role created and assigned to the Discovery first-party SP — see [docs](https://learn.microsoft.com/en-gb/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#assign-the-nsp-perimeter-joiner-role).
3. Quota in target region (`Microsoft.Compute` for the node pool SKU you pick).
4. Required Azure resource providers registered on your subscription. `./deploy.sh prereqs` registers the core 6 needed by this template; the full list (≈24 providers) is documented in [Discovery quickstart prerequisites](https://learn.microsoft.com/en-us/azure/microsoft-discovery/quickstart-infrastructure-portal#prerequisites).

> At the time of writing, uses ARM API `Microsoft.Discovery/*@2026-06-01`.

## Step-by-step deployment

```bash
# Override defaults if needed:
export RG=rg-discovery-yw-uno
export LOCATION=swedencentral

./deploy.sh prereqs            # register providers + create RG
./deploy.sh 1                  # Stage 1: networking            (~1 min)
./deploy.sh 2                  # Stage 2: SC + node pool        (~15-30 min)
./deploy.sh 3                  # Stage 3: workspace + project   (~15-30 min)
```

Or do it all at once:

```bash
./deploy.sh all
```

Inspect / clean up:

```bash
./deploy.sh outputs            # list resources
./deploy.sh teardown           # delete the RG
```

## Customizing each stage

Edit the matching `*.parameters.json` file or pass `--parameters key=value` flags. All stages share the `prefix` parameter (default `disc-yw`); names are derived from it (`vnet-<prefix>`, `sc-<prefix>`, `ws-<prefix>`, …).

**Stage 1 — networking:** `vnetAddressPrefix`, `aksSubnetPrefix`, `workspaceSubnetPrefix`, `agentSubnetPrefix`, `privateEndpointSubnetPrefix`, `searchSubnetPrefix`, `supercomputerNodepoolSubnetPrefix`.

**Stage 2 — supercomputer:** `nodePoolVmSize` (e.g. `Standard_NC4as_T4_v3`, `Standard_NC24ads_A100_v4`), `nodePoolMinNodeCount`, `nodePoolMaxNodeCount`, `nodePoolScaleSetPriority` (`Regular` | `Spot`).

**Stage 3 — workspace:** `chatModelName` (set to `""` to skip the chat model deployment), `chatModelFormat`.

## Local validation

```bash
./deploy.sh build              # compiles all 3 stages with `az bicep build` (no Azure calls)
```

Equivalent manual loop:

```bash
for f in 01-network.bicep 02-supercomputer.bicep 03-workspace.bicep; do
  az bicep build --file "$f" --stdout > /dev/null && echo "OK: $f"
done
```

## Connect

After Stage 3, sign in to <https://studio.discovery.microsoft.com/>, select the workspace `ws-disc-yw`, create a project investigation, and start a chat.

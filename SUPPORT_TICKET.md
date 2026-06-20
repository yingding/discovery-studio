# Orphan `legionservicelink` SAL after Microsoft Discovery workspace failure

## Subject

Discovery workspace failed deploy left orphan `legionservicelink` SAL on `agentSubnet` — backend purge needed to unlock VNet / RG delete

## Service

Microsoft Discovery (`Microsoft.Discovery/workspaces@2026-06-01`), with downstream impact on `Microsoft.App/environments` and `Microsoft.Network/virtualNetworks`.

## What happened

A `Microsoft.Discovery/workspaces@2026-06-01` deploy failed mid-way (Foundry capability-host preflight on the OpenAI dependency). The workspace and its Discovery-managed resource group (`mrg-dwsp-<workspace>-<rand>`) were force-deleted to recover. The Foundry capability host's Service Association Link on `agentSubnet` was not released by the platform tear-down and is now orphaned. Subnet / VNet / parent-RG delete are all permanently blocked.

## Orphan SAL

`.../virtualNetworks/<vnet>/subnets/agentSubnet/serviceAssociationLinks/legionservicelink`

- `linkedResourceType`: `Microsoft.App/environments`
- `allowDelete`: `false`
- `provisioningState`: `Succeeded`
- Owning capability host no longer exists.

## Already tried — all fail

| # | Attempt | Result |
|---|---|---|
| 1 | SAL `DELETE` via `az rest ?force=true` | `UnauthorizedClientApplication` |
| 2 | Subnet `PUT` without `serviceAssociationLinks` | SAL remains |
| 3 | `az network vnet subnet delete agentSubnet` | `InUseSubnetCannotBeDeleted` |
| 4 | `az network vnet delete <vnet>` | `InUseSubnetCannotBeDeleted` |
| 5 | `az group delete <rg>` | Stuck in `Deleting` indefinitely |
| 6 | `POST .../Microsoft.Web/locations/<region>/purgeUnusedVirtualNetworkIntegration?api-version=2024-04-01` (per [MS Learn Q&A 5869381][1]) | Returns `"Purged unused virtual network integration"`, SAL still present, subnet delete still fails |

## Request

Per the accepted answer in [MS Learn Q&A 5869381][1], backend team needs to purge the lingering `serviceAssociationLink` from the network platform so subnet / VNet / resource group can complete deletion.

## Repro signature (for product team)

Triggered reliably when a `Microsoft.Discovery/workspaces@2026-06-01` deploy reaches Foundry capability-host creation, fails, and the workspace is then deleted to recover. The capability-host tear-down hook that should release `legionservicelink` does not fire on this abnormal path, leaving the SAL un-removable from any user-callable API.

[1]: https://learn.microsoft.com/en-us/answers/questions/5869381/cannot-delete-vnet-because-of-orphaned-serviceasso

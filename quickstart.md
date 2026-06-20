# Quickstart — Microsoft Discovery staged Bicep

End-to-end walkthrough of the helper scripts in this repo: [deploy.sh](deploy.sh), [poll.sh](poll.sh), [cost.sh](cost.sh). Companion to the high-level [README.md](README.md) and the design doc [architecture.md](architecture.md).

## Contents

- [Quick start](#quick-start)
- [Prerequisites (once per subscription)](#prerequisites-once-per-subscription)
- [`deploy.sh` subcommand reference](#deploysh-subcommand-reference)
  - [Setup](#setup)
  - [Deploy](#deploy)
  - [Lifecycle](#lifecycle)
  - [Customisation](#customisation)
- [`poll.sh` — watch a deployment in real time](#pollsh--watch-a-deployment-in-real-time)
- [`cost.sh` — live monthly estimate](#costsh--live-monthly-estimate)
- [Connect](#connect)
- [Troubleshooting](#troubleshooting)

## Quick start

```bash
git clone git@github.com:yingding/discovery-studio.git
cd discovery-studio

export RG=rg-discovery-yw-uno
export LOCATION=swedencentral
export PREFIX=disc-yw            # all resource names derive from this

./deploy.sh prereqs              # one-time per subscription (~1 min)
./deploy.sh all                  # stages 1 + 2 + 3                 (~40-70 min)
./cost.sh                        # see what you're paying for
```

When you don't need the cluster: `./deploy.sh pause` (~$0/mo). Resume with `./deploy.sh 2`.

## Prerequisites (once per subscription)

1. **Azure CLI** ≥ 2.60 and **Bicep CLI** (`az bicep install`).
2. Signed in: `az login`, `az account set --subscription <id>`.
3. **Owner** or **User Access Administrator** on the subscription — needed to:
   - Register resource providers
   - Create the custom NSP Joiner role at subscription scope
   - Assign Reader + NSP Joiner roles to the Discovery first-party SP
4. **Discovery preview access** enabled for the subscription.
5. **Quota** for your chosen GPU SKU in the target region (the script will surface ARM errors if missing).

> Available regions for Microsoft Discovery: `eastus`, `eastus2`, `swedencentral`, `uksouth`.

## `deploy.sh` subcommand reference

All commands respect `RG`, `LOCATION`, `PREFIX`, and the CONFIG block at the top of the script (override via env vars, e.g. `NODE_POOL_VM_SIZE=Standard_NC24ads_A100_v4 ./deploy.sh 2`).

### Setup

| Command | What it does | Idempotent? |
|---|---|---|
| `./deploy.sh prereqs` | Registers RPs, creates the RG, ensures **Reader** + **Discovery NSP Perimeter Joiner** role assignments on the Discovery first-party SP at subscription scope. | ✅ |
| `./deploy.sh nsp-role` | Just the role part of `prereqs` (run if you only need to re-assert the SP roles). | ✅ |
| `./deploy.sh roles [user-upn-or-objectid]` | Assigns the platform-admin persona roles on the RG to the signed-in user (or the user you pass). | ✅ |

Why the NSP Joiner role? The GA API `Microsoft.Discovery/*@2026-06-01` auto-creates a Network Security Perimeter and enrols your subscription. That join requires `Microsoft.Network/networkSecurityPerimeters/joinPerimeterRule/action` at subscription scope on the Discovery SP. Reader is also needed for "NSP associations in Enforced mode". The [official quickstart template](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.discovery/discovery-infra-deployment) doesn't mention this because it still uses the preview API `@2026-02-01-preview` which skips the NSP step. See [roleconcept.md → subscription-scope](roleconcept.md#subscription-scope--discovery-first-party-sp) for the full role table and [Microsoft Discovery NSP docs](https://learn.microsoft.com/en-gb/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#assign-the-nsp-perimeter-joiner-role).

### Deploy

| Command | Stage | Wall-clock | Resources |
|---|---|---|---|
| `./deploy.sh 1` (or `network`) | 1 | ~1 min | VNet + 6 subnets |
| `./deploy.sh 2` (or `supercomputer` / `sc`) | 2 | ~10–20 min (SC ~8–15 min, np1 ~2–5 min once VMSS create is allowed) | UAMI · Storage · RBAC · Supercomputer · Node Pool |
| `./deploy.sh 3` (or `workspace` / `ws`) | 3 | ~15–30 min | Workspace · Chat Model · Project · Discovery Storage Container |
| `./deploy.sh 4` (or `foundry-role`) | 4 (post-deploy) | ~10 s | Assigns `Foundry User` to the signed-in az user (or `./deploy.sh 4 <upn-or-objectid>`) on the workspace's managed RG so Discovery Studio can open the workspace. Idempotent. |
| `./deploy.sh all` | prereqs + 1 + 2 + 3 + 4 | ~40–70 min | Everything end-to-end |
| `./deploy.sh build` | none (local) | ~10 s | Local `az bicep build` of all 3 templates |

Every stage prints `START` / `END` / elapsed-minute banners around the `az deployment group create` call.

### Lifecycle

| Command | Effect | Idempotent? |
|---|---|---|
| `./deploy.sh outputs` | Lists all resources in the RG. | n/a |
| `./deploy.sh pause` | Deletes the SC (cascades to np1) **plus the managed `mrg-dscmp-*` RG**, but keeps the VNet, UAMI, storage, RBAC, and prereq role assignments. Idle cost ≈ $0. Resume with `./deploy.sh 2`. Takes 5–15 min. | ✅ |
| `./deploy.sh teardown` | `az group delete --no-wait` on the whole RG. Use for long pauses. Full redeploy ~40–60 min. | ✅ |

### Customisation

Edit the matching `*.parameters.json` or set env vars before running:

| Env var | Stage | Default | Notes |
|---|---|---|---|
| `PREFIX` | all | `disc-yw` | Drives every resource name (`vnet-<prefix>`, `sc-<prefix>`, …) |
| `LOCATION` | all | `swedencentral` | One of the 4 Discovery regions |
| `RG` | all | `rg-<PREFIX>` | Resource group name |
| `TAG_PURPOSE` | all | `discovery` | FinOps tag value applied to every resource |
| `NODE_POOL_VM_SIZE` | 2 | `Standard_NC4as_T4_v3` | See [SKU table below](#node-pool-sku-options) |
| `NODE_POOL_MIN_NODE_COUNT` | 2 | `0` | Scale-to-zero default |
| `NODE_POOL_MAX_NODE_COUNT` | 2 | `1` | Max GPU nodes |
| `NODE_POOL_PRIORITY` | 2 | `Regular` | `Regular` or `Spot` — Spot ≈ 30 % of on-demand |
| `CHAT_MODEL_NAME` | 3 | `gpt-5-mini` | Set to `""` to skip the chat model deployment |

#### Node pool SKU options

| SKU | GPU | ~$/hr (Sweden Central, Linux PAYG) | When |
|---|---|---|---|
| `Standard_D4s_v6` | none | ~$0.21 | CPU-only validation / debugging |
| `Standard_NC4as_T4_v3` | 1× T4 (16 GB) | ~$0.56 | Default — most experiments |
| `Standard_NC8as_T4_v3` | 1× T4, 8 vCPU | ~$0.75 | More CPU per GPU |
| `Standard_NC24ads_A100_v4` | 1× A100 (80 GB) | ~$3.67 | Large models, fine-tuning |

Use `./cost.sh` to see live prices for your region and chosen SKU.

## `poll.sh` — watch a deployment in real time

Color-coded line per cycle: `[time | +elapsed] deployment=… state | sc=… | np1=…`. Auto-exits on terminal state (Succeeded / Failed / Canceled) or after `MAX_UNKNOWN` consecutive unreadable polls.

```bash
./poll.sh                           # default: Stage 2, every 60 s
INTERVAL=30 ./poll.sh               # custom poll interval
STAGE=3 ./poll.sh                   # watch Stage 3 (workspace)
MAX_UNKNOWN=10 ./poll.sh            # tolerate more transient empty polls
```

| Exit code | Meaning |
|---|---|
| `0` | Deployment Succeeded |
| `1` | Deployment Failed — failed operations are dumped to stdout |
| `2` | Gave up after `MAX_UNKNOWN` polls without a readable state |

Run it in a second terminal while `./deploy.sh 2` or `./deploy.sh 3` works.

## `cost.sh` — live monthly estimate

Queries the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) (no auth required) for the actual VM SKUs in your deployment and prints:

- **Idle subtotal** — system pool only (np1 at 0 nodes)
- **Active subtotal** — np1 at max node count, 24×7
- **Cost-saving levers** — Spot switch / `pause` / `teardown`

```bash
./cost.sh                           # auto-detects RG, region, SKUs
RG=rg-foo PREFIX=disc-bar ./cost.sh
```

Excludes: egress, support plans, chat-model token consumption, AKS-internal traffic, reservations / savings plans.

## Connect

After Stage 3 finishes, sign in to <https://studio.discovery.microsoft.com/>, select your workspace (`ws-<PREFIX>`), create a project investigation, and start a chat.

If the workspace doesn't open, run **Stage 4** (`./deploy.sh 4`) to assign the `Foundry User` role to the signed-in az user on the workspace's managed RG. Pass a UPN or object id to assign to someone else: `./deploy.sh 4 alice@example.com`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Stage 2 fails with `LinkedAuthorizationFailed` on `joinPerimeterRule/action` | NSP Joiner role missing on Discovery SP | `./deploy.sh prereqs` (or `nsp-role`) |
| Stage 2 fails with "Control Plane service principal does not have Reader permission at subscription … NSP associations in Enforced mode" | Reader role missing on Discovery SP | `./deploy.sh prereqs` (or `nsp-role`) |
| `sc-…` stuck in `Failed` after a previous error | Stale state in the managed `mrg-dscmp-*` RG | `./deploy.sh pause` then `./deploy.sh 2` |
| Stage 2 fails with `RequestDisallowedByPolicy` on the GPU VMSS | MCAPS deny policy blocks the SKU (Microsoft-tenant subs only) | `MCAPS_EXEMPTION=1 ./deploy.sh prereqs` (or ask MG admin to create the exemption manually) |
| Stage 3 runs >60 min and `ws=Accepted`; Discovery Studio shows "workspace in Accepted state, cannot create projects" | Discovery RP @2026-06-01 sometimes hangs on the final ARM callback even though all managed-RG resources are Succeeded | **Be patient.** Don't cancel, don't PATCH, don't re-run Bicep — those writes return `InvalidResourceOperation` and can push the workspace into a stuck Accepted state for 30–60+ min. Wait up to ~2 hours on the first deploy. If still stuck, last resort: delete the workspace and let Stage 3 recreate it from scratch (loses ~30–60 min of provisioning). |
| `InvalidResourceOperation: ws being provisioned with state: Accepted` | You re-PUT or PATCHed an in-flight workspace | Don't. The script's `stage_3()` only PUTs the workspace when it doesn't already exist; if it does, it skips Bicep and creates only the missing children via direct REST. |
| `cost.sh` shows `WARN: Retail API empty` | Region or SKU name mismatch | Confirm `LOCATION` is one of the 4 Discovery regions and the SKU is spelled exactly as in the Azure portal |
| Poller stuck on `Unknown` | List query transient empty | Re-run; the script tolerates 5 consecutive Unknowns then exits rc=2 |
| `./deploy.sh prereqs` fails on role create | Not Owner/UAA on the subscription | Ask a subscription owner to run `./deploy.sh nsp-role` once |

For deeper architectural context (resource graph, network model, RBAC mapping), read [architecture.md](architecture.md). For a complete RBAC role-by-role reference (who, where, why), read [roleconcept.md](roleconcept.md). For the full inventory of every resource that ends up in your subscription — yours plus the auto-created ones — read [resources-deployed.md](resources-deployed.md).

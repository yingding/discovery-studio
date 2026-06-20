#!/usr/bin/env bash
# Staged Microsoft Discovery deployment.
#
# Usage:
#   ./deploy.sh build                        # local Bicep compile/lint (no Azure call)
#   ./deploy.sh prereqs                      # register providers + create RG + assign NSP/Reader
#                                            # roles on the Discovery first-party SP. Also runs
#                                            # ensure_mcaps_exemption when MCAPS_EXEMPTION=1.
#   ./deploy.sh roles [user-upn-or-objectid] # assign Discovery Platform Admin persona roles on RG
#                                            # (defaults to the signed-in user)
#   ./deploy.sh nsp-role                     # ensure the Discovery first-party SP has the
#                                            # "Discovery NSP Perimeter Joiner" custom role + Reader
#                                            # at subscription scope (auto-run by `prereqs`).
#                                            # Required by Microsoft.Discovery/*@2026-06-01 GA API
#                                            # which auto-creates an NSP and enrolls the sub.
#                                            # Docs: https://learn.microsoft.com/en-gb/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#assign-the-nsp-perimeter-joiner-role
#   ./deploy.sh mcaps-exempt                 # opt-in: ensure Azure Policy exemptions exist on this
#                                            # subscription for each assignment listed in
#                                            # MCAPS_ASSIGNMENT_NAMES (default: MCAPSGovDeployPolicies
#                                            # and MCAPSGovDenyPolicies). The Deny one is what
#                                            # blocks the GPU VMSS the Discovery node pool creates.
#                                            # `prereqs` auto-runs this on MCAPS-governed subs
#                                            # (subscription name matches MngEnvMCAP*). Force on/off
#                                            # via MCAPS_EXEMPTION=1|0 (default: auto).
#                                            # Skips create when an exemption (self- or admin-created,
#                                            # any scope) already targets the assignment.
#                                            # Category defaults to Mitigated, expires 2030-01-01.
#                                            # Override with MCAPS_EXEMPTION_CATEGORY=Waiver,
#                                            # MCAPS_EXEMPTION_EXPIRES_ON=<ISO8601>, etc.
#   ./deploy.sh pause                        # delete the supercomputer (and its managed mrg-dscmp-* RG)
#                                            # to stop the always-on system-pool cost. VNet/UAMI/
#                                            # storage/RBAC are kept. Resume with `./deploy.sh 2`.
#   ./deploy.sh status                       # read-only one-screen summary of Stage 1–4 + orphan flags
#                                            # (no Azure mutations; great for re-orienting on a project).
#   ./deploy.sh cleanup-ws | cleanup-3       # full Stage 3 cleanup after a failed workspace deploy:
#                                            # delete the workspace + its managed RG (mrg-dwsp-*),
#                                            # then force-delete the stale Foundry Service Association
#                                            # Link ('legionservicelink') that gets left on agentSubnet.
#                                            # Without this, every retry fails with
#                                            # "subnet agentSubnet is already in use".
#                                            # Env: CLEANUP_WAIT_MIN=10 (max minutes to wait for the
#                                            # managed RG to disappear before forcing SAL delete),
#                                            # CLEANUP_RECREATE_SUBNET=1 (last resort: drop the subnet
#                                            # and re-run Stage 1 to restore it).
#   ./deploy.sh 1 | network                  # Stage 1: VNet + subnets
#   ./deploy.sh 2 | supercomputer            # Stage 2: UAMI + Storage + RBAC + SC + NodePool
#   ./deploy.sh 3 | workspace                # Stage 3: Workspace + ChatModel + Project + Container
#   ./deploy.sh 4 [user-upn-or-objectid]     # Stage 4 (post-3): assign 'Foundry User' to the signed-in
#                                            # user (or the user you pass) on the workspace's managed
#                                            # RG so Discovery Studio can open the workspace.
#                                            # Idempotent.
#                                            # Examples:
#                                            #   ./deploy.sh 4                          # signed-in az user
#                                            #   ./deploy.sh 4 alice@example.com        # specific UPN
#                                            #   ./deploy.sh 4 11111111-2222-3333-...   # specific object id
#   ./deploy.sh all                          # prereqs + 1 + 2 + 3 + 4
#   ./deploy.sh outputs                      # list deployed resources
#   ./deploy.sh teardown                     # full RG delete in dependency order:
#                                            # workspace -> nodepools -> supercomputer -> RG.
#                                            # Waits for the RG to fully vanish (TEARDOWN_WAIT=0
#                                            # to skip the wait). VNet drop also disposes of any
#                                            # locked `legionservicelink` SAL on agentSubnet.
#
# Configure RG/location via env vars:
#   RG=rg-discovery-yw-uno LOCATION=swedencentral ./deploy.sh 1
#   MCAPS_EXEMPTION=0 ./deploy.sh prereqs                          # disable MCAPS check even on MCAPS sub
#   MCAPS_EXEMPTION=1 ./deploy.sh prereqs                          # force MCAPS check on non-MCAPS sub

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — edit these to change deployment values without touching Bicep/JSON.
# Anything you set here overrides the matching parameter in *.parameters.json
# at deploy time via `--parameters key=value`.
# Syntax `${FOO:-bar}` = use $FOO if set & non-empty, else fall back to "bar"
# (so each var is also overridable from the environment, e.g. `RG=rg-x ./deploy.sh 1`).
# ---------------------------------------------------------------------------

# Master knob — every Discovery resource name is derived from this.
# e.g. PREFIX=disc-yw  -> vnet-disc-yw, sc-disc-yw, ws-disc-yw, uami-disc-yw, ...
PREFIX="${PREFIX:-disc-yw}"

LOCATION="${LOCATION:-swedencentral}"
RG="${RG:-rg-${PREFIX}}"                                   # default: rg-<PREFIX>
TAG_PURPOSE="${TAG_PURPOSE:-discovery}"                    # FinOps tag value

# Stage 2 — Supercomputer / Node pool
NODE_POOL_VM_SIZE="${NODE_POOL_VM_SIZE:-Standard_NC4as_T4_v3}"
NODE_POOL_MIN_NODE_COUNT="${NODE_POOL_MIN_NODE_COUNT:-0}"
NODE_POOL_MAX_NODE_COUNT="${NODE_POOL_MAX_NODE_COUNT:-1}"
NODE_POOL_PRIORITY="${NODE_POOL_PRIORITY:-Regular}"        # Regular | Spot

# Stage 3 — Workspace / Chat model
CHAT_MODEL_NAME="${CHAT_MODEL_NAME:-gpt-5-mini}"            # set to "" to skip chat model

# MCAPS Policy exemption
# Auto-detected: enabled when the subscription name matches the
# Microsoft-tenant MCAPS pattern (e.g. "ME-MngEnvMCAP..."); skipped
# otherwise. Force on/off with MCAPS_EXEMPTION=1 / MCAPS_EXEMPTION=0.
# Only relevant on MCAPS-governed subs where the deny policy blocks the
# GPU VMSS the Discovery node pool creates.
MCAPS_EXEMPTION="${MCAPS_EXEMPTION:-auto}"
# Bash glob pattern matched against `az account show --query name` to
# decide whether a subscription is MCAPS-governed. Edit or override if
# your tenant uses a different naming convention.
MCAPS_SUBSCRIPTION_PATTERN="${MCAPS_SUBSCRIPTION_PATTERN:-*MngEnvMCAP*}"
MCAPS_EXEMPTION_NAME="${MCAPS_EXEMPTION_NAME:-discovery-mcapsgov-${PREFIX}}"
# Which MCAPSGov assignments to check/exempt. Comma-separated list of
# assignment names. Defaults cover both the Deploy/Modify initiative and
# the Deny initiative (the actual RequestDisallowedByPolicy source for
# GPU VMSS creation).
MCAPS_ASSIGNMENT_NAMES="${MCAPS_ASSIGNMENT_NAMES:-${MCAPS_ASSIGNMENT_NAME:-MCAPSGovDeployPolicies,MCAPSGovDenyPolicies}}"
# Exemption category: Waiver (accept risk, no compensating control) or
# Mitigated (risk addressed elsewhere, e.g. Defender for Cloud + managed
# Discovery control plane). Mitigated reads better in audits.
MCAPS_EXEMPTION_CATEGORY="${MCAPS_EXEMPTION_CATEGORY:-Mitigated}"
MCAPS_EXEMPTION_EXPIRES_ON="${MCAPS_EXEMPTION_EXPIRES_ON:-2030-01-01T00:00:00Z}"

# Per-stage extra-parameter arrays (built from CONFIG above)
TAGS_OBJECT="{\"purpose\":\"${TAG_PURPOSE}\"}"
STAGE1_PARAMS=( prefix="$PREFIX" tags="$TAGS_OBJECT" )
STAGE2_PARAMS=(
  prefix="$PREFIX"
  tags="$TAGS_OBJECT"
  nodePoolVmSize="$NODE_POOL_VM_SIZE"
  nodePoolMinNodeCount="$NODE_POOL_MIN_NODE_COUNT"
  nodePoolMaxNodeCount="$NODE_POOL_MAX_NODE_COUNT"
  nodePoolScaleSetPriority="$NODE_POOL_PRIORITY"
)
STAGE3_PARAMS=(
  prefix="$PREFIX"
  tags="$TAGS_OBJECT"
  chatModelName="$CHAT_MODEL_NAME"
)
# ---------------------------------------------------------------------------

SUBSCRIPTION="$(az account show --query id -o tsv)"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Print a START/END/elapsed banner around a function call.
# Usage: time_step <label> <function-name> [args...]
# Prints END on success and on error (since `|| rc=$?` swallows the exit code);
# not on Ctrl-C / signal kills.
time_step() {
  local label="$1"; shift
  local start_ts start_human end_human elapsed_s elapsed_min rc=0
  start_ts=$(date +%s)
  start_human=$(date '+%Y-%m-%d %H:%M:%S %Z')
  log "${label} START: $start_human"

  "$@" || rc=$?

  end_human=$(date '+%Y-%m-%d %H:%M:%S %Z')
  elapsed_s=$(( $(date +%s) - start_ts ))
  elapsed_min=$(awk "BEGIN { printf \"%.1f\", $elapsed_s/60 }")
  log "${label} END:   $end_human  (elapsed: ${elapsed_min} min / ${elapsed_s}s, rc=$rc)"
  return $rc
}

_run_prereqs() {
  log "Subscription : $SUBSCRIPTION"
  log "Resource grp : $RG"
  log "Location     : $LOCATION"

  log "Checking required resource providers..."
  for ns in Microsoft.Discovery Microsoft.App Microsoft.ContainerService \
            Microsoft.Network Microsoft.ManagedIdentity Microsoft.Storage; do
    state="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || true)"
    if [[ "$state" == "Registered" ]]; then
      printf '    %-30s already Registered, skipping\n' "$ns"
    else
      printf '    %-30s state=%s, registering...\n' "$ns" "${state:-NotFound}"
      az provider register --namespace "$ns" --wait 1>/dev/null
      printf '    %-30s now %s\n' "$ns" "$(az provider show -n "$ns" --query registrationState -o tsv)"
    fi
  done

  log "Checking resource group $RG..."
  if [[ "$(az group exists --name "$RG")" == "true" ]]; then
    existing_loc="$(az group show --name "$RG" --query location -o tsv)"
    if [[ "$existing_loc" != "$LOCATION" ]]; then
      echo "WARNING: $RG already exists in '$existing_loc', not '$LOCATION'. Reusing as-is." >&2
    else
      printf '    %-30s already exists in %s, ensuring tag\n' "$RG" "$existing_loc"
    fi
    az group update --name "$RG" --tags purpose="$TAG_PURPOSE" -o none
  else
    printf '    %-30s creating in %s with tag purpose=%s...\n' "$RG" "$LOCATION" "$TAG_PURPOSE"
    az group create --name "$RG" --location "$LOCATION" --tags purpose="$TAG_PURPOSE" -o none
  fi

  ensure_nsp_joiner_role

  # MCAPS exemption check: auto-detect (or honor explicit on/off).
  local mcaps_run=0
  case "$MCAPS_EXEMPTION" in
    1|true|on|yes) mcaps_run=1 ;;
    0|false|off|no) mcaps_run=0 ;;
    auto|*)
      local sub_name
      sub_name="$(az account show --query name -o tsv 2>/dev/null || true)"
      if [[ "$sub_name" == $MCAPS_SUBSCRIPTION_PATTERN ]]; then
        log "Detected MCAPS-governed subscription ($sub_name); running exemption check."
        mcaps_run=1
      else
        printf '    %-30s sub="%s" doesn'"'"'t match %s, skipping MCAPS check\n' "MCAPS exemption" "$sub_name" "$MCAPS_SUBSCRIPTION_PATTERN"
      fi
      ;;
  esac
  if (( mcaps_run )); then
    ensure_mcaps_exemption
  fi
}

run_prereqs() { time_step "Prereqs" _run_prereqs; }

run_stage() {
  local num="$1" file="$2"
  shift 2
  local extra_params=("$@")

  log "Stage $num: validating $file..."
  az deployment group validate \
    --resource-group "$RG" \
    --template-file "$file" \
    --parameters "${file%.bicep}.parameters.json" \
    --parameters location="$LOCATION" \
    ${extra_params[@]+"${extra_params[@]}"} \
    -o none

  log "Stage $num: deploying $file (this can take 15-30 min for SC/Workspace)..."
  time_step "Stage $num" _stage_deploy "$num" "$file" "${extra_params[@]}"
}

_stage_deploy() {
  local num="$1" file="$2"
  shift 2
  local extra_params=("$@")
  az deployment group create \
    --resource-group "$RG" \
    --name "stage${num}-$(date +%Y%m%d-%H%M%S)" \
    --template-file "$file" \
    --parameters "${file%.bicep}.parameters.json" \
    --parameters location="$LOCATION" \
    ${extra_params[@]+"${extra_params[@]}"}
}

run_build() {
  for f in 01-network.bicep 02-supercomputer.bicep 03-workspace.bicep; do
    printf '%-30s ' "$f"
    az bicep build --file "$f" --stdout > /dev/null && echo OK
  done
}

# Microsoft Discovery first-party application id (constant across all tenants).
DISCOVERY_APP_ID="92c174ac-8e41-4815-a1b7-d81b19ab03ce"
NSP_JOINER_ROLE_NAME="Discovery NSP Perimeter Joiner"

# Idempotent: ensures the Discovery first-party SP can join this subscription
# to the NSP it manages inside its mrg-dscmp-* infra RG. Without this, the
# supercomputer resource fails with LinkedAuthorizationFailed on
# Microsoft.Network/networkSecurityPerimeters/joinPerimeterRule/action.
#
# Why this is needed (and not in the upstream quickstart):
#   The GA API Microsoft.Discovery/*@2026-06-01 auto-creates an NSP inside
#   the managed mrg-dscmp-* RG and enrolls your subscription. The Discovery
#   first-party SP needs `joinPerimeterRule/action` at subscription scope to
#   perform that enrollment. The official quickstart at
#   https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.discovery/discovery-infra-deployment
#   still uses the preview API @2026-02-01-preview which skips this step.
#
# Docs: https://learn.microsoft.com/en-gb/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#assign-the-nsp-perimeter-joiner-role
ensure_nsp_joiner_role() {
  log "Ensuring '$NSP_JOINER_ROLE_NAME' role exists and is assigned to Discovery SP..."
  local sub_scope="/subscriptions/$SUBSCRIPTION"
  local sleep_after=0

  # 1. Resolve the Discovery SP object id in this tenant.
  local sp_oid
  sp_oid="$(az ad sp show --id "$DISCOVERY_APP_ID" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$sp_oid" ]]; then
    printf '  Discovery SP not yet in tenant. Registering provider + creating SP...\n'
    az provider register -n Microsoft.Discovery --wait 1>/dev/null
    az ad sp create --id "$DISCOVERY_APP_ID" -o none 2>/dev/null || true
    sp_oid="$(az ad sp show --id "$DISCOVERY_APP_ID" --query id -o tsv 2>/dev/null || true)"
  fi
  if [[ -z "$sp_oid" ]]; then
    echo "ERROR: Could not resolve Discovery SP object id for app $DISCOVERY_APP_ID." >&2
    echo "       Ask your Entra admin to consent the Discovery app in this tenant." >&2
    exit 1
  fi
  printf '  Discovery SP object id: %s\n' "$sp_oid"

  # 2. Create the custom role if missing.
  local role_id
  role_id="$(az role definition list --name "$NSP_JOINER_ROLE_NAME" --scope "$sub_scope" --query "[0].name" -o tsv 2>/dev/null || true)"
  if [[ -z "$role_id" ]]; then
    printf '  Creating custom role definition...\n'
    az role definition create --role-definition "{
      \"Name\": \"$NSP_JOINER_ROLE_NAME\",
      \"IsCustom\": true,
      \"Description\": \"Allows Microsoft Discovery to enroll the subscription in its managed NSP.\",
      \"Actions\": [\"Microsoft.Network/networkSecurityPerimeters/joinPerimeterRule/action\"],
      \"AssignableScopes\": [\"$sub_scope\"]
    }" -o none
    sleep_after=20
  else
    printf '  Custom role already exists, skipping create.\n'
  fi

  # 3. Assign the role to the Discovery SP at subscription scope, if missing.
  local assigned
  assigned="$(az role assignment list --assignee "$sp_oid" --role "$NSP_JOINER_ROLE_NAME" --scope "$sub_scope" --query "[0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$assigned" ]]; then
    printf '  Assigning role to Discovery SP at subscription scope...\n'
    az role assignment create \
      --assignee-object-id "$sp_oid" \
      --assignee-principal-type ServicePrincipal \
      --role "$NSP_JOINER_ROLE_NAME" \
      --scope "$sub_scope" -o none
    sleep_after=30
  else
    printf '  Role assignment already exists, skipping.\n'
  fi

  # 4. Reader at subscription scope — required by the Discovery control plane
  #    to enumerate resources when associating the NSP in Enforced mode.
  #    Without this, SC creation fails with:
  #      "Control Plane service principal does not have Reader permission at
  #       subscription. Reader role is required for NSP associations in
  #       Enforced mode."
  local reader_assigned
  reader_assigned="$(az role assignment list --assignee "$sp_oid" --role Reader --scope "$sub_scope" --query "[0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$reader_assigned" ]]; then
    printf '  Assigning Reader role to Discovery SP at subscription scope...\n'
    az role assignment create \
      --assignee-object-id "$sp_oid" \
      --assignee-principal-type ServicePrincipal \
      --role Reader \
      --scope "$sub_scope" -o none
    sleep_after=$(( sleep_after > 30 ? sleep_after : 30 ))
  else
    printf '  Reader role assignment already exists, skipping.\n'
  fi

  if (( sleep_after > 0 )); then
    printf '  Sleeping %ds for RBAC propagation...\n' "$sleep_after"
    sleep "$sleep_after"
  fi
}

# Idempotent: creates a subscription-scope Waiver exemption against the
# MCAPSGov "Deploy and Modify Policies" assignment, so the GPU VMSS the
# Discovery node pool creates isn't blocked by RequestDisallowedByPolicy.
#
# Why subscription-scope: the failing VMSS lives in a managed RG
# (MC_mrg-dscmp-...) created and recreated by the Discovery RP with a
# fresh random suffix each deployment. An RG-scoped exemption would have
# to be recreated each time. Subscription scope is the only stable scope.
#
# Only runs when MCAPS_EXEMPTION=1 (opt-in). Skip otherwise.
ensure_mcaps_exemption() {
  log "Ensuring MCAPSGov policy exemption(s) at subscription scope..."
  local sub_scope="/subscriptions/$SUBSCRIPTION"

  # Process each assignment name in MCAPS_ASSIGNMENT_NAMES (comma-separated).
  local assignment_name
  IFS=',' read -r -a _names <<< "$MCAPS_ASSIGNMENT_NAMES"
  for assignment_name in "${_names[@]}"; do
    assignment_name="$(printf '%s' "$assignment_name" | tr -d '[:space:]')"
    [[ -z "$assignment_name" ]] && continue
    _ensure_mcaps_exemption_one "$assignment_name"
  done
}

_ensure_mcaps_exemption_one() {
  local assignment_name="$1"
  local sub_scope="/subscriptions/$SUBSCRIPTION"
  log "  -> assignment: $assignment_name"

  # 1. Discover the target MCAPSGov assignment by name via REST `atScope()`.
  local assignment_id
  assignment_id="$(az rest --method get \
    --uri "https://management.azure.com${sub_scope}/providers/Microsoft.Authorization/policyAssignments?api-version=2023-04-01&\$filter=atScope()" \
    --query "value[?name=='${assignment_name}'] | [0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$assignment_id" ]]; then
    echo "     WARN: assignment '$assignment_name' not visible at sub scope; skipping." >&2
    return 0
  fi
  printf '     id: %s\n' "$assignment_id"

  # 2. Skip if ANY exemption (regardless of name/scope) already targets this
  #    MCAPSGov assignment and is visible at sub scope. Covers both
  #    self-created and admin-created exemptions (including MG-inherited).
  #    Note: the API returns policyAssignmentId all-lowercase, so we match
  #    case-insensitively on the assignment name suffix.
  local needle
  needle="$(printf '%s' "$assignment_name" | tr '[:upper:]' '[:lower:]')"
  local existing
  existing="$(az rest --method get \
    --uri "https://management.azure.com${sub_scope}/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview&\$filter=atScope()" \
    --query "value[?ends_with(properties.policyAssignmentId, '/${needle}')].{name:name, category:properties.exemptionCategory, expires:properties.expiresOn, displayName:properties.displayName}" -o jsonc 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "[]" ]]; then
    printf '     Exemption already exists, skipping create:\n'
    printf '%s\n' "$existing" | sed 's/^/       /'
    return 0
  fi

  # 3. Create the exemption at sub scope (unique name per assignment).
  local exemption_name="${MCAPS_EXEMPTION_NAME}-${assignment_name}"
  printf '     Creating %s exemption %s (expires %s)...\n' "$MCAPS_EXEMPTION_CATEGORY" "$exemption_name" "$MCAPS_EXEMPTION_EXPIRES_ON"
  local body
  body=$(cat <<EOF
{
  "properties": {
    "policyAssignmentId": "${assignment_id}",
    "exemptionCategory": "${MCAPS_EXEMPTION_CATEGORY}",
    "displayName": "Microsoft Discovery (${PREFIX}) GPU VMSS exemption (${assignment_name})",
    "description": "Allow Microsoft.Discovery node pool to create the underlying VMSS for GPU SKUs (e.g. ${NODE_POOL_VM_SIZE}). Risk addressed by Defender for Cloud + the Discovery managed control plane. Created by deploy.sh ensure_mcaps_exemption().",
    "expiresOn": "${MCAPS_EXEMPTION_EXPIRES_ON}"
  }
}
EOF
)
  if az rest --method put \
    --uri "https://management.azure.com${sub_scope}/providers/Microsoft.Authorization/policyExemptions/${exemption_name}?api-version=2022-07-01-preview" \
    --body "$body" -o none 2>/tmp/az-exempt-err; then
    printf '     Exemption created.\n'
  else
    echo "     WARN: Failed to create exemption. You likely lack 'Microsoft.Authorization/policyAssignments/exempt/action'" >&2
    echo "           at the assignment scope. Ask your MG admin to create the exemption." >&2
    echo "           Error:" >&2
    sed 's/^/             /' /tmp/az-exempt-err >&2
  fi
  rm -f /tmp/az-exempt-err
}

# Persona roles required for a Microsoft Discovery Platform Administrator user.
# Source: https://learn.microsoft.com/azure/microsoft-discovery/how-to-assign-persona-roles
PLATFORM_ADMIN_ROLES=(
  "Microsoft Discovery Platform Administrator (Preview)"
  "Managed Identity Contributor"
  "Managed Identity Operator"
  "Storage Account Contributor"
  "Storage Blob Data Contributor"
  "Network Contributor"
  "AcrPush"
  "Microsoft Discovery Bookshelf Index Data Reader (Preview)"
  # 'Foundry User' is assigned at the workspace's managed RG, not here.
)

run_roles() {
  local target="${1:-}"
  local principal_id principal_type display
  if [[ -z "$target" ]]; then
    principal_id="$(az ad signed-in-user show --query id -o tsv)"
    display="$(az ad signed-in-user show --query userPrincipalName -o tsv)"
    principal_type=User
  else
    # Resolve UPN -> objectId, fall back to assuming caller passed an objectId.
    principal_id="$(az ad user show --id "$target" --query id -o tsv 2>/dev/null || echo "$target")"
    display="$target"
    principal_type=User
  fi

  local scope="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG"
  log "Assigning Platform Admin persona roles to $display ($principal_id)"
  log "Scope: $scope"

  for role in "${PLATFORM_ADMIN_ROLES[@]}"; do
    printf '  %-58s ' "$role"
    if az role assignment list --assignee "$principal_id" --role "$role" --scope "$scope" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
      echo "already assigned"
    else
      if az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type "$principal_type" --role "$role" --scope "$scope" -o none 2>/tmp/az-roles-err; then
        echo "assigned"
      else
        echo "FAILED ($(tr -d '\n' </tmp/az-roles-err | head -c 120))"
      fi
    fi
  done
  rm -f /tmp/az-roles-err
  log "Note: 'Foundry User' must be assigned separately on the workspace's managed resource group after Stage 3."
}

stage_1() { run_stage 1 01-network.bicep        "${STAGE1_PARAMS[@]}"; }
stage_2() {
  run_stage 2 02-supercomputer.bicep  "${STAGE2_PARAMS[@]}"
}

stage_3() {
  # Stage 3 needs the storage account name produced by Stage 2.
  local sa
  sa="$(az deployment group list \
        --resource-group "$RG" \
        --query "[?starts_with(name, 'stage2-')] | sort_by(@, &properties.timestamp) | [-1].properties.outputs.storageAccountName.value" \
        -o tsv)"
  if [[ -z "$sa" ]]; then
    echo "ERROR: could not find Stage 2 deployment output 'storageAccountName' in $RG. Run stage 2 first." >&2
    exit 1
  fi

  # =====================================================================
  # Discovery RP @2026-06-01 workspace-stuck bug — DO NOT re-PUT the
  # workspace if it already exists. Sending another PUT/PATCH while the
  # workspace is Succeeded (or even Accepted) can flip it into Accepted
  # state where the RP stops responding, refuses all further writes
  # with InvalidResourceOperation, and may sit there for 30-60+ minutes
  # before self-resolving. Once stuck, the only deterministic recovery
  # is to delete the workspace (which also tears down its mrg-dwsp-* RG
  # ~30-60 min of provisioning) and re-create.
  #
  # Strategy:
  #   - If workspace doesn't exist  -> full Bicep (creates everything).
  #   - If workspace exists         -> skip Bicep entirely. Wait for ws
  #                                    to reach Succeeded, then PUT only
  #                                    the missing children (stc, chat,
  #                                    project) via direct ARM REST.
  # The wait timeout defaults to 60 min because we've observed the RP
  # taking 35+ min between Accepted -> Succeeded on the first cycle.
  # =====================================================================
  if _stage3_workspace_already_provisioned; then
    log "Stage 3: workspace already exists; skipping Bicep re-PUT and only"
    log "         creating missing children via direct REST (avoids RP"
    log "         re-PUT bug — see comments in stage_3())."
    time_step "Stage 3 (children-only)" _stage3_children_via_rest "$sa"
  else
    # Preflight: refuse to (re)create the workspace while orphans from a
    # previous failed Stage 3 still hold agentSubnet. Otherwise the new
    # Foundry Capability Host preflight will fail with:
    #   "AccountIsNotSucceeded ... subnet agentSubnet is already in use"
    # and we have to redo the whole 30-60 min Bicep cycle.
    _stage3_preflight_clean_orphans || exit 1

    log "Stage 3: workspace not present; running full Bicep template."
    log "Stage 3: using storageAccountName=$sa from Stage 2 outputs."
    run_stage 3 03-workspace.bicep "${STAGE3_PARAMS[@]}" storageAccountName="$sa"
  fi
}

# Stage 3 preflight: detect orphans left behind by a previous failed Stage 3
# and clean them (or refuse) before kicking off the new ~30-60 min Bicep.
#
# Two orphan classes we check for (both cause the next workspace deploy to
# fail with 'AccountIsNotSucceeded' on the Foundry CapabilityHost):
#   a) mrg-dwsp-ws-<prefix>-*  resource groups (managed RG outlived its ws)
#   b) Service Association Links on agentSubnet (Foundry SAL outlived its ws)
#
# Behavior:
#   STAGE3_AUTOCLEAN=1 (default) -> automatically run _run_cleanup_ws and
#                                   continue if clean afterwards.
#   STAGE3_AUTOCLEAN=0           -> just fail fast with the cleanup command
#                                   to run, so user can investigate first.
_stage3_preflight_clean_orphans() {
  local sub vnet="vnet-${PREFIX}" subnet="agentSubnet"
  local ws_name="ws-${PREFIX}"
  sub="$(az account show --query id -o tsv)"

  local orphan_mrgs sals
  orphan_mrgs=$(az group list \
    --query "[?starts_with(name, 'mrg-dwsp-${ws_name}-')].name" -o tsv 2>/dev/null || true)
  sals=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${vnet}/subnets/${subnet}/serviceAssociationLinks?api-version=2024-05-01" \
    --query "value[].name" -o tsv 2>/dev/null || true)

  if [[ -z "$orphan_mrgs" && -z "$sals" ]]; then
    log "Stage 3 preflight: no orphans on ${subnet} or ${ws_name}, clean to deploy."
    return 0
  fi

  log "Stage 3 preflight: orphans from a previous failed Stage 3 detected:"
  [[ -n "$orphan_mrgs" ]] && log "  - managed RG(s) still present: ${orphan_mrgs//$'\n'/, }"
  [[ -n "$sals"        ]] && log "  - SAL(s) holding ${subnet}: ${sals//$'\n'/, }"
  log "  Deploying now would fail at Foundry CapabilityHost creation"
  log "  with 'AccountIsNotSucceeded / subnet already in use'."

  if [[ "${STAGE3_AUTOCLEAN:-1}" != "1" ]]; then
    log "STAGE3_AUTOCLEAN=0 — refusing to deploy. Run:"
    log "  ./deploy.sh cleanup-ws"
    log "then re-run: ./deploy.sh 3"
    return 1
  fi

  log "STAGE3_AUTOCLEAN=1 — running cleanup-ws automatically (set =0 to disable)."
  _run_cleanup_ws

  # Re-check; _run_cleanup_ws already exits non-zero if SALs remain, but be
  # defensive in case it was skipped or partial.
  orphan_mrgs=$(az group list \
    --query "[?starts_with(name, 'mrg-dwsp-${ws_name}-')].name" -o tsv 2>/dev/null || true)
  sals=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${vnet}/subnets/${subnet}/serviceAssociationLinks?api-version=2024-05-01" \
    --query "value[].name" -o tsv 2>/dev/null || true)
  if [[ -n "$orphan_mrgs" || -n "$sals" ]]; then
    log "Preflight cleanup did not fully resolve orphans. Aborting Stage 3."
    [[ -n "$orphan_mrgs" ]] && log "  still present: MRG ${orphan_mrgs//$'\n'/, }"
    [[ -n "$sals"        ]] && log "  still present: SAL ${sals//$'\n'/, }"
    log "Try: CLEANUP_RECREATE_SUBNET=1 ./deploy.sh cleanup-ws  (last-resort: re-stage agentSubnet)"
    return 1
  fi
  log "Preflight cleanup complete — proceeding with Stage 3 Bicep."
}

# Returns 0 if ws-<PREFIX> exists at all (Succeeded or in-flight). Used to
# decide whether to run the full Bicep template or just create missing
# children. We wait for Succeeded inside _stage3_children_via_rest so that
# Accepted/Running is still considered "already provisioned" here.
_stage3_workspace_already_provisioned() {
  local state
  state="$(az rest --method get \
    --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/ws-${PREFIX}?api-version=2026-06-01" \
    --query properties.provisioningState -o tsv 2>/dev/null || true)"
  [[ -n "$state" ]]
}

# Wait for ws-<PREFIX> to reach 'Succeeded' (per direct REST). Times out
# after MAX_WAIT_MIN minutes. Returns non-zero on timeout / unrecoverable
# state. Default 60 min because the Discovery RP has been observed to
# take 35+ min to drive a freshly-Accepted workspace to Succeeded after
# any inadvertent write. Override with WS_WAIT_MIN.
_wait_workspace_succeeded() {
  local max_min="${1:-${WS_WAIT_MIN:-60}}"
  local interval=15
  local elapsed=0 state
  while (( elapsed < max_min * 60 )); do
    state="$(az rest --method get \
      --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/ws-${PREFIX}?api-version=2026-06-01" \
      --query properties.provisioningState -o tsv 2>/dev/null || true)"
    case "$state" in
      Succeeded) return 0 ;;
      Failed|Canceled) echo "ERROR: workspace in terminal-failure state '$state'." >&2; return 1 ;;
      "") echo "ERROR: workspace not found." >&2; return 1 ;;
      *) printf '  workspace state=%s (waited %ds, will retry in %ds)...\n' "$state" "$elapsed" "$interval" ;;
    esac
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done
  echo "ERROR: workspace did not reach Succeeded within ${max_min} min." >&2
  return 1
}

# Get a child resource's provisioningState via REST. Echoes the state, or
# empty if the resource doesn't exist. Args: <child-path-from-workspace>.
_child_state() {
  local child="$1"
  az rest --method get \
    --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/ws-${PREFIX}/${child}?api-version=2026-06-01" \
    --query properties.provisioningState -o tsv 2>/dev/null || true
}

# Generic REST PUT helper. Args: <uri> <body-json> <description>.
_arm_put() {
  local uri="$1" body="$2" desc="$3"
  printf '  PUT %s ...\n' "$desc"
  if az rest --method put --uri "$uri" --body "$body" -o none 2>/tmp/az-put-err; then
    printf '  %s: created\n' "$desc"
  else
    printf '  %s: FAILED\n' "$desc"
    sed 's/^/    /' /tmp/az-put-err >&2
    rm -f /tmp/az-put-err
    return 1
  fi
  rm -f /tmp/az-put-err
}

# Create the Stage 3 children (storageContainer, chatModelDeployment,
# project) directly via ARM REST when workspace already exists. Skips any
# child that's already Succeeded. Arg: <storageAccountName>.
_stage3_children_via_rest() {
  local sa="$1"
  local sub="$SUBSCRIPTION"
  local stc_name="stc-${PREFIX}"
  local prj_name="prj-${PREFIX}"
  # Mirror Bicep default: take(replace(chatModelName,'.','-'), 24)
  local cmd_default="$(printf '%s' "${CHAT_MODEL_NAME:-chat}" | tr '.' '-' | cut -c1-24)"
  local cmd_name="$cmd_default"

  log "Waiting for workspace ws-${PREFIX} to be Succeeded (REST GET, up to ${WS_WAIT_MIN:-60} min)..."
  _wait_workspace_succeeded || return 1

  # Discovery Storage Container (not a workspace child, but Stage 3 owns it).
  local stc_state
  stc_state="$(az rest --method get \
    --uri "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/storageContainers/${stc_name}?api-version=2026-06-01" \
    --query properties.provisioningState -o tsv 2>/dev/null || true)"
  if [[ "$stc_state" == "Succeeded" ]]; then
    printf '  storageContainer %s: already Succeeded, skipping\n' "$stc_name"
  else
    _arm_put \
      "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/storageContainers/${stc_name}?api-version=2026-06-01" \
      "{\"location\":\"${LOCATION}\",\"tags\":{\"purpose\":\"${TAG_PURPOSE}\"},\"properties\":{\"storageStore\":{\"kind\":\"AzureStorageBlob\",\"storageAccountId\":\"/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Storage/storageAccounts/${sa}\"}}}" \
      "storageContainer/${stc_name}" || return 1
  fi

  # Chat model deployment (skip if CHAT_MODEL_NAME is empty).
  if [[ -n "$CHAT_MODEL_NAME" ]]; then
    local cmd_state
    cmd_state="$(_child_state "chatModelDeployments/${cmd_name}")"
    if [[ "$cmd_state" == "Succeeded" ]]; then
      printf '  chatModelDeployment %s: already Succeeded, skipping\n' "$cmd_name"
    else
      _arm_put \
        "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/ws-${PREFIX}/chatModelDeployments/${cmd_name}?api-version=2026-06-01" \
        "{\"location\":\"${LOCATION}\",\"tags\":{\"purpose\":\"${TAG_PURPOSE}\"},\"properties\":{\"modelFormat\":\"OpenAI\",\"modelName\":\"${CHAT_MODEL_NAME}\"}}" \
        "chatModelDeployment/${cmd_name}" || return 1
    fi
  fi

  # Project (depends on storageContainer).
  local prj_state
  prj_state="$(_child_state "projects/${prj_name}")"
  if [[ "$prj_state" == "Succeeded" ]]; then
    printf '  project %s: already Succeeded, skipping\n' "$prj_name"
  else
    _arm_put \
      "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/ws-${PREFIX}/projects/${prj_name}?api-version=2026-06-01" \
      "{\"location\":\"${LOCATION}\",\"tags\":{\"purpose\":\"${TAG_PURPOSE}\"},\"properties\":{\"storageContainerIds\":[\"/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/storageContainers/${stc_name}\"]}}" \
      "project/${prj_name}" || return 1
  fi

  log "Stage 3 children-only flow complete. Refresh Discovery Studio to open ws-${PREFIX}/${prj_name}."
}

_run_pause() {
  local sc_name="sc-${PREFIX}"
  log "Pausing $sc_name in $RG (VNet/UAMI/storage/RBAC are kept)."

  if [[ "$(az resource show -g "$RG" --resource-type Microsoft.Discovery/supercomputers --name "$sc_name" --query name -o tsv 2>/dev/null || true)" == "$sc_name" ]]; then
    log "Deleting supercomputer $sc_name (cascades to np1; takes 5-15 min)..."
    az resource delete -g "$RG" --resource-type Microsoft.Discovery/supercomputers --name "$sc_name"
  else
    log "Supercomputer $sc_name not found, skipping."
  fi

  # Discovery's managed infra RG is mrg-dscmp-sc-<prefix>-<random>. Usually
  # cleaned up automatically when the SC is deleted, but stale ones can
  # linger after a failed delete — sweep them too.
  local mrg
  for mrg in $(az group list --query "[?starts_with(name, 'mrg-dscmp-${sc_name}-')].name" -o tsv 2>/dev/null); do
    log "Deleting orphaned managed RG $mrg (async)..."
    az group delete --name "$mrg" --yes --no-wait
  done

  log "Pause done. Resume with: ./deploy.sh 2"
}
run_pause() { time_step "Pause" _run_pause; }

# Full teardown. RG delete alone often gets blocked on Discovery resources
# that need explicit child-first deletion in the right order:
#   nodepools  ->  supercomputer  ->  workspace  ->  RG
# If the workspace + its capability host are gone before we drop the RG,
# the orphan `legionservicelink` SAL on agentSubnet also disappears with
# the VNet (VNet delete bypasses SAL allowDelete:false).
#
# We also force-delete the Discovery-owned managed RGs directly
# (mrg-dscmp-<sc>-* and mrg-dwsp-<ws>-*) — Azure's auto-cascade from
# the parent Discovery resources doesn't always push these to completion
# (AKS / Key Vault soft-delete / NSP edge cases), and the parent RG
# delete waits for them indefinitely. These MRGs carry no deny-
# assignment on standard subs, so a direct `az group delete --no-wait`
# goes through and unblocks the parent.
#
# Env:
#   TEARDOWN_WAIT=1 (default)  - wait for RG to fully disappear before returning
#   TEARDOWN_WAIT=0            - kick off async and return immediately
_run_teardown() {
  local sc_name="sc-${PREFIX}" ws_name="ws-${PREFIX}"
  local sub; sub="$(az account show --query id -o tsv)"

  if ! az group show -n "$RG" -o none 2>/dev/null; then
    log "RG $RG already gone, nothing to do."
    return 0
  fi

  log "Teardown $RG: deleting Discovery children in dependency order first."

  # 1. Workspace (must die before SC so SAL is freed before VNet drop).
  local ws_state
  ws_state=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/${ws_name}?api-version=2026-06-01" \
    --query properties.provisioningState -o tsv 2>/dev/null || true)
  if [[ -n "$ws_state" ]]; then
    log "  - deleting workspace $ws_name (current state: $ws_state)..."
    az resource delete -g "$RG" --resource-type Microsoft.Discovery/workspaces \
      --name "$ws_name" 2>&1 | tail -3 || true
  fi

  # 2. Node pools (must die before SC).
  local np_id
  for np_id in $(az resource list -g "$RG" \
      --resource-type Microsoft.Discovery/supercomputers/nodePools \
      --query "[].id" -o tsv 2>/dev/null); do
    log "  - deleting nodePool ${np_id##*/} ..."
    az resource delete --ids "$np_id" 2>&1 | tail -3 || true
  done

  # 3. Supercomputer.
  if az resource show -g "$RG" --resource-type Microsoft.Discovery/supercomputers --name "$sc_name" -o none 2>/dev/null; then
    log "  - deleting supercomputer $sc_name ..."
    az resource delete -g "$RG" --resource-type Microsoft.Discovery/supercomputers --name "$sc_name" 2>&1 | tail -3 || true
  fi

  # 3b. Force-delete the Discovery-managed RGs directly.
  # The parent RG delete often gets stuck on these because:
  #   - mrg-dscmp-<sc>-* holds the SC's AKS cluster, Key Vault, NSP, Log
  #     Analytics, DCR — Azure's auto-cascade from a Discovery resource
  #     delete sometimes never makes progress past them.
  #   - mrg-dwsp-<ws>-* holds the Foundry account, KV, search, etc.,
  #     which similarly can outlive their parent workspace.
  # These RGs have NO deny-assignment on this MCAPS sub (verified), so
  # an explicit `az group delete --no-wait` on each goes through and
  # unblocks the parent RG.
  local mrg
  for mrg in $(az group list \
      --query "[?starts_with(name, 'mrg-dscmp-${sc_name}-') || starts_with(name, 'mrg-dwsp-${ws_name}-')].name" \
      -o tsv 2>/dev/null); do
    log "  - deleting Discovery-managed RG $mrg (async)..."
    az group delete --name "$mrg" --yes --no-wait 2>&1 | tail -2 || true
  done

  # 4. Final RG delete (catches anything left + any orphan SAL via cascading VNet drop).
  log "  - deleting resource group $RG ..."
  az group delete --name "$RG" --yes --no-wait

  if [[ "${TEARDOWN_WAIT:-1}" != "1" ]]; then
    log "Teardown initiated (TEARDOWN_WAIT=0; not waiting). Check with: az group show -n $RG"
    return 0
  fi

  # 5. Wait until the RG is fully gone.
  local deadline=$(( $(date +%s) + 30 * 60 ))
  while :; do
    if ! az group show -n "$RG" -o none 2>/dev/null; then
      log "Teardown done: $RG is gone."
      return 0
    fi
    local now=$(date +%s)
    if (( now > deadline )); then
      log "WARN: $RG still present after 30 min. Re-run: ./deploy.sh teardown"
      return 1
    fi
    local left=$(( (deadline - now) / 60 ))
    log "  ... still deleting $RG (${left}m left)"
    sleep 60
  done
}
run_teardown() { time_step "Teardown" _run_teardown; }

# Stage 3 cleanup. After a failed Stage 3 the workspace + its managed RG
# (mrg-dwsp-ws-<prefix>-*) often linger, AND the Foundry Capability Host
# leaves a stale Service Association Link on agentSubnet
# (`legionservicelink`, linkedResourceType Microsoft.App/environments).
# Until that SAL is removed, every retry fails with:
#   "The subnet 'agentSubnet' is already in use. The subnet must not
#    already be in use by any other environment or Azure service."
# This subcommand does the full sweep so a retry is one command away.
#
# Steps:
#   1. Delete the Discovery workspace (cascades to its managed RG).
#   2. Wait for every mrg-dwsp-ws-<prefix>-* RG to disappear (up to
#      CLEANUP_WAIT_MIN minutes, default 10).
#   3. Force-delete the leftover SAL on agentSubnet via REST.
#   4. As a last resort, delete + Bicep-recreate agentSubnet itself
#      (only when CLEANUP_RECREATE_SUBNET=1; default 0 since step 3
#      almost always frees it).
#
# Idempotent — safe to run multiple times. Re-run Stage 3 after this.
_run_cleanup_ws() {
  local ws_name="ws-${PREFIX}"
  local sub vnet="vnet-${PREFIX}" subnet="agentSubnet"
  local wait_min="${CLEANUP_WAIT_MIN:-10}"
  sub="$(az account show --query id -o tsv)"

  log "Stage 3 cleanup: workspace=$ws_name, vnet=$vnet, subnet=$subnet"

  # --- 1. Delete the workspace (if any state present) ---
  # Use REST GET (not `az resource show`, which returns 404 mid-delete even
  # while the workspace still exists in state 'Deleting').
  local ws_state
  ws_state=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/${ws_name}?api-version=2026-06-01" \
    --query properties.provisioningState -o tsv 2>/dev/null || true)
  case "$ws_state" in
    "")
      log "Workspace $ws_name not present, skipping delete."
      ;;
    Deleting)
      log "Workspace $ws_name already in state 'Deleting' — letting it finish."
      ;;
    *)
      log "Deleting workspace $ws_name (current state: $ws_state, cascades to mrg-dwsp-*; 5-15 min)..."
      az resource delete -g "$RG" --resource-type Microsoft.Discovery/workspaces \
        --name "$ws_name" 2>&1 | tail -5 || true
      ;;
  esac

  # --- 1b. Directly delete any orphaned managed RG ---
  # If the workspace was already gone but its managed RG (mrg-dwsp-ws-<prefix>-*)
  # is still around, the RG won't disappear on its own — Discovery's cascade
  # only fires while the workspace is being deleted. Delete it ourselves so
  # the SAL has no rightful owner left.
  local orphan
  for orphan in $(az group list \
      --query "[?starts_with(name, 'mrg-dwsp-${ws_name}-')].name" -o tsv 2>/dev/null); do
    log "Deleting orphaned managed RG $orphan (async)..."
    az group delete --name "$orphan" --yes --no-wait || true
  done

  # --- 2. Wait for every Foundry managed RG (mrg-dwsp-ws-<prefix>-*) to vanish ---
  local deadline=$(( $(date +%s) + wait_min * 60 ))
  local remaining
  while :; do
    remaining=$(az group list \
      --query "[?starts_with(name, 'mrg-dwsp-${ws_name}-')].name" -o tsv 2>/dev/null)
    [[ -z "$remaining" ]] && break
    local now_ts=$(date +%s)
    if (( now_ts > deadline )); then
      log "WARN: managed RG still present after ${wait_min}m: ${remaining//$'\n'/, }"
      log "      proceeding with SAL cleanup anyway — re-run later if SAL delete fails."
      break
    fi
    local left_min=$(( (deadline - now_ts) / 60 ))
    log "Waiting for managed RG (${left_min}m left): ${remaining//$'\n'/, }"
    sleep 30
  done

  # --- 3. Force-delete stale Service Association Links on agentSubnet ---
  local sals
  sals=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${vnet}/subnets/${subnet}/serviceAssociationLinks?api-version=2024-05-01" \
    --query "value[].name" -o tsv 2>/dev/null || true)
  if [[ -z "$sals" ]]; then
    log "No service association links on ${subnet}. Clean."
  else
    local sal
    for sal in $sals; do
      log "Force-deleting SAL ${subnet}/${sal} ..."
      if az rest --method delete \
          --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${vnet}/subnets/${subnet}/serviceAssociationLinks/${sal}?api-version=2024-05-01&force=true" \
          -o none 2>/tmp/az-sal-err; then
        log "  ${sal} deleted."
      else
        log "  ${sal} delete FAILED: $(tr -d '\n' </tmp/az-sal-err | head -c 240)"
        log "  Re-run after the managed RG is fully gone, OR set CLEANUP_RECREATE_SUBNET=1 to drop & restage subnet."
      fi
      rm -f /tmp/az-sal-err
    done
  fi

  # --- 4. Optional nuclear option: delete + recreate agentSubnet ---
  if [[ "${CLEANUP_RECREATE_SUBNET:-0}" == "1" ]]; then
    log "CLEANUP_RECREATE_SUBNET=1: deleting subnet ${subnet} and re-running Stage 1."
    az network vnet subnet delete -g "$RG" --vnet-name "$vnet" -n "$subnet" || true
    stage_1
  fi

  # --- Final verification ---
  log "Verifying ${subnet} is free..."
  local left_sals
  left_sals=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${vnet}/subnets/${subnet}/serviceAssociationLinks?api-version=2024-05-01" \
    --query "value[].name" -o tsv 2>/dev/null || true)
  if [[ -z "$left_sals" ]]; then
    log "OK — ${subnet} has no SALs. Re-run Stage 3 with: ./deploy.sh 3"
  else
    log "WARN — SAL(s) still present: ${left_sals//$'\n'/, }"
    log "      Wait a few minutes for the managed RG delete to finish, then re-run: ./deploy.sh cleanup-ws"
    log "      Or set CLEANUP_RECREATE_SUBNET=1 ./deploy.sh cleanup-ws to drop & recreate the subnet."
    exit 1
  fi
}
run_cleanup_ws() { time_step "Cleanup-ws" _run_cleanup_ws; }


# Stage 4: post-deployment role grant. The Discovery workspace creates a
# Foundry-managed RG (typically `mrg-<workspaceName>-<region>-<random>`)
# that hosts the Azure AI Foundry account + project. Discovery Studio
# requires the 'Foundry User' role on that managed RG before a user can
# open the workspace. Default target: the signed-in az CLI user.
_stage_4() {
  local target="${1:-}"
  local ws_name="ws-${PREFIX}"
  local role="Foundry User"

  local principal_id principal_type display
  if [[ -z "$target" ]]; then
    principal_id="$(az ad signed-in-user show --query id -o tsv)"
    display="$(az ad signed-in-user show --query userPrincipalName -o tsv)"
    principal_type=User
  else
    principal_id="$(az ad user show --id "$target" --query id -o tsv 2>/dev/null || echo "$target")"
    display="$target"
    principal_type=User
  fi

  log "Stage 4: resolving workspace $ws_name managed RG..."
  local mrg
  mrg="$(az resource show -g "$RG" \
    --resource-type Microsoft.Discovery/workspaces \
    --name "$ws_name" \
    --query properties.managedResourceGroup -o tsv 2>/dev/null || true)"
  if [[ -z "$mrg" ]]; then
    echo "ERROR: workspace $ws_name not found in $RG (or has no managedResourceGroup). Run ./deploy.sh 3 first." >&2
    exit 1
  fi
  local scope="/subscriptions/${SUBSCRIPTION}/resourceGroups/${mrg}"
  log "Workspace managed RG: $mrg"
  log "Assigning '$role' to $display ($principal_id) on $scope"

  if az role assignment list --assignee "$principal_id" --role "$role" --scope "$scope" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    printf '  %-58s already assigned\n' "$role"
  else
    if az role assignment create \
        --assignee-object-id "$principal_id" \
        --assignee-principal-type "$principal_type" \
        --role "$role" \
        --scope "$scope" -o none 2>/tmp/az-stage4-err; then
      printf '  %-58s assigned\n' "$role"
    else
      printf '  %-58s FAILED (%s)\n' "$role" "$(tr -d '\n' </tmp/az-stage4-err | head -c 160)"
      rm -f /tmp/az-stage4-err
      exit 1
    fi
  fi
  rm -f /tmp/az-stage4-err

  log "Done. Sign in to https://studio.discovery.microsoft.com/ and select workspace '$ws_name'."
}
stage_4() { time_step "Stage 4" _stage_4 "$@"; }

# Quick read-only status across all 4 stages + orphan flags. No mutations.
# Helps you remember where a project left off after coming back to it cold.
_run_status() {
  local sub vnet="vnet-${PREFIX}" subnet="agentSubnet" ws_name="ws-${PREFIX}" sc_name="sc-${PREFIX}"
  sub="$(az account show --query id -o tsv)"
  local sub_name; sub_name="$(az account show --query name -o tsv)"

  printf '\n\033[1;36m== Discovery deployment status ==\033[0m\n'
  printf '  subscription : %s (%s)\n' "$sub_name" "$sub"
  printf '  resource grp : %s\n' "$RG"
  printf '  region       : %s\n' "$LOCATION"
  printf '  prefix       : %s\n' "$PREFIX"

  if ! az group show -n "$RG" -o none 2>/dev/null; then
    printf '\n  \033[1;33mRG %s does not exist — run: ./deploy.sh prereqs\033[0m\n' "$RG"
    return 0
  fi

  # --- Stage 1 ---
  local vnet_state subnet_count
  vnet_state="$(az resource show -g "$RG" --resource-type Microsoft.Network/virtualNetworks --name "$vnet" --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
  subnet_count="$(az network vnet subnet list -g "$RG" --vnet-name "$vnet" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
  printf '\n  \033[1mStage 1 (network)\033[0m   vnet=%s subnets=%s\n' "$vnet_state" "$subnet_count"

  # --- Stage 2 ---
  local sc_state np_state
  sc_state="$(az resource show -g "$RG" --resource-type Microsoft.Discovery/supercomputers --name "$sc_name" --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
  np_state="$(az resource show --ids "/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/supercomputers/${sc_name}/nodePools/np1" --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
  printf '  \033[1mStage 2 (sc)\033[0m        sc=%s np1=%s\n' "$sc_state" "$np_state"

  # --- Stage 3 ---
  local ws_state cm_state prj_state stc_state
  ws_state="$(az rest --method get --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Discovery/workspaces/${ws_name}?api-version=2026-06-01" --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
  cm_state="$(az resource list -g "$RG" --resource-type Microsoft.Discovery/workspaces/chatModelDeployments --query "[0].provisioningState" -o tsv 2>/dev/null)"; [[ -z "$cm_state" ]] && cm_state=Missing
  prj_state="$(az resource list -g "$RG" --resource-type Microsoft.Discovery/workspaces/projects --query "[0].provisioningState" -o tsv 2>/dev/null)"; [[ -z "$prj_state" ]] && prj_state=Missing
  stc_state="$(az resource list -g "$RG" --resource-type Microsoft.Discovery/storageContainers --query "[0].provisioningState" -o tsv 2>/dev/null)"; [[ -z "$stc_state" ]] && stc_state=Missing
  printf '  \033[1mStage 3 (ws)\033[0m        ws=%s chat=%s proj=%s stc=%s\n' "$ws_state" "$cm_state" "$prj_state" "$stc_state"

  # --- Stage 4: signed-in user's Foundry User assignment on the workspace MRG ---
  if [[ "$ws_state" == "Succeeded" ]]; then
    local mrg signed_oid has_role
    mrg="$(az resource show -g "$RG" --resource-type Microsoft.Discovery/workspaces --name "$ws_name" --query properties.managedResourceGroup -o tsv 2>/dev/null || true)"
    signed_oid="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
    if [[ -n "$mrg" && -n "$signed_oid" ]]; then
      has_role="$(az role assignment list --assignee "$signed_oid" --scope "/subscriptions/${sub}/resourceGroups/${mrg}" --role 'Foundry User' --query "[0].id" -o tsv 2>/dev/null || true)"
      if [[ -n "$has_role" ]]; then
        printf '  \033[1mStage 4 (role)\033[0m      Foundry User assigned on %s (signed-in user)\n' "$mrg"
      else
        printf '  \033[1mStage 4 (role)\033[0m      \033[1;33mNOT assigned\033[0m on %s — run: ./deploy.sh 4\n' "$mrg"
      fi
    fi
  else
    printf '  \033[1mStage 4 (role)\033[0m      (skipped — needs ws Succeeded)\n'
  fi

  # --- Orphan flags ---
  local orphan_mrgs sals
  orphan_mrgs="$(az group list --query "[?starts_with(name, 'mrg-dwsp-${ws_name}-')].name" -o tsv 2>/dev/null || true)"
  sals="$(az rest --method get --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${vnet}/subnets/${subnet}/serviceAssociationLinks?api-version=2024-05-01" --query "value[].name" -o tsv 2>/dev/null || true)"

  # An MRG/SAL is only an "orphan" if there's no live workspace owning it.
  if [[ "$ws_state" != "Succeeded" && "$ws_state" != "Accepted" && "$ws_state" != "Running" && "$ws_state" != "Creating" && "$ws_state" != "Updating" ]]; then
    if [[ -n "$orphan_mrgs" || -n "$sals" ]]; then
      printf '\n  \033[1;33mOrphans detected\033[0m (no live workspace):\n'
      [[ -n "$orphan_mrgs" ]] && printf '    - managed RG : %s\n' "${orphan_mrgs//$'\n'/, }"
      [[ -n "$sals"        ]] && printf '    - SAL on %s : %s\n' "$subnet" "${sals//$'\n'/, }"
      printf '    Run: ./deploy.sh cleanup-ws  (or rely on stage_3 preflight)\n'
    fi
  fi
  echo
}
run_status() { _run_status; }

cmd="${1:-}"
case "$cmd" in
  build)                       run_build ;;
  prereqs)                     run_prereqs ;;
  roles)                       run_roles "${2:-}" ;;
  nsp-role)                    ensure_nsp_joiner_role ;;
  mcaps-exempt)                ensure_mcaps_exemption ;;
  status)                      run_status ;;
  pause)                       run_pause ;;
  cleanup-ws|cleanup-3)        run_cleanup_ws ;;
  1|network)                   stage_1 ;;
  2|supercomputer|sc)          stage_2 ;;
  3|workspace|ws)              stage_3 ;;
  4|foundry-role)              stage_4 "${2:-}" ;;
  all)                         run_prereqs; stage_1; stage_2; stage_3; stage_4 ;;
  outputs)                     az resource list --resource-group "$RG" -o table ;;
  teardown)                    run_teardown ;;
  *)
    sed -n '2,15p' "$0"
    exit 1
    ;;
esac

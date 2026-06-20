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
#                                            # Only needed on MCAPS-governed subscriptions (e.g.
#                                            # MngEnvMCAP*). Auto-run by `prereqs` when MCAPS_EXEMPTION=1.
#                                            # Skips create when an exemption (self- or admin-created,
#                                            # any scope) already targets the assignment.
#                                            # Category defaults to Mitigated, expires 2030-01-01.
#                                            # Override with MCAPS_EXEMPTION_CATEGORY=Waiver,
#                                            # MCAPS_EXEMPTION_EXPIRES_ON=<ISO8601>, etc.
#   ./deploy.sh pause                        # delete the supercomputer (and its managed mrg-dscmp-* RG)
#                                            # to stop the always-on system-pool cost. VNet/UAMI/
#                                            # storage/RBAC are kept. Resume with `./deploy.sh 2`.
#   ./deploy.sh 1 | network                  # Stage 1: VNet + subnets
#   ./deploy.sh 2 | supercomputer            # Stage 2: UAMI + Storage + RBAC + SC + NodePool
#   ./deploy.sh 3 | workspace                # Stage 3: Workspace + ChatModel + Project + Container
#   ./deploy.sh all                          # prereqs + 1 + 2 + 3
#   ./deploy.sh outputs                      # list deployed resources
#   ./deploy.sh teardown                     # delete the resource group
#
# Configure RG/location via env vars:
#   RG=rg-discovery-yw-uno LOCATION=swedencentral ./deploy.sh 1
#   MCAPS_EXEMPTION=1 ./deploy.sh prereqs                          # opt-in MCAPS exemption check

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

# MCAPS Policy exemption (opt-in)
# Set MCAPS_EXEMPTION=1 to auto-create a subscription-scope exemption
# against the MCAPSGov initiative during `./deploy.sh prereqs`.
# Only needed on MCAPS-governed subscriptions where the deny policy blocks
# the GPU VMSS the Discovery node pool creates.
MCAPS_EXEMPTION="${MCAPS_EXEMPTION:-0}"
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
  if [[ "$MCAPS_EXEMPTION" == "1" ]]; then
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
  log "Stage 3: using storageAccountName=$sa from Stage 2 outputs."
  run_stage 3 03-workspace.bicep "${STAGE3_PARAMS[@]}" storageAccountName="$sa"
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

cmd="${1:-}"
case "$cmd" in
  build)                       run_build ;;
  prereqs)                     run_prereqs ;;
  roles)                       run_roles "${2:-}" ;;
  nsp-role)                    ensure_nsp_joiner_role ;;
  mcaps-exempt)                ensure_mcaps_exemption ;;
  pause)                       run_pause ;;
  1|network)                   stage_1 ;;
  2|supercomputer|sc)          stage_2 ;;
  3|workspace|ws)              stage_3 ;;
  all)                         run_prereqs; stage_1; stage_2; stage_3 ;;
  outputs)                     az resource list --resource-group "$RG" -o table ;;
  teardown)                    az group delete --name "$RG" --yes --no-wait ;;
  *)
    sed -n '2,15p' "$0"
    exit 1
    ;;
esac

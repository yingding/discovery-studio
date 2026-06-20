#!/usr/bin/env bash
# Poll the latest Discovery deployment and the resources it touches.
#
# Output (two lines per cycle):
#   line 1: deployment name + state + a dynamic list of every
#           Microsoft.Discovery/* resource in $RG (your resources).
#   line 2: a summary of each Discovery-managed sibling RG (mrg-dscmp-*,
#           mrg-dwsp-*) — number of resources and provisioning-state counts.
#
# Discovery resources are looked up dynamically (no hardcoded names beyond
# the script's PREFIX). If you change PREFIX or add another nodePool /
# project / chatModelDeployment, it shows up automatically.
#
# Usage:
#   ./poll.sh                              # default: STAGE=2, every 60s
#   STAGE=1 ./poll.sh                      # watch Stage 1 (network)
#   STAGE=3 ./poll.sh                      # watch Stage 3 (workspace + Foundry mrg)
#   INTERVAL=30 ./poll.sh                  # custom poll interval (seconds)
#   RG=rg-foo PREFIX=disc-bar ./poll.sh    # custom RG and naming prefix
#   MAX_UNKNOWN=10 ./poll.sh               # tolerate up to N consecutive Unknown polls (default 5)
#
# Stops automatically when the deployment reaches a terminal state
# (Succeeded / Failed / Canceled) or after MAX_UNKNOWN consecutive
# unreadable polls. Exit codes: 0=Succeeded, 1=Failed (prints failed
# operations), 2=gave up on Unknown streak.

set -uo pipefail

RG="${RG:-rg-discovery-yw-uno}"
PREFIX="${PREFIX:-disc-yw}"
STAGE="${STAGE:-2}"
INTERVAL="${INTERVAL:-60}"

SUB="$(az account show --query id -o tsv)"

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }

state_color() {
  case "$1" in
    Succeeded)               color "1;32" "$1" ;;  # green
    Failed|Canceled)         color "1;31" "$1" ;;  # red
    Running|Accepted|Creating|Updating) color "1;33" "$1" ;;  # yellow
    *)                       color "0"    "$1" ;;
  esac
}

is_terminal() {
  case "$1" in
    Succeeded|Failed|Canceled) return 0 ;;
    *)                         return 1 ;;
  esac
}

# Print every Microsoft.Discovery/* resource in $RG as `<shortname>=<state>`.
# Shortname = last segment of the type (e.g. supercomputers -> sc/np1 already
# carry the parent prefix in their name) plus the resource name for clarity.
# Returns empty string if nothing matches.
discovery_status_line() {
  az resource list -g "$RG" \
    --query "[?starts_with(type, 'Microsoft.Discovery/')].{name:name, type:type, state:provisioningState}" \
    -o tsv 2>/dev/null \
  | awk -v color_succ="$(printf '\033[1;32m')" \
        -v color_warn="$(printf '\033[1;33m')" \
        -v color_err="$(printf '\033[1;31m')" \
        -v color_off="$(printf '\033[0m')" '
    function colorize(s) {
      if (s == "Succeeded") return color_succ s color_off
      if (s == "Failed" || s == "Canceled") return color_err s color_off
      if (s == "Running" || s == "Accepted" || s == "Creating" || s == "Updating") return color_warn s color_off
      return s
    }
    {
      name = $1
      type = $2
      state = $3
      # short label = last "/" segment of the type
      n = split(type, parts, "/")
      label = parts[n]
      # for parent/child names like sc-disc-yw/np1, just take the child name
      cn = split(name, np, "/")
      shortname = np[cn]
      out = out " | " label "/" shortname "=" colorize(state)
    }
    END { print out }
  '
}

# Print a summary of each Discovery-managed sibling RG: `<rg-prefix>: N (counts)`.
# Discovers them via `properties.managedResourceGroup` on Discovery parents in $RG.
managed_status_line() {
  local mrgs mrg out=""
  mrgs="$(az resource list -g "$RG" \
    --query "[?type=='Microsoft.Discovery/supercomputers' || type=='Microsoft.Discovery/workspaces'].name" \
    -o tsv 2>/dev/null)"
  for parent_name in $mrgs; do
    # Get the parent's managedResourceGroup
    local parent_type
    parent_type="$(az resource list -g "$RG" --name "$parent_name" --query "[0].type" -o tsv 2>/dev/null)"
    mrg="$(az resource show -g "$RG" --resource-type "$parent_type" --name "$parent_name" \
      --query properties.managedResourceGroup -o tsv 2>/dev/null || true)"
    [[ -z "$mrg" ]] && continue
    local summary
    summary="$(az resource list -g "$mrg" --query '[].provisioningState' -o tsv 2>/dev/null | \
      awk 'BEGIN{n=0} {n++; counts[$1]++} END {
        if (n==0) {print "0"; exit}
        out = n " ("
        first = 1
        for (s in counts) {
          if (!first) out = out ", "
          out = out counts[s] " " s
          first = 0
        }
        out = out ")"
        print out
      }')"
    out="${out} | ${mrg}=${summary}"
  done
  printf '%s' "$out"
}

MAX_UNKNOWN="${MAX_UNKNOWN:-5}"   # consecutive 'Unknown' polls before giving up
unknown_streak=0

start_ts="$(date +%s)"
echo "Polling RG=$RG prefix=$PREFIX stage=$STAGE every ${INTERVAL}s (Ctrl-C to stop)"
echo

while :; do
  now="$(date +%H:%M:%S)"
  elapsed=$(( ( $(date +%s) - start_ts ) / 60 ))

  # Latest stageN deployment
  read -r dep_name dep_state < <(
    az deployment group list -g "$RG" \
      --query "[?starts_with(name,'stage${STAGE}-')] | sort_by(@, &properties.timestamp) | [-1].[name, properties.provisioningState]" \
      -o tsv 2>/dev/null
  )
  dep_name="${dep_name:-<none>}"
  dep_state="${dep_state:-}"

  # If the list query came back empty (transient API hiccup), fall back to
  # a direct `deployment show` on the last-known name so we don't get stuck
  # on a stale 'Unknown' forever.
  if [[ -z "$dep_state" && "$dep_name" != "<none>" ]]; then
    dep_state="$(az deployment group show -g "$RG" -n "$dep_name" --query properties.provisioningState -o tsv 2>/dev/null || true)"
  fi
  dep_state="${dep_state:-Unknown}"

  # Line 1: deployment + dynamic Discovery resources (or VNet for stage 1)
  if [[ "$STAGE" == "1" ]]; then
    vn_state="$(az resource show -g "$RG" \
      --resource-type Microsoft.Network/virtualNetworks \
      --name "vnet-${PREFIX}" \
      --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
    resources=" | vnet=$(state_color "$vn_state")"
  else
    resources="$(discovery_status_line)"
  fi

  printf '[%s | +%3dm] deployment=%-30s %s%s\n' \
    "$now" "$elapsed" "$dep_name" \
    "$(state_color "$dep_state")" \
    "$resources"

  # Line 2: managed RG summary (only when there's something to show)
  if [[ "$STAGE" != "1" ]]; then
    mrg_line="$(managed_status_line)"
    if [[ -n "$mrg_line" ]]; then
      printf '                       managed%s\n' "$mrg_line"
    fi
  fi

  if is_terminal "$dep_state"; then
    echo
    echo "Deployment reached terminal state: $(state_color "$dep_state")"
    if [[ "$dep_state" == "Failed" ]]; then
      echo "Failed operations:"
      az deployment operation group list -g "$RG" --name "$dep_name" \
        --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName, type:properties.targetResource.resourceType, err:properties.statusMessage.error.message}" \
        -o jsonc
      exit 1
    fi
    exit 0
  fi

  # Track consecutive 'Unknown' polls so we don't loop forever when ARM/Graph
  # can't return a state (e.g. RG just deleted, or transient throttling).
  if [[ "$dep_state" == "Unknown" ]]; then
    unknown_streak=$(( unknown_streak + 1 ))
    if (( unknown_streak >= MAX_UNKNOWN )); then
      echo
      echo "Got 'Unknown' deployment state ${unknown_streak} times in a row. Giving up."
      echo "(Set MAX_UNKNOWN=N to change the threshold; run ./deploy.sh ... to start a new deployment.)"
      exit 2
    fi
  else
    unknown_streak=0
  fi

  sleep "$INTERVAL"
done

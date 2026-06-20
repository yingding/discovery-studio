#!/usr/bin/env bash
# Poll the latest Stage 2 deployment + supercomputer + node pool.
#
# Usage:
#   ./poll.sh                              # poll every 60s with defaults
#   INTERVAL=30 ./poll.sh                  # custom interval (seconds)
#   RG=rg-foo PREFIX=disc-bar ./poll.sh    # custom RG and prefix
#   STAGE=3 ./poll.sh                      # poll Stage 3 (workspace) instead
#
# Stops automatically when the deployment reaches a terminal state
# (Succeeded / Failed / Canceled).

set -uo pipefail

RG="${RG:-rg-discovery-yw-uno}"
PREFIX="${PREFIX:-disc-yw}"
STAGE="${STAGE:-2}"
INTERVAL="${INTERVAL:-60}"
SC_NAME="sc-${PREFIX}"
NP_NAME="np1"

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
  dep_state="${dep_state:-Unknown}"

  # Supercomputer state
  sc_state="$(az resource show -g "$RG" \
    --resource-type Microsoft.Discovery/supercomputers \
    --name "$SC_NAME" \
    --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"

  # Node pool state (only meaningful in stage 2)
  np_state="$(az resource show \
    --ids "/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Discovery/supercomputers/${SC_NAME}/nodePools/${NP_NAME}" \
    --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"

  printf '[%s | +%3dm] deployment=%-30s %s | sc=%s | np1=%s\n' \
    "$now" "$elapsed" "$dep_name" \
    "$(state_color "$dep_state")" \
    "$(state_color "$sc_state")" \
    "$(state_color "$np_state")"

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

  sleep "$INTERVAL"
done

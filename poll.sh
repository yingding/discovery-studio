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
#   STALE_MIN=10 ./poll.sh                 # treat terminal deployments older than N min as history
#                                          # (default 5; set 0 to exit immediately like before).
#                                          # Lets you keep the poller running across redeploys.
#
# Stops automatically when the deployment reaches a terminal state
# (Succeeded / Failed / Canceled) **within the last STALE_MIN minutes**
# or after MAX_UNKNOWN consecutive unreadable polls. Older terminal
# deployments are reported once and then ignored so a new redeploy can
# be picked up without restarting the script. Exit codes: 0=Succeeded,
# 1=Failed (prints failed operations), 2=gave up on Unknown streak.

set -uo pipefail

PREFIX="${PREFIX:-disc-yw-1}"
RG="${RG:-rg-${PREFIX}}"               # default: rg-<PREFIX>, same convention as deploy.sh
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

# Emit every Microsoft.Discovery/* resource in $RG as one line per resource:
#   <label>\t<state>
# Where <label> = <last-type-segment>/<resource-shortname>. Newline-separated.
discovery_status_lines() {
  az resource list -g "$RG" \
    --query "[?starts_with(type, 'Microsoft.Discovery/')].{name:name, type:type, state:provisioningState}" \
    -o tsv 2>/dev/null \
  | awk -v OFS='\t' '
    {
      name = $1
      type = $2
      state = $3
      n = split(type, parts, "/")
      label = parts[n]
      cn = split(name, np, "/")
      shortname = np[cn]
      print label "/" shortname, state
    }
  '
}

# Print a multi-line tree summary of each Discovery-managed sibling RG
# (mrg-dscmp-* / mrg-dwsp-*). Discovers them via
# `properties.managedResourceGroup` on Discovery parents in $RG.
#
# Output format (when there are MRGs):
#   └─ managed
#      ├─ mrg-<name>
#      │  ├─ resources=N succeeded ✓              # compact when all green
#      │  └─ nested-deploys=M total              # tree when mixed
#      │     ├─ X in-progress (X Running)
#      │     └─ Y succeeded
#      └─ mrg-<other> ...
#
# Prints nothing when no MRGs exist (e.g. Stage 1).
# `nested-deploys` = ARM Microsoft.Resources/deployments nested inside the MRG.
managed_status_block() {
  local mrgs parent_name parent_type mrg
  local -a all_mrgs=()
  mrgs="$(az resource list -g "$RG" \
    --query "[?type=='Microsoft.Discovery/supercomputers' || type=='Microsoft.Discovery/workspaces'].name" \
    -o tsv 2>/dev/null)"
  for parent_name in $mrgs; do
    parent_type="$(az resource list -g "$RG" --name "$parent_name" --query "[0].type" -o tsv 2>/dev/null)"
    mrg="$(az resource show -g "$RG" --resource-type "$parent_type" --name "$parent_name" \
      --query properties.managedResourceGroup -o tsv 2>/dev/null || true)"
    [[ -n "$mrg" ]] && all_mrgs+=("$mrg")
  done

  (( ${#all_mrgs[@]} == 0 )) && return 0

  printf '└─ managed\n'
  local mrg_idx mrg_last_idx=$(( ${#all_mrgs[@]} - 1 ))
  local mrg_branch mrg_indent
  for mrg_idx in "${!all_mrgs[@]}"; do
    mrg="${all_mrgs[$mrg_idx]}"
    if (( mrg_idx == mrg_last_idx )); then
      mrg_branch='└─'; mrg_indent='   '
    else
      mrg_branch='├─'; mrg_indent='│  '
    fi
    printf '   %s %s\n' "$mrg_branch" "$mrg"
    _render_bucket "resources" "   ${mrg_indent}├─" "   ${mrg_indent}│  " \
      "$(az resource list -g "$mrg" --query '[].provisioningState' -o tsv 2>/dev/null)"
    _render_bucket "nested-deploys" "   ${mrg_indent}└─" "   ${mrg_indent}   " \
      "$(az deployment group list -g "$mrg" --query '[].properties.provisioningState' -o tsv 2>/dev/null)"
  done
}

# Return 0 if at least one Discovery-managed RG exists for this PREFIX. Used
# by the main loop to decide which tree branch char to use on discovery items.
has_managed_rgs() {
  local mrgs parent_name parent_type mrg
  mrgs="$(az resource list -g "$RG" \
    --query "[?type=='Microsoft.Discovery/supercomputers' || type=='Microsoft.Discovery/workspaces'].name" \
    -o tsv 2>/dev/null)"
  for parent_name in $mrgs; do
    parent_type="$(az resource list -g "$RG" --name "$parent_name" --query "[0].type" -o tsv 2>/dev/null)"
    mrg="$(az resource show -g "$RG" --resource-type "$parent_type" --name "$parent_name" \
      --query properties.managedResourceGroup -o tsv 2>/dev/null || true)"
    [[ -n "$mrg" ]] && return 0
  done
  return 1
}

# Render one bucket (resources or nested-deploys) into the tree.
#   $1 = label ("resources" or "nested-deploys")
#   $2 = branch prefix (e.g. "   │  ├─" or "   │  └─")
#   $3 = continuation indent for breakdown lines (e.g. "   │  │  ")
#   $4 = newline-separated provisioning-state values
# Compact when all Succeeded: `<prefix> <label>=N succeeded ✓`.
# Otherwise tree: header + one child line per non-empty bucket
# (in-progress / failed / other / succeeded), so X + Y + Z visibly sums to N.
_render_bucket() {
  local label="$1" prefix="$2" indent="$3" states="$4"
  printf '%s' "$states" | awk -v label="$label" -v prefix="$prefix" -v indent="$indent" '
    BEGIN{n=0}
    NF>0 {n++; counts[$1]++}
    END {
      if (n==0) { printf "%s %s=0\n", prefix, label; exit }
      inp_states  = "Running Accepted Creating Updating Deleting Migrating"
      fail_states = "Failed Canceled"

      inp_total=0; inp_detail=""
      split(inp_states, ip, " ")
      for (i=1; i<=length(ip); i++) {
        s=ip[i]
        if (counts[s]+0 > 0) {
          inp_total += counts[s]
          inp_detail = inp_detail (inp_detail ? ", " : "") counts[s] " " s
          delete counts[s]
        }
      }

      fail_total=0; fail_detail=""
      split(fail_states, fl, " ")
      for (i=1; i<=length(fl); i++) {
        s=fl[i]
        if (counts[s]+0 > 0) {
          fail_total += counts[s]
          fail_detail = fail_detail (fail_detail ? ", " : "") counts[s] " " s
          delete counts[s]
        }
      }

      succ = counts["Succeeded"]+0
      delete counts["Succeeded"]

      other_total=0; other_detail=""
      for (s in counts) {
        if (counts[s] != "" && counts[s]+0 > 0) {
          other_total += counts[s]
          other_detail = other_detail (other_detail ? ", " : "") counts[s] " " s
        }
      }

      # Compact: all Succeeded -> single line
      if (inp_total == 0 && fail_total == 0 && other_total == 0) {
        printf "%s %s=%d succeeded ✓\n", prefix, label, n
      } else {
        printf "%s %s=%d total\n", prefix, label, n
        parts = 0
        if (inp_total > 0)   parts++
        if (fail_total > 0)  parts++
        if (other_total > 0) parts++
        if (succ > 0)        parts++
        seen = 0
        if (inp_total > 0) {
          seen++
          br = (seen == parts) ? "└─" : "├─"
          printf "%s%s %d in-progress (%s)\n", indent, br, inp_total, inp_detail
        }
        if (fail_total > 0) {
          seen++
          br = (seen == parts) ? "└─" : "├─"
          printf "%s%s %d failed (%s)\n", indent, br, fail_total, fail_detail
        }
        if (other_total > 0) {
          seen++
          br = (seen == parts) ? "└─" : "├─"
          printf "%s%s %d other (%s)\n", indent, br, other_total, other_detail
        }
        if (succ > 0) {
          seen++
          br = (seen == parts) ? "└─" : "├─"
          printf "%s%s %d succeeded\n", indent, br, succ
        }
      }
    }
  '
}

MAX_UNKNOWN="${MAX_UNKNOWN:-5}"   # consecutive 'Unknown' polls before giving up
STALE_MIN="${STALE_MIN:-5}"       # treat terminal deployments older than N min as history (don't exit; keep polling for new ones)
unknown_streak=0
prev_dep_name=""
prev_dep_state=""

start_ts="$(date +%s)"
echo "Polling RG=$RG prefix=$PREFIX stage=$STAGE every ${INTERVAL}s (Ctrl-C to stop)"
echo

while :; do
  now="$(date +%H:%M:%S)"
  elapsed=$(( ( $(date +%s) - start_ts ) / 60 ))

  # Latest stageN deployment. Use a multi-select hash so `-o tsv` emits
  # all values on a single tab-separated line (multi-select list would
  # be one value per line, breaking `read -r`).
  read -r dep_name dep_state dep_ts < <(
    az deployment group list -g "$RG" \
      --query "[?starts_with(name,'stage${STAGE}-')] | sort_by(@, &properties.timestamp) | [-1].{name:name, state:properties.provisioningState, ts:properties.timestamp}" \
      -o tsv 2>/dev/null
  )
  dep_name="${dep_name:-<none>}"
  dep_state="${dep_state:-}"
  dep_ts="${dep_ts:-}"

  # If the list query came back empty (transient API hiccup), fall back to
  # a direct `deployment show` on the last-known name so we don't get stuck
  # on a stale 'Unknown' forever.
  if [[ -z "$dep_state" && "$dep_name" != "<none>" ]]; then
    dep_state="$(az deployment group show -g "$RG" -n "$dep_name" --query properties.provisioningState -o tsv 2>/dev/null || true)"
  fi
  dep_state="${dep_state:-Unknown}"

  # Line 1: deployment + short stage-specific labels
  resources=""
  case "$STAGE" in
    1)
      vn_state="$(az resource show -g "$RG" \
        --resource-type Microsoft.Network/virtualNetworks \
        --name "vnet-${PREFIX}" \
        --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
      resources=" | vnet=$(state_color "$vn_state")"
      ;;
    2)
      sc_state="$(az resource show -g "$RG" \
        --resource-type Microsoft.Discovery/supercomputers \
        --name "sc-${PREFIX}" \
        --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
      np_state="$(az resource show \
        --ids "/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Discovery/supercomputers/sc-${PREFIX}/nodePools/np1" \
        --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
      resources=" | sc=$(state_color "$sc_state") | np1=$(state_color "$np_state")"
      ;;
    3)
      ws_state="$(az resource show -g "$RG" \
        --resource-type Microsoft.Discovery/workspaces \
        --name "ws-${PREFIX}" \
        --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
      cm_state="$(az resource list -g "$RG" \
        --resource-type Microsoft.Discovery/workspaces/chatModelDeployments \
        --query "[0].provisioningState" -o tsv 2>/dev/null)"
      [[ -z "$cm_state" ]] && cm_state=Missing
      prj_state="$(az resource list -g "$RG" \
        --resource-type Microsoft.Discovery/workspaces/projects \
        --query "[0].provisioningState" -o tsv 2>/dev/null)"
      [[ -z "$prj_state" ]] && prj_state=Missing
      stc_state="$(az resource list -g "$RG" \
        --resource-type Microsoft.Discovery/storageContainers \
        --query "[0].provisioningState" -o tsv 2>/dev/null)"
      [[ -z "$stc_state" ]] && stc_state=Missing
      resources=" | ws=$(state_color "$ws_state") | chat=$(state_color "$cm_state") | proj=$(state_color "$prj_state") | stc=$(state_color "$stc_state")"
      ;;
  esac

  # Mark stale historical deployments so the user doesn't mistake an old
  # 'Failed' record for the current state. Compact marker — appended right
  # after the state, doesn't shift downstream columns much.
  stale_marker=""
  if is_terminal "$dep_state" && [[ -n "$dep_ts" ]]; then
    dep_age_min_hdr=$(python3 -c "
import datetime
try:
    ts = datetime.datetime.fromisoformat('$dep_ts'.replace('Z', '+00:00').split('+')[0] + '+00:00')
    print(int((datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 60))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
    if (( dep_age_min_hdr >= STALE_MIN )); then
      stale_marker=" \033[2m(history, ${dep_age_min_hdr}m old)\033[0m"
    fi
  fi

  printf '[%s | +%3dm] deployment=%-30s %s%b%s\n' \
    "$now" "$elapsed" "$dep_name" \
    "$(state_color "$dep_state")" \
    "$stale_marker" \
    "$resources"

  # Lines 2..N-1: dynamic verbose list of every Microsoft.Discovery/* resource.
  # One resource per line for readability. Tree chars indicate hierarchy.
  # Final block: managed RG summary (tree form, see managed_status_block).
  if [[ "$STAGE" != "1" ]]; then
    # Collect discovery items + check for managed RGs so we know last-line markers.
    disc_items=()
    while IFS=$'\t' read -r label state; do
      [[ -n "$label" ]] && disc_items+=("$label=$(state_color "$state")")
    done < <(discovery_status_lines)
    mrg_present=0
    has_managed_rgs && mrg_present=1

    if (( ${#disc_items[@]} > 0 )); then
      printf '├─ discovery\n'
      last_idx=$((${#disc_items[@]} - 1))
      for i in "${!disc_items[@]}"; do
        if (( mrg_present == 1 )); then
          # managed block follows -> all discovery items use ├ (non-last branch)
          printf '│  ├─ %s\n' "${disc_items[$i]}"
        else
          # no managed block -> last discovery item uses └
          if (( i == last_idx )); then
            printf '│  └─ %s\n' "${disc_items[$i]}"
          else
            printf '│  ├─ %s\n' "${disc_items[$i]}"
          fi
        fi
      done
    fi

    if (( mrg_present == 1 )); then
      managed_status_block
    fi
  fi

  if is_terminal "$dep_state"; then
    # If the terminal deployment is older than STALE_MIN minutes, treat it
    # as history and keep polling — a new deployment may be kicked off
    # while the poller is running. Saves having to restart poll.sh after
    # every retry. Set STALE_MIN=0 to revert to the old "exit immediately"
    # behaviour.
    if [[ "$dep_state" != "$prev_dep_state" || "$dep_name" != "$prev_dep_name" ]]; then
      # Only print the "reached terminal state" line once per (dep, state).
      echo
      echo "Deployment '$dep_name' is in terminal state: $(state_color "$dep_state")"
      if [[ "$dep_state" == "Failed" ]]; then
        echo "Failed operations:"
        # ARM error messages often have 3 nested layers:
        #   outer "ARM template deployment 'x' failed with the following errors:\n..."
        #   middle "Details:\n<actionable message>"
        #   trailing "Raw:\n{escaped-json-with-same-message-again}"
        # Dumping the raw JSON buries the one useful sentence under hundreds
        # of chars. Parse with Python: print resource, type, and ONLY the
        # most-inner 'Details:' line (or the outer message if no Details).
        az deployment operation group list -g "$RG" --name "$dep_name" \
          --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName, type:properties.targetResource.resourceType, err:properties.statusMessage.error.message}" \
          -o json 2>/dev/null \
        | python3 -c '
import json, re, sys
try:
    ops = json.load(sys.stdin)
except Exception:
    ops = []
if not ops:
    print("  (no failed operations returned)")
for op in ops:
    res = op.get("resource") or "<n/a>"
    typ = op.get("type") or "<n/a>"
    raw = op.get("err") or ""
    # Pick the "Details:\n..." block if present, otherwise first line.
    m = re.search(r"Details:\s*\n(.+?)(?:\n\s*Raw:|\Z)", raw, re.DOTALL)
    inner = (m.group(1) if m else raw.splitlines()[0] if raw else "").strip()
    # Collapse runs of whitespace for one-line output.
    inner = re.sub(r"\s+", " ", inner)[:400]
    print(f"  - {typ}/{res}")
    print(f"      \x1b[1;31m{inner}\x1b[0m")
' || true
      fi
      prev_dep_name="$dep_name"
      prev_dep_state="$dep_state"
    fi

    # Age check
    dep_age_min=0
    if [[ -n "$dep_ts" ]]; then
      dep_age_min=$(python3 -c "
import sys, datetime
try:
    ts = datetime.datetime.fromisoformat('$dep_ts'.replace('Z', '+00:00').split('+')[0] + '+00:00')
    delta = datetime.datetime.now(datetime.timezone.utc) - ts
    print(int(delta.total_seconds() / 60))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
    fi

    if (( dep_age_min >= STALE_MIN )); then
      # Old terminal deployment — keep polling for a newer one.
      sleep "$INTERVAL"
      continue
    else
      # Recent terminal state — deployment just finished. Exit.
      exit_code=0
      [[ "$dep_state" == "Failed" ]] && exit_code=1
      exit $exit_code
    fi
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

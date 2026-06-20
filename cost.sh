#!/usr/bin/env bash
# Estimate monthly cost of the current Microsoft Discovery deployment.
#
# Uses the Azure Retail Prices API (no auth required) for live VM hourly
# rates. Storage / VNet / UAMI / EventGrid components are rounded as
# negligible (pennies/month).
#
# Usage:
#   ./cost.sh                              # default RG=rg-disc-yw-1, PREFIX=disc-yw-1
#   RG=rg-foo PREFIX=disc-bar ./cost.sh
#
# Caveats:
# - System pool (D4s_v6) is assumed to be 1 node. Microsoft may scale it
#   up for HA in some regions; check the mrg-dscmp-* RG to confirm.
# - Spot prices are roughly estimated as 30% of on-demand if Retail API
#   doesn't return them. Real spot prices fluctuate.
# - Excludes egress, support plans, chat-model token usage, and any
#   AKS-internal traffic.

set -uo pipefail

PREFIX="${PREFIX:-disc-yw-1}"
RG="${RG:-rg-${PREFIX}}"               # default: rg-<PREFIX>, same convention as deploy.sh
SC_NAME="sc-${PREFIX}"
HOURS_PER_MONTH=730

bold() { printf '\033[1m%s\033[0m' "$*"; }
dim()  { printf '\033[2m%s\033[0m' "$*"; }
green(){ printf '\033[32m%s\033[0m' "$*"; }
yellow(){ printf '\033[33m%s\033[0m' "$*"; }

# Fetch lowest Linux on-demand consumption hourly price for a VM SKU in a region.
# Args: <region> <armSkuName>
# Output: price in USD per hour, or empty if not found.
price_per_hour() {
  local region="$1" sku="$2"
  az rest --method get \
    --uri "https://prices.azure.com/api/retail/prices?currencyCode=USD&\$filter=armRegionName eq '${region}' and armSkuName eq '${sku}' and priceType eq 'Consumption'" \
    --skip-authorization-header 2>/dev/null \
    | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Filter out Windows (priced higher) and Spot (priced separately).
items = [i for i in data.get("Items", [])
         if "Windows" not in i.get("productName", "")
         and "Spot" not in i.get("skuName", "")
         and "Low Priority" not in i.get("skuName", "")]
if not items:
    sys.exit(0)
items.sort(key=lambda i: i.get("retailPrice", 9999))
print(items[0]["retailPrice"])
' 2>/dev/null
}

# Discover current deployment
LOCATION="$(az group show -n "$RG" --query location -o tsv 2>/dev/null || echo unknown)"
SC_STATE="$(az resource show -g "$RG" --resource-type Microsoft.Discovery/supercomputers --name "$SC_NAME" --query properties.provisioningState -o tsv 2>/dev/null || echo Missing)"
SUB="$(az account show --query id -o tsv 2>/dev/null || echo)"

NP_JSON="$(az resource show \
  --ids "/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Discovery/supercomputers/${SC_NAME}/nodePools/np1" \
  --query "{sku:properties.vmSize, current:properties.currentNodeCount, max:properties.maxNodeCount, priority:properties.scaleSetPriority}" \
  -o json 2>/dev/null || echo '{}')"

NP_SKU="$(echo "$NP_JSON"  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sku","") or "")')"
NP_MAX="$(echo "$NP_JSON"  | python3 -c 'import sys,json; v=json.load(sys.stdin).get("max"); print(v if v is not None else "")')"
NP_CUR="$(echo "$NP_JSON"  | python3 -c 'import sys,json; v=json.load(sys.stdin).get("current"); print(v if v is not None else 0)')"
NP_PRIO="$(echo "$NP_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("priority","") or "")')"

# Header
echo "=== Microsoft Discovery monthly cost estimate ==="
echo "RG       : $RG"
echo "Region   : $LOCATION"
echo "SC state : $SC_STATE"
if [[ -n "$NP_SKU" ]]; then
  echo "np1      : $NP_SKU  (current=$NP_CUR, max=$NP_MAX, priority=$NP_PRIO)"
fi
echo

if [[ "$SC_STATE" == "Missing" ]]; then
  echo "$(green "Supercomputer is not deployed — current monthly cost: ~\$0 (storage only, pennies).")"
  echo "$(dim "Run ./deploy.sh 2 to bring it back.")"
  exit 0
fi

echo "Fetching live prices from Azure Retail Prices API..."
SYS_SKU="Standard_D4s_v6"
SYS_PRICE="$(price_per_hour "$LOCATION" "$SYS_SKU")"
NP_PRICE=""
if [[ -n "$NP_SKU" ]]; then
  NP_PRICE="$(price_per_hour "$LOCATION" "$NP_SKU")"
fi

# Fallbacks (rough Sweden Central numbers as of 2026)
if [[ -z "$SYS_PRICE" ]]; then
  SYS_PRICE="0.20"
  echo "$(yellow "WARN: Retail API empty for $SYS_SKU; using fallback \$${SYS_PRICE}/hr")"
fi

calc_mo() { python3 -c "print(round(${1} * ${HOURS_PER_MONTH}, 2))"; }
SYS_MO="$(calc_mo "$SYS_PRICE")"

# Spot discount (if np1 priority is Spot, scale price by ~0.3 if API didn't already return a spot price)
NP_EFFECTIVE_PRICE="$NP_PRICE"
if [[ "$NP_PRIO" == "Spot" && -n "$NP_PRICE" ]]; then
  NP_EFFECTIVE_PRICE="$(python3 -c "print(round(${NP_PRICE} * 0.3, 4))")"
fi

NP_MO_MAX=""
NP_MO_CUR=""
if [[ -n "$NP_EFFECTIVE_PRICE" && -n "$NP_MAX" ]]; then
  NP_MO_MAX="$(python3 -c "print(round(${NP_EFFECTIVE_PRICE} * ${HOURS_PER_MONTH} * ${NP_MAX}, 2))")"
  NP_MO_CUR="$(python3 -c "print(round(${NP_EFFECTIVE_PRICE} * ${HOURS_PER_MONTH} * ${NP_CUR}, 2))")"
fi

echo
echo "$(bold "Always-on (idle, np1 scaled to 0):")"
printf '  System pool %-25s x1   $%6s/hr  -> $%8s/mo  %s\n' \
  "$SYS_SKU" "$SYS_PRICE" "$SYS_MO" "$(dim "(Microsoft-managed; cannot shrink)")"
printf '  Storage / VNet / UAMI / EventGrid                   ~$    0.10/mo  %s\n' "$(dim "(negligible)")"
printf '  np1 (current=%s nodes)                              $    0.00/mo\n' "$NP_CUR"
printf '  %-50s %s\n' "" "----------------------------------"
IDLE_TOTAL="$(python3 -c "print(round(${SYS_MO} + ${NP_MO_CUR:-0} + 0.10, 2))")"
printf '  %s ~$%s/mo\n' "$(bold "Idle subtotal:")" "$IDLE_TOTAL"

if [[ -n "$NP_PRICE" && -n "$NP_MO_MAX" ]]; then
  echo
  echo "$(bold "Active (np1 at max=${NP_MAX} nodes 24x7):")"
  printf '  np1 %-29s x%s   $%6s/hr  -> $%8s/mo\n' \
    "$NP_SKU" "$NP_MAX" "$NP_EFFECTIVE_PRICE" "$NP_MO_MAX"
  [[ "$NP_PRIO" == "Spot" ]] && printf '  %s\n' "$(dim "(spot estimate ~ 30% of on-demand; real prices fluctuate)")"
  ACTIVE_TOTAL="$(python3 -c "print(round(${SYS_MO} + ${NP_MO_MAX} + 0.10, 2))")"
  printf '  %-50s %s\n' "" "----------------------------------"
  printf '  %s ~$%s/mo\n' "$(bold "Active subtotal:")" "$ACTIVE_TOTAL"

  echo
  echo "$(bold "Cost-saving levers:")"
  if [[ "$NP_PRIO" != "Spot" ]]; then
    SPOT_PRICE="$(python3 -c "print(round(${NP_PRICE} * 0.3, 4))")"
    SPOT_MO="$(python3 -c "print(round(${SPOT_PRICE} * ${HOURS_PER_MONTH} * ${NP_MAX}, 2))")"
    SAVED="$(python3 -c "print(round(${NP_MO_MAX} - ${SPOT_MO}, 2))")"
    printf '  Switch np1 to Spot priority: NODE_POOL_PRIORITY=Spot ./deploy.sh 2 -> ~$%s/mo saved\n' "$SAVED"
  fi
  printf '  Pause when idle: ./deploy.sh pause -> idle cost drops to ~$0/mo (resume ~10-30 min)\n'
  printf '  Teardown for long pauses: ./deploy.sh teardown -> ~$0/mo (full redeploy ~40-60 min)\n'
fi

echo
echo "$(dim "Disclaimer: estimates based on Azure Retail Prices API at Linux pay-as-you-go.")"
echo "$(dim "Excludes egress, support plans, chat-model token usage, AKS-internal traffic, RIs/savings plans.")"

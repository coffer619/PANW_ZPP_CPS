#!/usr/bin/env bash
# Interface-scoped CPS sampler. For a single-interface zone (untrust = eth1/1)
# these ARE the zone's connection rates.
#
#   PAN_USER=<user> PAN_PASS=<password> ./iface-cps-poll.sh ethernet1/1 10 3600 untrust.csv
#
# Harvests every tag whose name contains "cps" (schema-agnostic across PAN-OS
# versions) and writes BOTH raw and halved values. PAN counts C2S and S2C
# segments separately, so raw is 2x reality -- the *_true columns are halved.
# 10s interval matches the firewall's internal refresh; faster just resamples.
set -uo pipefail
cd "$(dirname "$0")"; . ./pan-lib.sh
mkdir -p data
IF="${1:-ethernet1/1}"; INT="${2:-10}"; DUR="${3:-3600}"
OUT="${4:-data/ifcps-$(echo "$IF" | tr '/' '_')-$(date +%Y%m%d-%H%M%S).csv}"
if [ -z "${PAN_KEY:-}" ]; then
  PAN_KEY=$(pan_keygen "${PAN_USER:?set PAN_USER}" "${PAN_PASS:?set PAN_PASS}") || exit 1
fi
CMD="<show><counter><interface>${IF}</interface></counter></show>"
harvest(){ grep -oiE '<[a-z0-9_.-]*cps[a-z0-9_.-]*>[^<]*</[a-z0-9_.-]*cps[a-z0-9_.-]*>'; }

X=$(pan_op "$CMD"); KEYS=$(harvest <<<"$X" | sed 's:^<\([^>]*\)>.*:\1:' | sort -u)
[ -n "$KEYS" ] || { echo "No cps-named tags on $IF. Run ./discover.sh and inspect." >&2; exit 1; }
echo "harvesting: $(tr '\n' ' ' <<<"$KEYS")" >&2
{ printf 'epoch,iso'; for k in $KEYS; do printf ',%s_raw,%s_true' "$k" "$k"; done; echo; } > "$OUT"

END=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$END" ]; do
  X=$(pan_op "$CMD")
  printf '%s,%s' "$(date +%s)" "$(date -Is)" >> "$OUT"
  for k in $KEYS; do
    v=$(sed -n "s:.*<$k>\([0-9]*\)</$k>.*:\1:p" <<<"$X" | head -1); v=${v:-0}
    printf ',%s,%s' "$v" "$(( v / 2 ))" >> "$OUT"
  done
  echo >> "$OUT"; sleep "$INT"
done
echo >&2; for k in $KEYS; do echo "=== ${k}_true ==="; ./stats.sh "$OUT" "${k}_true"; echo; done

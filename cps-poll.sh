#!/usr/bin/env bash
# Global new-connection-rate sampler for PAN-OS.
# Polls `show session info` and records cps/pps/kbps/session counts to CSV.
#
#   PAN_KEY=... ./cps-poll.sh [interval_sec] [duration_sec] [outfile]
#   PAN_USER=<user> PAN_PASS=<password> ./cps-poll.sh 5 3600 baseline.csv
#
# Interval 5s is a good default: PAN-OS refreshes these counters ~every second,
# and 5s over a full business cycle keeps the CSV manageable.
set -uo pipefail
cd "$(dirname "$0")"; . ./pan-lib.sh
mkdir -p data

INT="${1:-5}"; DUR="${2:-3600}"; OUT="${3:-data/cps-baseline-$(date +%Y%m%d-%H%M%S).csv}"

if [ -z "${PAN_KEY:-}" ]; then
  [ -n "${PAN_USER:-}" ] && [ -n "${PAN_PASS:-}" ] || { echo "Set PAN_KEY, or PAN_USER+PAN_PASS" >&2; exit 1; }
  PAN_KEY=$(pan_keygen "$PAN_USER" "$PAN_PASS") || exit 1
  export PAN_KEY
fi

echo "epoch,iso,cps,pps,kbps,active,tcp,udp,icmp" > "$OUT"
echo "polling ${PAN_HOST} every ${INT}s for ${DUR}s -> $OUT  (Ctrl-C to stop early)" >&2

END=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$END" ]; do
  X=$(pan_op '<show><session><info/></session></show>')
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date +%s)" "$(date -Is)" \
    "$(pan_tag "$X" cps)"      "$(pan_tag "$X" pps)"  "$(pan_tag "$X" kbps)" \
    "$(pan_tag "$X" num-active)" "$(pan_tag "$X" num-tcp)" \
    "$(pan_tag "$X" num-udp)"  "$(pan_tag "$X" num-icmp)" >> "$OUT"
  sleep "$INT"
done

echo >&2; echo "=== global CPS distribution ($OUT) ===" >&2
./stats.sh "$OUT" cps

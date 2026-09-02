#!/usr/bin/env bash
# Per-zone, per-protocol new-connection rate from PAN-OS traffic logs.
# This is the number that actually maps onto Zone Protection flood buckets,
# because it is scoped to one zone and split SYN / UDP / ICMP / Other-IP.
#
#   PAN_KEY=... ./zone-cps.sh [zone] [pages] [extra_query]
#   PAN_USER=<user> PAN_PASS=<password> ./zone-cps.sh untrust 4
#
# Each page = 5000 log entries (API max), walking backward from now.
set -uo pipefail
cd "$(dirname "$0")"; . ./pan-lib.sh
mkdir -p data

ZONE="${1:-untrust}"; PAGES="${2:-2}"; EXTRA="${3:-}"
QUERY="(zone.src eq ${ZONE})"; [ -n "$EXTRA" ] && QUERY="$QUERY and ($EXTRA)"

if [ -z "${PAN_KEY:-}" ]; then
  [ -n "${PAN_USER:-}" ] && [ -n "${PAN_PASS:-}" ] || { echo "Set PAN_KEY, or PAN_USER+PAN_PASS" >&2; exit 1; }
  PAN_KEY=$(pan_keygen "$PAN_USER" "$PAN_PASS") || exit 1
fi

RAW="data/zone-${ZONE}-logs-$(date +%Y%m%d-%H%M%S).xml"; : > "$RAW"

for ((p=0; p<PAGES; p++)); do
  SKIP=$(( p * 5000 ))
  echo "requesting page $((p+1))/$PAGES (skip=$SKIP) query: $QUERY" >&2
  SUB=$(curl $PAN_CURL_OPTS -X POST "https://${PAN_HOST}/api/" -H "X-PAN-KEY: ${PAN_KEY}" \
        --data-urlencode "type=log" --data-urlencode "log-type=traffic" \
        --data-urlencode "query=$QUERY" --data-urlencode "nlogs=5000" \
        --data-urlencode "skip=$SKIP" --data-urlencode "dir=backward")
  JOB=$(sed -n 's:.*<job>\([0-9]*\)</job>.*:\1:p' <<<"$SUB" | head -1)
  [ -n "$JOB" ] || { echo "no job id returned: $SUB" >&2; exit 1; }

  for ((i=0; i<60; i++)); do
    RES=$(curl $PAN_CURL_OPTS -X POST "https://${PAN_HOST}/api/" -H "X-PAN-KEY: ${PAN_KEY}" \
          --data-urlencode "type=log" --data-urlencode "action=get" --data-urlencode "job-id=$JOB")
    grep -q "<status>FIN</status>" <<<"$RES" && break
    sleep 1
  done
  CNT=$(grep -o '<entry ' <<<"$RES" | wc -l)
  echo "  got $CNT entries" >&2
  printf '%s\n' "$RES" >> "$RAW"
  [ "$CNT" -lt 5000 ] && break
done

echo >&2
gawk -v zone="$ZONE" '
BEGIN{ RS="<entry "; FS="\n" }
{
  if (match($0, /<start>[^<]*<\/start>/)) {
    st = substr($0, RSTART+7, RLENGTH-15)
  } else next
  proto = "other"
  if (match($0, /<proto>[^<]*<\/proto>/))
    proto = tolower(substr($0, RSTART+7, RLENGTH-15))
  if (proto=="tcp") b="tcp-syn"; else if (proto=="udp") b="udp";
  else if (proto=="icmp") b="icmp"; else if (proto=="ipv6-icmp") b="icmpv6"; else b="other-ip";
  sec[b SUBSEP st]++; sec["ALL" SUBSEP st]++
  buckets[b]=1; buckets["ALL"]=1
}
END{
  order["tcp-syn"]=1; order["udp"]=2; order["icmp"]=3; order["icmpv6"]=4; order["other-ip"]=5; order["ALL"]=6
  printf "%-10s %8s %8s %8s %8s %8s   %s\n","bucket","seconds","mean","p95","p99","PEAK","-> Alarm / Activate / Max"
  printf "%s\n", "---------------------------------------------------------------------------------------"
  for (o=1; o<=6; o++) for (b in buckets) if (order[b]==o) {
    n=0; s=0; delete v
    for (k in sec) { split(k,a,SUBSEP); if(a[1]==b){ v[++n]=sec[k]; s+=sec[k] } }
    if(!n) continue
    m=asort(v)
    p95=v[int(95*(m-1)/100)+1]; p99=v[int(99*(m-1)/100)+1]; pk=v[m]
    printf "%-10s %8d %8.1f %8d %8d %8d   %d / %d / %d\n", b, m, s/m, p95, p99, pk,
           int(s/m*1.20)+1, int(pk*1.1)+1, int(pk*3)+1
  }
  print ""
  print "seconds = how many one-second intervals contained at least one new connection."
  print "          It is a count of SECONDS, not of connections."
  print "mean/p95/PEAK = connections started per second, during those seconds."
  print "NOTE: this counts SESSIONS. The SYN-flood bucket counts SYN PACKETS, so treat"
  print "      tcp-syn PEAK as a FLOOR. Confirm with the alarm-rate walk-down (see notes)."
}' "$RAW"
echo "raw log XML kept at: $RAW" >&2

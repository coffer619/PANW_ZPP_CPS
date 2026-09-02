#!/usr/bin/env bash
# Dump raw XML for the CPS-bearing op commands so we can see this PAN-OS
# version's actual tag names before parsing them.
#   PAN_USER=<user> PAN_PASS=<password> ./discover.sh [interface] [zone]
set -uo pipefail
cd "$(dirname "$0")"; . ./pan-lib.sh
IF="${1:-ethernet1/1}"; ZONE="${2:-untrust}"
if [ -z "${PAN_KEY:-}" ]; then
  PAN_KEY=$(pan_keygen "${PAN_USER:?set PAN_USER}" "${PAN_PASS:?set PAN_PASS}") || exit 1
fi
dump(){ echo "===== $1"; echo "--- cmd: $2"; pan_op "$2" | tr '>' '>\n' | sed 's/^[[:space:]]*//' | grep -v '^$' | head -80; echo; }
dump "system info (version)"  '<show><system><info/></system></show>'
dump "session info (global)"  '<show><session><info/></session></show>'
dump "counter interface $IF"  "<show><counter><interface>${IF}</interface></counter></show>"
dump "zone-protection $ZONE"  "<show><zone-protection><zone>${ZONE}</zone></zone-protection></show>"
echo "===== any tag containing 'cps' across those commands ====="
for c in '<show><session><info/></session></show>' \
         "<show><counter><interface>${IF}</interface></counter></show>"; do
  pan_op "$c" | grep -oiE '<[a-z0-9_.-]*cps[a-z0-9_.-]*>[^<]*</[a-z0-9_.-]*cps[a-z0-9_.-]*>'
done | sort -u

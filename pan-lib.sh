#!/usr/bin/env bash
# Shared helpers for PAN-OS XML API. Source this, don't run it.
: "${PAN_HOST:?Set PAN_HOST to your firewall management IP or hostname}"
: "${PAN_CURL_OPTS:=-k -s --max-time 30}"

pan_keygen() {   # pan_keygen <user> <pass>  -> prints API key
  local u="$1" p="$2" r
  r=$(curl $PAN_CURL_OPTS -X POST "https://${PAN_HOST}/api/" \
        --data-urlencode "type=keygen" \
        --data-urlencode "user=$u" \
        --data-urlencode "password=$p")
  if ! grep -q "success" <<<"$r"; then echo "keygen failed: $r" >&2; return 1; fi
  sed -n 's:.*<key>\(.*\)</key>.*:\1:p' <<<"$r"
}

pan_op() {       # pan_op '<show><session><info/></session></show>' -> raw XML
  curl $PAN_CURL_OPTS -X POST "https://${PAN_HOST}/api/" \
    -H "X-PAN-KEY: ${PAN_KEY}" \
    --data-urlencode "type=op" \
    --data-urlencode "cmd=$1"
}

pan_tag() {      # pan_tag <xml> <tagname> -> first value
  sed -n "s:.*<$2>\([^<]*\)</$2>.*:\1:p" <<<"$1" | head -1
}

#!/usr/bin/env bash
# stats.sh <csv> [column]  -> distribution + Palo Alto's documented thresholds
set -uo pipefail
gawk -F, -v col="${2:-cps}" '
NR==1 { for(i=1;i<=NF;i++) if($i==col) c=i
        if(!c){ print "column not found: " col > "/dev/stderr"; exit 1 } next }
$c ~ /^[0-9]+(\.[0-9]+)?$/ { v[++n]=$c+0; s+=$c }
function pct(p){ return v[int(p*(m-1)/100)+1] }
END{
  if(n==0){ print "no numeric samples in column " col; exit }
  m=asort(v); avg=s/m; pk=v[m]
  printf "samples : %d\n", m
  printf "mean    : %.1f\n", avg
  printf "p50     : %d\n", pct(50)
  printf "p90     : %d\n", pct(90)
  printf "p95     : %d\n", pct(95)
  printf "p99     : %d\n", pct(99)
  printf "max     : %d\n", pk
  printf "\nPalo Alto documented guidance (avg %.1f, peak %d):\n", avg, pk
  printf "  Alarm Rate    : %d - %d   (15-20%% above AVERAGE cps)\n", int(avg*1.15)+1, int(avg*1.20)+1
  printf "  Activate Rate : %d        (just above PEAK cps - drops start here)\n", int(pk*1.1)+1
  printf "  Max Rate      : %d        (judgment call ~3x peak; MUST stay under platform capacity)\n", int(pk*3)+1
  printf "\nIf this column came from SNMP or `show counter interface`, confirm it was\n"
  printf "halved first - those sources report 2x actual (C2S + S2C counted separately).\n"
}' "$1"

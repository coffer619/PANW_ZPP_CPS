# Baselining Zone Protection CPS Thresholds on PAN-OS

A step-by-step procedure for measuring the real connections-per-second (CPS) rate
of a firewall zone, so you can set Zone Protection flood thresholds from evidence
instead of guesswork.

Written for and verified on PAN-OS 11.2.x.

---

## Before you start

**You need:**

- An SNMP client (`snmpwalk` / `snmpget` from net-snmp, or equivalent)
- Read-only API access to the firewall (an admin account, or an API key)
- `bash`, `gawk`, and `curl` for the log-based scripts

**Set these shell variables** — every command below uses them:

```bash
export FW=<firewall-management-ip-or-hostname>
export RO=<snmp-v2c-read-only-community-string>
export ZONE=<zone-name>            # e.g. the zone facing your untrusted network
export PAN_HOST="$FW"              # the bash scripts read this
export PAN_KEY=<your-api-key>      # or use PAN_USER / PAN_PASS instead
```

To generate an API key:

```bash
curl -k -X POST "https://$FW/api/?type=keygen" \
  --data-urlencode "user=<user>" --data-urlencode "password=<password>"
```

---

## Background: what you are actually measuring

Zone Protection has **five independent flood buckets** — SYN, UDP, ICMP, ICMPv6,
and Other IP. Each has its own Alarm / Activate / Max triplet. You must baseline
them **separately**; a single "CPS" number is not enough.

The three thresholds behave very differently:

| Field | Behavior |
|---|---|
| **Alarm Rate** | Writes a Threat log entry. **Never drops traffic.** Safe to experiment with. |
| **Activate Rate** | Random Early Drop or SYN cookies **begin here**. This one can break traffic. |
| **Max Rate** | Hard ceiling. Everything above is dropped outright. |

---

## Step 1 — Enable SNMP on the firewall

In the web UI: **Device → Setup → Operations → SNMP Setup**. Choose V2c, set a
read-only community string, commit.

Confirm your client can reach it:

```bash
snmpget -v2c -c "$RO" "$FW" 1.3.6.1.2.1.1.5.0
```

You should get the firewall's hostname back. If it times out, check that the
management interface permits SNMP (**Device → Setup → Interfaces → Management**).

---

## Step 2 — Find your zone's OID index

Per-zone CPS lives in `panZoneTable` at `1.3.6.1.4.1.25461.2.1.2.3.10`. The table
is indexed by `<name-length>.<ascii-of-name>.<vsys-id>`, which is awkward to build
by hand — so just walk the name column and read the index off:

```bash
snmpwalk -v2c -c "$RO" "$FW" 1.3.6.1.4.1.25461.2.1.2.3.10.1.1
```

Output looks like:

```
...10.1.1.3.68.77.90.1 = STRING: DMZ
...10.1.1.5.116.114.117.115.116.1 = STRING: trust
...10.1.1.7.117.110.116.114.117.115.116.1 = STRING: untrust
```

The part after `10.1.1.` is your index. Save it:

```bash
export IDX=<the-index-for-your-zone>     # e.g. 7.117.110.116.114.117.115.116.1
```

> Only zones that actually contain interfaces appear in this table. If your zone
> is missing, it has no interfaces assigned — see Step 7.

---

## Step 3 — Read the three CPS counters

```bash
BASE=1.3.6.1.4.1.25461.2.1.2.3.10
snmpget -v2c -c "$RO" "$FW" \
  $BASE.1.2.$IDX \
  $BASE.1.3.$IDX \
  $BASE.1.4.$IDX
```

| Column | OID | Zone Protection bucket |
|---|---|---|
| `panZoneActiveTcpCps` | `$BASE.1.2.$IDX` | SYN |
| `panZoneActiveUdpCps` | `$BASE.1.3.$IDX` | UDP |
| `panZoneActiveOtherIpCps` | `$BASE.1.4.$IDX` | Other IP |

### Two things that will bite you

**1. These values are reported at 2x actual.** PAN-OS counts the client-to-server
and server-to-client segments of a session separately. **Divide every reading by
two.** Get this wrong and every threshold you set is twice as loose as intended.

**2. There is no ICMP column.** ICMP is folded into Other-IP here, but Zone
Protection has *separate* ICMP and ICMPv6 buckets. For those two, use the
log-based method in Step 4b.

---

## Step 4 — Collect the baseline

Pick the method that matches your zone. **Read Step 4c before choosing.**

### 4a. SNMP polling — for busy zones

The firewall refreshes these counters every 10 seconds, so poll at that interval:

```bash
BASE=1.3.6.1.4.1.25461.2.1.2.3.10
while true; do
  printf '%s' "$(date -Is)"
  for col in 2 3 4; do
    v=$(snmpget -v2c -c "$RO" -Oqv "$FW" $BASE.1.$col.$IDX)
    printf ',%s' "$((v / 2))"          # halved -> true CPS
  done
  echo
  sleep 10
done | tee data/zone-cps.csv
```

Or use the bundled poller, which does the same and writes raw + halved columns:

```powershell
.\zone-cps-snmp.ps1 -TargetHost <fw> -Community <ro-string> `
                    -IntervalSec 10 -DurationSec 3600
```

### 4b. Traffic logs — for quiet or bursty zones

Counts every session in the window, split across all five buckets:

```bash
./zone-cps.sh "$ZONE" 4        # 4 pages x 5000 log entries
```

Requires **Log at Session Start** on the relevant security rules for accurate
per-second timing. Log-at-end still works but the timing is delayed.

### 4c. Which method to use — this matters more than it looks

SNMP reports an **instantaneous gauge sampled every 10 seconds**. If your zone
averages well under 1 CPS, most polls read zero and the one-second bursts that
set your true peak are **missed entirely**.

- Zone averages **> ~10 CPS** → SNMP polling is fine
- Zone averages **< ~10 CPS** → use traffic logs; SNMP will undercount your peak

Traffic logs see every second in the window. SNMP is the better tool for *live
monitoring after* thresholds are set, not for establishing them.

**Baseline over a full business cycle — at minimum one week.** A single day will
miss weekly batch jobs, backups, and patch windows.

---

## Step 5 — Analyze

```bash
./stats.sh data/<your-file>.csv <column-name>
```

Reports mean, p50/p90/p95/p99, max, and suggested thresholds.

---

## Step 6 — Choose your thresholds

### If your zone carries meaningful traffic

Palo Alto's documented guidance:

- **Alarm Rate** — 15–20% above **average** CPS
- **Activate Rate** — just above **peak** CPS
- **Max Rate** — bounded by platform capacity

Note that Alarm anchors to *average* and Activate to *peak*. They are not
multiples of the same number.

### If your zone is very quiet, do not use the formula

Look up your platform's rated new-sessions-per-second on its datasheet, then
compare against your measured peak. If your peak is a tiny fraction of capacity,
the formula produces thresholds that trip on ordinary activity.

**Worked example** (the synthetic dataset in `data/`). A zone measuring 0.31 CPS
average and 24 CPS peak, on an appliance rated 50,000 CPS — a peak of 0.05% of
capacity. The formula yields Alarm = 1, Activate = 27. A single speed test or OS
update would trip that.

With three orders of magnitude of headroom, derive from capacity and threat model
instead:

| | Value | Reasoning |
|---|---|---|
| Alarm Rate | 600 | 25x peak — silent normally, early warning |
| Activate Rate | 6,000 | 250x peak, ~12% of platform |
| Max Rate | 25,000 | ~50% of platform, appliance stays functional |

Prefer **SYN cookies** over Random Early Drop where the platform can sustain it —
less collateral damage to legitimate traffic.

---

## Step 7 — Verify the profile is attached to the right zone

A profile applied to a zone with no interfaces does nothing. Check that your
zone actually has interfaces and a profile:

```bash
curl -k -X POST "https://$FW/api/" -H "X-PAN-KEY: $PAN_KEY" \
  --data-urlencode "type=config" --data-urlencode "action=get" \
  --data-urlencode "xpath=/config/devices/entry/vsys/entry[@name='vsys1']/zone"
```

Look for `<layer3><member>` entries and a `<zone-protection-profile>` on the same
zone. An empty `<layer3/>` means no interfaces are assigned.

If zones show `src="tpl"`, they are pushed from a Panorama template and must be
fixed there, not locally.

Also confirm the flood buckets are actually enabled — a profile can be attached
with every flood flag off:

```bash
curl -k -X POST "https://$FW/api/" -H "X-PAN-KEY: $PAN_KEY" \
  --data-urlencode "type=op" \
  --data-urlencode "cmd=<show><zone-protection/></show>"
```

Check the `<tcp>`, `<udp>`, `<icmp>`, `<ip>`, `<icmp6>`, and `<tcp-syn-cookie>`
flags on your zone's entry.

---

## Step 8 — Confirm your peak with an alarm walk-down

The highest-fidelity check, and it is non-disruptive because **Alarm Rate never
drops traffic**.

1. Apply a Zone Protection profile to your zone.
2. Pin **Activate** and **Max** at the platform maximum, so nothing can ever drop.
3. Set **Alarm** very high, then walk it down: 100000 → 10000 → 1000 → …
4. Stop when flood events start appearing in the Threat log.

The value where alarms first appear is your real peak, counted by the dataplane
in exactly the units the thresholds use — no derivation error.

This matters because the SYN bucket counts SYN **packets**, while log- and
SNMP-derived figures count **sessions**. Half-open and retransmitted SYNs never
become sessions, so your measured TCP figure is a **floor**, not a ceiling.

---

## Step 9 — Deploy, then watch for collateral damage

After setting real thresholds:

```bash
curl -k -X POST "https://$FW/api/" -H "X-PAN-KEY: $PAN_KEY" \
  --data-urlencode "type=op" \
  --data-urlencode "cmd=<show><counter><global><filter><aspect>session</aspect><delta>yes</delta></filter></global></counter></show>" \
  | grep -i flow_dos
```

**Any non-zero zone-flood drop counter during normal operation means your
Activate Rate is too low and you are dropping legitimate traffic.**

---

## Reference

### Useful OIDs

| Name | OID |
|---|---|
| panZoneTable | `1.3.6.1.4.1.25461.2.1.2.3.10` |
| — zone name | `…2.3.10.1.1.<idx>` |
| — TCP CPS | `…2.3.10.1.2.<idx>` |
| — UDP CPS | `…2.3.10.1.3.<idx>` |
| — Other-IP CPS | `…2.3.10.1.4.<idx>` |
| Per-interface table | `1.3.6.1.4.1.25461.2.1.2.3.11` |
| Session scalars (max/active/tcp/udp/icmp) | `1.3.6.1.4.1.25461.2.1.2.3.1–.8` |

### Methods that do NOT work on PAN-OS 11.2.x

Both appear in Palo Alto's own documentation; neither holds on 11.2.7:

- **`show counter interface <if>` has no CPS fields.** Byte, packet, and error
  counters only. Verified by dumping the raw XML response.
- **`show zone-protection` returns no rates.** Only True/False enable flags and
  packet-drop counters.

SNMP is the only per-zone CPS source on this version.

### Cloud and Panorama alternatives

- **AIOps Threshold Recommendations** (PAN-OS 10.0+) is documented as the best
  method — it recommends thresholds directly from telemetry. Requires cloud
  connectivity, so it is unavailable on isolated networks.
- **Panorama device monitoring** gives 90-day CPS trends if you run Panorama.

---

## Scripts in this folder

Bash scripts read `PAN_HOST` and `PAN_KEY` (or `PAN_USER` + `PAN_PASS`) from the
environment. No credentials are stored in any file. Output is written to `data/`.

| Script | Purpose |
|---|---|
| `pan-lib.sh` | Shared XML API helpers. Source it, don't run it. |
| `discover.sh` | Dump raw XML for the CPS-bearing op commands. Run after a PAN-OS upgrade to re-check tag names. |
| `zone-cps.sh` | Per-zone, per-protocol CPS from traffic logs. Best for quiet zones. |
| `cps-poll.sh` | Global CPS sampler via `show session info`. |
| `iface-cps-poll.sh` | Interface-scoped CPS. Exits cleanly on 11.2.x, where no such counters exist. |
| `stats.sh` | Distribution and threshold suggestions for any CSV column. |
| `snmpwalk.ps1` | Minimal SNMPv2c walker for hosts with no SNMP client installed. |
| `zone-cps-snmp.ps1` | Per-zone CPS poller via `panZoneTable`, raw + halved columns. |

### `data/example-baseline-per-second.csv`

A **synthetic** example baseline you can use to try the analysis steps before
pointing anything at a live firewall. Per-second session counts by bucket over a
12-hour window, 13,495 sessions. Columns are `second,bucket,sessions`.

Generated, not captured — it contains no traffic from any real network. It is the
data behind the worked example in Step 6:

| bucket | active secs | mean | peak |
|---|---|---|---|
| tcp-syn | 8039 | 1.5 | 24 |
| udp | 907 | 1.6 | 11 |
| icmp | 113 | 1.3 | 3 |
| other-ip | 14 | 1.0 | 1 |

Try it with:

```bash
gawk -F, 'NR==1{print "sessions";next} $2=="tcp-syn"{print $3}' \
  data/example-baseline-per-second.csv > /tmp/tcp.csv
./stats.sh /tmp/tcp.csv sessions
```

# Measuring Firewall Connection Rates for Zone Protection

A complete, follow-along guide to measuring how many new connections per second
(CPS) your Palo Alto firewall handles, so you can set Zone Protection flood
thresholds based on real numbers instead of guessing.

**No prior scripting experience needed.** Every command is written out in full,
with the output you should expect.

---

## What this is for

Zone Protection defends a firewall zone against connection floods. To turn it on
you must supply three numbers per protocol: **Alarm**, **Activate**, and
**Maximum** connections per second.

Pick numbers too high and an attack passes straight through. Pick them too low
and the firewall starts dropping your own legitimate traffic. Neither failure is
obvious until it hurts, so the numbers need to come from measurement.

This guide measures your actual rates, then helps you choose the thresholds.

### The three numbers, and which one is dangerous

| Setting | What happens when traffic exceeds it |
|---|---|
| **Alarm Rate** | Writes a log entry. **Nothing is blocked.** Completely safe. |
| **Activate Rate** | The firewall **starts dropping connections**. This one can break things. |
| **Maximum Rate** | Hard ceiling — everything above is dropped. |

Set **Activate** too low and you break your own network. That is the setting to
be careful with.

### Time required

- 20 minutes of setup
- 1 hour minimum of data collection, **1 full week strongly recommended**
- 15 minutes to interpret and apply

### Will this change my firewall?

**No.** Parts 1–7 only read data. Nothing is modified until Part 8, which you do
by hand in the firewall's web interface.

---

# Part 1 — Choose your track

There are two ways to collect the data. **Read this before installing anything.**

| | **Track A — SNMP** | **Track B — Traffic Logs** |
|---|---|---|
| Needs an API key? | **No** | **Yes** |
| Needs an SNMP community string? | **Yes** | No |
| Works on quiet networks? | **Poorly** | **Yes** |
| Separates ICMP from other traffic? | No | Yes |
| Setup difficulty | Easier | Slightly harder |

### Which should I use?

**If your firewall handles more than about 10 new connections per second on
average, use Track A.** It is simpler.

**If it is quieter than that — a home lab, a small office, a branch site — use
Track B.** Here is why this matters, because it is the single most common way
these measurements go wrong:

SNMP reports a snapshot taken once every 10 seconds. On a quiet network, most of
those snapshots land on a moment when nothing is happening, so they read zero.
The brief one-second bursts that determine your real peak fall between snapshots
and are **never recorded**. You end up with a peak that is far too low, and if you
set Activate from it, you drop legitimate traffic.

Traffic logs record every single connection, so nothing is missed.

**Not sure how busy your network is?** Do Part 3 (Track A) first. It takes ten
minutes and prints a number. If that number is mostly 0, switch to Track B.

---

# Part 2 — Setup

## 2.1 Open a terminal

A terminal is a window where you type commands.

**Windows** — Click Start, type `powershell`, press Enter.
A blue window opens with a prompt like `PS C:\Users\you>`.

**macOS** — Press Cmd+Space, type `terminal`, press Enter.

**Linux** — Press Ctrl+Alt+T.

Throughout this guide, "run this" means: click into the terminal window, type
(or paste) the command, and press Enter.

> **Pasting into a terminal:** Ctrl+V works in Windows PowerShell and most Linux
> terminals. On macOS use Cmd+V. In some older terminals paste is right-click.

## 2.2 Download these scripts

Run this:

```
git clone https://github.com/coffer619/PANW.git
cd PANW
```

If you get `git: command not found`, install Git first from
<https://git-scm.com/downloads>, then close and reopen your terminal and try again.

## 2.3 Check what tools you have

Run these three commands one at a time. You are just looking to see whether each
prints a version number or says "not found."

```
git --version
snmpwalk --version
gawk --version
```

**What you need depends on your track:**

| Tool | Track A | Track B | If missing |
|---|---|---|---|
| `git` | yes | yes | <https://git-scm.com/downloads> |
| `snmpwalk` | see below | no | see 2.4 |
| `gawk` | no | yes | see 2.5 |
| `curl` | no | yes | Built into Windows 10+, macOS, and Linux |

**Windows users on Track A:** you do **not** need `snmpwalk`. This repo includes
`snmpwalk.ps1`, a self-contained replacement that needs nothing installed. Skip 2.4.

## 2.4 Installing an SNMP client (Track A, macOS/Linux only)

**macOS:** `brew install net-snmp`
(If `brew` is not found, install Homebrew from <https://brew.sh> first.)

**Ubuntu/Debian Linux:** `sudo apt install snmp`

**RHEL/Fedora/Rocky Linux:** `sudo dnf install net-snmp-utils`

## 2.5 Installing gawk (Track B)

The analysis script needs **gawk** specifically, not the `awk` that ships with
macOS — it uses a sorting function plain `awk` does not have.

**Windows:** Included with Git for Windows. Use the **Git Bash** terminal for
Track B, not PowerShell. (Start → type `git bash` → Enter.)

**macOS:** `brew install gawk`

**Ubuntu/Debian:** `sudo apt install gawk`

**RHEL/Fedora:** `sudo dnf install gawk`

---

# Part 3 — Track A: Measuring with SNMP

**Skip to Part 4 if you chose Track B.**

## 3.1 Turn on SNMP on the firewall

In the firewall's web interface:

1. Go to **Device → Setup → Operations**
2. Click **SNMP Setup**
3. Select **V2c**
4. In **SNMP Community String**, type a password-like word. This acts as a
   read-only password for monitoring. Write it down.
5. Click **OK**, then **Commit** in the top right

Then make sure the management interface allows SNMP:

1. Go to **Device → Setup → Interfaces**
2. Click **Management**
3. Under **Network Services**, tick **SNMP**
4. Click **OK**, then **Commit**

> **Is this safe?** The community string is read-only — it cannot change firewall
> settings. It is sent unencrypted, so use it only on a trusted network, and do
> not reuse a real password.

## 3.2 Save your firewall's address and community string

You will use these values repeatedly. Rather than retyping them, save each under
a short name. A saved name like this is called a **variable**.

**On Windows (PowerShell)** — run these two, replacing the example values:

```
$FW = "192.0.2.1"
$RO = "your-community-string"
```

**On macOS or Linux** — run these two. **Do not put spaces around the `=` sign**;
that is the most common mistake here:

```
FW=192.0.2.1
RO=your-community-string
```

Neither command prints anything. That is correct.

**Check it worked.** Run:

```
echo $FW
```

You should see your firewall's IP address printed back:

```
192.0.2.1
```

If you see nothing, or the literal text `$FW`, it did not save. Retype it, and on
Mac/Linux check there are no spaces around the `=`.

> **These disappear when you close the terminal.** If you close the window, set
> them again before continuing.

## 3.3 Confirm you can reach the firewall

**Windows:**

```
.\snmpwalk.ps1 -TargetHost $FW -Community $RO -Oid 1.3.6.1.2.1.1.5
```

**macOS/Linux:**

```
snmpget -v2c -c "$RO" "$FW" 1.3.6.1.2.1.1.5.0
```

> **Note the difference:** the Windows command ends `1.5`, the macOS/Linux one
> ends `1.5.0`. That is not a typo. `snmpwalk.ps1` reads a whole branch, so it
> needs the branch (`1.5`); `snmpget` reads one exact value, so it needs the full
> address (`1.5.0`). Using `1.5.0` with the Windows script silently prints
> nothing.

**Success looks like** your firewall's name printed back, e.g.:

```
1.3.6.1.2.1.1.5.0    PA-440
```

**If it times out or hangs**, work through these in order:

1. Did you Commit both changes in step 3.1? Changes do nothing until committed.
2. Is the community string typed exactly right? It is case-sensitive.
3. Can you reach the firewall at all? Run `ping 192.0.2.1` with your real IP.
4. Is SNMP ticked under Management interface Network Services?

## 3.4 Find your zone's ID number

The firewall stores each zone's data under a numeric ID. You need the one for
your zone.

**Windows:**

```
.\snmpwalk.ps1 -TargetHost $FW -Community $RO -Oid 1.3.6.1.4.1.25461.2.1.2.3.10.1.1
```

**macOS/Linux:**

```
snmpwalk -v2c -c "$RO" "$FW" 1.3.6.1.4.1.25461.2.1.2.3.10.1.1
```

You will see one line per zone:

```
1.3.6.1.4.1.25461.2.1.2.3.10.1.1.3.68.77.90.1                    DMZ
1.3.6.1.4.1.25461.2.1.2.3.10.1.1.5.116.114.117.115.116.1         trust
1.3.6.1.4.1.25461.2.1.2.3.10.1.1.7.117.110.116.114.117.115.116.1 untrust
```

Find the line ending in the zone you want to measure. Copy **only the digits
that come after `...2.3.10.1.1.`** on that line.

In the example above, for the zone named `untrust`, that is:

```
7.117.110.116.114.117.115.116.1
```

Save it. **Windows:**

```
$IDX = "7.117.110.116.114.117.115.116.1"
```

**macOS/Linux:**

```
IDX=7.117.110.116.114.117.115.116.1
```

> **Your zone is not listed?** Only zones with network interfaces assigned appear
> here. If yours is missing, it has no interfaces — see Part 8.1, because that is
> itself a problem worth fixing.

## 3.5 Take a test reading

**Windows:**

```
.\zone-cps-snmp.ps1 -TargetHost $FW -Community $RO -IntervalSec 10 -DurationSec 30
```

**macOS/Linux:**

```
for col in 2 3 4; do
  snmpget -v2c -c "$RO" -Oqv "$FW" 1.3.6.1.4.1.25461.2.1.2.3.10.1.$col.$IDX
done
```

You will get numbers for TCP, UDP, and Other-IP connections per second.

> **This script never asks for an API key or a password.** It uses SNMP only. If
> a required option is missing it prints an error immediately rather than
> prompting, so it is safe to run unattended in a scheduled task.

### Two critical things about these numbers

**1. Every number is exactly double the truth.** The firewall counts each
connection twice — once outbound, once on the reply. **Divide by 2.** Get this
wrong and every threshold you set is twice as loose as you intended.

The bundled `zone-cps-snmp.ps1` already does this for you: its output has both
`_raw` (as reported) and `_true` (halved) columns. **Always use the `_true`
columns.** If you run the raw `snmpget` commands yourself, halve them by hand.

**2. Mostly zeros? Stop and switch to Track B.** As explained in Part 1, a quiet
network cannot be measured this way. You will get a peak that is far too low.

## 3.6 Collect the real baseline

Run for one hour:

```
.\zone-cps-snmp.ps1 -TargetHost $FW -Community $RO -IntervalSec 10 -DurationSec 3600
```

For a full week, change `-DurationSec 3600` to `-DurationSec 604800`.

**Leave the terminal window open while it runs.** Closing it stops the collection.
To stop early, press Ctrl+C.

Results are written to the `data` folder. **Now go to Part 5.**

---

# Part 4 — Track B: Measuring with traffic logs

**Skip this if you completed Track A.**

This track needs a terminal that can run bash: **Git Bash** on Windows (Start →
type `git bash`), or the normal Terminal on macOS/Linux.

## 4.1 Turn on connection logging

For accurate per-second timing, the firewall must log when connections *start*.

1. Go to **Policies → Security**
2. For each rule carrying traffic in your zone: click it, open the **Actions**
   tab, tick **Log at Session Start**
3. Click **OK**, then **Commit**

> This increases log volume. If that is a concern, leave it off — the guide still
> works using session-end times, the timing is just slightly delayed.

## 4.2 Get an API key

This is a long password-like string that lets the scripts read logs.

Run this, replacing all three values with your firewall's IP, your admin
username, and your admin password:

```
curl -k -X POST "https://192.0.2.1/api/?type=keygen" \
  --data-urlencode "user=admin" \
  --data-urlencode "password=YourPasswordHere"
```

You will get back something like:

```xml
<response status="success"><result><key>LUFRPT05RUR0SjI1UzlPd1...</key></result></response>
```

Copy the long string **between `<key>` and `</key>`**.

> **A read-only admin account is enough** — these scripts only read. If your
> firewall admin will not issue API access, use Track A, which needs none.

## 4.3 Save your values

Run these three, substituting your own values:

```
export PAN_HOST=192.0.2.1
export PAN_KEY=LUFRPT05RUR0SjI1UzlPd1...
export ZONE=untrust
```

Check it worked:

```
echo $PAN_HOST
```

Your IP should print back.

## 4.4 Collect the baseline

```
./zone-cps.sh "$ZONE" 4
```

The `4` means fetch 4 pages of 5,000 log entries — 20,000 connections. Increase
it for a longer window.

If you get `Permission denied`, run `chmod +x *.sh` once, then retry.

This prints a summary table directly, and saves raw data in the `data` folder.
**Now go to Part 5.**

---

# Part 5 — Reading your results

Run the analysis:

```
./stats.sh data/YOUR-FILE.csv COLUMN-NAME
```

Replace `YOUR-FILE.csv` with the file that was created. Not sure of the name?
Run `ls data` to list the folder.

## Try it right now on the example data

The repo includes a synthetic sample so you can practise before using your own:

```
gawk -F, 'NR==1{print "sessions";next} $2=="tcp-syn"{print $3}' \
  data/example-baseline-per-second.csv > /tmp/tcp.csv
./stats.sh /tmp/tcp.csv sessions
```

Output:

```
samples : 8039
mean    : 1.5
p50     : 1
p90     : 2
p95     : 3
p99     : 5
max     : 24
```

## What these mean

| | Meaning |
|---|---|
| `samples` | How many measurements were taken. More is better. |
| `mean` | The average. |
| `p95` | 95% of the time you were **below** this. |
| `p99` | 99% of the time you were below this. |
| **`max`** | Your **peak** — the busiest moment recorded. **This is the important one.** |

Write down your **mean** and your **max**. Part 6 uses both.

---

# Part 6 — Choosing your thresholds

## 6.1 Look up your firewall's capacity

Search the web for your model plus "datasheet" — e.g. "PA-440 datasheet" — and
find **new sessions per second**. It will be a large number, typically tens of
thousands.

Write it down as your **capacity**.

## 6.2 Compare your peak to that capacity

Divide your measured **max** by the **capacity**.

### If your peak is more than about 5% of capacity

Your network is busy enough to use the standard formula:

- **Alarm Rate** = your **mean**, plus 20%
- **Activate Rate** = your **max**, plus 10%
- **Maximum Rate** = roughly half your capacity

Note that Alarm comes from the *average* and Activate from the *peak*. They are
not multiples of the same number.

### If your peak is under about 5% of capacity — do not use the formula

This is the common case for home labs, branch offices, and small sites, and
applying the formula here will hurt you.

**Worked example** (the sample data included in this repo). A zone averaging 0.31
CPS with a peak of 24, on a firewall rated 50,000 CPS — a peak that is 0.05% of
capacity. The formula gives Alarm = 1 and Activate = 27.

An Activate of 27 means the firewall starts dropping connections the moment
someone runs a speed test or a computer downloads updates. You would be attacking
yourself.

When there is that much headroom, set the numbers from capacity instead:

| Setting | Value | Why |
|---|---|---|
| Alarm Rate | **25 × your peak** | Silent day to day, warns on anything unusual |
| Activate Rate | **250 × your peak** | Far above normal, far below capacity |
| Maximum Rate | **half your capacity** | Firewall stays functional under load |

For the example above: Alarm 600, Activate 6,000, Maximum 25,000.

## 6.3 A caution about TCP

Your TCP measurement is a **floor, not a ceiling** — the true number is somewhat
higher than you measured.

The firewall's SYN flood counter counts connection *attempts*. Both measurement
methods count completed *connections*. Attempts that never complete — normal on
any network — are invisible to your measurement.

This is another reason to be generous with Activate rather than tight.

---

# Part 7 — Verify your peak safely (recommended)

This confirms your number using the firewall's own counter, **without any risk of
dropping traffic**, because Alarm Rate never blocks anything.

1. Create a Zone Protection profile (**Network → Network Profiles → Zone
   Protection**)
2. Set **Activate** and **Maximum** to the highest values the firewall accepts.
   This guarantees nothing can ever be dropped during the test.
3. Set **Alarm** to a high number, such as 100000
4. Attach the profile to your zone (**Network → Zones**), Commit
5. Wait a day, then check **Monitor → Logs → Threat** for flood entries
6. No entries? Lower Alarm — 100000 → 10000 → 1000 → and so on — committing and
   waiting each time
7. Stop when flood entries begin appearing

The Alarm value where entries first appear is your true peak, measured by the
firewall itself in exactly the units the settings use.

**Then set your real values** from Part 6, using this confirmed peak.

---

# Part 8 — Applying and checking your settings

## 8.1 First, verify the profile is on the right zone

**A Zone Protection profile attached to a zone with no interfaces does nothing at
all.** This is a genuinely common misconfiguration and it is invisible in the UI —
everything looks configured.

1. Go to **Network → Zones**
2. Find your zone. Confirm the **Interfaces** column is **not empty**.
3. Confirm the **Zone Protection Profile** column names your profile.

If the interface list is empty, that zone carries no traffic and protecting it
accomplishes nothing. Find the zone that actually holds your internet-facing
interface and attach the profile there.

## 8.2 If your firewall is centrally managed, change it there

If your firewall is managed by **Panorama** or **Strata Cloud Manager**, local
edits are **overwritten on the next push from the manager**. Make the change in
the management system instead.

To find out which applies, run in the firewall CLI:

```
show panorama-status
show cloud-management-status
```

## 8.3 Watch for collateral damage

After applying real thresholds, check that you are not dropping your own traffic.
In the firewall CLI:

```
show counter global filter aspect session delta yes | match flow_dos
```

**Any non-zero zone-flood drop counter during normal business hours means your
Activate Rate is too low and you are dropping legitimate traffic.** Raise it.

Check on day one, day two, and after your first busy period.

---

# Part 9 — Troubleshooting

**"command not found" / "not recognized"**
The tool is not installed or the terminal was opened before installing it. Close
the terminal, open a new one, try again. Still failing — revisit Part 2.

**SNMP times out**
Work through Part 3.3's checklist. The most common cause is forgetting to
**Commit** on the firewall.

**"Permission denied" running a .sh script**
Run `chmod +x *.sh` once, then retry.

**PowerShell: "running scripts is disabled on this system"**
Run this once, then retry:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

**Windows: `snmpwalk.ps1` prints nothing at all — no output, no error**
You almost certainly used an OID ending in `.0`. That script reads a whole
branch, and an address ending in `.0` is a single leaf, so there is nothing
beneath it to list. Drop the trailing `.0` and run it again.

**Every reading is 0**
Either your network genuinely is idle, or you are on Track A on a quiet network.
See Part 1 — switch to Track B.

**My zone is not in the list in 3.4**
It has no interfaces assigned. See Part 8.1.

**`echo $FW` prints nothing**
The variable did not save, or you closed and reopened the terminal. Set it again.
On Mac/Linux, check for spaces around the `=` sign.

**`awk: calling undefined function asort`**
You have plain `awk`, not `gawk`. See Part 2.5.

---

# Technical reference

Everything below is background. You do not need it to follow the guide.

## Where per-zone CPS actually lives

`panZoneTable`, base OID `1.3.6.1.4.1.25461.2.1.2.3.10`, indexed by
`<name-length>.<ascii-of-zone-name>.<vsys-id>`.

| Column | OID | Zone Protection bucket |
|---|---|---|
| `panZoneName` | `…2.3.10.1.1.<idx>` | (the index lookup) |
| `panZoneActiveTcpCps` | `…2.3.10.1.2.<idx>` | SYN |
| `panZoneActiveUdpCps` | `…2.3.10.1.3.<idx>` | UDP |
| `panZoneActiveOtherIpCps` | `…2.3.10.1.4.<idx>` | Other IP |

A per-interface equivalent exists at `1.3.6.1.4.1.25461.2.1.2.3.11`. Device-wide
session scalars are at `…2.3.1` through `…2.3.8`.

**There is no ICMP column.** ICMP is folded into Other-IP, but Zone Protection has
separate ICMP and ICMPv6 buckets. Track B is the only way to measure those two.

**All values are doubled** because client-to-server and server-to-client segments
are counted separately. Halve them.

## Methods that do not work on PAN-OS 11.2.x

Both appear in Palo Alto's documentation; neither holds on 11.2.7, verified by
dumping raw API output:

- **`show counter interface <if>` has no CPS fields** — byte, packet, and error
  counters only.
- **`show zone-protection` returns no rates** — only enable flags and packet-drop
  counters.

SNMP is the only per-zone CPS source on this version.

## Management-plane alternatives

**Neither Panorama nor Strata Cloud Manager exposes `panZoneTable`.** Their health
monitoring is device-level — total CPS for the firewall, not split by zone or
protocol. Per-zone CPS comes only from polling each firewall's SNMP agent
directly, which is why this toolkit exists.

| Platform | What | Where |
|---|---|---|
| Panorama | Device-level CPS trends (~90 days) | Managed Devices → Health |
| Panorama | Aggregated traffic logs, longer retention | Monitor → Logs → Traffic |
| Panorama | Zone Protection profiles | Template → Network → Network Profiles |
| Strata Cloud Manager | Zone Protection profiles, pushed config | Manage → Configuration → NGFW and Prisma Access |

Track B ports to either — point the query at the collector rather than the
firewall for a longer window.

## AIOps Threshold Recommendations

Palo Alto documents these as the best way to measure CPS on PAN-OS 10.0+. They
recommend Alarm / Activate / Maximum for TCP (SYN), UDP, and Other IP straight
from telemetry, and separately flag zones with no Zone Protection profile.

Two prerequisites — the second catches people out:

1. **Outbound cloud connectivity with device telemetry enabled.** Verify with
   `show cloud-management-status`. This needs only *outbound* reachability; a
   zone with no inbound exposure can still be fully cloud-connected.
2. **Premium AIOps.** ZPP threshold recommendations are Premium-tier. A connected
   firewall on the free tier will not receive them.

If both hold, prefer the recommendations. If either fails, use this toolkit.

## Scripts in this folder

| Script | Track | Purpose |
|---|---|---|
| `snmpwalk.ps1` | A | Self-contained SNMPv2c client. No install needed. |
| `zone-cps-snmp.ps1` | A | Per-zone CPS poller. Writes raw and halved columns. |
| `zone-cps.sh` | B | Per-zone, per-protocol CPS from traffic logs. |
| `stats.sh` | both | Distribution and threshold suggestions for any CSV column. |
| `pan-lib.sh` | B | Shared API helpers. Sourced by other scripts, not run directly. |
| `discover.sh` | B | Dumps raw API output. For re-checking after a PAN-OS upgrade. |
| `cps-poll.sh` | B | Device-wide (not per-zone) CPS sampler. |
| `iface-cps-poll.sh` | B | Per-interface CPS. Exits cleanly on 11.2.x, where none exist. |

Track A scripts need `-TargetHost` and `-Community` only — **never an API key**.
Track B scripts read `PAN_HOST` and `PAN_KEY` (or `PAN_USER` and `PAN_PASS`) from
the environment. No credentials are stored in any file.

### `data/example-baseline-per-second.csv`

A **synthetic** sample for practising the analysis steps before touching a live
firewall. Per-second connection counts by protocol over 12 hours, 13,495
connections, columns `second,bucket,sessions`. Generated, not captured — it
contains no traffic from any real network.

| bucket | active secs | mean | peak |
|---|---|---|---|
| tcp-syn | 8039 | 1.5 | 24 |
| udp | 907 | 1.6 | 11 |
| icmp | 113 | 1.3 | 3 |
| other-ip | 14 | 1.0 | 1 |

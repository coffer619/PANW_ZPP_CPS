# Per-zone CPS sampler via PAN-OS panZoneTable (SNMPv2c).
#
#   .\zone-cps-snmp.ps1 -TargetHost <fw-ip> -Community <ro-string> `
#                       -IntervalSec 10 -DurationSec 3600
#
# panZoneTable = 1.3.6.1.4.1.25461.2.1.2.3.10, indexed by <namelen>.<ascii-name>.<vsysid>
#   .10.1.1.<idx> = panZoneName
#   .10.1.2.<idx> = panZoneActiveTcpCps       -> SYN flood bucket
#   .10.1.3.<idx> = panZoneActiveUdpCps       -> UDP flood bucket
#   .10.1.4.<idx> = panZoneActiveOtherIpCps   -> Other-IP flood bucket (ICMP folded in here)
#
# Palo Alto counts C2S and S2C session segments separately, so the MIB reports
# 2x actual. *_true columns are halved. Firewall refreshes these every 10s.
param(
  [int]$IntervalSec   = 10,
  [int]$DurationSec   = 300,
  [string]$Out        = "",
  [string]$Community  = "",
  [string]$TargetHost = ""
)
if(-not $TargetHost){ Write-Error "-TargetHost is required (firewall management IP or hostname)"; exit 1 }
if(-not $Community) { Write-Error "-Community is required (SNMP v2c read-only community string)"; exit 1 }
if(-not $Out){ $Out = Join-Path $PSScriptRoot ("data\zone-cps-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss")) }
$dataDir = Split-Path $Out -Parent
if($dataDir -and -not (Test-Path $dataDir)){ New-Item -ItemType Directory -Force $dataDir | Out-Null }
$walker = Join-Path $PSScriptRoot "snmpwalk.ps1"
$BASE   = "1.3.6.1.4.1.25461.2.1.2.3.10"
$esc    = [regex]::Escape($BASE)

"epoch,iso,zone,tcp_raw,tcp_true,udp_raw,udp_true,otherip_raw,otherip_true" |
  Out-File -FilePath $Out -Encoding utf8

Write-Host "polling panZoneTable on $TargetHost every ${IntervalSec}s for ${DurationSec}s -> $Out"
$end = (Get-Date).AddSeconds($DurationSec)
while((Get-Date) -lt $end){
  $rows = & $walker -TargetHost $TargetHost -Community $Community -Oid $BASE -MaxRows 500
  $name=@{}; $tcp=@{}; $udp=@{}; $oth=@{}
  foreach($r in $rows){
    $p = $r -split "`t"
    if($p.Count -lt 2){ continue }
    if($p[0] -match "^$esc\.1\.(\d+)\.(.+)$"){
      $col=$matches[1]; $idx=$matches[2]
      switch($col){
        "1" { $name[$idx]=$p[1] }
        "2" { $tcp[$idx]=[int]$p[1] }
        "3" { $udp[$idx]=[int]$p[1] }
        "4" { $oth[$idx]=[int]$p[1] }
      }
    }
  }
  $ep  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $iso = (Get-Date).ToString("s")
  foreach($idx in $name.Keys){
    $t=[int]$tcp[$idx]; $u=[int]$udp[$idx]; $x=[int]$oth[$idx]
    "$ep,$iso,$($name[$idx]),$t,$([math]::Floor($t/2)),$u,$([math]::Floor($u/2)),$x,$([math]::Floor($x/2))" |
      Out-File -FilePath $Out -Append -Encoding utf8
  }
  Start-Sleep -Seconds $IntervalSec
}
Write-Host "done -> $Out"

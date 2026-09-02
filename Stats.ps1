# Distribution and threshold suggestions for a CSV column - PowerShell version.
# Windows equivalent of stats.sh, so Track A users never need bash or gawk.
#
#   .\Stats.ps1 -Path data\zone-cps-20260101-120000.csv -Column tcp_true -Zone untrust
#
# -Zone is optional and only applies to files that have a "zone" column
# (anything produced by zone-cps-snmp.ps1). Omit it to analyse every row.
param(
  [string]$Path   = "",
  [string]$Column = "",
  [string]$Zone   = ""
)
if(-not $Path){   Write-Error "-Path is required (the CSV file to analyse)"; exit 1 }
if(-not $Column){ Write-Error "-Column is required (which column to analyse, e.g. tcp_true)"; exit 1 }
if(-not (Test-Path $Path)){ Write-Error "File not found: $Path"; exit 1 }

$rows = Import-Csv $Path
if($rows.Count -eq 0){ Write-Error "That file has no data rows."; exit 1 }

if(-not ($rows[0].PSObject.Properties.Name -contains $Column)){
  Write-Host "There is no column called '$Column' in that file." -ForegroundColor Yellow
  Write-Host "Available columns are:"
  $rows[0].PSObject.Properties.Name | ForEach-Object { "  $_" }
  exit 1
}

if($Zone){
  if($rows[0].PSObject.Properties.Name -contains 'zone'){
    $rows = $rows | Where-Object { $_.zone -eq $Zone }
    if($rows.Count -eq 0){ Write-Error "No rows found for zone '$Zone'."; exit 1 }
  } else {
    Write-Host "Note: this file has no 'zone' column, so -Zone was ignored.`n" -ForegroundColor Yellow
  }
}

$vals = foreach($r in $rows){
  $raw = $r.$Column
  $n = 0.0
  if([double]::TryParse($raw, [ref]$n)){ $n }
}
$vals = @($vals)
if($vals.Count -eq 0){ Write-Error "Column '$Column' contains no numeric values."; exit 1 }

$sorted = $vals | Sort-Object
$m      = $sorted.Count
# NOTE: [int] in PowerShell ROUNDS (and uses banker's rounding); awk's int()
# truncates. Use [Math]::Floor everywhere so this agrees with stats.sh exactly.
function Pct([int]$p){ return $sorted[[int][Math]::Floor(($p * ($m - 1)) / 100)] }
$avg = ($sorted | Measure-Object -Average).Average
$pk  = $sorted[$m - 1]

"samples : {0}"     -f $m
"mean    : {0:N1}"  -f $avg
"p50     : {0}"     -f (Pct 50)
"p90     : {0}"     -f (Pct 90)
"p95     : {0}"     -f (Pct 95)
"p99     : {0}"     -f (Pct 99)
"max     : {0}"     -f $pk
""
"Palo Alto documented guidance (avg {0:N1}, peak {1}):" -f $avg, $pk
"  Alarm Rate    : {0} - {1}   (15-20% above AVERAGE cps)"        -f ([int][Math]::Floor($avg*1.15)+1), ([int][Math]::Floor($avg*1.20)+1)
"  Activate Rate : {0}        (just above PEAK cps - drops start here)" -f ([int][Math]::Floor($pk*1.1)+1)
"  Max Rate      : {0}        (judgment call ~3x peak; MUST stay under platform capacity)" -f ([int][Math]::Floor($pk*3)+1)
""
"If your peak is a tiny fraction of your platform's rated capacity, do NOT use"
"the numbers above - see Part 6 of the README. On a quiet network they will drop"
"legitimate traffic."
""
if($Column -notlike "*_true" -and $Column -notlike "*sessions*"){
  "WARNING: column '$Column' does not look like a halved value. SNMP reports 2x"
  "actual. Use the *_true columns, or halve these numbers yourself."
}

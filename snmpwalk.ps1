# Minimal SNMPv2c walker (no net-snmp dependency). BER encode/decode over UDP/161.
param(
  [string]$TargetHost = "",
  [string]$Community  = "",
  [string]$Oid        = "1.3.6.1.4.1.25461.2.1.2.3",
  [int]$TimeoutMs     = 3000,
  [int]$MaxRows       = 4000
)
if(-not $TargetHost){ Write-Error "-TargetHost is required (firewall management IP or hostname)"; exit 1 }
if(-not $Community) { Write-Error "-Community is required (SNMP v2c read-only community string)"; exit 1 }
function Enc-Len([int]$n){
  if($n -lt 128){ return ,[byte]$n }
  $b=@(); $t=$n
  while($t -gt 0){ $b=,([byte]($t -band 0xFF))+$b; $t=[int][math]::Floor($t/256) }
  return ,([byte](0x80 -bor $b.Count))+$b
}
function Enc-TLV([byte]$tag,[byte[]]$val){ return ,$tag+(Enc-Len $val.Length)+$val }
function Enc-Int([int]$v){
  $b=[System.BitConverter]::GetBytes([int]$v); [array]::Reverse($b)
  $i=0; while($i -lt 3 -and $b[$i] -eq 0 -and ($b[$i+1] -band 0x80) -eq 0){$i++}
  return Enc-TLV 0x02 $b[$i..3]
}
function Enc-OID([string]$o){
  $a=@($o.Split('.') | ForEach-Object {[int]$_})
  $b=@([byte](40*$a[0]+$a[1]))
  for($i=2;$i -lt $a.Count;$i++){
    $v=$a[$i]; $t=@([byte]($v -band 0x7F)); $v=[int][math]::Floor($v/128)
    while($v -gt 0){ $t=,([byte](($v -band 0x7F) -bor 0x80))+$t; $v=[int][math]::Floor($v/128) }
    $b+=$t
  }
  return Enc-TLV 0x06 $b
}
function Dec-Len([byte[]]$buf,[ref]$p){
  $l=$buf[$p.Value]; $p.Value=$p.Value+1
  if($l -lt 128){ return [int]$l }
  $n=$l -band 0x7F; $v=0
  for($i=0;$i -lt $n;$i++){ $v=$v*256+$buf[$p.Value]; $p.Value=$p.Value+1 }
  return [int]$v
}
function Dec-OID([byte[]]$b){
  if($b.Count -eq 0){ return "" }
  $o=@([int][math]::Floor($b[0]/40),[int]($b[0]%40)); $v=0
  for($i=1;$i -lt $b.Count;$i++){
    $v=$v*128+($b[$i] -band 0x7F)
    if(($b[$i] -band 0x80) -eq 0){ $o+=$v; $v=0 }
  }
  return ($o -join '.')
}
$udp=New-Object System.Net.Sockets.UdpClient
$udp.Client.ReceiveTimeout=$TimeoutMs
$udp.Connect($TargetHost,161)
$cur=$Oid; $rid=1000; $rows=0
while($rows -lt $MaxRows){
  $vb  = Enc-TLV 0x30 ((Enc-OID $cur)+(Enc-TLV 0x05 @()))
  $vbl = Enc-TLV 0x30 $vb
  $pdu = Enc-TLV 0xA1 ((Enc-Int $rid)+(Enc-Int 0)+(Enc-Int 0)+$vbl)   # 0xA1 = GetNextRequest
  $msg = Enc-TLV 0x30 ((Enc-Int 1)+(Enc-TLV 0x04 ([Text.Encoding]::ASCII.GetBytes($Community)))+$pdu)
  [void]$udp.Send($msg,$msg.Length)
  try { $ep=New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any,0); $resp=$udp.Receive([ref]$ep) }
  catch { Write-Error "timeout/no response from $TargetHost (community wrong, or SNMP not permitted from this host)"; exit 2 }
  $p=0
  $null=$resp[$p]; $p++; $null=Dec-Len $resp ([ref]$p)          # outer SEQUENCE
  $null=$resp[$p]; $p++; $l=Dec-Len $resp ([ref]$p); $p+=$l     # version
  $null=$resp[$p]; $p++; $l=Dec-Len $resp ([ref]$p); $p+=$l     # community
  $null=$resp[$p]; $p++; $null=Dec-Len $resp ([ref]$p)          # PDU
  $null=$resp[$p]; $p++; $l=Dec-Len $resp ([ref]$p); $p+=$l     # request-id
  $null=$resp[$p]; $p++; $l=Dec-Len $resp ([ref]$p)
  $errStatus=0; for($i=0;$i -lt $l;$i++){ $errStatus=$errStatus*256+$resp[$p+$i] }; $p+=$l
  $null=$resp[$p]; $p++; $l=Dec-Len $resp ([ref]$p); $p+=$l     # error-index
  if($errStatus -ne 0){ Write-Error "SNMP error-status $errStatus"; exit 3 }
  $null=$resp[$p]; $p++; $null=Dec-Len $resp ([ref]$p)          # varbindlist
  $null=$resp[$p]; $p++; $null=Dec-Len $resp ([ref]$p)          # varbind
  $null=$resp[$p]; $p++; $l=Dec-Len $resp ([ref]$p)
  $roid=Dec-OID $resp[$p..($p+$l-1)]; $p+=$l
  $vtag=$resp[$p]; $p++; $vl=Dec-Len $resp ([ref]$p)
  if($vtag -eq 0x82 -or $roid -eq "" -or -not $roid.StartsWith($Oid)){ break }
  $val=""
  if($vl -gt 0){ $raw=$resp[$p..($p+$vl-1)] } else { $raw=@() }
  switch($vtag){
    0x04 { $val=[Text.Encoding]::UTF8.GetString($raw) }
    0x06 { $val=Dec-OID $raw }
    0x05 { $val="NULL" }
    default { $n=0; foreach($by in $raw){ $n=$n*256+$by }; $val="$n" }
  }
  "{0}`t{1}" -f $roid,$val
  $cur=$roid; $rid++; $rows++
}
$udp.Close()

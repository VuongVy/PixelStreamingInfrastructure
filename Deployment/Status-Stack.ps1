<#
.SYNOPSIS
    Shows which services are listening and, per Wilbur instance, how many UE streamers / players are connected.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Common.ps1')

$r = Read-JsonFile -Path $ResolvedFile
if (-not $r) {
    Write-Host 'Stack is not running (no runtime\stack.resolved.json). Run .\Start-Stack.ps1' -ForegroundColor Yellow
    exit 1
}

function Format-State([bool]$ok, [string]$yes = 'UP', [string]$no = 'DOWN') {
    if ($ok) { return $yes } else { return $no }
}

Write-Host ''
Write-Host ("Server {0}  /  Public {1}" -f $r.ServerIp, $r.PublicIp) -ForegroundColor Cyan
Write-Host ''

$rows = @()
$rows += [pscustomobject]@{ Service = 'Matchmaker HTTP'; Port = $r.Matchmaker.HttpPort; State = Format-State (Test-TcpListening $r.Matchmaker.HttpPort) }
if ($r.TurnEngine -and $r.TurnEngine -ne 'none') {
    $udp = [bool](Get-NetUDPEndpoint -LocalPort $r.Turn.Port -ErrorAction SilentlyContinue)
    $ok = $udp
    if ($r.TurnEngine -eq 'coturn') { $ok = $udp -and (Test-TcpListening $r.Turn.Port) }
    $rows += [pscustomobject]@{ Service = "TURN ($($r.TurnEngine))"; Port = $r.Turn.Port; State = Format-State $ok }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

$instRows = foreach ($inst in $r.Instances) {
    $s = Get-WilburStatus -Port $inst.Http
    [pscustomobject]@{
        Instance   = "#$($inst.Index)"
        'HTTP'     = "$($inst.Http) " + (Format-State ([bool]$s))
        'Streamer' = "$($inst.Streamer) " + (Format-State (Test-TcpListening $inst.Streamer))
        'UE'       = if ($s) { $s.streamer_count } else { '-' }
        'Players'  = if ($s) { $s.player_count } else { '-' }
    }
}
$instRows | Format-Table -AutoSize | Out-String | Write-Host

$free = @($instRows | Where-Object { $_.UE -ge 1 -and $_.Players -eq 0 }).Count
Write-Host ("Instances ready for a new user: {0} / {1}" -f $free, $r.InstanceCount)
$dup = @($instRows | Where-Object { $_.UE -gt 1 })
if ($dup.Count -gt 0) {
    Write-Host ('WARNING: more than one UE connected to instance {0} (UE launched twice on the same port?)' -f (($dup | ForEach-Object Instance) -join ', ')) -ForegroundColor Yellow
}
Write-Host ("Client URL: http://{0}:{1}/" -f $r.PublicIp, $r.Matchmaker.HttpPort) -ForegroundColor Green

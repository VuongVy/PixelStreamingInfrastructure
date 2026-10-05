<#
.SYNOPSIS
    Creates (or removes) Windows Firewall inbound rules on the signalling server, matching stack.config.json.
    Must be run as Administrator. Not needed for a single-machine local test.

.EXAMPLE
    .\Open-Firewall.ps1 -MaxInstances 20
    .\Open-Firewall.ps1 -Remove
#>
[CmdletBinding()]
param(
    [int]$MaxInstances = 20,
    [switch]$Remove,
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$group = 'PixelStreaming'
$cfg = Get-StackConfig -Path $ConfigPath
if (-not $Remove -and $cfg.ModeResolved -eq 'local') {
    Write-Host 'Mode is "local": everything binds to 127.0.0.1, no firewall rule is needed. Nothing changed.' -ForegroundColor Yellow
    return
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this script as Administrator.' }

Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Remove) { Write-Host "Removed firewall rules in group '$group'."; return }

$first = Get-InstancePorts -Cfg $cfg -Index 1
$last  = Get-InstancePorts -Cfg $cfg -Index $MaxInstances

$rules = @(
    @{ Name = 'PS Matchmaker HTTP';   Protocol = 'TCP'; Port = "$($cfg.Matchmaker.HttpPort)" }
    @{ Name = 'PS Signalling HTTP+WS'; Protocol = 'TCP'; Port = "$($first.Http)-$($last.Http)" }
    @{ Name = 'PS Signalling Streamer'; Protocol = 'TCP'; Port = "$($first.Streamer)-$($last.Streamer)" }
)
if ($cfg.Turn.Enabled) {
    $rules += @{ Name = 'PS TURN TCP';   Protocol = 'TCP'; Port = "$($cfg.Turn.Port)" }
    $rules += @{ Name = 'PS TURN UDP';   Protocol = 'UDP'; Port = "$($cfg.Turn.Port)" }
    $rules += @{ Name = 'PS TURN relay'; Protocol = 'UDP'; Port = "$($cfg.Turn.MinPort)-$($cfg.Turn.MaxPort)" }
}

foreach ($r in $rules) {
    New-NetFirewallRule -DisplayName $r.Name -Group $group -Direction Inbound -Action Allow `
        -Protocol $r.Protocol -LocalPort $r.Port | Out-Null
    Write-Host ("Allowed inbound {0,-4} {1,-13} ({2})" -f $r.Protocol, $r.Port, $r.Name)
}
Write-Host 'Done. SFU ports stay closed (localhost only).' -ForegroundColor Green

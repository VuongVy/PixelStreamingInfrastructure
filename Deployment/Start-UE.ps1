<#
.SYNOPSIS
    Launches UE Pixel Streaming instances, each pointed at its own Wilbur Streamer port.

.DESCRIPTION
    Can run on the same machine as the stack (local test) or on a separate UE machine.
    On a separate UE machine pass -ServerIp (the server's IP reachable from the UE machine).

.EXAMPLE
    # Local test, 2 instances
    .\Start-UE.ps1 -Exe "D:\Builds\Windows\MyProject.exe" -Count 2

    # UE machine #2 serves instances 3 and 4 of a server at 10.0.0.10
    .\Start-UE.ps1 -Exe "D:\Builds\Windows\MyProject.exe" -ServerIp 10.0.0.10 -StartIndex 3 -Count 2
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [int]$Count = 0,
    [int]$StartIndex = 1,
    [string]$ServerIp,
    [string]$ExtraArgs,
    [switch]$LegacyArgs,
    [string]$ConfigPath
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$cfgFile = $ConfigPath
if (-not $cfgFile) { $cfgFile = $DefaultConfig }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
$resolved = Read-JsonFile -Path $ResolvedFile

# Server IP: parameter > running local stack > Mode local (127.0.0.1) > explicit value in config.
if (-not $ServerIp) {
    if ($resolved) { $ServerIp = $resolved.ServerIp }
    elseif (-not $cfg.Mode -or $cfg.Mode -eq 'local') { $ServerIp = '127.0.0.1' }
    elseif ($cfg.ServerIp -and $cfg.ServerIp -ne 'auto') { $ServerIp = $cfg.ServerIp }
    else { throw 'Cannot determine server IP. Pass -ServerIp <ip of the signalling server>.' }
}
if (-not $Exe) { $Exe = $cfg.UE.Exe }
if (-not $Exe) { throw 'Pass -Exe <path to packaged UE exe> or set UE.Exe in stack.config.json.' }
if (-not (Test-Path $Exe)) { throw "UE exe not found: $Exe" }
if ($Count -lt 1) { $Count = [int]$cfg.InstanceCount }
if (-not $PSBoundParameters.ContainsKey('ExtraArgs')) { $ExtraArgs = $cfg.UE.ExtraArgs }
if (-not $PSBoundParameters.ContainsKey('LegacyArgs')) { $LegacyArgs = [bool]$cfg.UE.LegacyArgs }

$existing = @(Read-JsonFile -Path $UePidFile) | Where-Object { $_ }
$launched = @()

for ($i = $StartIndex; $i -lt $StartIndex + $Count; $i++) {
    $ports = Get-InstancePorts -Cfg $cfg -Index $i
    if ($LegacyArgs) {
        # UE 4.27 style
        $psArgs = "-PixelStreamingIP=$ServerIp -PixelStreamingPort=$($ports.Streamer)"
    } else {
        # UE 5.5+ Pixel Streaming 2 (-PixelStreamingURL is still accepted but logged as legacy)
        $psArgs = "-PixelStreamingConnectionURL=ws://$($ServerIp):$($ports.Streamer)"
    }
    $argLine = "$psArgs $ExtraArgs".Trim()
    Write-Host ("UE #{0}: {1} {2}" -f $i, (Split-Path $Exe -Leaf), $argLine)
    $p = Start-Process -FilePath $Exe -ArgumentList $argLine -PassThru
    $launched += [pscustomobject]@{ Name = ('ue_{0:D2}' -f $i); Pid = $p.Id }
    # Stagger start-up so instances don't fight over shader cache / GPU init.
    Start-Sleep -Seconds 2
}

Write-JsonFile -Path $UePidFile -Object @($existing + $launched)
Write-Host "Launched $($launched.Count) UE instance(s). Check with .\Status-Stack.ps1" -ForegroundColor Green

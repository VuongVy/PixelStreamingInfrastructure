<#
.SYNOPSIS
    Stops everything started by Start-Stack.ps1 (and Start-UE.ps1 unless -KeepUE).
#>
[CmdletBinding()]
param(
    [switch]$KeepUE
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Stop-Recorded {
    param([string]$File)
    $entries = @(Read-JsonFile -Path $File)
    foreach ($e in $entries) {
        if (-not $e) { continue }
        if (Get-Process -Id $e.Pid -ErrorAction SilentlyContinue) {
            Write-Host ("Stopping {0,-12} (pid {1})" -f $e.Name, $e.Pid)
            # /T kills the whole tree (cmd.exe launcher -> node.exe / turnserver.exe / UE).
            & taskkill.exe /T /F /PID $e.Pid 2>&1 | Out-Null
        }
    }
    if (Test-Path $File) { Remove-Item $File -Force }
}

if (-not $KeepUE) { Stop-Recorded -File $UePidFile }
Stop-Recorded -File $PidFile
if (Test-Path $ResolvedFile) { Remove-Item $ResolvedFile -Force }
Write-Host 'Stopped.' -ForegroundColor Green

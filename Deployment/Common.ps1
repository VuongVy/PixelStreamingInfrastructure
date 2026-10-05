# Shared helpers for the Pixel Streaming stack (Matchmaker + N x Wilbur + TURN), UE5.7 infrastructure.
# Dot-source this file from the other Deployment scripts. Compatible with Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = 'Stop'

$script:DeployRoot     = $PSScriptRoot
$script:RepoRoot       = Split-Path $PSScriptRoot -Parent
# Epic's UE5.7 infrastructure (unmodified). Upgrade = replace this folder with a newer branch.
$script:InfraRoot      = Join-Path $RepoRoot 'Infra-UE5.7'
$script:WilburRoot     = Join-Path $InfraRoot 'SignallingWebServer'
$script:WilburEntry    = Join-Path $WilburRoot 'dist\index.js'
$script:WilburWww      = Join-Path $WilburRoot 'www'
$script:BindHostJs     = Join-Path $PSScriptRoot 'wilbur\bind-host.js'
# Epic removed the Matchmaker in UE5.5; this is our replacement (polls Wilbur's REST API).
$script:MatchmakerJs   = Join-Path $PSScriptRoot 'matchmaker\matchmaker.js'
# The legacy (UE5.0) SignallingWebServer is only used for its node/coturn download helpers.
$script:CirrusRoot     = Join-Path $RepoRoot 'SignallingWebServer'
$script:CirrusScripts  = Join-Path $CirrusRoot 'platform_scripts\cmd'
$script:CoturnDir      = Join-Path $CirrusScripts 'coturn'
$script:RuntimeRoot    = Join-Path $PSScriptRoot 'runtime'
$script:PidFile        = Join-Path $RuntimeRoot 'pids.json'
$script:UePidFile      = Join-Path $RuntimeRoot 'ue_pids.json'
$script:ResolvedFile   = Join-Path $RuntimeRoot 'stack.resolved.json'
$script:DefaultConfig  = Join-Path $PSScriptRoot 'stack.config.json'

# Returns the IPv4 address of the interface that owns the default route (the "LAN IP").
function Get-LanIp {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
        Select-Object -First 1
    if ($route) {
        $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    }
    return '127.0.0.1'
}

# Loads stack.config.json and resolves IPs according to Mode:
#   local  -> everything (UE, browser, TURN, Cirrus, Matchmaker) on 127.0.0.1; nothing is reachable from outside.
#   server -> ServerIp = private IP (auto-detected if "auto"), PublicIp = client-facing IP, listen on all interfaces.
function Get-StackConfig {
    param([string]$Path)
    if (-not $Path) { $Path = $script:DefaultConfig }
    if (-not (Test-Path $Path)) { throw "Config not found: $Path" }
    $cfg = Get-Content $Path -Raw | ConvertFrom-Json

    $mode = if ($cfg.Mode) { $cfg.Mode.ToString().ToLower() } else { 'local' }
    if ($mode -eq 'local') {
        $cfg.ServerIp = '127.0.0.1'
        $cfg.PublicIp = '127.0.0.1'
        $listenIp = '127.0.0.1'
    } elseif ($mode -eq 'server') {
        if (-not $cfg.ServerIp -or $cfg.ServerIp -eq 'auto') { $cfg.ServerIp = Get-LanIp }
        if (-not $cfg.PublicIp) { $cfg.PublicIp = $cfg.ServerIp }
        $listenIp = ''   # all interfaces
    } else {
        throw "Unknown Mode '$($cfg.Mode)'. Use 'local' or 'server'."
    }
    $cfg | Add-Member -NotePropertyName ModeResolved -NotePropertyValue $mode -Force
    $cfg | Add-Member -NotePropertyName ListenIp -NotePropertyValue $listenIp -Force
    return $cfg
}

# Ports used by signalling instance #$Index (1-based).
# Http = Wilbur player_port: serves the web page AND the player WebSocket on the same port.
function Get-InstancePorts {
    param($Cfg, [int]$Index)
    $s = if ($Cfg.Signalling) { $Cfg.Signalling } else { $Cfg.Cirrus }
    return [pscustomobject]@{
        Index    = $Index
        Http     = [int]$s.HttpPortBase + $Index
        Streamer = [int]$s.StreamerPortBase + $Index
        Sfu      = [int]$s.SfuPortBase + $Index
    }
}

# Builds the WebRTC peer options (as a JSON string) that the signalling server sends to both UE and the browser.
function Get-PeerConnectionOptionsJson {
    param($Cfg, [string]$TurnEngine = 'coturn')
    if (-not $Cfg.Turn.Enabled) { return '{}' }

    $ips = @($Cfg.ServerIp, $Cfg.PublicIp) | Select-Object -Unique
    $urls = @()
    foreach ($ip in $ips) {
        $urls += "stun:$($ip):$($Cfg.Turn.Port)"
        $urls += "turn:$($ip):$($Cfg.Turn.Port)?transport=udp"
        # node-turn only supports UDP; coturn also accepts TURN over TCP.
        if ($TurnEngine -eq 'coturn') { $urls += "turn:$($ip):$($Cfg.Turn.Port)?transport=tcp" }
    }
    $opts = [ordered]@{
        iceServers = @(
            [ordered]@{
                urls       = $urls
                username   = $Cfg.Turn.User
                credential = $Cfg.Turn.Password
            }
        )
    }
    # Relay-only is only meaningful in server mode. In local mode TURN sits on 127.0.0.1, which UE's libwebrtc
    # never uses (it skips the loopback interface, so UE gets no relay candidate), and a relay-only browser
    # cannot reach UE's LAN host candidates from a loopback-bound relay -> black screen. Locally, browser and
    # UE connect directly over host candidates on the same machine instead (no inbound port involved).
    if ($Cfg.Turn.ForceRelay -and $Cfg.ModeResolved -ne 'local') { $opts.iceTransportPolicy = 'relay' }
    return ($opts | ConvertTo-Json -Depth 6 -Compress)
}

# Prefers a system NodeJS, falls back to the one bundled by the repo's setup_node.bat.
function Resolve-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $bundled = Join-Path $script:CirrusScripts 'node\node.exe'
    if (-not (Test-Path $bundled)) {
        Write-Host 'NodeJS not found on PATH, downloading bundled copy...' -ForegroundColor Yellow
        & cmd.exe /c "`"$(Join-Path $script:CirrusScripts 'setup_node.bat')`"" | Out-Host
    }
    if (-not (Test-Path $bundled)) { throw 'NodeJS not found and download failed.' }
    return $bundled
}

function Resolve-NpmCmd {
    param([string]$NodeExe)
    $npm = Join-Path (Split-Path $NodeExe -Parent) 'npm.cmd'
    if (Test-Path $npm) { return $npm }
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'npm not found.'
}

function Install-NodeDeps {
    param([string]$Dir, [string]$Npm)
    if (Test-Path (Join-Path $Dir 'node_modules')) { return }
    Write-Host "Installing npm packages in $Dir ..." -ForegroundColor Cyan
    Push-Location $Dir
    try {
        & $Npm install --no-save | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "npm install failed in $Dir" }
    } finally { Pop-Location }
}

# Installs and builds the UE5.7 infrastructure (Common, Signalling, Wilbur, Frontend) once.
# Output: Infra-UE5.7/SignallingWebServer/dist/index.js and the player page in .../www.
function Install-Wilbur {
    param([string]$Npm, [switch]$Force)
    $ready = (Test-Path $script:WilburEntry) -and (Test-Path (Join-Path $script:WilburWww 'player.html'))
    if ($ready -and -not $Force) { return }
    if (-not (Test-Path $script:InfraRoot)) { throw "UE5.7 infrastructure not found at $($script:InfraRoot)." }

    Write-Host 'Building UE5.7 infrastructure (first run takes a few minutes)...' -ForegroundColor Cyan
    Push-Location $script:InfraRoot
    try {
        & $Npm install --no-audit --no-fund -w Common -w Signalling -w SignallingWebServer `
            -w Frontend/library -w Frontend/ui-library -w Frontend/implementations/typescript | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'npm install failed for Infra-UE5.7' }
        & $Npm run build:all:cjs | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Build failed for Infra-UE5.7' }
    } finally { Pop-Location }
    if (-not (Test-Path $script:WilburEntry)) { throw "Build finished but $($script:WilburEntry) is missing." }
}

# Reads Wilbur's REST status (streamer_count / player_count). Returns $null if unreachable.
function Get-WilburStatus {
    param([int]$Port)
    try {
        return Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/status" -TimeoutSec 2
    } catch { return $null }
}

# Downloads the Windows coturn build using the repo's setup_coturn.bat if missing.
# Returns the exe path, or $null if it could not be obtained (e.g. GitHub blocked by the corporate network).
function Install-Coturn {
    $exe = Join-Path $script:CoturnDir 'turnserver.exe'
    if (Test-Path $exe) { return $exe }

    # setup_coturn.bat skips the download whenever the folder exists, so clear a leftover empty folder.
    if (Test-Path $script:CoturnDir) { Remove-Item $script:CoturnDir -Recurse -Force }

    Write-Host 'coturn not found, downloading...' -ForegroundColor Yellow
    & cmd.exe /c "`"$(Join-Path $script:CirrusScripts 'setup_coturn.bat')`"" | Out-Host
    if (Test-Path $exe) { return $exe }

    if (Test-Path $script:CoturnDir) { Remove-Item $script:CoturnDir -Recurse -Force }
    Write-Host "coturn download failed. You can copy turnserver.exe (+ DLLs) manually into $($script:CoturnDir)" -ForegroundColor Yellow
    return $null
}

# Installs the npm-based fallback TURN server (Deployment/node-turn) and returns its entry script.
function Install-NodeTurn {
    param([string]$Npm)
    $dir = Join-Path $script:DeployRoot 'node-turn'
    Install-NodeDeps -Dir $dir -Npm $Npm
    return (Join-Path $dir 'turn-server.js')
}

# Starts a command in its own console window (via a generated .cmd launcher) and returns the process.
function Start-StackProcess {
    param(
        [string]$Name,
        [string]$Title,
        [string]$WorkDir,
        [string]$CommandLine
    )
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $launcher = Join-Path $WorkDir "$Name.cmd"
    @(
        '@echo off'
        "title $Title"
        "cd /d `"$WorkDir`""
        $CommandLine
        'echo.'
        "echo [$Title] exited with code %ERRORLEVEL%"
        'pause'
    ) | Set-Content -Path $launcher -Encoding ASCII

    return Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$launcher`"" -WorkingDirectory $WorkDir -PassThru
}

function Test-TcpListening {
    param([int]$Port)
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Test-TcpEstablished {
    param([int]$Port)
    return [bool](Get-NetTCPConnection -State Established -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param([string]$Path, $Object)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    # Node's JSON.parse fails on a UTF-8 BOM (which PS 5.1's Set-Content -Encoding UTF8 adds), so write BOM-less.
    $json = ConvertTo-Json -InputObject $Object -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

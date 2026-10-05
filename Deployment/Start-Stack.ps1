<#
.SYNOPSIS
    Starts the Pixel Streaming server stack (UE5.7 infrastructure): TURN + Matchmaker + N x Wilbur.

.DESCRIPTION
    Every Wilbur (signalling server) instance serves exactly one UE Instance. Instance #i uses:
        HTTP + player WS = Signalling.HttpPortBase     + i
        Streamer (UE)    = Signalling.StreamerPortBase + i
        SFU (internal)   = Signalling.SfuPortBase      + i
    Clients open http://<PublicIp>:<Matchmaker.HttpPort>/ and are redirected to a free instance.
    The Matchmaker polls each Wilbur's REST API (/api/status) on 127.0.0.1, so it needs no extra port.

    Mode "local"  : everything binds to 127.0.0.1 (UE + browser on this machine, no port reachable from outside).
    Mode "server" : binds all interfaces, for the dedicated signalling server.

.EXAMPLE
    .\Start-Stack.ps1                    # uses stack.config.json
    .\Start-Stack.ps1 -InstanceCount 1   # override number of signalling instances
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$InstanceCount = 0,
    [switch]$Wait
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$cfg = Get-StackConfig -Path $ConfigPath
if ($InstanceCount -gt 0) { $cfg.InstanceCount = $InstanceCount }
$count = [int]$cfg.InstanceCount
if ($count -lt 1) { throw 'InstanceCount must be >= 1.' }

if (Test-Path $PidFile) {
    Write-Host "Stack seems to be running already ($PidFile exists). Run .\Stop-Stack.ps1 first." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Dependencies (decides the TURN engine, which affects the port list)
# ---------------------------------------------------------------------------
$node = Resolve-NodeExe
$npm  = Resolve-NpmCmd -NodeExe $node
Write-Host "Node: $node ($(& $node -v))"
Install-Wilbur -Npm $npm

$turnEngine = 'none'
if ($cfg.Turn.Enabled) {
    $wanted = if ($cfg.Turn.Engine) { $cfg.Turn.Engine.ToString().ToLower() } else { 'auto' }
    if ($wanted -eq 'coturn' -or $wanted -eq 'auto') {
        $turnExe = Install-Coturn
        if ($turnExe) { $turnEngine = 'coturn' }
        elseif ($wanted -eq 'coturn') { throw 'Turn.Engine is "coturn" but turnserver.exe is not available.' }
    }
    if ($turnEngine -eq 'none') {
        Write-Host 'Using node-turn (UDP only) as TURN server.' -ForegroundColor Yellow
        $nodeTurnJs = Install-NodeTurn -Npm $npm
        $turnEngine = 'node-turn'
    }
}

# ---------------------------------------------------------------------------
# 2. Port conflict check
# ---------------------------------------------------------------------------
$instances = 1..$count | ForEach-Object { Get-InstancePorts -Cfg $cfg -Index $_ }
$tcpPorts = @([int]$cfg.Matchmaker.HttpPort)
$tcpPorts += $instances | ForEach-Object { $_.Http, $_.Streamer, $_.Sfu }
if ($turnEngine -eq 'coturn') { $tcpPorts += [int]$cfg.Turn.Port }

$busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $tcpPorts -contains $_.LocalPort })
if ($turnEngine -ne 'none') {
    $busy += @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq [int]$cfg.Turn.Port })
}
if ($busy.Count -gt 0) {
    Write-Host 'These ports are already in use:' -ForegroundColor Red
    $busy | Sort-Object LocalPort -Unique | ForEach-Object {
        $procName = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Write-Host ("  port {0,-6} pid {1,-6} {2}" -f $_.LocalPort, $_.OwningProcess, $procName) -ForegroundColor Red
    }
    Write-Host 'Change the port bases in stack.config.json or stop the conflicting processes.' -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
$procs = @()
# Address TURN binds to: the listen IP in local mode, the server's private IP in server mode.
$turnBindIp = if ($cfg.ListenIp) { $cfg.ListenIp } else { $cfg.ServerIp }

# ---------------------------------------------------------------------------
# 3. TURN
# ---------------------------------------------------------------------------
if ($turnEngine -eq 'coturn') {
    $turnDir = Join-Path $RuntimeRoot 'turn'
    New-Item -ItemType Directory -Force -Path $turnDir | Out-Null
    $turnArgs = @(
        "-p $($cfg.Turn.Port)"
        "-r $($cfg.Turn.Realm)"
        "-L $turnBindIp"
        "-E $turnBindIp"
        "--min-port $($cfg.Turn.MinPort)"
        "--max-port $($cfg.Turn.MaxPort)"
        '--no-cli --no-tls --no-dtls -f -a -v -n'
        "--pidfile `"$(Join-Path $turnDir 'turnserver.pid')`""
        "-u $($cfg.Turn.User):$($cfg.Turn.Password)"
    )
    # Behind NAT: advertise the public IP mapped to the private relay IP.
    if ($cfg.PublicIp -ne $turnBindIp) { $turnArgs += "-X $($cfg.PublicIp)/$turnBindIp" }

    $p = Start-StackProcess -Name 'turn' -Title "coturn ${turnBindIp}:$($cfg.Turn.Port)" -WorkDir $turnDir `
        -CommandLine "`"$turnExe`" $($turnArgs -join ' ')"
    $procs += [pscustomobject]@{ Name = 'turn'; Pid = $p.Id }
}
elseif ($turnEngine -eq 'node-turn') {
    $turnDir = Join-Path $RuntimeRoot 'turn'
    $turnConfig = Join-Path $turnDir 'turn.json'
    Write-JsonFile -Path $turnConfig -Object ([ordered]@{
        listenIp   = $turnBindIp
        externalIp = $cfg.PublicIp
        port       = [int]$cfg.Turn.Port
        minPort    = [int]$cfg.Turn.MinPort
        maxPort    = [int]$cfg.Turn.MaxPort
        realm      = $cfg.Turn.Realm
        user       = $cfg.Turn.User
        password   = $cfg.Turn.Password
        debugLevel = 'INFO'
    })
    $p = Start-StackProcess -Name 'turn' -Title "node-turn ${turnBindIp}:$($cfg.Turn.Port)" -WorkDir $turnDir `
        -CommandLine "`"$node`" `"$nodeTurnJs`" --config=`"$turnConfig`""
    $procs += [pscustomobject]@{ Name = 'turn'; Pid = $p.Id }
}

# ---------------------------------------------------------------------------
# 4. Matchmaker (polls each Wilbur's /api/status, redirects browsers to a free instance)
# ---------------------------------------------------------------------------
$mmDir = Join-Path $RuntimeRoot 'matchmaker'
$mmConfig = Join-Path $mmDir 'matchmaker.json'
Write-JsonFile -Path $mmConfig -Object ([ordered]@{
    httpPort       = [int]$cfg.Matchmaker.HttpPort
    listenIp       = $cfg.ListenIp
    publicIp       = $cfg.PublicIp
    pollIntervalMs = 1000
    reserveSeconds = 15
    logDir         = (Join-Path $mmDir 'logs')
    instances      = @($instances | ForEach-Object { [ordered]@{ index = $_.Index; httpPort = $_.Http } })
})
$p = Start-StackProcess -Name 'matchmaker' -Title "Matchmaker :$($cfg.Matchmaker.HttpPort)" -WorkDir $mmDir `
    -CommandLine "`"$node`" `"$MatchmakerJs`" --config=`"$mmConfig`""
$procs += [pscustomobject]@{ Name = 'matchmaker'; Pid = $p.Id }

# ---------------------------------------------------------------------------
# 5. Wilbur x N (UE5.7 signalling + web server)
# ---------------------------------------------------------------------------
$peerOptions = Get-PeerConnectionOptionsJson -Cfg $cfg -TurnEngine $turnEngine
foreach ($inst in $instances) {
    $name = 'wilbur_{0:D2}' -f $inst.Index
    $dir = Join-Path $RuntimeRoot $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $peerFile = Join-Path $dir 'peer_options.json'
    [System.IO.File]::WriteAllText($peerFile, $peerOptions, (New-Object System.Text.UTF8Encoding $false))

    # Per-instance config file (Wilbur reads it as defaults; nothing is passed as fragile CLI JSON).
    $wilburConfig = Join-Path $dir "$name.json"
    Write-JsonFile -Path $wilburConfig -Object ([ordered]@{
        log_folder        = (Join-Path $dir 'logs')
        log_level_console = 'info'
        log_level_file    = 'info'
        streamer_port     = "$($inst.Streamer)"
        player_port       = "$($inst.Http)"
        sfu_port          = "$($inst.Sfu)"
        max_players       = '0'          # unlimited; the Matchmaker hands each instance to one user
        serve             = $true
        http_root         = $WilburWww
        homepage          = 'player.html'
        https             = $false
        rest_api          = $true        # /api/status is what the Matchmaker polls
        peer_options_file = $peerFile
        log_config        = $true
        console_messages  = 'basic'
    })

    # PS_LISTEN_HOST + bind-host.js keep Wilbur on 127.0.0.1 in local mode (Wilbur has no listen-address option).
    # Wilbur loads ./apidoc/*.yml relative to the working directory (REST API), so run it from its own folder.
    $envLine = if ($cfg.ListenIp) { "set PS_LISTEN_HOST=$($cfg.ListenIp)& " } else { '' }
    $p = Start-StackProcess -Name $name -Title ("Wilbur #{0} http:{1} ue:{2}" -f $inst.Index, $inst.Http, $inst.Streamer) -WorkDir $dir `
        -CommandLine "cd /d `"$WilburRoot`" & $envLine`"$node`" -r `"$BindHostJs`" `"$WilburEntry`" --config_file `"$wilburConfig`""
    $procs += [pscustomobject]@{ Name = $name; Pid = $p.Id }
}

Write-JsonFile -Path $PidFile -Object @($procs)
Write-JsonFile -Path $ResolvedFile -Object ([ordered]@{
    Mode          = $cfg.ModeResolved
    ServerIp      = $cfg.ServerIp
    PublicIp      = $cfg.PublicIp
    ListenIp      = $cfg.ListenIp
    InstanceCount = $count
    TurnEngine    = $turnEngine
    Matchmaker    = $cfg.Matchmaker
    Signalling    = $(if ($cfg.Signalling) { $cfg.Signalling } else { $cfg.Cirrus })
    Turn          = $cfg.Turn
    Instances     = @($instances)
})

# ---------------------------------------------------------------------------
# 6. Verify + summary
# ---------------------------------------------------------------------------
Write-Host 'Waiting for services to listen...'
$deadline = (Get-Date).AddSeconds(20)
do {
    Start-Sleep -Milliseconds 500
    $pending = @($tcpPorts | Where-Object { -not (Test-TcpListening -Port $_) })
} while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)

Write-Host ''
if ($pending.Count -gt 0) {
    Write-Host "WARNING: not listening yet on: $($pending -join ', '). Check the console windows / runtime logs." -ForegroundColor Yellow
} else {
    Write-Host 'All services are listening.' -ForegroundColor Green
}

# In local mode, prove that nothing is bound to an externally reachable address.
if ($cfg.ModeResolved -eq 'local') {
    $exposed = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $tcpPorts -contains $_.LocalPort -and $_.LocalAddress -ne '127.0.0.1' })
    if ($turnEngine -ne 'none') {
        $exposed += @(Get-NetUDPEndpoint -LocalPort ([int]$cfg.Turn.Port) -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -ne '127.0.0.1' })
    }
    if ($exposed.Count -gt 0) {
        Write-Host 'WARNING: some ports are bound to non-loopback addresses:' -ForegroundColor Red
        $exposed | ForEach-Object { Write-Host ("  {0}:{1}" -f $_.LocalAddress, $_.LocalPort) -ForegroundColor Red }
    } else {
        Write-Host 'Local-only check: every port is bound to 127.0.0.1 (not reachable from other machines).' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '================ Pixel Streaming stack ================' -ForegroundColor Cyan
Write-Host ("Mode                    : {0}" -f $cfg.ModeResolved)
Write-Host ("Server IP (UE side)     : {0}" -f $cfg.ServerIp)
Write-Host ("Public IP (client side) : {0}" -f $cfg.PublicIp)
if ($turnEngine -ne 'none') {
    Write-Host ("TURN ({0,-9})        : {1}:{2}  relay {3}-{4}  forceRelay={5}" -f $turnEngine, $turnBindIp, $cfg.Turn.Port, $cfg.Turn.MinPort, $cfg.Turn.MaxPort, $cfg.Turn.ForceRelay)
}
Write-Host ''
Write-Host ("Client URL              : http://{0}:{1}/" -f $cfg.PublicIp, $cfg.Matchmaker.HttpPort) -ForegroundColor Green
Write-Host ''
Write-Host 'Instance  Player URL (direct)              UE launch argument'
foreach ($inst in $instances) {
    Write-Host ("#{0,-7}  {1,-32} -PixelStreamingConnectionURL=ws://{2}:{3}" -f $inst.Index, "http://$($cfg.PublicIp):$($inst.Http)/", $cfg.ServerIp, $inst.Streamer)
}
Write-Host ''
Write-Host 'Next: start UE instances with .\Start-UE.ps1 -Exe <path to game exe>' -ForegroundColor Cyan
Write-Host 'Status: .\Status-Stack.ps1    Stop: .\Stop-Stack.ps1'

if ($Wait) {
    Write-Host ''
    Write-Host 'Running in foreground (-Wait). Press Ctrl+C to stop the whole stack.' -ForegroundColor Yellow
    try {
        while ($true) { Start-Sleep -Seconds 5 }
    } finally {
        & (Join-Path $PSScriptRoot 'Stop-Stack.ps1')
    }
}

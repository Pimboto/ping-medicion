param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir
)

$ErrorActionPreference = 'SilentlyContinue'
$deadline = (Get-Date).AddMinutes(20)
$stopFile = Join-Path $SessionDir 'STOP'
$connFile = Join-Path $SessionDir 'conexiones.csv'
$latFile = Join-Path $SessionDir 'latencia-base.csv'
$adFile = Join-Path $SessionDir 'adaptadores.csv'
$logFile = Join-Path $SessionDir 'vigilar.log'

function Write-Log([string]$Message) {
    Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date).ToString('o'), $Message) -Encoding UTF8
}

function Get-PingMs([string]$Target) {
    $output = & ping.exe -n 1 -w 800 $Target 2>&1 | Out-String
    if ($output -match '(?i)(?:tiempo|time)\s*[=<]\s*(\d+)\s*ms') {
        return [int]$Matches[1]
    }
    if ($output -match '(?i)(?:tiempo|time)\s*<\s*1\s*ms') {
        return 0
    }
    return $null
}

if (-not (Test-Path $connFile)) {
    Set-Content -Path $connFile -Value 'timestamp,proto,localAddr,localPort,remoteAddr,remotePort,state,pid,process' -Encoding UTF8
}
if (-not (Test-Path $latFile)) {
    Set-Content -Path $latFile -Value 'timestamp,target,ms' -Encoding UTF8
}
if (-not (Test-Path $adFile)) {
    Set-Content -Path $adFile -Value 'timestamp,name,status,description,mac,link' -Encoding UTF8
}

$names = @{}
$adapterTick = 0
$gateway = $null
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
if ($route -and $route.NextHop -and $route.NextHop -ne '0.0.0.0') {
    $gateway = [string]$route.NextHop
}
if ($gateway) {
    Set-Content -Path (Join-Path $SessionDir 'gateway.txt') -Value $gateway -Encoding UTF8
}
$pingTargets = @('1.1.1.1')
if ($gateway) { $pingTargets = @($gateway) + $pingTargets }
Write-Log ("vigilar iniciado gateway={0}" -f $gateway)

while ((-not (Test-Path $stopFile)) -and ((Get-Date) -lt $deadline)) {
    $now = (Get-Date).ToString('o')

    $tcp = Get-NetTCPConnection -State Established
    foreach ($row in $tcp) {
        $remote = [string]$row.RemoteAddress
        if ($remote -match '^(127\.|0\.0\.0\.0|::1|fe80:|::)') { continue }
        $procId = [int]$row.OwningProcess
        if (-not $names.ContainsKey($procId)) {
            $proc = Get-Process -Id $procId
            if ($proc) { $names[$procId] = $proc.ProcessName } else { $names[$procId] = '' }
        }
        $procName = ($names[$procId] -replace ',', ' ')
        $line = '{0},TCP,{1},{2},{3},{4},{5},{6},{7}' -f $now, $row.LocalAddress, $row.LocalPort, $remote, $row.RemotePort, $row.State, $procId, $procName
        Add-Content -Path $connFile -Value $line -Encoding UTF8
    }

    $udp = Get-NetUDPEndpoint
    foreach ($row in $udp) {
        $procId = [int]$row.OwningProcess
        if ($procId -le 0) { continue }
        if (-not $names.ContainsKey($procId)) {
            $proc = Get-Process -Id $procId
            if ($proc) { $names[$procId] = $proc.ProcessName } else { $names[$procId] = '' }
        }
        $procName = ($names[$procId] -replace ',', ' ')
        if ([string]::IsNullOrWhiteSpace($procName)) { continue }
        $line = '{0},UDP,{1},{2},,,{3},{4},{5}' -f $now, $row.LocalAddress, $row.LocalPort, 'Listen', $procId, $procName
        Add-Content -Path $connFile -Value $line -Encoding UTF8
    }

    foreach ($target in $pingTargets) {
        $ms = Get-PingMs $target
        if ($null -eq $ms) {
            Add-Content -Path $latFile -Value ("{0},{1}," -f $now, $target) -Encoding UTF8
        } else {
            Add-Content -Path $latFile -Value ("{0},{1},{2}" -f $now, $target, $ms) -Encoding UTF8
        }
    }

    $adapterTick++
    if (($adapterTick % 5) -eq 1) {
        $adapters = Get-NetAdapter
        foreach ($adapter in $adapters) {
            $desc = ([string]$adapter.InterfaceDescription) -replace ',', ' '
            $name = ([string]$adapter.Name) -replace ',', ' '
            $line = '{0},{1},{2},{3},{4},{5}' -f $now, $name, $adapter.Status, $desc, $adapter.MacAddress, $adapter.LinkSpeed
            Add-Content -Path $adFile -Value $line -Encoding UTF8
        }
    }

    Start-Sleep -Seconds 2
}

Write-Log 'vigilar terminado'

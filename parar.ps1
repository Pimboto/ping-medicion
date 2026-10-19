$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$activaPath = Join-Path $root 'ACTIVA.json'

if (-not (Test-Path $activaPath)) {
    Write-Host 'No hay una grabacion activa.'
    exit 1
}

$activa = Get-Content -Path $activaPath -Raw | ConvertFrom-Json
$session = $activa.session
$modo = $activa.modo
Write-Host ("Parando sesion {0}" -f $modo)
Write-Host $session

Set-Content -Path (Join-Path $session 'STOP') -Value (Get-Date).ToString('o') -Encoding UTF8

if ($activa.vigilarPid) {
    $vig = Get-Process -Id $activa.vigilarPid -ErrorAction SilentlyContinue
    if ($vig) {
        Wait-Process -Id $activa.vigilarPid -Timeout 15 -ErrorAction SilentlyContinue
        $still = Get-Process -Id $activa.vigilarPid -ErrorAction SilentlyContinue
        if ($still) { Stop-Process -Id $activa.vigilarPid -Force -ErrorAction SilentlyContinue }
    }
}

$lista = Join-Path $session 'CAPTURA_LISTA'
$esperarHasta = (Get-Date).AddSeconds(90)
while ((-not (Test-Path $lista)) -and ((Get-Date) -lt $esperarHasta)) {
    Start-Sleep -Seconds 1
}

Get-CimInstance Win32_Process |
    Select-Object ProcessId, Name, ExecutablePath |
    Export-Csv -Path (Join-Path $session 'procesos-fin.csv') -NoTypeInformation -Encoding UTF8

$flujosPath = Join-Path $session 'flujos.json'
$python = 'C:\Python313\python.exe'
if (-not (Test-Path $python)) { $python = 'python' }
& $python (Join-Path $root 'resumir_pktmon.py') (Join-Path $session 'captura.txt') $flujosPath (Join-Path $session 'conexiones.csv') |
    Out-File -FilePath (Join-Path $session 'resumen-parser.txt') -Encoding utf8

$flows = @()
if (Test-Path $flujosPath) {
    $parsed = Get-Content -Path $flujosPath -Raw | ConvertFrom-Json
    $flows = @($parsed.flows)
}

$gateway = 'router'
$gatewayFile = Join-Path $session 'gateway.txt'
if (Test-Path $gatewayFile) { $gateway = (Get-Content $gatewayFile -Raw).Trim() }
$exclude = @('1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4')
if ($gateway -and $gateway -ne 'router') { $exclude += $gateway }
$candidatos = @($flows | Where-Object { $_ -and ($exclude -notcontains $_.ip) })
$objetivos = @($candidatos | Select-Object -First 2)

function Get-PingStats([string]$Target) {
    $outFile = Join-Path $session ("ping-{0}.txt" -f ($Target -replace '[^0-9\.]', '_'))
    $raw = & ping.exe -n 20 -w 800 $Target 2>&1 | Out-String
    Set-Content -Path $outFile -Value $raw -Encoding UTF8
    $times = @()
    foreach ($m in [regex]::Matches($raw, '(?i)(?:tiempo|time)\s*[=<]\s*(\d+)\s*ms')) {
        $times += [int]$m.Groups[1].Value
    }
    $loss = $null
    if ($raw -match '(?i)(\d+)\s*%') { $loss = [int]$Matches[1] }
    $avg = $null
    if ($times.Count -gt 0) {
        $avg = [int](($times | Measure-Object -Average).Average)
    }
    return [pscustomobject]@{ Target = $Target; Average = $avg; Loss = $loss; Samples = $times.Count; File = $outFile }
}

function Get-Trace([string]$Target) {
    $outFile = Join-Path $session ("tracert-{0}.txt" -f ($Target -replace '[^0-9\.]', '_'))
    $raw = & tracert.exe -d -h 18 -w 800 $Target 2>&1 | Out-String
    Set-Content -Path $outFile -Value $raw -Encoding UTF8
    return $outFile
}

$medidas = @()
foreach ($item in $objetivos) {
    Write-Host ("Midiendo ruta hacia {0}" -f $item.ip)
    $ping = Get-PingStats $item.ip
    $trace = Get-Trace $item.ip
    $medidas += [pscustomobject]@{ Ip = $item.ip; Ports = $item.ports; Process = $item.process; Packets = $item.packets; Ping = $ping; Trace = $trace }
}

$globalpingFile = Join-Path $session 'globalping.txt'
if ($objetivos.Count -gt 0) {
    $destino = $objetivos[0].ip
    Write-Host ("Globalping hacia {0}" -f $destino)
    $gp = & npx --yes globalping traceroute $destino from "Madrid,Frankfurt,London,New York,Sao Paulo" --limit 5 --ci 2>&1 | Out-String
    Set-Content -Path $globalpingFile -Value $gp -Encoding UTF8
} else {
    Set-Content -Path $globalpingFile -Value 'Sin un destino publico claro en la captura. Globalping no se ejecuto.' -Encoding UTF8
}

function Summarize-Latency([string]$Path, [string]$Target) {
    if (-not (Test-Path $Path)) { return 'sin datos' }
    $rows = Import-Csv $Path | Where-Object { $_.target -eq $Target -and $_.ms -ne '' }
    $lost = @(Import-Csv $Path | Where-Object { $_.target -eq $Target -and $_.ms -eq '' })
    if (-not $rows -or $rows.Count -eq 0) { return 'sin respuestas' }
    $values = @($rows | ForEach-Object { [int]$_.ms } | Sort-Object)
    $avg = [int](($values | Measure-Object -Average).Average)
    $mid = $values[[int]($values.Count / 2)]
    $total = $values.Count + $lost.Count
    $lossPct = 0
    if ($total -gt 0) { $lossPct = [int](($lost.Count * 100) / $total) }
    return ("media {0} ms, mediana {1} ms, perdida {2}% sobre {3} pruebas" -f $avg, $mid, $lossPct, $total)
}

$latPath = Join-Path $session 'latencia-base.csv'
$gw = Summarize-Latency $latPath $gateway
$cf = Summarize-Latency $latPath '1.1.1.1'

$procInicio = @{}
if (Test-Path (Join-Path $session 'procesos-inicio.csv')) {
    Import-Csv (Join-Path $session 'procesos-inicio.csv') | ForEach-Object { $procInicio[$_.Name] = $true }
}
$nuevos = @()
if (Test-Path (Join-Path $session 'procesos-fin.csv')) {
    Import-Csv (Join-Path $session 'procesos-fin.csv') | ForEach-Object {
        if (-not $procInicio.ContainsKey($_.Name)) { $nuevos += $_ }
    }
}
$nuevosUnicos = $nuevos | Sort-Object Name -Unique | Select-Object -First 25

$pktmonOk = Test-Path (Join-Path $session 'PKTMON_OK')
$pktmonErr = ''
if (Test-Path (Join-Path $session 'PKTMON_ERROR')) {
    $pktmonErr = Get-Content (Join-Path $session 'PKTMON_ERROR') -Raw
}

$informe = Join-Path $session 'INFORME.md'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Medicion de red")
[void]$sb.AppendLine("")
[void]$sb.AppendLine(("Modo: **{0} programa**." -f $(if ($modo -eq 'con') { 'con' } else { 'sin' })))
[void]$sb.AppendLine(("Inicio: {0}" -f $activa.started))
[void]$sb.AppendLine(("Fin: {0}" -f (Get-Date).ToString('o')))
[void]$sb.AppendLine(("Carpeta: ``{0}``" -f $session))
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Durante la partida")
[void]$sb.AppendLine("")
[void]$sb.AppendLine(("Ping al router de casa ({0}): {1}." -f $gateway, $gw))
[void]$sb.AppendLine(("Ping a Internet (1.1.1.1): {0}." -f $cf))
[void]$sb.AppendLine("")
if ($pktmonOk) {
    [void]$sb.AppendLine("La captura de paquetes arranco.")
} else {
    [void]$sb.AppendLine("La captura de paquetes no arranco. Hace falta aceptar el permiso de administrador.")
    if ($pktmonErr) { [void]$sb.AppendLine(("Detalle: {0}" -f $pktmonErr.Trim())) }
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Trafico que salio a Internet")
[void]$sb.AppendLine("")
if ($candidatos.Count -eq 0) {
    [void]$sb.AppendLine("No aparecio un destino publico claro. Puede que la captura no haya cubierto la partida, o que el juego aun no hubiera abierto la conexion.")
} else {
    [void]$sb.AppendLine("| Destino | Paquetes vistos | Puertos | Proceso asociado |")
    [void]$sb.AppendLine("|---|---:|---|---|")
    foreach ($item in ($candidatos | Select-Object -First 8)) {
        $ports = @($item.ports | ForEach-Object { $_.port }) -join ', '
        $procName = $item.process
        if (-not $procName) { $procName = '(no ligado a un proceso)' }
        [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $item.ip, $item.packets, $ports, $procName))
    }
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Ruta de este PC")
[void]$sb.AppendLine("")
if ($medidas.Count -eq 0) {
    [void]$sb.AppendLine("No se trazo una ruta porque no hubo destino.")
} else {
    foreach ($medida in $medidas) {
        [void]$sb.AppendLine(("### {0}" -f $medida.Ip))
        [void]$sb.AppendLine("")
        $avgText = $medida.Ping.Average
        if ($null -eq $avgText) { $avgText = 'sin respuesta' } else { $avgText = "$avgText ms de media" }
        [void]$sb.AppendLine(("Ping directo: {0}. Perdida: {1}%." -f $avgText, $medida.Ping.Loss))
        [void]$sb.AppendLine(("Traza guardada en ``{0}``." -f $medida.Trace))
        [void]$sb.AppendLine("")
        if (Test-Path $medida.Trace) {
            $traceText = Get-Content -Path $medida.Trace -Raw
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine($traceText.Trim())
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine("")
        }
    }
}
[void]$sb.AppendLine("## Otras ciudades")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Globalping miro la ruta desde Madrid, Frankfurt, Londres, Nueva York y Sao Paulo hacia el destino principal. El texto completo esta en ``globalping.txt``.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Programas que aparecieron durante la prueba")
[void]$sb.AppendLine("")
if ($nuevosUnicos) {
    foreach ($proc in $nuevosUnicos) {
        $pathText = $proc.ExecutablePath
        if (-not $pathText) { $pathText = '(sin ruta visible)' }
        [void]$sb.AppendLine(("- {0} - {1}" -f $proc.Name, $pathText))
    }
} else {
    [void]$sb.AppendLine("No vi procesos nuevos con ruta visible. El juego puede haber estado abierto desde antes.")
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## REA")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("REA no captura en vivo. Resume una captura ya hecha y pide Node.js 22.19 o mas nuevo, mas Wireshark (tshark y capinfos). Si esta sesion dejo ``captura.pcapng``, ese es el archivo para REA. La ruta y el ping de esta prueba salen de pktmon, tracert y Globalping.")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Que se puede concluir")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Esta es una sola pasada. El limite por distancia se confirma cuando la pasada con programa y la pasada sin programa tengan la misma lista de saltos y el mismo tiempo, y cuando Globalping no encuentre una ciudad cuya ruta hasta el servidor sea claramente mas corta que la de casa.")

Set-Content -Path $informe -Value $sb.ToString() -Encoding UTF8
Remove-Item -Path $activaPath -Force
Write-Host ''
Write-Host 'LISTO'
Write-Host $informe

param(
    [ValidateSet('con', 'sin')]
    [string]$Modo = 'con'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$activaPath = Join-Path $root 'ACTIVA.json'

if (Test-Path $activaPath) {
    Write-Host 'Ya hay una grabacion activa. Para con parar.ps1 antes de iniciar otra.'
    Get-Content -Path $activaPath
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$session = Join-Path $root ("sesiones\{0}-{1}" -f $Modo, $stamp)
New-Item -ItemType Directory -Force -Path $session | Out-Null

Get-NetIPConfiguration | Out-File -FilePath (Join-Path $session 'red-inicio.txt') -Encoding utf8
Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
    Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric, InterfaceMetric |
    Format-Table -AutoSize |
    Out-String |
    Out-File -FilePath (Join-Path $session 'ruta-inicio.txt') -Encoding utf8
Get-NetAdapter |
    Select-Object Name, Status, MacAddress, LinkSpeed, InterfaceDescription |
    Format-List |
    Out-String |
    Out-File -FilePath (Join-Path $session 'adaptadores-inicio.txt') -Encoding utf8
Get-CimInstance Win32_Process |
    Select-Object ProcessId, Name, ExecutablePath |
    Export-Csv -Path (Join-Path $session 'procesos-inicio.csv') -NoTypeInformation -Encoding UTF8

$vigilar = Join-Path $root 'vigilar.ps1'
$vigilarProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $vigilar, '-SessionDir', $session
)

$estado = [ordered]@{
    session    = $session
    modo       = $Modo
    started    = (Get-Date).ToString('o')
    vigilarPid = $vigilarProc.Id
}
$estado | ConvertTo-Json | Set-Content -Path $activaPath -Encoding UTF8

Write-Host ''
Write-Host ("SESION {0}" -f $Modo)
Write-Host $session
Write-Host ''
Write-Host 'Si aparece el permiso de administrador, pulsa Si.'
Write-Host 'Cuando la ventana diga GRABANDO, abre el juego y juega unos 3 minutos.'
Write-Host 'No cierres esa ventana. Avisa en el chat con: ya'

$admin = Join-Path $root 'grabar-admin.ps1'
try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $admin, '-SessionDir', $session
    )
    Write-Host 'Ventana de captura solicitada.'
}
catch {
    $msg = $_.Exception.Message
    Set-Content -Path (Join-Path $session 'PKTMON_ERROR') -Value $msg -Encoding UTF8
    Write-Host ("No se pudo pedir permiso de administrador: {0}" -f $msg)
}

$deadline = (Get-Date).AddMinutes(20)
$stopFile = Join-Path $session 'STOP'
while ((-not (Test-Path $stopFile)) -and ((Get-Date) -lt $deadline)) {
    if ($vigilarProc.HasExited) {
        $vigilarProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $vigilar, '-SessionDir', $session
        )
        $estado.vigilarPid = $vigilarProc.Id
        $estado | ConvertTo-Json | Set-Content -Path $activaPath -Encoding UTF8
    }
    Start-Sleep -Seconds 2
}
Write-Host 'Sesion de grabacion cerrada.'

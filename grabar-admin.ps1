param(
    [Parameter(Mandatory = $true)]
    [string]$SessionDir
)

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = 'Grabacion de red - no cierres esta ventana' } catch {}
Set-Content -Path (Join-Path $SessionDir 'admin-arranque.txt') -Value (Get-Date).ToString('o') -Encoding UTF8
$logFile = Join-Path $SessionDir 'admin.log'
$etl = Join-Path $SessionDir 'captura.etl'
$txt = Join-Path $SessionDir 'captura.txt'
$stopFile = Join-Path $SessionDir 'STOP'

function Write-Log([string]$Message) {
    Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date).ToString('o'), $Message) -Encoding UTF8
}

Write-Host ''
Write-Host 'GRABANDO la red de este PC.'
Write-Host 'No cierres esta ventana.'
Write-Host 'Vuelve al chat, abre el juego con tu programa y juega unos 3 minutos.'
Write-Host 'La grabacion se apaga sola a los 20 minutos, o cuando se pare desde el chat.'
Write-Host ''

try {
    pktmon filter remove 2>&1 | Out-Null
    pktmon list --json 2>&1 | Out-File -FilePath (Join-Path $SessionDir 'componentes.json') -Encoding utf8
    pktmon start --capture --comp nics --pkt-size 96 --file-name $etl --file-size 256 --log-mode circular
    if ($LASTEXITCODE -ne 0) {
        throw "pktmon start devolvio $LASTEXITCODE"
    }
    Set-Content -Path (Join-Path $SessionDir 'PKTMON_OK') -Value (Get-Date).ToString('o') -Encoding UTF8
    Write-Log 'pktmon iniciado'
    Write-Host 'Captura de paquetes activa.'

    $deadline = (Get-Date).AddMinutes(20)
    while ((-not (Test-Path $stopFile)) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Seconds 1
    }
    Write-Log 'parada pedida o tiempo cumplido'
}
catch {
    Write-Log $_.Exception.Message
    Set-Content -Path (Join-Path $SessionDir 'PKTMON_ERROR') -Value $_.Exception.Message -Encoding UTF8
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
}
finally {
    pktmon stop 2>&1 | Out-Null
    Write-Log 'pktmon stop'
    if (Test-Path $etl) {
        $pcap = Join-Path $SessionDir 'captura.pcapng'
        pktmon etl2pcap $etl --out $pcap 2>&1 | Out-File -FilePath (Join-Path $SessionDir 'etl2pcap.log') -Encoding utf8
        Write-Log ("etl2pcap exit {0}" -f $LASTEXITCODE)
        pktmon etl2txt $etl --out $txt --brief --timestamp 2>&1 | Out-File -FilePath (Join-Path $SessionDir 'etl2txt.log') -Encoding utf8
        Write-Log ("etl2txt exit {0}" -f $LASTEXITCODE)
    }
    Set-Content -Path (Join-Path $SessionDir 'CAPTURA_LISTA') -Value (Get-Date).ToString('o') -Encoding UTF8
    Write-Host 'Captura cerrada. Ya puedes cerrar esta ventana.'
}

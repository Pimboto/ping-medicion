# Grabador de ruta

Mide, en tu propio Windows, a quién le habla el PC mientras juegas y por qué routers sale ese tráfico. Sirve para comparar el mismo juego **con** un programa de ping y **sin** él.

No sube la captura a ningún sitio. Los archivos quedan en `sesiones\` de esta carpeta.

## Qué necesitas

- Windows 10 o 11
- Python 3 en el PATH (`python --version`)
- Permiso de administrador la primera vez (Windows lo pide solo)
- Node.js 22.19 o más nuevo y Wireshark, solo si después quieres pasar el `.pcapng` por [REA](https://github.com/morluto/rea)

## Cómo grabar

Abre PowerShell en esta carpeta.

Con el programa de ping encendido:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\iniciar.ps1 -Modo con
```

Pulsa Sí en el permiso de administrador. Cuando la ventana diga GRABANDO, juega unos 3 minutos. No la cierres. Luego:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\parar.ps1
```

Sin el programa, repite con `-Modo sin` y otra vez `parar.ps1`.

Cada pasada deja:

- `sesiones\<modo-fecha>\INFORME.md` con destinos, ping y tracert
- `sesiones\<modo-fecha>\captura.pcapng` para REA
- `sesiones\<modo-fecha>\globalping.txt` con la ruta vista desde otras ciudades

La grabación se apaga sola a los 20 minutos.

## Pasar el pcapng por REA

REA no graba. Solo lee un archivo ya guardado. Hace falta Wireshark instalado y Node 22.19 o más nuevo.

```powershell
$env:REA_TSHARK_COMMAND = "C:\Program Files\Wireshark\tshark.exe"
$env:REA_CAPINFOS_COMMAND = "C:\Program Files\Wireshark\capinfos.exe"
npx -y rea-agents@latest inspect-pcap-capture "C:\ruta\al\archivo.pcapng" --json
```

Si ese comando no existe, `npx -y rea-agents@latest --help` muestra el nombre actual.

## Qué mirar en el resultado

El programa solo acorta el ping si, con él encendido, cambia la lista de saltos o baja el tiempo de forma clara hacia el mismo servidor. Si la ruta y el tiempo quedan iguales, el límite es la distancia y el operador.

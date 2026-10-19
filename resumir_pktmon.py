"""Resume a pktmon brief/text export into IP and port counts.

Reads packet headers only. Does not print payloads.
"""

import csv
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

IPV4_FLOW = re.compile(
    r"(?P<src>(?:\d{1,3}\.){3}\d{1,3})(?::(?P<sport>\d{1,5}))?\s*(?:>|->)\s*"
    r"(?P<dst>(?:\d{1,3}\.){3}\d{1,3})(?::(?P<dport>\d{1,5}))?"
)


def is_public(ip: str) -> bool:
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        octets = [int(part) for part in parts]
    except ValueError:
        return False
    if any(part < 0 or part > 255 for part in octets):
        return False
    a, b = octets[0], octets[1]
    if a in (0, 10, 127):
        return False
    if a == 169 and b == 254:
        return False
    if a == 172 and 16 <= b <= 31:
        return False
    if a == 192 and b == 168:
        return False
    if a == 100 and 64 <= b <= 127:
        return False
    if a >= 224:
        return False
    return True


def noise_port(port: int) -> bool:
    return port in {53, 67, 68, 123, 137, 138, 139, 190, 500, 1900, 5353, 5355, 4500}


def load_processes(csv_path: Path) -> dict:
    by_local_port = defaultdict(list)
    by_remote = defaultdict(list)
    if not csv_path.exists():
        return {"local": by_local_port, "remote": by_remote}
    with csv_path.open(newline="", encoding="utf-8", errors="replace") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            process = (row.get("process") or "").strip()
            if not process:
                continue
            local_port = (row.get("localPort") or "").strip()
            remote = (row.get("remoteAddr") or "").strip()
            if local_port:
                by_local_port[local_port].append(process)
            if remote:
                by_remote[remote].append(process)
    return {"local": by_local_port, "remote": by_remote}


def most_common(names: list) -> str:
    if not names:
        return ""
    counts = defaultdict(int)
    for name in names:
        counts[name] += 1
    return sorted(counts.items(), key=lambda item: (-item[1], item[0]))[0][0]


def main() -> int:
    if len(sys.argv) < 3:
        print("uso: resumir_pktmon.py CAPTURA.txt SALIDA.json [conexiones.csv]", file=sys.stderr)
        return 1
    capture_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    process_path = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    processes = load_processes(process_path) if process_path else {"local": {}, "remote": {}}

    flows = defaultdict(lambda: {"packets": 0, "sports": defaultdict(int), "dports": defaultdict(int)})
    sample_lines = []
    if not capture_path.exists():
        out_path.write_text(json.dumps({"flows": [], "sample": [], "error": "sin captura"}, indent=2), encoding="utf-8")
        return 2

    with capture_path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if len(sample_lines) < 40 and line.strip():
                sample_lines.append(line.strip()[:240])
            for match in IPV4_FLOW.finditer(line):
                src = match.group("src")
                dst = match.group("dst")
                sport = int(match.group("sport") or 0)
                dport = int(match.group("dport") or 0)
                if not is_public(dst):
                    continue
                if dport and noise_port(dport):
                    continue
                bucket = flows[dst]
                bucket["packets"] += 1
                if sport:
                    bucket["sports"][sport] += 1
                if dport:
                    bucket["dports"][dport] += 1

    ranked = []
    for ip, bucket in flows.items():
        ports = sorted(bucket["dports"].items(), key=lambda item: -item[1])[:6]
        local_ports = sorted(bucket["sports"].items(), key=lambda item: -item[1])[:6]
        process_names = list(processes["remote"].get(ip, []))
        for local_port, _count in local_ports:
            process_names.extend(processes["local"].get(str(local_port), []))
        ranked.append(
            {
                "ip": ip,
                "packets": bucket["packets"],
                "ports": [{"port": port, "packets": count} for port, count in ports],
                "localPorts": [{"port": port, "packets": count} for port, count in local_ports],
                "process": most_common(process_names),
            }
        )
    ranked.sort(key=lambda item: -item["packets"])
    payload = {"flows": ranked[:30], "sample": sample_lines[:15], "totalPublicDestinations": len(ranked)}
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(json.dumps({"destinations": len(ranked), "top": [item["ip"] for item in ranked[:5]]}))
    return 0 if ranked else 2


if __name__ == "__main__":
    sys.exit(main())

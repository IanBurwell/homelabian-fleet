#!/usr/bin/env python3
"""Lightweight HTTP GET JSON status server for the USB backup drive and SMART health."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import shutil
import subprocess
from urllib.parse import parse_qs, urlparse

PORT = {{ borg_backup_server_status_port }}
CACHE_FILE = "{{ borg_backup_server_home }}/smart_cache.json"
LABEL = "{{ borg_backup_server_label }}"
DEVICE = "{{ borg_backup_server_device }}"
MOUNTPOINT = "{{ borg_backup_mountpoint }}"

# SMART attribute IDs of interest to surface as notes when non-zero
WATCHED_ATTRS = {
    5: "Reallocated_Sector_Ct",
    187: "Reported_Uncorrect",
    188: "Command_Timeout",
    189: "High_Fly_Writes",
    197: "Current_Pending_Sector",
    198: "Offline_Uncorrectable",
    199: "UDMA_CRC_Error_Count",
}


def load_cache():
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except Exception:
            pass
    return {}


def save_cache(cache):
    try:
        with open(CACHE_FILE, "w", encoding="utf-8") as fh:
            json.dump(cache, fh)
    except Exception:
        pass


def get_power_state():
    proc = subprocess.run(["hdparm", "-C", DEVICE], capture_output=True, text=True, check=False)
    if "standby" in proc.stdout.lower():
        return "standby"
    return "active"


def query_smart(cached_entry, force_refresh=False):
    has_full_cache = bool(cached_entry and "total_gb" in cached_entry)
    power_state = get_power_state()

    # Do not issue ATA SMART READ commands on routine status polls, as they reset
    # the drive's hardware spindown timer. Only query SMART when explicitly forced
    # (e.g. post-backup ?refresh=1) or when the cache has never been populated.
    if has_full_cache and (power_state == "standby" or not force_refresh):
        result = dict(cached_entry)
        result["power_state"] = power_state
        return result, False

    cmd = ["smartctl", "-j", "-d", "sat", "-a"]
    if has_full_cache:
        cmd.extend(["-n", "standby"])
    cmd.append(DEVICE)

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    try:
        data = json.loads(proc.stdout)
    except Exception:
        data = {}

    messages = " ".join(m.get("string", "") for m in data.get("smartctl", {}).get("messages", []))
    if "STANDBY" in messages.upper() or (proc.returncode == 2 and has_full_cache):
        result = dict(cached_entry)
        result["power_state"] = "standby"
        return result, False

    attrs = {}
    notes = []
    for row in data.get("ata_smart_attributes", {}).get("table", []):
        attr_id = row.get("id")
        raw_val = row.get("raw", {}).get("value", 0)
        attrs[attr_id] = raw_val
        if attr_id in WATCHED_ATTRS and raw_val > 0:
            notes.append(f"{WATCHED_ATTRS[attr_id]}={raw_val}")

    smart_passed = data.get("smart_status", {}).get("passed", True)
    if not smart_passed:
        notes.insert(0, "SMART_HEALTH_FAILED")

    try:
        usage = shutil.disk_usage(MOUNTPOINT)
        disk_stats = {
            "total_gb": round(usage.total / (1024 ** 3), 2),
            "used_gb": round(usage.used / (1024 ** 3), 2),
            "free_gb": round(usage.free / (1024 ** 3), 2),
            "used_percent": round((usage.used / usage.total) * 100, 1) if usage.total else 0.0,
        }
    except OSError:
        disk_stats = {"total_gb": 0, "used_gb": 0, "free_gb": 0, "used_percent": 0.0}

    entry = {
        "power_state": "active",
        "smart_healthy": bool(smart_passed),
        "temperature_c": data.get("temperature", {}).get("current"),
        "high_fly_writes": attrs.get(189, 0),
        "reallocated_sectors": attrs.get(5, 0),
        "pending_sectors": attrs.get(197, 0),
        "uncorrectable_sectors": attrs.get(198, 0),
        "smart_notes": notes,
        **disk_stats,
    }
    return entry, True


def collect_status(force_refresh=False):
    cached = load_cache()
    smart_info, updated = query_smart(cached, force_refresh=force_refresh)
    if updated:
        save_cache(smart_info)

    disk_stats = {
        "total_gb": smart_info.get("total_gb", 0),
        "used_gb": smart_info.get("used_gb", 0),
        "free_gb": smart_info.get("free_gb", 0),
        "used_percent": smart_info.get("used_percent", 0.0),
    }

    overall = "healthy"
    if not smart_info["smart_healthy"]:
        overall = "critical"
    elif smart_info["smart_notes"]:
        overall = "warning"

    return {
        "status": overall,
        "label": LABEL,
        "mountpoint": MOUNTPOINT,
        **disk_stats,
        **smart_info,
    }


class StatusHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        force_refresh = query.get("refresh", ["0"])[0] in ("1", "true", "yes")
        body = json.dumps(collect_status(force_refresh=force_refresh), indent=2).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), StatusHandler).serve_forever()

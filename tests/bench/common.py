"""Shared utilities for the gitd benchmark suite (Python 3.10+ stdlib only)."""

from __future__ import annotations

import http.client
import json
import math
import os
import platform
import shutil
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from typing import Any

GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
}

GIT_ID = [
    "-c",
    "user.name=bench",
    "-c",
    "user.email=bench@example.com",
    "-c",
    "init.defaultBranch=main",
]

_RETRYABLE_HTTP_ERRORS = (
    http.client.RemoteDisconnected,
    http.client.BadStatusLine,
    BrokenPipeError,
    ConnectionResetError,
)


class KeepAliveClient:
    """Thread-safe HTTP/1.1 client with per-thread persistent connections."""

    def __init__(
        self,
        base_url: str,
        token: str | None = None,
        *,
        timeout: float = 60.0,
        no_keepalive: bool = False,
    ) -> None:
        parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise ValueError(f"unsupported base URL: {base_url}")
        self.base_url = base_url.rstrip("/")
        self.scheme = parsed.scheme
        self.host = parsed.hostname
        self.port = parsed.port or (443 if parsed.scheme == "https" else 80)
        self.base_path = parsed.path.rstrip("/")
        self.default_token = token
        self.timeout = timeout
        self.no_keepalive = no_keepalive
        self._local = threading.local()
        self._lock = threading.Lock()
        self._conns: set[http.client.HTTPConnection] = set()

    def _new_conn(self) -> http.client.HTTPConnection:
        cls = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        conn = cls(self.host, self.port, timeout=self.timeout)
        with self._lock:
            self._conns.add(conn)
        return conn

    def _drop_conn(self, conn: http.client.HTTPConnection | None) -> None:
        if conn is None:
            return
        try:
            conn.close()
        except Exception:
            pass
        with self._lock:
            self._conns.discard(conn)
        if getattr(self._local, "conn", None) is conn:
            self._local.conn = None

    def close(self) -> None:
        """Close this thread's cached connection, if any."""
        conn = getattr(self._local, "conn", None)
        self._drop_conn(conn)

    def close_all(self) -> None:
        """Close every connection opened by this client across all threads."""
        with self._lock:
            conns = list(self._conns)
            self._conns.clear()
        for conn in conns:
            try:
                conn.close()
            except Exception:
                pass
        self._local = threading.local()

    def request_raw(
        self,
        method: str,
        path: str,
        *,
        body: Any = None,
        headers: dict[str, str] | None = None,
        token: str | None = None,
    ) -> tuple[int, dict[str, str], bytes, float]:
        full_path = f"{self.base_path}{path}" if path.startswith("/") else f"{self.base_path}/{path}"
        req_headers: dict[str, str] = {}
        if headers:
            req_headers.update(headers)
        auth_token = token if token is not None else self.default_token
        if auth_token and "Authorization" not in req_headers and "authorization" not in req_headers:
            req_headers["Authorization"] = f"Bearer {auth_token}"

        payload: bytes | None = None
        if body is not None:
            if isinstance(body, (bytes, bytearray)):
                payload = bytes(body)
            else:
                payload = json.dumps(body).encode("utf-8")
                req_headers.setdefault("Content-Type", "application/json")
        if self.no_keepalive:
            req_headers["Connection"] = "close"

        for attempt in range(2):
            conn: http.client.HTTPConnection | None = getattr(self._local, "conn", None)
            was_reused = conn is not None
            if conn is None:
                conn = self._new_conn()
                self._local.conn = conn
            start = time.perf_counter()
            try:
                conn.request(method, full_path, body=payload, headers=req_headers)
                resp = conn.getresponse()
                raw = resp.read()
                elapsed_ms = (time.perf_counter() - start) * 1000.0
                resp_headers = {k.lower(): v for k, v in resp.getheaders()}
                if self.no_keepalive or resp.will_close or resp_headers.get("connection", "").lower() == "close":
                    self._drop_conn(conn)
                return resp.status, resp_headers, raw, elapsed_ms
            except _RETRYABLE_HTTP_ERRORS:
                self._drop_conn(conn)
                if was_reused and attempt == 0:
                    continue
                raise
            except Exception:
                self._drop_conn(conn)
                raise
        raise RuntimeError("unreachable")

    def request_json(
        self,
        method: str,
        path: str,
        *,
        body: Any = None,
        headers: dict[str, str] | None = None,
        token: str | None = None,
    ) -> tuple[int, Any, float]:
        status, _, raw, elapsed_ms = self.request_raw(
            method, path, body=body, headers=headers, token=token
        )
        if not raw.strip():
            return status, {}, elapsed_ms
        try:
            return status, json.loads(raw.decode("utf-8")), elapsed_ms
        except Exception:
            return status, {"raw": raw.decode("utf-8", errors="replace")}, elapsed_ms


def summarize(samples_ms: list[float]) -> dict[str, float | int]:
    """Return count, min, p50, p95, p99, max, mean for latency samples."""
    n = len(samples_ms)
    if n == 0:
        return {"n": 0, "min": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "mean": 0.0}
    s = sorted(samples_ms)

    def pct(p: float) -> float:
        idx = min(n - 1, max(0, math.ceil(p * n) - 1))
        return s[idx]

    return {
        "n": n,
        "min": round(s[0], 2),
        "p50": round(statistics.median(s), 2),
        "p95": round(pct(0.95), 2),
        "p99": round(pct(0.99), 2),
        "max": round(s[-1], 2),
        "mean": round(statistics.fmean(s), 2),
    }


def format_ms(val: float) -> str:
    if val >= 1000.0:
        return f"{val / 1000.0:.2f} s"
    return f"{val:.1f} ms"


def format_bytes(n: int | float) -> str:
    val = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if val < 1024.0 or unit == "GiB":
            if unit == "B":
                return f"{int(val)} B"
            return f"{val:.1f} {unit}"
        val /= 1024.0
    return f"{val:.1f} GiB"


def markdown_table(headers: list[str], rows: list[list[Any]]) -> str:
    str_rows = [[str(cell) for cell in row] for row in rows]
    lines = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join("---" for _ in headers) + "|",
    ]
    for row in str_rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def dir_size_bytes(path: str | os.PathLike[str]) -> int:
    total = 0
    for root, _, files in os.walk(path, followlinks=False):
        for name in files:
            fp = os.path.join(root, name)
            try:
                if not os.path.islink(fp):
                    total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def pick_free_port(host: str = "127.0.0.1") -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((host, 0))
        return int(s.getsockname()[1])


class RssMonitor:
    """Polls resident memory (MiB) of a running process."""

    def __init__(self, pid: int, interval_s: float = 0.2) -> None:
        self.pid = pid
        self.interval_s = interval_s
        self.idle_mib: float | None = None
        self.peak_mib: float = 0.0
        self.samples_mib: list[float] = []
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None

    @staticmethod
    def read_pid_rss_mib(pid: int) -> tuple[float | None, float | None]:
        proc_status = f"/proc/{pid}/status"
        if os.path.exists(proc_status):
            rss_kb: int | None = None
            hwm_kb: int | None = None
            try:
                with open(proc_status, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        if line.startswith("VmRSS:"):
                            rss_kb = int(line.split()[1])
                        elif line.startswith("VmHWM:"):
                            hwm_kb = int(line.split()[1])
            except OSError:
                return None, None
            return (
                rss_kb / 1024.0 if rss_kb is not None else None,
                hwm_kb / 1024.0 if hwm_kb is not None else None,
            )
        try:
            out = subprocess.check_output(
                ["ps", "-o", "rss=", "-p", str(pid)],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=2.0,
            ).strip()
            if out:
                rss_mib = int(out.splitlines()[0].strip()) / 1024.0
                return rss_mib, rss_mib
        except Exception:
            pass
        return None, None

    def sample_now(self) -> float | None:
        rss_mib, hwm_mib = self.read_pid_rss_mib(self.pid)
        if rss_mib is None:
            return None
        with self._lock:
            if self.idle_mib is None:
                self.idle_mib = round(rss_mib, 2)
            self.samples_mib.append(rss_mib)
            cand = max(rss_mib, hwm_mib or rss_mib)
            if cand > self.peak_mib:
                self.peak_mib = round(cand, 2)
        return rss_mib

    def start(self) -> None:
        self.sample_now()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.wait(self.interval_s):
            self.sample_now()

    def stop(self) -> dict[str, float | int | None]:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        self.sample_now()
        with self._lock:
            return {
                "idle_mib": self.idle_mib,
                "peak_mib": self.peak_mib if self.samples_mib else None,
                "samples": len(self.samples_mib),
            }


def _cmd_out(argv: list[str]) -> str:
    try:
        return subprocess.check_output(argv, stderr=subprocess.DEVNULL, text=True, timeout=5.0).strip()
    except Exception:
        return ""


def collect_sysinfo(gitd_bin: str | None = None, data_dir: str | None = None) -> dict[str, Any]:
    sys_name = platform.system()
    cpu_model = ""
    ram_gib: float | None = None

    if sys_name == "Linux":
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith(("model name", "Model", "Hardware")):
                        cpu_model = line.split(":", 1)[1].strip()
                        if cpu_model:
                            break
        except OSError:
            pass
        try:
            with open("/proc/meminfo", "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kb = int(line.split()[1])
                        ram_gib = round(kb / (1024.0 * 1024.0), 2)
                        break
        except OSError:
            pass
    elif sys_name == "Darwin":
        cpu_model = _cmd_out(["sysctl", "-n", "machdep.cpu.brand_string"]) or platform.processor()
        mem_s = _cmd_out(["sysctl", "-n", "hw.memsize"])
        if mem_s.isdigit():
            ram_gib = round(int(mem_s) / (1024.0**3), 2)

    if not cpu_model:
        cpu_model = platform.processor() or platform.machine()

    target_path = data_dir if data_dir and os.path.exists(data_dir) else "."
    disk_fs = ""
    if sys_name == "Linux":
        out = _cmd_out(["df", "-PT", target_path])
        lines = out.splitlines()
        if len(lines) >= 2:
            disk_fs = " ".join(lines[1].split()[:2])
    else:
        out = _cmd_out(["df", "-h", target_path])
        lines = out.splitlines()
        if len(lines) >= 2:
            parts = lines[1].split()
            disk_fs = parts[0] if parts else ""

    gitd_bin_bytes: int | None = None
    if gitd_bin and os.path.exists(gitd_bin):
        gitd_bin_bytes = os.path.getsize(gitd_bin)

    zig_path = shutil.which("zig")
    zig_ver = _cmd_out([zig_path, "version"]) if zig_path else ""

    return {
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "os": sys_name,
        "platform": platform.platform(),
        "arch": platform.machine(),
        "cpu_model": cpu_model,
        "cpu_count": os.cpu_count(),
        "ram_gib": ram_gib,
        "git_version": _cmd_out(["git", "--version"]),
        "zig_version": zig_ver or None,
        "python_version": sys.version.split()[0],
        "disk_fs": disk_fs or None,
        "gitd_bin_bytes": gitd_bin_bytes,
    }

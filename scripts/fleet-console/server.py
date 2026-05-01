#!/usr/bin/env python3
"""
MayaOS Fleet Console -- local HTTP server.

Serves a single-page UI that:
  * launches STF in a separate browser window (cookie partitioning makes
    iframing it on a different origin a non-starter; see commit history)
  * launches per-device STF screen popups so each device gets its own
    first-party-cookied window with the live minicap stream
  * polls a rolling tail of the x86_64 MayaOS build log on the builder pod
  * polls a rolling tail of /var/log/stf/stf.log on the fleet pod
  * serves /api/devices with per-device telemetry (serial, model, ready,
    using, display dimensions) pulled live from STF's RethinkDB

Originally we tried to add a /stream/<serial> endpoint that piped a true
h.264 video stream from each emulator via Android's `screenrecord -` ->
ffmpeg fragmented-MP4 wrap, but Android 16's screenrecord (v1.4) dropped
the `--output-format` flag entirely -- it now only writes complete .mp4
files to disk after recording stops, which is useless for live streaming.
The right replacement is the scrcpy-server JAR (Genymobile/scrcpy v3.x);
it pushes a small Java app onto the device that opens a UNIX socket and
streams raw h.264 NAL units, which we then forward via `adb forward`
and remux to fragmented MP4 locally. That's a v2 follow-up; until it
lands, devices are operated through STF's minicap pump (JPEG-per-frame).

Architecture: per-log daemon thread runs `ssh ... tail -F <path>` and
appends each line into an in-memory ring buffer; the browser polls
GET /log/<name>?since=<seq> every second to fetch new lines. We pay the
SSH-stream cost once (one persistent connection per pod) and serve every
viewer + every refresh from the local buffer -- no fan-out cost on the
remote pod even if multiple browser tabs are open.

All addresses + creds come from env vars (start.sh sets them); nothing
operator-specific is hardcoded so the script is committable and reusable
across environments.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT = int(os.environ.get("FLEET_CONSOLE_PORT", "8080"))
HERE = os.path.dirname(os.path.abspath(__file__))
SSH_KEY = os.path.expanduser(
    os.environ.get("FLEET_SSH_KEY", "~/.ssh/id_ed25519_runpod")
)
BUILDER_HOST = os.environ.get("BUILDER_HOST", "root@38.147.83.25")
BUILDER_PORT = int(os.environ.get("BUILDER_PORT", "47023"))
BUILD_LOG = os.environ.get(
    "BUILD_LOG", "/workspace/aosp-logs/mayaos-x86-build.log"
)
FLEET_HOST = os.environ.get("FLEET_HOST", "root@38.147.83.24")
FLEET_PORT = int(os.environ.get("FLEET_PORT", "37662"))
STF_LOG = os.environ.get("STF_LOG", "/var/log/stf/stf.log")

BUFFER_LINES = int(os.environ.get("BUFFER_LINES", "1200"))


class Stream:
    __slots__ = ("name", "host", "port", "path", "lines", "seq", "lock")

    def __init__(self, name: str, host: str, port: int, path: str) -> None:
        self.name = name
        self.host = host
        self.port = port
        self.path = path
        self.lines: list[tuple[int, str]] = []
        self.seq = 0
        self.lock = threading.Lock()

    def push(self, line: str) -> None:
        with self.lock:
            self.lines.append((self.seq, line))
            self.seq += 1
            if len(self.lines) > BUFFER_LINES:
                # Trim from the head; keep the tail. List slicing returns a
                # new list each time but BUFFER_LINES is small (~1200) so the
                # O(n) cost is dwarfed by the SSH-tail latency.
                self.lines[:] = self.lines[-BUFFER_LINES:]

    def slice_since(self, since: int) -> tuple[list[tuple[int, str]], int]:
        with self.lock:
            return [(s, l) for (s, l) in self.lines if s >= since], self.seq


STREAMS: dict[str, Stream] = {
    "build": Stream("build", BUILDER_HOST, BUILDER_PORT, BUILD_LOG),
    "stf": Stream("stf", FLEET_HOST, FLEET_PORT, STF_LOG),
}


# Snapshot of device state, refreshed every DEVICE_POLL_INTERVAL seconds by
# devices_loop(). Served by GET /api/devices. We poll on a background thread
# so HTTP requests stay sub-millisecond instead of paying the SSH RTT each
# time the launcher panel re-renders.
DEVICE_POLL_INTERVAL = int(os.environ.get("DEVICE_POLL_INTERVAL", "10"))
device_state: dict[str, object] = {"total": None, "ready": None, "using": None, "updated_at": 0}
device_lock = threading.Lock()


def devices_loop() -> None:
    """Poll the fleet pod's rethinkdb for device counts.

    Uses a tiny inline node.js snippet over SSH because the rethinkdb client
    is already installed inside the STF node_modules tree on the pod -- no
    need to add a Python rethinkdb dependency on the operator's mac.
    """
    # Pull both aggregate counts and a per-device list (serial, model, present,
    # ready, using) from rethinkdb. The frontend uses the list to render one
    # video card per device with the correct ready/using badges.
    snippet = (
        'const r=require("/root/mdf/stf/node_modules/rethinkdb");'
        'r.connect({host:"127.0.0.1",port:28015,db:"stf"},(e,c)=>{'
        'if(e){console.log(JSON.stringify({err:String(e)}));return;}'
        'r.table("devices").run(c,(e,cur)=>{'
        'cur.toArray((e,a)=>{'
        'const total=a.length;'
        'const ready=a.filter(d=>d.present&&d.ready).length;'
        'const using=a.filter(d=>d.owner).length;'
        'const list=a.map(d=>({'
        'serial:d.serial,'
        'model:(d.model||d.product||"")+(d.abi?" ("+d.abi+")":""),'
        'present:!!d.present,'
        'ready:!!d.ready,'
        'using:!!d.owner,'
        'width:(d.display&&d.display.width)||0,'
        'height:(d.display&&d.display.height)||0'
        '})).sort((x,y)=>x.serial.localeCompare(y.serial));'
        'console.log(JSON.stringify({total,ready,using,list}));'
        'c.close();'
        '});});});'
    )
    cmd_base = [
        "ssh",
        "-i",
        SSH_KEY,
        "-p",
        str(FLEET_PORT),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ServerAliveInterval=15",
        FLEET_HOST,
    ]
    while True:
        try:
            res = subprocess.run(
                cmd_base + [f"/usr/bin/node -e '{snippet}'"],
                capture_output=True,
                text=True,
                timeout=20,
            )
            payload = (res.stdout or "").strip().splitlines()
            # Take the LAST line so any SSH banner / motd noise gets ignored.
            for line in reversed(payload):
                line = line.strip()
                if line.startswith("{"):
                    parsed = json.loads(line)
                    with device_lock:
                        if "err" in parsed:
                            device_state["err"] = parsed["err"]
                        else:
                            device_state.update(parsed)
                            device_state.pop("err", None)
                        device_state["updated_at"] = int(time.time())
                    break
        except Exception as exc:
            with device_lock:
                device_state["err"] = repr(exc)
                device_state["updated_at"] = int(time.time())
        time.sleep(DEVICE_POLL_INTERVAL)


def tail_loop(stream: Stream) -> None:
    """Spawn `ssh ... tail -F` and feed every line into the stream buffer.

    Auto-reconnects on disconnect with a 2s backoff. ServerAliveInterval
    keeps the SSH socket alive across NAT timeouts; without it the tail
    would silently stop receiving lines after ~5 minutes of build inactivity
    (which is common during heavy linker stages).
    """
    cmd = [
        "ssh",
        "-i",
        SSH_KEY,
        "-p",
        str(stream.port),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ConnectTimeout=10",
        stream.host,
        f"tail -n 400 -F {stream.path}",
    ]
    while True:
        try:
            stream.push(f"[fleet-console] connecting to {stream.host}:{stream.port}")
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                stream.push(line.rstrip("\n").rstrip("\r"))
            proc.wait()
            stream.push(
                f"[fleet-console] tail exited rc={proc.returncode}; reconnecting in 2s"
            )
        except Exception as exc:
            stream.push(f"[fleet-console] tail error: {exc!r}")
        time.sleep(2)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        parts = urlsplit(self.path)
        path = parts.path
        if path in ("/", "/index.html"):
            self._file("index.html", "text/html; charset=utf-8")
            return
        if path == "/health":
            self._json({"ok": True, "streams": {n: STREAMS[n].seq for n in STREAMS}})
            return
        if path == "/api/devices":
            with device_lock:
                snapshot = dict(device_state)
            self._json(snapshot)
            return
        if path.startswith("/log/"):
            name = path[len("/log/") :]
            if name not in STREAMS:
                self.send_error(404)
                return
            since = self._qparam(parts.query, "since", 0)
            new, current = STREAMS[name].slice_since(since)
            self._json({"lines": new, "next": current})
            return
        self.send_error(404)

    @staticmethod
    def _qparam(query: str, key: str, default: int) -> int:
        try:
            return int(parse_qs(query).get(key, [str(default)])[0])
        except (ValueError, IndexError):
            return default

    def _file(self, name: str, ctype: str) -> None:
        try:
            with open(os.path.join(HERE, name), "rb") as f:
                body = f.read()
        except FileNotFoundError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj: object) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:  # noqa: A003
        return


def main() -> None:
    for stream in STREAMS.values():
        threading.Thread(
            target=tail_loop, args=(stream,), daemon=True, name=f"tail-{stream.name}"
        ).start()
    threading.Thread(target=devices_loop, daemon=True, name="devices").start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[fleet-console] http://localhost:{PORT}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[fleet-console] shutting down")


if __name__ == "__main__":
    main()

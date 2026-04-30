#!/usr/bin/env python3
"""replay.py -- replay a recorded sensor stream into a MayaOS guest.

The recorded format is JSONL (one event per line). The Phase-5
mdf-plugin-recording produces this format alongside its other tracks:

    {"t": 1714512000123456789, "sensor": "accel", "v": [0.0, 0.1, 9.8]}
    {"t": 1714512000128456789, "sensor": "accel", "v": [0.0, 0.1, 9.8]}
    {"t": 1714512000133456789, "sensor": "gyro",  "v": [0.0, 0.0, 0.0]}
    ...

Replay paces frames at the original timing (relative to the first
event's `t`) so the in-guest sensor framework sees the same temporal
distribution it saw at record time.
"""

from __future__ import annotations

import argparse
import json
import socket
import struct
import sys
import time
from pathlib import Path

from inject import SENSOR_TYPES, FRAME_FMT


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Replay a sensor JSONL recording")
    p.add_argument("path", help="path to *.jsonl recording")
    p.add_argument(
        "--socket",
        default="\0mayaos.sensors",
        help="Linux abstract socket name; default @mayaos.sensors",
    )
    p.add_argument(
        "--rate",
        type=float,
        default=1.0,
        help="speed multiplier; >1 = faster than real-time",
    )
    p.add_argument(
        "--loop",
        action="store_true",
        help="restart from the top after EOF",
    )
    args = p.parse_args(argv)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)

    while True:
        events = []
        with Path(args.path).open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                events.append(json.loads(line))
        if not events:
            print("recording is empty", file=sys.stderr)
            return 1

        first_t = events[0]["t"]
        wall_start = time.monotonic()

        for ev in events:
            sensor_name = ev["sensor"]
            sensor_type = SENSOR_TYPES.get(sensor_name)
            if sensor_type is None:
                print(f"unknown sensor: {sensor_name!r}", file=sys.stderr)
                continue
            vals = list(ev.get("v", []))
            while len(vals) < 4:
                vals.append(0.0)

            target_offset = (ev["t"] - first_t) / 1e9 / args.rate
            now_offset = time.monotonic() - wall_start
            sleep_for = target_offset - now_offset
            if sleep_for > 0:
                time.sleep(sleep_for)

            frame = struct.pack(
                FRAME_FMT,
                sensor_type,
                0,
                int(ev.get("flags", 0)),
                0,
                int(ev["t"]),
                vals[0],
                vals[1],
                vals[2],
                vals[3],
            )
            sock.sendall(frame)

        if not args.loop:
            break
        print("loop: restarting", file=sys.stderr)

    sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

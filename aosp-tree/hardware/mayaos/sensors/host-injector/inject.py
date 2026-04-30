#!/usr/bin/env python3
"""inject.py -- one-shot sensor event into a MayaOS guest's sensors HAL.

Talks to the @mayaos.sensors abstract Unix socket. The Phase-5
mdf-plugin-recording's sensor injector binds the host side; this CLI
opens it as a client and writes a single 32-byte frame.

Usage:

    # accelerometer reading: device on its back, 1g down z.
    inject.py accel --val 0,0,9.81

    # proximity sensor: hand close to phone -> 0 cm.
    inject.py proximity --val 0

    # step counter: 12,345 total steps since boot.
    inject.py step_counter --val 12345

    # rotation vector: face up, no rotation.
    inject.py rot_vec --val 0,0,0,1
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

SENSOR_TYPES = {
    "accel": 1,
    "gyro": 4,
    "light": 5,
    "pressure": 6,
    "proximity": 8,
    "rot_vec": 11,
    "ambient_temp": 13,
    "step_counter": 19,
    "step_detect": 20,
}

FRAME_FMT = "<BBHi q ffff"  # see protocol.md
assert struct.calcsize(FRAME_FMT) == 32


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        description="One-shot sensor event into MayaOS guest"
    )
    p.add_argument("sensor", choices=sorted(SENSOR_TYPES.keys()))
    p.add_argument(
        "--val",
        required=True,
        help="comma-separated channel values; padded with 0 to 4 floats",
    )
    p.add_argument(
        "--socket",
        default="\0mayaos.sensors",
        help="Linux abstract socket name; default @mayaos.sensors",
    )
    p.add_argument(
        "--repeat",
        type=int,
        default=1,
        help="emit N times at --interval-ms apart (default 1)",
    )
    p.add_argument("--interval-ms", type=int, default=100)
    p.add_argument(
        "--wakeup",
        action="store_true",
        help="set bit 0 of flags (wakeUpEvent)",
    )
    args = p.parse_args(argv)

    vals = [float(x.strip()) for x in args.val.split(",")]
    while len(vals) < 4:
        vals.append(0.0)
    if len(vals) > 4:
        print("error: at most 4 channel values supported", file=sys.stderr)
        return 2

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)

    sensor_type = SENSOR_TYPES[args.sensor]
    flags = 0x1 if args.wakeup else 0
    payload_len = 0
    timestamp_ns = 0  # let HAL stamp now()

    for _ in range(args.repeat):
        frame = struct.pack(
            FRAME_FMT,
            sensor_type,
            0,
            flags,
            payload_len,
            timestamp_ns,
            vals[0],
            vals[1],
            vals[2],
            vals[3],
        )
        sock.sendall(frame)
        if args.repeat > 1:
            time.sleep(args.interval_ms / 1000.0)

    sock.close()
    print(f"sent {args.repeat} frame(s) for {args.sensor}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

#!/usr/bin/env bash
# MayaOS Fleet Console launcher.
#
# Opens persistent SSH tunnels into the fleet pod (so the STF UI on
# port 7100 + its websocket gateway + per-device VNC streams are
# reachable on localhost), starts the local Python HTTP server, and
# pops the browser open.
#
# Idempotent: re-running stops any prior session and starts fresh.
# Run `./start.sh stop` to tear down everything.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNDIR="${RUNDIR:-$HOME/.cache/mayaos-fleet-console}"
mkdir -p "$RUNDIR"

# All addresses are env-overridable so this script is committable.
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_runpod}"
FLEET_HOST="${FLEET_HOST:-root@38.147.83.24}"
FLEET_PORT="${FLEET_PORT:-37662}"
BUILDER_HOST="${BUILDER_HOST:-root@38.147.83.25}"
BUILDER_PORT="${BUILDER_PORT:-47023}"
LOCAL_PORT="${FLEET_CONSOLE_PORT:-8080}"

# STF needs:
#   7100  -- web UI / API
#   7110  -- websocket gateway (the iframe makes ws connections to this)
#   7700  -- storage temp uploads
#   7400-7415  -- per-device screen stream (one port per device slot)
declare -a STF_PORTS=(7100 7110 7700)
for p in $(seq 7400 7415); do STF_PORTS+=("$p"); done

stop_existing() {
    local stopped=0
    for f in tunnel-fleet.pid server.pid; do
        if [[ -f "$RUNDIR/$f" ]]; then
            local pid
            pid="$(cat "$RUNDIR/$f")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                sleep 0.3
                kill -9 "$pid" 2>/dev/null || true
                stopped=$((stopped + 1))
            fi
            rm -f "$RUNDIR/$f"
        fi
    done
    if [[ $stopped -gt 0 ]]; then
        echo "[stop] terminated $stopped previous process(es)"
    fi
}

start_tunnel() {
    local fwd_args=()
    for p in "${STF_PORTS[@]}"; do fwd_args+=(-L "$p:127.0.0.1:$p"); done

    echo "[tunnel] STF -> $FLEET_HOST:$FLEET_PORT (${#STF_PORTS[@]} ports)"
    # nohup + < /dev/null + & detaches the ssh client from this shell so
    # closing this terminal doesn't drop the tunnel. ServerAliveInterval
    # keeps the socket alive across NAT timeouts; ExitOnForwardFailure
    # makes us notice immediately if any port is already bound locally.
    nohup ssh -N \
        -i "$SSH_KEY" -p "$FLEET_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=4 \
        -o ExitOnForwardFailure=yes \
        "${fwd_args[@]}" \
        "$FLEET_HOST" \
        < /dev/null >> "$RUNDIR/tunnel.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$RUNDIR/tunnel-fleet.pid"
    sleep 1.5
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "[err] SSH tunnel failed to come up; tail of $RUNDIR/tunnel.log:"
        tail -10 "$RUNDIR/tunnel.log" 2>/dev/null || true
        exit 1
    fi
    echo "[tunnel] up (pid=$pid)"
}

start_server() {
    echo "[server] starting on http://localhost:$LOCAL_PORT/"
    nohup env \
        FLEET_CONSOLE_PORT="$LOCAL_PORT" \
        BUILDER_HOST="$BUILDER_HOST" \
        BUILDER_PORT="$BUILDER_PORT" \
        FLEET_HOST="$FLEET_HOST" \
        FLEET_PORT="$FLEET_PORT" \
        FLEET_SSH_KEY="$SSH_KEY" \
        python3 "$HERE/server.py" \
        > "$RUNDIR/server.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$RUNDIR/server.pid"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "[err] python server failed to start; tail of $RUNDIR/server.log:"
        tail -10 "$RUNDIR/server.log" 2>/dev/null || true
        exit 1
    fi
    # Smoke test the HTTP endpoint
    if curl -sf "http://localhost:$LOCAL_PORT/health" > /dev/null; then
        echo "[server] healthy (pid=$pid)"
    else
        echo "[err] /health probe failed"
        exit 1
    fi
}

cmd="${1:-start}"
case "$cmd" in
    start)
        stop_existing
        start_tunnel
        start_server
        echo
        echo "  open  http://localhost:$LOCAL_PORT/"
        echo "  logs  tail -F $RUNDIR/{tunnel,server}.log"
        echo "  stop  $0 stop"
        echo
        if command -v open >/dev/null 2>&1; then
            open "http://localhost:$LOCAL_PORT/"
        fi
        ;;
    stop)
        stop_existing
        echo "[ok] stopped"
        ;;
    status)
        # `local` is only valid inside functions; at top-level we just use
        # plain assignment.
        for f in tunnel-fleet.pid server.pid; do
            if [[ -f "$RUNDIR/$f" ]]; then
                pid="$(cat "$RUNDIR/$f")"
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    echo "[run]  $f -> pid=$pid"
                else
                    echo "[dead] $f -> pid=$pid (not running)"
                fi
            else
                echo "[none] $f"
            fi
        done
        ;;
    *)
        echo "usage: $0 {start|stop|status}"
        exit 2
        ;;
esac

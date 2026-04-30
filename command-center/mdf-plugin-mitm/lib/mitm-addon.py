"""mdf mitm addon.

Streams every request/response into RethinkDB via a unix socket so the
MDF UI can render flows live. Reads intercept/modify rules from the
``mitm_rules`` table at startup and on SIGHUP.

References
----------
- https://docs.mitmproxy.org/stable/addons-overview/
- https://docs.mitmproxy.org/stable/addons-options/
"""
from __future__ import annotations

import json
import os
import socket
import time
import uuid
from typing import Any

from mitmproxy import ctx, http
from mitmproxy.script import concurrent

SERIAL = os.environ.get("MDF_SERIAL", "unknown")
SOCK_PATH = "/run/mdf/mitm.sock"


def _send(payload: dict[str, Any]) -> None:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.sendto(json.dumps(payload).encode("utf-8"), SOCK_PATH)
        s.close()
    except OSError as exc:
        ctx.log.warn(f"mdf-addon: send failed: {exc}")


class MdfAddon:
    """Capture every flow + apply intercept rules.

    Intercept rules are loaded from a JSON file on first request and reloaded
    on SIGHUP (sent by ``mdf-plugin-mitm`` when a rule is added).
    """

    def __init__(self) -> None:
        self.rules: list[dict[str, Any]] = []
        self.rules_path = os.environ.get(
            "MDF_RULES_PATH", "/var/lib/mdf/mitm/rules.json"
        )

    def load(self, loader) -> None:  # noqa: D401, ANN001
        loader.add_option(
            name="mdf_serial", typespec=str, default=SERIAL,
            help="instance serial",
        )
        loader.add_option(
            name="mdf_state_dir", typespec=str,
            default="/var/lib/mdf/mitm",
            help="per-instance state dir",
        )
        self._reload_rules()

    def _reload_rules(self) -> None:
        try:
            with open(self.rules_path, "r", encoding="utf-8") as f:
                self.rules = json.load(f)
                ctx.log.info(
                    f"mdf-addon: reloaded {len(self.rules)} rules"
                )
        except FileNotFoundError:
            self.rules = []

    @concurrent
    def request(self, flow: http.HTTPFlow) -> None:
        for rule in self.rules:
            if rule.get("when") != "request":
                continue
            if not _matches(flow, rule.get("match", {})):
                continue
            _apply(flow, rule.get("action", {}))

        _send({
            "id": str(uuid.uuid4()),
            "serial": ctx.options.mdf_serial,
            "ts": int(time.time() * 1000),
            "phase": "request",
            "method": flow.request.method,
            "url": flow.request.pretty_url,
            "headers": dict(flow.request.headers),
            "body_len": len(flow.request.content or b""),
        })

    @concurrent
    def response(self, flow: http.HTTPFlow) -> None:
        for rule in self.rules:
            if rule.get("when") != "response":
                continue
            if not _matches(flow, rule.get("match", {})):
                continue
            _apply(flow, rule.get("action", {}))

        _send({
            "id": str(uuid.uuid4()),
            "serial": ctx.options.mdf_serial,
            "ts": int(time.time() * 1000),
            "phase": "response",
            "method": flow.request.method,
            "url": flow.request.pretty_url,
            "status": flow.response.status_code if flow.response else None,
            "headers": dict(flow.response.headers) if flow.response else {},
            "body_len": len(flow.response.content or b"") if flow.response else 0,
        })


def _matches(flow: http.HTTPFlow, match: dict[str, Any]) -> bool:
    if "host" in match and match["host"] not in flow.request.host:
        return False
    if "path" in match and match["path"] not in flow.request.path:
        return False
    if "method" in match and match["method"] != flow.request.method:
        return False
    return True


def _apply(flow: http.HTTPFlow, action: dict[str, Any]) -> None:
    if action.get("kill"):
        flow.kill()
        return
    if "set_header" in action and flow.request:
        for k, v in action["set_header"].items():
            flow.request.headers[k] = v
    if "replace_body" in action and flow.response:
        flow.response.text = action["replace_body"]
    if "set_status" in action and flow.response:
        flow.response.status_code = int(action["set_status"])


addons = [MdfAddon()]

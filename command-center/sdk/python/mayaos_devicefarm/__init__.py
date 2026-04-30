"""MayaOS Device Farm SDK (Python).

Lightweight client for the MDF REST API. Reuses the same Cloudflare
Access JWT the operator UI uses, so credentials = whatever your
``cloudflared access token`` returns. Most useful for CI / automated
device test flows that need to claim / release / interact with
MayaOS instances programmatically.

Example
-------

>>> from mayaos_devicefarm import Client
>>> mdf = Client("https://mdf-pod-eu-de-0.mdf.mayaos.dev")
>>> serial = mdf.warmpool.checkout()
>>> mdf.shell(serial, "input keyevent KEYCODE_HOME")
>>> mdf.warmpool.checkin(serial)
"""
from __future__ import annotations

import os
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any, Iterable

import httpx


__version__ = "1.0.0"


@dataclass
class Device:
    serial: str
    model: str
    channel: str
    status: str


class _SubClient:
    def __init__(self, parent: "Client", path: str) -> None:
        self._parent = parent
        self._path = path

    def _post(self, suffix: str, **kwargs: Any) -> dict:
        return self._parent._request("POST", self._path + suffix, **kwargs)

    def _get(self, suffix: str, **kwargs: Any) -> dict:
        return self._parent._request("GET", self._path + suffix, **kwargs)


class _Warmpool(_SubClient):
    def checkout(self, timeout_s: float = 5.0) -> str:
        end = time.time() + timeout_s
        while time.time() < end:
            try:
                resp = self._post("/checkout")
                return resp["serial"]
            except RuntimeError as exc:
                if "pool empty" in str(exc):
                    time.sleep(0.5)
                    continue
                raise
        raise TimeoutError("warmpool checkout timed out")

    def checkin(self, serial: str) -> None:
        self._post(f"/checkin/{serial}")

    def pool_size(self, size: int) -> None:
        self._post("/pool/size", json={"size": size})

    def pool(self) -> dict:
        return self._get("/pool")


class _Mitm(_SubClient):
    def start(self, serial: str) -> dict:
        return self._post(f"/devices/{serial}/start")

    def stop(self, serial: str) -> dict:
        return self._post(f"/devices/{serial}/stop")

    def flows(self, serial: str, limit: int = 200) -> list[dict]:
        return self._get(f"/devices/{serial}/flows?limit={limit}").get("flows", [])

    def add_rule(self, serial: str, rule: dict) -> None:
        self._post(f"/devices/{serial}/intercept-rule", json=rule)


class _Recording(_SubClient):
    def start(self, serial: str) -> str:
        return self._post(f"/devices/{serial}/start")["sessionId"]

    def stop(self, serial: str) -> dict:
        return self._post(f"/devices/{serial}/stop")

    def list(self, serial: str | None = None, limit: int = 100) -> list[dict]:
        q = "?limit=" + str(limit)
        if serial:
            q += "&serial=" + serial
        return self._get("/sessions" + q).get("sessions", [])


class _Ota(_SubClient):
    def channels(self) -> dict:
        return self._get("/channels")

    def pin(self, serial: str, channel: str) -> None:
        self._post(f"/devices/{serial}/channel", json={"channel": channel})

    def check_now(self, serial: str) -> dict:
        return self._post(f"/devices/{serial}/check-now")


class _Hvf(_SubClient):
    def snapshot(self, serial: str) -> dict:
        return self._post(f"/devices/{serial}/snapshot")


class Client:
    """MDF API client.

    Parameters
    ----------
    base_url:
        e.g. ``https://mdf-pod-eu-de-0.mdf.mayaos.dev``.
    access_token:
        Cloudflare Access JWT. Reads ``$MDF_ACCESS_TOKEN`` if unset.
    timeout:
        Per-request timeout in seconds. Defaults to 30.
    """

    def __init__(
        self,
        base_url: str,
        *,
        access_token: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self._base = base_url.rstrip("/")
        self._token = access_token or os.environ.get("MDF_ACCESS_TOKEN", "")
        self._client = httpx.Client(
            base_url=self._base,
            timeout=timeout,
            headers=self._auth_headers(),
        )
        self.warmpool  = _Warmpool(self,  "/mdf/warmpool")
        self.mitm      = _Mitm(self,      "/mdf/mitm")
        self.recording = _Recording(self, "/mdf/recording")
        self.ota       = _Ota(self,       "/mdf/ota-channel")
        self.hvf       = _Hvf(self,       "/mdf/hvf-preview")

    def _auth_headers(self) -> dict[str, str]:
        h = {"User-Agent": f"mayaos-devicefarm-python/{__version__}"}
        if self._token:
            h["cf-access-token"] = self._token
        return h

    def _request(self, method: str, path: str, **kwargs: Any) -> dict:
        resp = self._client.request(method, path, **kwargs)
        if resp.status_code >= 400:
            raise RuntimeError(
                f"MDF API {method} {path} -> {resp.status_code}: {resp.text}"
            )
        if not resp.content:
            return {}
        return resp.json()

    def devices(self) -> list[Device]:
        out = []
        for d in self._request("GET", "/api/v1/devices").get("devices", []):
            out.append(Device(
                serial   = d["serial"],
                model    = d.get("model", "Galaxy S26 Ultra"),
                channel  = d.get("channel", "stable"),
                status   = d.get("status", "unknown"),
            ))
        return out

    def shell(self, serial: str, cmd: str | Iterable[str]) -> str:
        if not isinstance(cmd, str):
            cmd = " ".join(cmd)
        body = {"cmd": cmd}
        resp = self._request("POST", f"/api/v1/devices/{serial}/shell", json=body)
        return resp.get("stdout", "")

    def install(self, serial: str, apk_path: str) -> None:
        with open(apk_path, "rb") as f:
            self._client.post(f"/api/v1/devices/{serial}/install",
                              files={"apk": f}).raise_for_status()

    def uninstall(self, serial: str, package: str) -> None:
        self._request("DELETE", f"/api/v1/devices/{serial}/apps/{package}")

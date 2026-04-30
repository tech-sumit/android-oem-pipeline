# mayaos-devicefarm (Python)

```bash
pip install mayaos-devicefarm  # not yet on PyPI; install from this repo
```

## Quickstart

```python
from mayaos_devicefarm import Client

mdf = Client("https://mdf-pod-eu-de-0.mdf.mayaos.dev")
serial = mdf.warmpool.checkout()
try:
    mdf.shell(serial, "input keyevent KEYCODE_HOME")
    mdf.mitm.start(serial)
    flows = mdf.mitm.flows(serial, limit=50)
    print(flows)
finally:
    mdf.mitm.stop(serial)
    mdf.warmpool.checkin(serial)
```

## Auth

Pass a Cloudflare Access JWT via `access_token=` or
`MDF_ACCESS_TOKEN`. Get one with:

```bash
cloudflared access login https://mdf-pod-eu-de-0.mdf.mayaos.dev
TOKEN=$(cloudflared access token --app https://mdf-pod-eu-de-0.mdf.mayaos.dev)
export MDF_ACCESS_TOKEN="$TOKEN"
```

## API surface

| Subclient        | Methods                                                                  |
|------------------|--------------------------------------------------------------------------|
| `mdf.warmpool`   | `checkout`, `checkin`, `pool_size`, `pool`                                |
| `mdf.mitm`       | `start`, `stop`, `flows`, `add_rule`                                      |
| `mdf.recording`  | `start`, `stop`, `list`                                                   |
| `mdf.ota`        | `channels`, `pin`, `check_now`                                            |
| `mdf.hvf`        | `snapshot`                                                                |
| top-level        | `devices`, `shell`, `install`, `uninstall`                                |

See `command-center/docs/plugin-api.md` for the underlying REST contract.

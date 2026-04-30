# @mayaos/devicefarm (TypeScript)

```bash
npm install @mayaos/devicefarm  # not yet on npm; install from this repo
```

## Quickstart

```ts
import { Client } from "@mayaos/devicefarm";

const mdf = new Client("https://mdf-pod-eu-de-0.mdf.mayaos.dev");
const serial = await mdf.warmpool.checkout();
try {
  await mdf.shell(serial, "input keyevent KEYCODE_HOME");
  await mdf.mitm.start(serial);
  const flows = await mdf.mitm.flows(serial, 50);
  console.log(flows);
} finally {
  await mdf.mitm.stop(serial);
  await mdf.warmpool.checkin(serial);
}
```

## Auth

Pass a Cloudflare Access JWT via `accessToken` or `MDF_ACCESS_TOKEN`:

```bash
TOKEN=$(cloudflared access token --app https://mdf-pod-eu-de-0.mdf.mayaos.dev)
export MDF_ACCESS_TOKEN="$TOKEN"
```

See `command-center/docs/plugin-api.md` for the underlying REST contract.

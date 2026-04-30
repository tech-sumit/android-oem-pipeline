# MDF plugin contract

Every MDF plugin runs as a **sibling Node.js process** of STF inside the
same container. It does **not** monkey-patch STF's source; it talks to
STF over the public surfaces that STF already exposes:

1. **ZeroMQ event bus** (`tcp://*:7160` PUB, `tcp://*:7170` PULL by
   default). STF publishes a stream of `{topic, channel, payload}`
   protobuf-wrapped messages. Plugins SUB to `topic` filters they
   care about. This is exactly how STF's own `processor`, `provider`
   and `device` workers communicate — see
   [`stf/lib/wire/wire.proto`](https://github.com/DeviceFarmer/stf/blob/master/lib/wire/wire.proto).

2. **REST namespace** `/mdf/*` mounted under STF's main app via
   `app.use('/mdf/<plugin>', router)`. Plugins are auto-discovered by
   `stf-provider-emulator` at boot using the `discoverPlugins()`
   helper in `lib/plugins.js`.

3. **WebSocket sub-protocol** `mdf-v1` upgraded under STF's existing
   websocket server. Plugins register a per-channel `onMessage` and
   `onClose` handler. STF auth (cookie -> session -> user) is reused.

4. **RethinkDB tables** in the `mdf` database (separate from STF's
   `stf` db, but on the same cluster). Each plugin owns its own
   tables, listed in `command-center/sql/<plugin>.r.js`.

## Wire format

```ts
type MdfMessage<T extends string, P> = {
  v: 1;             // protocol version
  topic: T;         // plugin topic, e.g. "mitm" | "rec" | "ota"
  serial: string;   // emulator serial, e.g. "emulator-5554"
  ts: number;       // ms since epoch
  payload: P;       // plugin-specific
};
```

All payloads are JSON, **not** protobuf — easier to evolve and the
QPS is well under STF's internal device-channel rates.

## Reserved topics

| topic         | publisher                | subscribers                  |
|---------------|--------------------------|------------------------------|
| `provider`    | `stf-provider-emulator`  | STF processor, warmpool      |
| `mitm`        | `mdf-plugin-mitm`        | UI, recording                |
| `rec`         | `mdf-plugin-recording`   | UI                           |
| `ota`         | `mdf-plugin-ota-channel` | UI, MayaOSUpdater (push)     |
| `hvf`         | `mdf-plugin-hvf-preview` | UI                           |
| `warm`        | `mdf-plugin-warmpool`    | provider, UI                 |

## REST endpoints

See plan §11.4. Summary:

| method | path                                | plugin    |
|--------|-------------------------------------|-----------|
| GET    | `/mdf/devices`                      | core      |
| POST   | `/mdf/devices/:serial/restart`      | core      |
| POST   | `/mdf/devices/:serial/factory-reset`| core      |
| POST   | `/mdf/devices/:serial/install`      | core      |
| DELETE | `/mdf/devices/:serial/apps/:pkg`    | core      |
| POST   | `/mdf/devices/:serial/mitm/start`   | mitm      |
| POST   | `/mdf/devices/:serial/mitm/stop`    | mitm      |
| GET    | `/mdf/devices/:serial/mitm/flows`   | mitm      |
| POST   | `/mdf/devices/:serial/rec/start`    | recording |
| POST   | `/mdf/devices/:serial/rec/stop`     | recording |
| POST   | `/mdf/channels`                     | ota       |
| POST   | `/mdf/devices/:serial/channel`      | ota       |
| POST   | `/mdf/hvf/preview`                  | hvf       |
| GET    | `/mdf/warm/pool`                    | warmpool  |
| POST   | `/mdf/warm/pool/size`               | warmpool  |

## Plugin lifecycle

Plugins MUST export:

```js
// command-center/<plugin-dir>/index.js
module.exports = {
  name: 'mitm',
  version: '1.0.0',
  // mounted on STF's main app under /mdf/<name>
  routes(app) { ... },
  // attach websocket handlers via STF's wsServer
  websockets(wss) { ... },
  // subscribe to ZMQ topics
  subscribe(sub) { ... },
  // start any background loops
  async start({ db, log, config }) { ... },
  async stop() { ... },
};
```

`stf-provider-emulator` (which is the canonical entry point inside the
container) loads each plugin from `command-center/mdf-plugin-*/index.js`
at startup and wires it into STF.

## Auth

Plugins MUST NOT issue ad-hoc tokens. Reuse STF's `req.user` (populated
by STF's auth middleware) and the `requireGroup(name)` middleware
exposed via `lib/auth.js`. Cloudflare Access at the edge enforces OIDC
before any request reaches STF.

## Logging

Use the shared `lib/log.js` which writes JSON lines to stdout and tags
each line with `{plugin, instance, serial}`. Grafana Alloy on the host
ships these to Loki.

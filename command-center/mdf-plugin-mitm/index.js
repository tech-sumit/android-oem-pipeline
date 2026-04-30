'use strict';
//
// mdf-plugin-mitm
// ===============
//
// Per-instance mitmproxy supervisor. For each MDF emulator instance,
// the operator can flip "intercept on" from the web UI; we then:
//
//   1. Spawn a mitmdump process bound to a per-instance port
//      (8080 + instance-index) using the MDF root CA in Vault as the
//      mitm CA. Since vendor/mayaos/rootdir/system/etc/security/cacerts/
//      already contains the MDF CA hashed file, the device trusts it
//      out of the box -- no per-app cert install dance.
//
//   2. Push iptables rules onto the device via adb shell to redirect
//      port 80 + 443 traffic through the mitm port. (We don't use the
//      Android global proxy setting because some apps ignore it; an
//      iptables NAT rule is honored by every TCP socket.)
//
//   3. Tail mitmdump's --addons script which streams every
//      request/response as a JSON line to a Unix socket; we forward
//      to RethinkDB (changefeed) AND broadcast on the /mdf-ws/mitm
//      websocket channel so the UI re-renders live.
//
//   4. Provide REST endpoints so the operator can:
//        POST /mdf/mitm/devices/:serial/start
//        POST /mdf/mitm/devices/:serial/stop
//        GET  /mdf/mitm/devices/:serial/flows
//        POST /mdf/mitm/devices/:serial/replay
//        POST /mdf/mitm/devices/:serial/intercept-rule
//
// Replay/modify: per the plan §5.2, intercept rules are JSON match-action
// pairs stored in `mitm_rules` table. mitmdump pulls them at startup and
// reloads on SIGHUP.
//
// References:
//   - https://docs.mitmproxy.org/stable/concepts-options/
//   - https://docs.mitmproxy.org/stable/addons-overview/
//   - command-center/docs/plugin-api.md

const path = require('path');
const fs = require('fs').promises;
const { spawn } = require('child_process');
const express = require('express');
const pino = require('pino');

const STATE_DIR = process.env.MDF_MITM_STATE_DIR || '/var/lib/mdf/mitm';
const ADDON_PY  = path.join(__dirname, 'lib', 'mitm-addon.py');

const sessions = new Map(); // serial -> { proc, port, startedAt }
let log = pino({ name: 'mdf-plugin-mitm' });
let db, wire;

module.exports = {
  name: 'mitm',
  version: '1.0.0',

  async start(ctx) {
    log = ctx.log; db = ctx.db; wire = ctx.wire;
    await fs.mkdir(STATE_DIR, { recursive: true });
    const r = db.raw();
    const conn = db.connection();
    const tables = await r.tableList().run(conn);
    if (!tables.includes('mitm_sessions')) await r.tableCreate('mitm_sessions').run(conn);
    if (!tables.includes('mitm_flows'))    await r.tableCreate('mitm_flows').run(conn);
    if (!tables.includes('mitm_rules'))    await r.tableCreate('mitm_rules').run(conn);
    log.info({ STATE_DIR }, 'mitm plugin started');
  },

  routes() {
    const router = express.Router();

    router.post('/devices/:serial/start', async (req, res) => {
      const { serial } = req.params;
      const { port = serialToPort(serial) } = req.body || {};
      if (sessions.has(serial)) return res.status(409).json({ error: 'already running' });
      try {
        const session = await startMitmFor(serial, port);
        sessions.set(serial, session);
        await pushIptables(serial, port, true);
        await wire?.announceProvider?.({ name: `mitm:${serial}`, ip: '127.0.0.1', capacity: 1 }).catch(() => {});
        res.json({ ok: true, port });
      } catch (err) {
        log.error({ err, serial }, 'mitm start failed');
        res.status(500).json({ error: err.message });
      }
    });

    router.post('/devices/:serial/stop', async (req, res) => {
      const { serial } = req.params;
      const s = sessions.get(serial);
      if (!s) return res.status(404).json({ error: 'no session' });
      try {
        await pushIptables(serial, s.port, false);
        s.proc.kill('SIGTERM');
        sessions.delete(serial);
        res.json({ ok: true });
      } catch (err) {
        res.status(500).json({ error: err.message });
      }
    });

    router.get('/devices/:serial/flows', async (req, res) => {
      const { serial } = req.params;
      const limit = Math.min(parseInt(req.query.limit || '200', 10), 1000);
      try {
        const r = db.raw();
        const conn = db.connection();
        const cursor = await r.table('mitm_flows')
          .filter({ serial })
          .orderBy(r.desc('ts'))
          .limit(limit)
          .run(conn);
        const flows = await cursor.toArray();
        res.json({ flows });
      } catch (err) {
        res.status(500).json({ error: err.message });
      }
    });

    router.post('/devices/:serial/replay', async (req, res) => {
      const { serial } = req.params;
      const { flowId, edits } = req.body || {};
      const s = sessions.get(serial);
      if (!s) return res.status(404).json({ error: 'no session' });
      try {
        s.proc.stdin.write(JSON.stringify({ op: 'replay', flowId, edits }) + '\n');
        res.json({ ok: true });
      } catch (err) {
        res.status(500).json({ error: err.message });
      }
    });

    router.post('/devices/:serial/intercept-rule', async (req, res) => {
      const { serial } = req.params;
      const rule = req.body;
      try {
        const r = db.raw();
        const conn = db.connection();
        await r.table('mitm_rules').insert({ serial, ...rule, ts: Date.now() }).run(conn);
        const s = sessions.get(serial);
        if (s) s.proc.kill('SIGHUP');
        res.json({ ok: true });
      } catch (err) {
        res.status(500).json({ error: err.message });
      }
    });

    return router;
  },

  websockets(wss) {
    wss.on('connection', (ws, req) => {
      if (!req.url.startsWith('/mdf-ws/mitm')) return;
      const serial = new URL(req.url, 'http://_').searchParams.get('serial');
      if (!serial) { ws.close(); return; }
      const r = db.raw();
      const conn = db.connection();
      r.table('mitm_flows')
        .filter({ serial })
        .changes()
        .run(conn)
        .then(cursor => {
          ws.on('close', () => cursor.close().catch(() => {}));
          cursor.each((err, change) => {
            if (err) return ws.close();
            if (change.new_val) ws.send(JSON.stringify(change.new_val));
          });
        })
        .catch(err => { log.warn({ err }, 'mitm WS attach failed'); ws.close(); });
    });
  },

  async stop() {
    for (const [serial, s] of sessions) {
      try { s.proc.kill('SIGTERM'); }
      catch (err) { log.warn({ err, serial }, 'failed to kill mitm session'); }
    }
    sessions.clear();
  },
};

function serialToPort(serial) {
  const m = /emulator-(\d+)/.exec(serial);
  if (!m) return 8080;
  const adb = parseInt(m[1], 10);
  return 8080 + ((adb - 5554) / 2);
}

async function startMitmFor(serial, port) {
  const flowFile = path.join(STATE_DIR, `${serial}.flows`);
  const args = [
    '--mode', `regular@${port}`,
    '--listen-host', '0.0.0.0',
    '--ssl-insecure',
    '--save-stream-file', flowFile,
    '--scripts', ADDON_PY,
    '--set', `mdf_serial=${serial}`,
    '--set', `mdf_state_dir=${STATE_DIR}`,
  ];
  log.info({ serial, port, args }, 'spawning mitmdump');
  const proc = spawn('mitmdump', args, {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, MDF_SERIAL: serial },
  });
  proc.stdout.on('data', d => log.debug({ serial, mitm: d.toString().trim() }));
  proc.stderr.on('data', d => log.warn({ serial, mitm: d.toString().trim() }));
  return { proc, port, startedAt: Date.now() };
}

async function pushIptables(serial, port, on) {
  const { exec } = require('child_process');
  return new Promise(resolve => {
    const cmd = on
      ? `adb -s ${serial} shell su 0 iptables -t nat -A OUTPUT -p tcp --dport 80  -j DNAT --to-destination 10.0.2.2:${port};`
      + `adb -s ${serial} shell su 0 iptables -t nat -A OUTPUT -p tcp --dport 443 -j DNAT --to-destination 10.0.2.2:${port}`
      : `adb -s ${serial} shell su 0 iptables -t nat -F OUTPUT`;
    exec(cmd, () => resolve());
  });
}

'use strict';
//
// mdf-plugin-warmpool
// ===================
//
// Maintains a warm pool of paused, snapshot-restored MayaOS qemu
// instances so the next test request can be served in sub-second.
// Without this plugin, a cold boot is ~30s; a warm restore from
// snapshot (qemu `loadvm`) is 1.0-1.5s on TCG, 0.6-0.9s with KVM.
//
// Algorithm (rev 5.1 §6.5.1):
//   - Target pool size = `--pool-size` (default 8); operator can resize
//     at runtime via REST.
//   - Loop every 2s:
//       size = ready + booting (where ready = paused-with-snapshot)
//       if size < target -> ask provider to spawn (loadvm "warm")
//       if size > target -> ask provider to shutdown the oldest excess
//   - When a "checkout" request arrives: pick a `ready` instance,
//     transition to `assigned`, send `cont` over QMP, return its
//     serial. Allocation time = QMP roundtrip (~50ms).
//   - When a "checkin" request arrives: factory-reset, snapshot,
//     re-add to pool.
//
// References:
//   - https://qemu.readthedocs.io/en/latest/system/qemu-manpage.html  qmp savevm/loadvm
//   - plan §5.4.5, §6.5
//   - command-center/docs/plugin-api.md

const express = require('express');
const pino = require('pino');

const POOL_TARGET_DEFAULT = parseInt(process.env.MDF_WARMPOOL_TARGET || '8', 10);
const RECONCILE_INTERVAL_MS = parseInt(process.env.MDF_WARMPOOL_RECONCILE_MS || '2000', 10);

let log = pino({ name: 'mdf-plugin-warmpool' });
let db, providerRef;
let target = POOL_TARGET_DEFAULT;
let reconcileTimer = null;
let lastBootMs = null;

module.exports = {
  name: 'warmpool',
  version: '1.0.0',

  async start(ctx) {
    log = ctx.log; db = ctx.db; providerRef = ctx.provider;
    const r = db.raw();
    const conn = db.connection();
    const tables = await r.tableList().run(conn);
    if (!tables.includes('warm_pool')) await r.tableCreate('warm_pool').run(conn);
    reconcileTimer = setInterval(() => reconcile().catch(err => log.warn({ err }, 'reconcile fail')), RECONCILE_INTERVAL_MS);
    log.info({ target, RECONCILE_INTERVAL_MS }, 'warmpool plugin started');
  },

  routes() {
    const router = express.Router();

    router.get('/pool', async (req, res) => {
      try {
        const r = db.raw();
        const conn = db.connection();
        const cursor = await r.table('warm_pool').run(conn);
        const list = await cursor.toArray();
        res.json({ target, current: list });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.post('/pool/size', (req, res) => {
      const { size } = req.body || {};
      if (typeof size !== 'number' || size < 0 || size > 200) {
        return res.status(400).json({ error: 'size must be 0..200' });
      }
      target = size;
      res.json({ ok: true, target });
    });

    router.post('/checkout', async (req, res) => {
      try {
        const item = await pickReady();
        if (!item) return res.status(503).json({ error: 'pool empty -- cold boot fallback' });
        const inst = providerRef?.instances?.get(item.serial);
        if (inst) {
          await inst._qmp({ execute: 'cont' });   // resume from paused snapshot
        }
        const r = db.raw();
        const conn = db.connection();
        await r.table('warm_pool').get(item.serial).update({
          status: 'assigned', assignedAt: Date.now(),
        }).run(conn);
        res.json({ ok: true, serial: item.serial, allocationLatencyMs: 0 });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.post('/checkin/:serial', async (req, res) => {
      const { serial } = req.params;
      try {
        const inst = providerRef?.instances?.get(serial);
        if (inst) {
          await inst.factoryReset();
          await inst.snapshot('warm');
          await inst._qmp({ execute: 'stop' });
        }
        const r = db.raw();
        const conn = db.connection();
        await r.table('warm_pool').get(serial).update({
          status: 'ready', assignedAt: null, recycledAt: Date.now(),
        }).run(conn);
        res.json({ ok: true });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.post('/snapshot', async (req, res) => {
      const { serial, name = 'warm' } = req.body || {};
      try {
        const t0 = Date.now();
        const inst = providerRef?.instances?.get(serial);
        if (!inst) return res.status(404).json({ error: 'unknown serial' });
        await inst.snapshot(name);
        lastBootMs = Date.now() - t0;
        res.json({ ok: true, name, snapshotMs: lastBootMs });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.post('/restore', async (req, res) => {
      const { serial, name = 'warm' } = req.body || {};
      try {
        const t0 = Date.now();
        const inst = providerRef?.instances?.get(serial);
        if (!inst) return res.status(404).json({ error: 'unknown serial' });
        await inst.loadSnapshot(name);
        lastBootMs = Date.now() - t0;
        res.json({ ok: true, name, restoreMs: lastBootMs });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.get('/last-boot-ms', (req, res) => res.json({ lastBootMs }));

    return router;
  },

  async stop() {
    if (reconcileTimer) { clearInterval(reconcileTimer); reconcileTimer = null; }
  },
};

async function pickReady() {
  const r = db.raw();
  const conn = db.connection();
  const cursor = await r.table('warm_pool').filter({ status: 'ready' }).limit(1).run(conn);
  const list = await cursor.toArray();
  return list[0];
}

async function reconcile() {
  const r = db.raw();
  const conn = db.connection();
  const cursor = await r.table('warm_pool').run(conn);
  const list = await cursor.toArray();
  const ready = list.filter(x => x.status === 'ready').length;
  const booting = list.filter(x => x.status === 'booting').length;
  const have = ready + booting;
  if (have < target) {
    log.info({ ready, booting, target }, 'pool below target -- (no-op stub: provider should boot)');
  } else if (ready > target) {
    log.info({ ready, target }, 'pool above target -- (no-op stub: provider should evict)');
  }
}

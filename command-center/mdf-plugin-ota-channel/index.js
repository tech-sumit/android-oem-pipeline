'use strict';
//
// mdf-plugin-ota-channel
// ======================
//
// Per-device OTA channel pin + manual-push.
//
// MDF builds the MayaOS image whenever a commit lands; the artifact +
// build metadata are uploaded to R2 (Phase 6 ota/append.py). A static
// JSON index of "channels" lives at https://ota.mayaos.dev/channels.json
// (Cloudflare Pages). Each channel maps to a stream of builds:
//   - stable    -> N most recent builds with explicit promotion
//   - canary    -> auto-promoted on every passing build
//   - dev       -> every build, no promotion
//   - <custom>  -> operator-defined (e.g. for a single test campaign)
//
// This plugin lets operators:
//   1. Pin a device to a specific channel (`mdf_devices.channel`).
//   2. List the most recent builds in a channel.
//   3. Trigger an immediate "check now" on the MayaOSUpdater app
//      via `am start-foreground-service` over adb.
//   4. View the OTA install status (success/failure/duration).
//
// References:
//   - waydroid/OTA               channel JSON layout
//   - waydroid/android_packages_apps_WaydroidUpdater
//   - plan §6, §11.4
//   - command-center/docs/plugin-api.md

const path = require('path');
const fs = require('fs').promises;
const { exec } = require('child_process');
const express = require('express');
const fetch = (...args) => import('node-fetch').then(({default: f}) => f(...args));
const pino = require('pino');

const OTA_INDEX_URL = process.env.MDF_OTA_INDEX_URL || 'https://ota.mayaos.dev/channels.json';
const OTA_INDEX_REFRESH_MS = parseInt(process.env.MDF_OTA_REFRESH_MS || '60000', 10);

let log = pino({ name: 'mdf-plugin-ota-channel' });
let db;
let cachedIndex = { channels: {}, fetchedAt: 0 };
let refreshTimer = null;

module.exports = {
  name: 'ota-channel',
  version: '1.0.0',

  async start(ctx) {
    log = ctx.log; db = ctx.db;
    const r = db.raw();
    const conn = db.connection();
    const tables = await r.tableList().run(conn);
    if (!tables.includes('mdf_devices'))     await r.tableCreate('mdf_devices').run(conn);
    if (!tables.includes('ota_attempts'))    await r.tableCreate('ota_attempts').run(conn);
    if (!tables.includes('ota_channels'))    await r.tableCreate('ota_channels').run(conn);
    await refreshIndex();
    refreshTimer = setInterval(refreshIndex, OTA_INDEX_REFRESH_MS);
    log.info({ OTA_INDEX_URL, OTA_INDEX_REFRESH_MS }, 'ota-channel plugin started');
  },

  routes() {
    const router = express.Router();

    router.get('/channels', (req, res) => {
      res.json({
        channels: cachedIndex.channels,
        fetchedAt: cachedIndex.fetchedAt,
      });
    });

    router.post('/channels/:name', async (req, res) => {
      const { name } = req.params;
      const { source = 'mdf-operator', notes } = req.body || {};
      try {
        const r = db.raw();
        const conn = db.connection();
        await r.table('ota_channels').insert(
          { name, source, notes, ts: Date.now() },
          { conflict: 'replace' }
        ).run(conn);
        res.json({ ok: true });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.get('/devices/:serial/channel', async (req, res) => {
      const { serial } = req.params;
      try {
        const r = db.raw();
        const conn = db.connection();
        const dev = await r.table('mdf_devices').get(serial).run(conn);
        res.json({ serial, channel: dev?.channel || 'stable' });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.post('/devices/:serial/channel', async (req, res) => {
      const { serial } = req.params;
      const { channel } = req.body || {};
      if (!channel) return res.status(400).json({ error: 'channel required' });
      try {
        const r = db.raw();
        const conn = db.connection();
        await r.table('mdf_devices').insert(
          { id: serial, channel, ts: Date.now() },
          { conflict: 'update' }
        ).run(conn);
        res.json({ ok: true });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.post('/devices/:serial/check-now', async (req, res) => {
      const { serial } = req.params;
      try {
        const r = db.raw();
        const conn = db.connection();
        const dev = await r.table('mdf_devices').get(serial).run(conn);
        const channel = dev?.channel || 'stable';
        await r.table('ota_attempts').insert({
          serial, channel, startedAt: Date.now(), source: 'check-now',
        }).run(conn);
        await new Promise((resolve, reject) => {
          exec(
            `adb -s ${serial} shell am start-foreground-service ` +
            `-n dev.mayaos.updater/.UpdateCheckService ` +
            `--es channel "${channel}"`,
            (err, stdout, stderr) => err ? reject(err) : resolve()
          );
        });
        res.json({ ok: true, channel });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    router.get('/devices/:serial/attempts', async (req, res) => {
      const { serial } = req.params;
      try {
        const r = db.raw();
        const conn = db.connection();
        const cursor = await r.table('ota_attempts')
          .filter({ serial })
          .orderBy(r.desc('startedAt'))
          .limit(50)
          .run(conn);
        const list = await cursor.toArray();
        res.json({ attempts: list });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    return router;
  },

  async stop() {
    if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null; }
  },
};

async function refreshIndex() {
  try {
    const res = await fetch(OTA_INDEX_URL, { timeout: 10_000 });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const json = await res.json();
    cachedIndex = { channels: json.channels || {}, fetchedAt: Date.now() };
  } catch (err) {
    log.warn({ err: err.message, url: OTA_INDEX_URL }, 'OTA index refresh failed');
  }
}

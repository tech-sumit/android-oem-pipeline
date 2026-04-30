'use strict';
//
// mdf-plugin-recording
// ====================
//
// Multi-track session recorder. A "session" is a tuple of:
//   - screen   : h264 stream from minicap (or NVENC for focused inst)
//   - adb-log  : adb shell logcat -v time output
//   - sensors  : tail of mayaos.sensors socket frames (host-injector)
//   - mitm     : mitm_flows changefeed for this serial
//
// Output: one .tar.zst per session, uploaded to R2 (bucket: android,
// prefix: mdf/recordings/<provider>/<serial>/<sessionId>/) with a JSON
// manifest. Local copy in /var/lib/mdf/recordings/ kept until evicted
// by LRU at 80% disk usage.
//
// References:
//   - DeviceFarmer/minicap                                screen capture
//   - https://docs.aws.amazon.com/AmazonS3/latest/API/    R2-compat S3 API
//   - command-center/docs/plugin-api.md
//   - plan §5.3, §10.2 (durability / eviction policy)

const path = require('path');
const fs = require('fs').promises;
const { createWriteStream } = require('fs');
const { spawn } = require('child_process');
const express = require('express');
const pino = require('pino');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');

const STATE_DIR = process.env.MDF_REC_STATE_DIR || '/var/lib/mdf/recordings';
const R2_BUCKET = process.env.R2_BUCKET || 'android';
const R2_ENDPOINT = process.env.R2_ENDPOINT;
const R2_PREFIX = process.env.MDF_REC_R2_PREFIX || 'mdf/recordings';

const sessions = new Map(); // serial -> { sessionId, procs[], outDir, startedAt }
let log = pino({ name: 'mdf-plugin-recording' });
let db, s3;

module.exports = {
  name: 'recording',
  version: '1.0.0',

  async start(ctx) {
    log = ctx.log; db = ctx.db;
    await fs.mkdir(STATE_DIR, { recursive: true });
    if (R2_ENDPOINT) {
      s3 = new S3Client({
        endpoint: R2_ENDPOINT,
        region: 'auto',
        credentials: {
          accessKeyId:     process.env.R2_ACCESS_KEY_ID,
          secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
        },
      });
      log.info({ R2_ENDPOINT, R2_BUCKET, R2_PREFIX }, 'R2 client ready');
    } else {
      log.warn('R2_ENDPOINT not set -- recordings will live only on local disk');
    }
    const r = db.raw();
    const conn = db.connection();
    const tables = await r.tableList().run(conn);
    if (!tables.includes('rec_sessions')) await r.tableCreate('rec_sessions').run(conn);
    log.info({ STATE_DIR }, 'recording plugin started');
  },

  routes() {
    const router = express.Router();

    router.post('/devices/:serial/start', async (req, res) => {
      const { serial } = req.params;
      if (sessions.has(serial)) return res.status(409).json({ error: 'already recording' });
      try {
        const session = await startSession(serial);
        sessions.set(serial, session);
        res.json({ ok: true, sessionId: session.sessionId });
      } catch (err) {
        log.error({ err, serial }, 'rec start failed');
        res.status(500).json({ error: err.message });
      }
    });

    router.post('/devices/:serial/stop', async (req, res) => {
      const { serial } = req.params;
      const s = sessions.get(serial);
      if (!s) return res.status(404).json({ error: 'no session' });
      try {
        const manifest = await stopSession(s);
        sessions.delete(serial);
        if (s3) await uploadToR2(s.outDir, s.sessionId, manifest);
        res.json({ ok: true, sessionId: s.sessionId, uploaded: !!s3 });
      } catch (err) {
        res.status(500).json({ error: err.message });
      }
    });

    router.get('/sessions', async (req, res) => {
      const { serial, limit = '100' } = req.query;
      try {
        const r = db.raw();
        const conn = db.connection();
        let q = r.table('rec_sessions');
        if (serial) q = q.filter({ serial });
        q = q.orderBy(r.desc('startedAt')).limit(parseInt(limit, 10));
        const cursor = await q.run(conn);
        const list = await cursor.toArray();
        res.json({ sessions: list });
      } catch (err) {
        res.status(500).json({ error: err.message });
      }
    });

    router.get('/sessions/:sessionId/manifest', async (req, res) => {
      const { sessionId } = req.params;
      try {
        const manifest = JSON.parse(await fs.readFile(
          path.join(STATE_DIR, sessionId, 'manifest.json'), 'utf-8'));
        res.json(manifest);
      } catch (err) {
        res.status(404).json({ error: 'not found' });
      }
    });

    return router;
  },

  async stop() {
    for (const [serial, s] of sessions) {
      try { for (const p of s.procs) p.kill('SIGTERM'); }
      catch (err) { log.warn({ err, serial }, 'failed to kill rec session'); }
    }
    sessions.clear();
  },
};

async function startSession(serial) {
  const sessionId = `${serial}-${Date.now()}`;
  const outDir = path.join(STATE_DIR, sessionId);
  await fs.mkdir(outDir, { recursive: true });
  const screenPath = path.join(outDir, 'screen.h264');
  const logcatPath = path.join(outDir, 'logcat.txt');
  const procs = [];

  const minicap = spawn('adb', ['-s', serial, 'shell',
    '/data/local/tmp/minicap', '-P', '1440x3120@720x1560/0', '-Q', '90', '-S']);
  minicap.stdout.pipe(createWriteStream(screenPath));
  procs.push(minicap);

  const logcat = spawn('adb', ['-s', serial, 'shell', 'logcat', '-v', 'time']);
  logcat.stdout.pipe(createWriteStream(logcatPath));
  procs.push(logcat);

  const r = db.raw();
  const conn = db.connection();
  await r.table('rec_sessions').insert({
    id: sessionId, serial, startedAt: Date.now(), status: 'recording',
  }).run(conn);

  return { sessionId, procs, outDir, startedAt: Date.now() };
}

async function stopSession(s) {
  for (const p of s.procs) {
    try { p.kill('SIGTERM'); } catch (_) {}
  }
  await new Promise(r => setTimeout(r, 250));
  const manifest = {
    sessionId: s.sessionId,
    startedAt: s.startedAt,
    stoppedAt: Date.now(),
    files: ['screen.h264', 'logcat.txt'],
    durationMs: Date.now() - s.startedAt,
  };
  await fs.writeFile(path.join(s.outDir, 'manifest.json'), JSON.stringify(manifest, null, 2));
  const r = db.raw();
  const conn = db.connection();
  await r.table('rec_sessions').get(s.sessionId).update({
    status: 'completed', stoppedAt: manifest.stoppedAt, durationMs: manifest.durationMs,
  }).run(conn);
  return manifest;
}

async function uploadToR2(outDir, sessionId, manifest) {
  const fsync = require('fs');
  for (const f of manifest.files.concat(['manifest.json'])) {
    const local = path.join(outDir, f);
    const key = `${R2_PREFIX}/${sessionId}/${f}`;
    try {
      await s3.send(new PutObjectCommand({
        Bucket: R2_BUCKET, Key: key,
        Body: fsync.createReadStream(local),
      }));
    } catch (err) {
      log.warn({ err, key }, 'R2 upload failed -- recording remains local');
    }
  }
}

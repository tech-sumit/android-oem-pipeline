'use strict';
//
// mdf-plugin-hvf-preview
// ======================
//
// Mac handoff: take an instance running on the RunPod TCG fleet and
// produce an artifact a developer can boot natively under HVF on their
// Apple Silicon Mac via the Android Studio Emulator. We do NOT live-
// migrate qemu (cross-arch is impossible); we instead:
//
//   1. Snapshot-quiesce the chosen instance (QMP `stop`).
//   2. Bundle the per-instance overlay.qcow2 + the AVD config.ini +
//      the build manifest into a tarball.
//   3. Upload to R2 with a short-lived (24h) signed URL.
//   4. Return the URL + a one-line `make hvf-attach IMG=<sha>` command
//      for the developer to copy-paste.
//
// On the developer's Mac, the same Makefile target downloads the
// tarball, expands it next to the matching system.img.qcow2 (also
// fetched if not present), and launches the Android Studio Emulator
// in HVF mode -- exactly the bring-up flow we already have for the
// arm64 emulator artifact.
//
// References:
//   - https://developer.apple.com/documentation/hypervisor
//   - https://developer.android.com/studio/run/emulator-acceleration
//   - command-center/docs/plugin-api.md
//   - plan §5.4

const path = require('path');
const fs = require('fs').promises;
const { exec } = require('child_process');
const express = require('express');
const pino = require('pino');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');

const STATE_DIR = process.env.MDF_HVF_STATE_DIR || '/var/lib/mdf/hvf';
const R2_BUCKET = process.env.R2_BUCKET || 'android';
const R2_ENDPOINT = process.env.R2_ENDPOINT;
const R2_PREFIX = process.env.MDF_HVF_R2_PREFIX || 'mdf/hvf-handoff';
const SIGN_TTL_SEC = parseInt(process.env.MDF_HVF_SIGN_TTL_SEC || '86400', 10);

let log = pino({ name: 'mdf-plugin-hvf-preview' });
let db, s3;

module.exports = {
  name: 'hvf-preview',
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
      log.warn('R2_ENDPOINT not set -- hvf-preview disabled');
    }
    const r = db.raw();
    const conn = db.connection();
    const tables = await r.tableList().run(conn);
    if (!tables.includes('hvf_handoffs')) await r.tableCreate('hvf_handoffs').run(conn);
    log.info({ STATE_DIR }, 'hvf-preview plugin started');
  },

  routes() {
    const router = express.Router();

    router.post('/devices/:serial/snapshot', async (req, res) => {
      if (!s3) return res.status(503).json({ error: 'R2 not configured' });
      const { serial } = req.params;
      const handoffId = `hvf-${serial}-${Date.now()}`;
      const tarball = path.join(STATE_DIR, `${handoffId}.tar`);
      try {
        await new Promise((resolve, reject) => exec(
          `qmp ${serial} stop && qmp ${serial} commit && ` +
          `tar -cf "${tarball}" -C /var/lib/mdf/instances/${serial} overlay.qcow2`,
          err => err ? reject(err) : resolve()
        ));
        const key = `${R2_PREFIX}/${handoffId}.tar`;
        const fsync = require('fs');
        await s3.send(new PutObjectCommand({
          Bucket: R2_BUCKET, Key: key,
          Body: fsync.createReadStream(tarball),
        }));
        const url = await getSignedUrl(s3,
          new GetObjectCommand({ Bucket: R2_BUCKET, Key: key }),
          { expiresIn: SIGN_TTL_SEC });
        const r = db.raw();
        const conn = db.connection();
        await r.table('hvf_handoffs').insert({
          id: handoffId, serial, key, ts: Date.now(),
          ttlSec: SIGN_TTL_SEC,
        }).run(conn);
        try { await fs.unlink(tarball); } catch (_) {}
        res.json({
          ok: true,
          handoffId,
          url,
          attachCommand: `make hvf-attach IMG=${handoffId}`,
          ttlSec: SIGN_TTL_SEC,
        });
      } catch (err) {
        log.error({ err, serial }, 'hvf snapshot failed');
        res.status(500).json({ error: err.message });
      }
    });

    router.get('/handoffs', async (req, res) => {
      try {
        const r = db.raw();
        const conn = db.connection();
        const cursor = await r.table('hvf_handoffs')
          .orderBy(r.desc('ts'))
          .limit(50)
          .run(conn);
        const list = await cursor.toArray();
        res.json({ handoffs: list });
      } catch (err) { res.status(500).json({ error: err.message }); }
    });

    return router;
  },

  async stop() { /* nothing to clean up */ },
};

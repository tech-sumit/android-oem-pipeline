'use strict';
//
// AdbHelper
// =========
//
// Wraps adbkit to provide the operations the provider needs:
//   - waitForDevice(serial, timeout)           wait for boot_completed
//   - pushAgents(serial)                       minicap + minitouch + STFService
//   - install(serial, apkPath)                 pm install
//   - uninstall(serial, pkg)                   pm uninstall
//
// Pushes the on-device blobs that STF + MDF need:
//   - /data/local/tmp/minicap          + minicap.so       (DeviceFarmer/minicap)
//   - /data/local/tmp/minitouch                            (DeviceFarmer/minitouch)
//   - install STFService.apk                               (DeviceFarmer/STFService.apk)
//
// These are baked into the MayaOS vendor partition by §3 of the plan,
// but re-pushing on first connect is idempotent and lets us also
// upgrade them from the host without an OTA.

const path = require('path');
const fs = require('fs').promises;
const adbkit = require('adbkit');

const AGENT_DIR = '/opt/mdf/agents';     // mounted from /var/lib/mdf/agents

class AdbHelper {
  constructor({ log }) {
    this.log = log;
    this.client = adbkit.createClient();
  }

  async waitForDevice(serial, timeoutMs = 60_000) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      try {
        const devices = await this.client.listDevices();
        const found = devices.find(d => d.id === serial && d.type === 'device');
        if (found) {
          const out = await this._exec(serial, ['getprop', 'sys.boot_completed']);
          if (out.trim() === '1') return true;
        }
      } catch (_) { /* not ready */ }
      await new Promise(r => setTimeout(r, 1000));
    }
    throw new Error(`timeout waiting for device ${serial}`);
  }

  async pushAgents(serial) {
    const blobs = [
      { src: path.join(AGENT_DIR, 'minicap'),    dst: '/data/local/tmp/minicap',    mode: 0o755 },
      { src: path.join(AGENT_DIR, 'minicap.so'), dst: '/data/local/tmp/minicap.so', mode: 0o644 },
      { src: path.join(AGENT_DIR, 'minitouch'),  dst: '/data/local/tmp/minitouch',  mode: 0o755 },
    ];
    for (const b of blobs) {
      try {
        const exists = await this._exists(b.src);
        if (!exists) { this.log.warn({ src: b.src }, 'agent blob missing -- baked into vendor partition?'); continue; }
        const stream = await this.client.push(serial, b.src, b.dst, b.mode);
        await new Promise((resolve, reject) => stream.on('end', resolve).on('error', reject));
      } catch (err) {
        this.log.warn({ err, src: b.src, dst: b.dst }, 'failed to push agent');
      }
    }
    const apk = path.join(AGENT_DIR, 'STFService.apk');
    if (await this._exists(apk)) {
      try { await this.client.install(serial, apk); }
      catch (err) { this.log.warn({ err, apk }, 'STFService install failed'); }
    }
    try { await this._exec(serial, ['am', 'startservice', '-n', 'jp.co.cyberagent.stf/.Service']); }
    catch (_) { /* fine on cold boot */ }
  }

  async install(serial, apkPath) {
    return this.client.install(serial, apkPath);
  }

  async uninstall(serial, pkg) {
    return this.client.uninstall(serial, pkg);
  }

  async _exec(serial, argv) {
    const stream = await this.client.shell(serial, argv);
    return new Promise((resolve, reject) => {
      const chunks = [];
      stream.on('data', c => chunks.push(c));
      stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf-8')));
      stream.on('error', reject);
    });
  }

  async _exists(p) { try { await fs.access(p); return true; } catch { return false; } }
}

module.exports = AdbHelper;

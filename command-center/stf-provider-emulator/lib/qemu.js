'use strict';
//
// QemuInstance
// ============
//
// Owns the lifecycle of a single qemu-system-x86_64 process running
// the MayaOS emulator x86_64 image. Implements the cold-boot path
// (Phase 4) and the snapshot-restore warm path (Phase 5e + §6.5.1).
//
// QEMU CLI rationale (locked in plan §6.5):
//   -accel tcg,thread=multi,tb-size=512   §6.5.5  shared-image multi-thread TCG
//   -smp cores=4                          §6.5    enough vCPUs for boot, stays cool at idle
//   -m 1536                               §6.5    1.5 GB; KSM dedupes ~60% across instances
//   -mem-prealloc -mem-path /dev/hugepages §6.5.4 hugepages backing
//   -gpu host -device virtio-gpu-gl       §6.5.2  gfxstream / A6000 passthrough
//   -netdev user,...                      §6.5.5  passt later replaces this
//   -snapshot                             dev-only; instance-dir overlays in prod
//   -drive ...,file=system.qcow2,...,readonly=on  §6.5.4 RO base + RW overlay
//   -drive ...,file=overlay.qcow2,...    per-instance overlay (cheap, ~50 MB)
//
// QMP control socket lets warmpool plugin issue snapshot-load /
// snapshot-save commands at runtime.

const path = require('path');
const fs = require('fs').promises;
const { spawn } = require('child_process');
const net = require('net');
const { EventEmitter } = require('events');

class QemuInstance extends EventEmitter {
  constructor({ log, instanceId, imageDir, instanceDir, adbPort, vncPort, qmpPort }) {
    super();
    this.log = log;
    this.instanceId = instanceId;
    this.imageDir = imageDir;
    this.instanceDir = instanceDir;
    this.adbPort = adbPort;
    this.vncPort = vncPort;
    this.qmpPort = qmpPort;
    this.proc = null;
    this.state = 'idle';   // idle | booting | running | shutting-down
  }

  async boot({ snapshot } = {}) {
    if (this.state !== 'idle') throw new Error(`cannot boot: state=${this.state}`);
    this.state = 'booting';
    await fs.mkdir(this.instanceDir, { recursive: true });

    const overlay = path.join(this.instanceDir, 'overlay.qcow2');
    const baseImg = path.join(this.imageDir, 'system.qcow2');

    if (!await this._exists(overlay)) {
      this.log.info({ baseImg, overlay }, 'creating per-instance qcow2 overlay');
      await this._run('qemu-img', [
        'create', '-f', 'qcow2',
        '-b', baseImg, '-F', 'qcow2',
        overlay,
      ]);
    }

    const cdrom = path.join(this.imageDir, 'mayaos-config.iso');
    const args = [
      '-name', this.instanceId,
      '-cpu', 'qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt',
      '-smp', 'cores=4,threads=1,sockets=1',
      '-m', '1536',
      '-accel', 'tcg,thread=multi,tb-size=512',
      '-machine', 'q35',
      '-device', 'qemu-xhci',
      '-device', 'virtio-gpu-gl',
      '-display', 'vnc=:' + (this.vncPort - 5900) + ',gl=on',
      '-netdev', `user,id=net0,hostfwd=tcp::${this.adbPort}-:5555`,
      '-device', 'virtio-net-pci,netdev=net0',
      '-drive', `file=${overlay},if=virtio,cache=writeback,format=qcow2`,
      '-qmp', `tcp:127.0.0.1:${this.qmpPort},server,nowait`,
      '-monitor', 'none',
      '-no-reboot',
    ];
    if (await this._exists(cdrom)) args.push('-cdrom', cdrom);
    if (snapshot) args.push('-loadvm', snapshot);

    this.log.info({ args }, 'spawning qemu');
    this.proc = spawn('qemu-system-x86_64', args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: false,
    });
    this.proc.stdout.on('data', d => this.log.debug({ qemu: d.toString().trim() }));
    this.proc.stderr.on('data', d => this.log.warn({ qemu: d.toString().trim() }));
    this.proc.on('exit', (code, signal) => {
      this.log.warn({ code, signal }, 'qemu exited');
      this.state = 'idle';
      this.emit('exit', { code, signal });
    });
    this.state = 'running';
    return { adbPort: this.adbPort, vncPort: this.vncPort };
  }

  async restart() {
    await this.shutdown();
    await new Promise(r => setTimeout(r, 250));
    await this.boot();
  }

  async factoryReset() {
    await this.shutdown();
    const overlay = path.join(this.instanceDir, 'overlay.qcow2');
    try { await fs.unlink(overlay); } catch (_) {}
    await this.boot();
  }

  async shutdown() {
    if (this.state === 'idle') return;
    this.state = 'shutting-down';
    try {
      await this._qmp({ execute: 'system_powerdown' });
      await this._waitExit(5000);
    } catch (err) {
      this.log.warn({ err }, 'graceful shutdown failed; SIGTERM');
    } finally {
      if (this.proc && !this.proc.killed) {
        this.proc.kill('SIGTERM');
        try { await this._waitExit(3000); } catch (_) { this.proc.kill('SIGKILL'); }
      }
      this.proc = null;
      this.state = 'idle';
    }
  }

  async snapshot(name = 'warm') {
    return this._qmp({ execute: 'savevm', arguments: { name } });
  }

  async loadSnapshot(name = 'warm') {
    return this._qmp({ execute: 'loadvm', arguments: { name } });
  }

  async _qmp(cmd) {
    return new Promise((resolve, reject) => {
      const sock = net.connect(this.qmpPort, '127.0.0.1');
      let buf = '';
      sock.on('data', chunk => {
        buf += chunk.toString();
        if (buf.includes('"QMP"')) {
          sock.write(JSON.stringify({ execute: 'qmp_capabilities' }) + '\n');
          sock.write(JSON.stringify(cmd) + '\n');
        }
        if (buf.includes('"return"')) { sock.end(); resolve(buf); }
        if (buf.includes('"error"'))  { sock.end(); reject(new Error(buf)); }
      });
      sock.on('error', reject);
      setTimeout(() => { sock.destroy(); reject(new Error('qmp timeout')); }, 5000);
    });
  }

  _waitExit(ms) {
    return new Promise((resolve, reject) => {
      if (!this.proc) return resolve();
      const t = setTimeout(() => reject(new Error('exit timeout')), ms);
      this.proc.once('exit', () => { clearTimeout(t); resolve(); });
    });
  }

  async _exists(p) { try { await fs.access(p); return true; } catch { return false; } }

  _run(cmd, args) {
    return new Promise((resolve, reject) => {
      const c = spawn(cmd, args, { stdio: 'inherit' });
      c.on('exit', code => code === 0 ? resolve() : reject(new Error(`${cmd} exit ${code}`)));
      c.on('error', reject);
    });
  }
}

module.exports = QemuInstance;

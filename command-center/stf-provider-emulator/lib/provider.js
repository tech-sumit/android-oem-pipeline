'use strict';
//
// stf-provider-emulator
// =====================
//
// MDF's custom STF provider. STF's stock providers (`stf provider`,
// `stf-provider-android`) assume the worker host has a USB-attached
// physical device and ADB has already enumerated it. We don't have
// that — we have N qemu emulator instances we boot ourselves on
// demand. This file is the orchestrator that:
//
//   1. Boots `--fleet-size` qemu emulator processes against the
//      MayaOS base system.img.
//   2. Waits for each emulator's ADB endpoint to come up
//      (`adbkit.waitForDevice`).
//   3. Pushes minicap + minitouch + STFService.apk onto the device
//      using the same recipes STF's setup uses.
//   4. Registers each device with STF over its ZMQ wire bus using
//      the `DeviceIntroductionMessage` / `DevicePresentMessage`
//      protobuf wire types.
//   5. Loads every `mdf-plugin-*` package from --plugin-dir and
//      mounts its routes / websockets / topics.
//   6. Maintains liveness: if a qemu instance dies, restart it from
//      the warm pool snapshot (or cold-boot if pool empty).
//
// References:
//   - DeviceFarmer/stf:                  ZMQ wire format + provider proto
//   - DeviceFarmer/minicap:              screen capture binary
//   - DeviceFarmer/minitouch:            multitouch input binary
//   - DeviceFarmer/STFService.apk:       on-device agent
//   - command-center/docs/plugin-api.md: plugin contract

const path = require('path');
const fs = require('fs').promises;
const fssync = require('fs');
const { EventEmitter } = require('events');
const express = require('express');
const { WebSocketServer } = require('ws');
const pino = require('pino');
const Wire = require('./wire');
const Plugins = require('./plugins');
const QemuInstance = require('./qemu');
const AdbHelper = require('./adb');
const RethinkClient = require('./rethink');

class Provider extends EventEmitter {
  constructor(argv) {
    super();
    this.argv = argv;
    this.log = pino({ name: 'stf-provider-emulator', level: process.env.LOG_LEVEL || 'info' });
    this.instances = new Map();      // serial -> QemuInstance
    this.wire = new Wire({ log: this.log, sub: argv['connect-sub'], push: argv['connect-push'] });
    this.adb = new AdbHelper({ log: this.log });
    this.rest = express();
    this.rest.use(express.json({ limit: '4mb' }));
    this.wss = null;
    this.plugins = new Plugins({
      log: this.log,
      provider: this,
      pluginDir: argv['plugin-dir'],
    });
    this.db = new RethinkClient({ log: this.log });
  }

  async start() {
    this.log.info({ argv: this.argv }, 'starting MDF provider');

    await fs.mkdir(this.argv['instance-dir'], { recursive: true });
    if (!fssync.existsSync(this.argv['image-dir'])) {
      this.log.warn({ dir: this.argv['image-dir'] }, 'image-dir missing -- create it before booting');
    }

    await this.db.connectWithRetry();
    await this.db.ensureSchema();

    await this.wire.connect();
    await this.wire.announceProvider({
      name: this.argv.provider,
      ip: this.argv['public-ip'],
      capacity: this.argv['fleet-size'],
    });

    await this.plugins.discover();
    await this.plugins.start({ db: this.db, wire: this.wire });

    this.plugins.mountRoutes(this.rest);
    const restServer = this.rest.listen(this.argv['rest-port']);
    this.wss = new WebSocketServer({ port: this.argv['ws-port'], path: '/mdf-ws/' });
    this.plugins.mountWebsockets(this.wss);
    this.log.info({
      rest: this.argv['rest-port'],
      ws: this.argv['ws-port']
    }, 'plugin REST/WS endpoints up');

    for (let i = 0; i < this.argv['fleet-size']; i++) {
      const ports = this._allocatePorts(i);
      const instanceId = `mdf-${this.argv.provider}-${i.toString().padStart(3, '0')}`;
      const qemu = new QemuInstance({
        log: this.log.child({ instanceId }),
        instanceId,
        imageDir: this.argv['image-dir'],
        instanceDir: path.join(this.argv['instance-dir'], instanceId),
        adbPort: ports.adb,
        vncPort: ports.vnc,
        qmpPort: ports.qmp,
      });
      await qemu.boot();
      const serial = `emulator-${ports.adb}`;
      this.instances.set(serial, qemu);

      try {
        await this.adb.waitForDevice(serial, 120_000);
        await this.adb.pushAgents(serial);
        await this.wire.announceDevice({
          serial,
          provider: this.argv.provider,
          model: 'Galaxy S26 Ultra',
          manufacturer: 'samsung',
          version: '16',
          sdk: 36,
          abi: 'x86_64',
          status: 'present',
        });
      } catch (err) {
        this.log.error({ err, serial }, 'failed to bring instance online');
      }
    }

    this.wire.on('control', msg => this._onControl(msg));

    this.log.info({ count: this.instances.size }, 'provider online');
    this._restServer = restServer;
  }

  _allocatePorts(i) {
    return {
      adb: this.argv['first-adb-port'] + (i * 2),
      vnc: this.argv['first-vnc-port'] + i,
      qmp: this.argv['first-qmp-port'] + i,
    };
  }

  async _onControl(msg) {
    const { serial, action, payload } = msg;
    const instance = this.instances.get(serial);
    if (!instance) {
      this.log.warn({ serial, action }, 'control message for unknown instance');
      return;
    }
    try {
      switch (action) {
        case 'restart':       await instance.restart();                         break;
        case 'factory-reset': await instance.factoryReset();                    break;
        case 'shutdown':      await instance.shutdown();                        break;
        case 'install':       await this.adb.install(serial, payload.apk);      break;
        case 'uninstall':     await this.adb.uninstall(serial, payload.pkg);    break;
        default:
          this.log.warn({ serial, action }, 'unknown control action');
      }
    } catch (err) {
      this.log.error({ err, serial, action }, 'control action failed');
    }
  }

  async stop() {
    this.log.info('stopping');
    if (this.wss) this.wss.close();
    if (this._restServer) this._restServer.close();
    await Promise.all([...this.instances.values()].map(i => i.shutdown().catch(() => {})));
    await this.plugins.stop();
    await this.wire.close();
    await this.db.close();
  }
}

module.exports = Provider;

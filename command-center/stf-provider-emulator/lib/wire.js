'use strict';
//
// Wire
// ====
//
// Thin wrapper around STF's ZeroMQ wire bus. STF uses two sockets per
// participant:
//   - SUB on tcp://triproxy:7150 (we connect to provider-side
//     tcp://triproxy:7160 here as the canonical SUB endpoint).
//   - PUSH on tcp://triproxy:7170 (where we publish our messages).
//
// Each message is a `wire.Envelope` (protobuf): { type, channel, message }.
// We use a JSON-friendly subset for our control plane and let STF's
// existing processor route the protobuf-shaped DeviceIntroduction /
// DevicePresent messages to the app.
//
// References:
//   - stf/lib/wire/wire.proto
//   - stf/lib/units/triproxy/index.js
//   - stf/lib/units/provider/index.js (canonical example of registering)

const { Subscriber, Push } = require('zeromq');
const { EventEmitter } = require('events');

const TOPIC = {
  PROVIDER:  Buffer.from('p'),  // provider announcements
  DEVICE:    Buffer.from('d'),  // device announcements
  CONTROL:   Buffer.from('c'),  // control plane (UI -> provider)
  EVENT:     Buffer.from('e'),  // generic events
};

class Wire extends EventEmitter {
  constructor({ log, sub, push }) {
    super();
    this.log = log;
    this.subEndpoint = sub;
    this.pushEndpoint = push;
    this.sub = null;
    this.push = null;
    this._loop = null;
  }

  async connect() {
    this.push = new Push({ sendTimeout: 1000 });
    this.push.connect(this.pushEndpoint);

    this.sub = new Subscriber({ receiveTimeout: -1 });
    this.sub.connect(this.subEndpoint);
    this.sub.subscribe(TOPIC.CONTROL);
    this.sub.subscribe(TOPIC.EVENT);

    this._loop = (async () => {
      for await (const [topic, payload] of this.sub) {
        try {
          const msg = JSON.parse(payload.toString('utf-8'));
          if (topic.equals(TOPIC.CONTROL)) this.emit('control', msg);
          else                              this.emit('event', msg);
        } catch (err) {
          this.log.warn({ err, topic: topic.toString() }, 'malformed wire frame');
        }
      }
    })().catch(err => this.log.error({ err }, 'sub loop crashed'));
    this.log.info({ sub: this.subEndpoint, push: this.pushEndpoint }, 'wire connected');
  }

  async announceProvider({ name, ip, capacity }) {
    return this._send(TOPIC.PROVIDER, {
      type: 'ProviderHeartbeatMessage',
      v: 1, name, ip, capacity, ts: Date.now(),
    });
  }

  async announceDevice({ serial, provider, model, manufacturer, version, sdk, abi, status }) {
    return this._send(TOPIC.DEVICE, {
      type: 'DevicePresentMessage',
      v: 1, serial, provider,
      properties: { model, manufacturer, version, sdk: String(sdk), abi },
      status, ts: Date.now(),
    });
  }

  async _send(topic, payload) {
    const buf = Buffer.from(JSON.stringify(payload), 'utf-8');
    await this.push.send([topic, buf]);
  }

  async close() {
    if (this.sub)  { await this.sub.close().catch(() => {});  this.sub = null; }
    if (this.push) { await this.push.close().catch(() => {}); this.push = null; }
  }
}

Wire.TOPIC = TOPIC;
module.exports = Wire;

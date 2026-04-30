#!/usr/bin/env node
'use strict';
const path = require('path');
const yargs = require('yargs');
const Provider = require('../lib/provider');

const argv = yargs
  .option('connect-sub',  { type: 'string', demandOption: true, describe: 'STF wire SUB endpoint (tcp://host:7160)' })
  .option('connect-push', { type: 'string', demandOption: true, describe: 'STF wire PUSH endpoint (tcp://host:7170)' })
  .option('provider',     { type: 'string', demandOption: true, describe: 'Provider name registered with STF' })
  .option('public-ip',    { type: 'string', demandOption: true, describe: 'Public IP devices advertise to clients' })
  .option('fleet-size',   { type: 'number', default: 1,         describe: 'Number of qemu instances to boot' })
  .option('image-dir',    { type: 'string', default: '/srv/mayaos-images', describe: 'Where the read-only base system.img lives' })
  .option('instance-dir', { type: 'string', default: '/var/lib/mdf/instances', describe: 'Per-instance qcow2 + state' })
  .option('plugin-dir',   { type: 'string', default: path.resolve(__dirname, '../..'), describe: 'Where to discover mdf-plugin-* packages' })
  .option('rest-port',    { type: 'number', default: 7180,      describe: 'Port for /mdf REST namespace' })
  .option('ws-port',      { type: 'number', default: 7181,      describe: 'Port for /mdf-ws/ websocket' })
  .option('first-adb-port', { type: 'number', default: 5554,    describe: 'First ADB port; even=device, odd=auth' })
  .option('first-vnc-port', { type: 'number', default: 5900,    describe: 'First VNC port for hvf-preview/recording' })
  .option('first-qmp-port', { type: 'number', default: 4444,    describe: 'First QMP control socket port (qemu)' })
  .strict()
  .help()
  .argv;

const provider = new Provider(argv);

async function shutdown(signal) {
  provider.log.warn({ signal }, 'received shutdown signal');
  try { await provider.stop(); } finally { process.exit(0); }
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('uncaughtException', err => {
  provider.log.fatal({ err }, 'uncaughtException');
  process.exit(1);
});
process.on('unhandledRejection', reason => {
  provider.log.fatal({ reason }, 'unhandledRejection');
  process.exit(1);
});

provider.start().catch(err => {
  provider.log.fatal({ err }, 'provider failed to start');
  process.exit(1);
});

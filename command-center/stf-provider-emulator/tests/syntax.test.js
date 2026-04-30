'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');

function syntaxCheck(rel) {
  const file = path.join(ROOT, rel);
  execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
}

test('bin/provider.js parses', () => syntaxCheck('bin/provider.js'));
test('lib/provider.js parses', () => syntaxCheck('lib/provider.js'));
test('lib/qemu.js parses',     () => syntaxCheck('lib/qemu.js'));
test('lib/wire.js parses',     () => syntaxCheck('lib/wire.js'));
test('lib/adb.js parses',      () => syntaxCheck('lib/adb.js'));
test('lib/plugins.js parses',  () => syntaxCheck('lib/plugins.js'));
test('lib/rethink.js parses',  () => syntaxCheck('lib/rethink.js'));

test('Wire.TOPIC has the expected channels', () => {
  const Wire = require('../lib/wire');
  assert.ok(Wire.TOPIC.PROVIDER, 'PROVIDER topic present');
  assert.ok(Wire.TOPIC.DEVICE,   'DEVICE topic present');
  assert.ok(Wire.TOPIC.CONTROL,  'CONTROL topic present');
  assert.ok(Wire.TOPIC.EVENT,    'EVENT topic present');
});

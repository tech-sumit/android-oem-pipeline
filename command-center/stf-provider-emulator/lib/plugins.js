'use strict';
//
// Plugins
// =======
//
// Discover, load, start and lifecycle every `mdf-plugin-*` package
// inside `--plugin-dir`. Each plugin must export the API documented
// in command-center/docs/plugin-api.md. We never bind plugin lifetimes
// to the qemu instance lifetimes -- they outlive any single instance.
//
// Discovery rules:
//   - directory name MUST match `mdf-plugin-*`
//   - directory MUST contain index.js with module.exports per the
//     contract.
//   - missing optional fields (websockets, subscribe, ...) are no-ops.

const path = require('path');
const fs = require('fs').promises;

class Plugins {
  constructor({ log, provider, pluginDir }) {
    this.log = log.child({ scope: 'plugins' });
    this.provider = provider;
    this.pluginDir = pluginDir;
    this.loaded = [];      // [{ mod, dir }]
  }

  async discover() {
    const entries = await fs.readdir(this.pluginDir, { withFileTypes: true });
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      if (!e.name.startsWith('mdf-plugin-')) continue;
      const dir = path.join(this.pluginDir, e.name);
      const idx = path.join(dir, 'index.js');
      try {
        await fs.access(idx);
      } catch (_) {
        this.log.warn({ dir }, 'plugin missing index.js -- skipping');
        continue;
      }
      try {
        const mod = require(idx);
        if (!mod || !mod.name) {
          this.log.warn({ dir }, 'plugin missing module.exports.name -- skipping');
          continue;
        }
        this.loaded.push({ mod, dir });
        this.log.info({ name: mod.name, dir }, 'plugin discovered');
      } catch (err) {
        this.log.error({ err, dir }, 'failed to require plugin');
      }
    }
  }

  async start(ctx) {
    for (const { mod } of this.loaded) {
      if (typeof mod.start !== 'function') continue;
      try {
        await mod.start({
          log: this.log.child({ plugin: mod.name }),
          db: ctx.db,
          wire: ctx.wire,
          provider: this.provider,
        });
        if (typeof mod.subscribe === 'function') mod.subscribe(ctx.wire);
        this.log.info({ name: mod.name }, 'plugin started');
      } catch (err) {
        this.log.error({ err, name: mod.name }, 'plugin start failed');
      }
    }
  }

  mountRoutes(app) {
    for (const { mod } of this.loaded) {
      if (typeof mod.routes !== 'function') continue;
      try {
        const router = mod.routes(app);
        if (router) app.use(`/mdf/${mod.name}`, router);
        this.log.info({ name: mod.name }, 'plugin routes mounted');
      } catch (err) {
        this.log.error({ err, name: mod.name }, 'plugin routes failed');
      }
    }
  }

  mountWebsockets(wss) {
    for (const { mod } of this.loaded) {
      if (typeof mod.websockets !== 'function') continue;
      try { mod.websockets(wss); }
      catch (err) { this.log.error({ err, name: mod.name }, 'plugin websockets failed'); }
    }
  }

  async stop() {
    for (const { mod } of this.loaded) {
      if (typeof mod.stop !== 'function') continue;
      try { await mod.stop(); } catch (err) { this.log.error({ err, name: mod.name }, 'plugin stop failed'); }
    }
  }
}

module.exports = Plugins;

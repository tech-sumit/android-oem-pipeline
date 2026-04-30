'use strict';
//
// RethinkClient
// =============
//
// Owns the connection to the RethinkDB cluster and creates the `mdf`
// database + plugin tables on first boot. Every plugin should obtain
// its own connection via getConnection() and re-use; we don't pool here
// because rethinkdb's official driver pools internally per-connection.

const r = require('rethinkdb');

const TABLES = [
  // Created by plugins themselves at start(). We just ensure the db.
];

class RethinkClient {
  constructor({ log, host, port } = {}) {
    this.log = log.child({ scope: 'rethink' });
    this.host = host || process.env.RETHINKDB_PORT_28015_TCP_ADDR || '127.0.0.1';
    this.port = parseInt(port || process.env.RETHINKDB_PORT_28015_TCP_PORT || '28015', 10);
    this.conn = null;
  }

  async connectWithRetry({ tries = 30, delayMs = 1000 } = {}) {
    for (let i = 0; i < tries; i++) {
      try {
        this.conn = await r.connect({ host: this.host, port: this.port, db: 'mdf' });
        this.log.info({ host: this.host, port: this.port }, 'rethink connected');
        return this.conn;
      } catch (err) {
        if (i === tries - 1) throw err;
        await new Promise(res => setTimeout(res, delayMs));
      }
    }
  }

  async ensureSchema() {
    const dbs = await r.dbList().run(this.conn);
    if (!dbs.includes('mdf')) {
      this.log.info('creating mdf database');
      await r.dbCreate('mdf').run(this.conn);
      this.conn.use('mdf');
    } else {
      this.conn.use('mdf');
    }
    for (const t of TABLES) {
      const exists = await r.tableList().run(this.conn);
      if (!exists.includes(t)) {
        this.log.info({ table: t }, 'creating table');
        await r.tableCreate(t).run(this.conn);
      }
    }
  }

  raw() { return r; }
  connection() { return this.conn; }

  async close() { if (this.conn) await this.conn.close(); this.conn = null; }
}

module.exports = RethinkClient;

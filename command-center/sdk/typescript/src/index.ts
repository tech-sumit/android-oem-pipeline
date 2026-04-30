/**
 * MayaOS Device Farm SDK (TypeScript).
 *
 * Lightweight client for the MDF REST API. Uses native `fetch` (Node 18+
 * + browsers + Deno + Bun). Auth is the same Cloudflare Access JWT the
 * operator UI uses; pass it via `accessToken` or `MDF_ACCESS_TOKEN`.
 *
 * @example
 * ```ts
 * import { Client } from "@mayaos/devicefarm";
 * const mdf = new Client("https://mdf-pod-eu-de-0.mdf.mayaos.dev");
 * const serial = await mdf.warmpool.checkout();
 * await mdf.shell(serial, "input keyevent KEYCODE_HOME");
 * await mdf.warmpool.checkin(serial);
 * ```
 */

export interface Device {
  serial: string;
  model: string;
  channel: string;
  status: string;
}

export interface MitmFlow {
  id: string;
  serial: string;
  ts: number;
  phase: "request" | "response";
  method: string;
  url: string;
  headers: Record<string, string>;
  body_len: number;
  status?: number;
}

export interface InterceptRule {
  when: "request" | "response";
  match: { host?: string; path?: string; method?: string };
  action: {
    kill?: boolean;
    set_header?: Record<string, string>;
    replace_body?: string;
    set_status?: number;
  };
}

export interface ClientOptions {
  accessToken?: string;
  timeoutMs?: number;
  fetch?: typeof globalThis.fetch;
}

export class MdfApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly method: string,
    public readonly path: string,
    public readonly body: string,
  ) {
    super(`MDF ${method} ${path} -> ${status}: ${body}`);
    this.name = "MdfApiError";
  }
}

export class Client {
  private readonly base: string;
  private readonly token: string;
  private readonly timeoutMs: number;
  private readonly fetcher: typeof globalThis.fetch;

  readonly warmpool:  Warmpool;
  readonly mitm:      Mitm;
  readonly recording: Recording;
  readonly ota:       Ota;
  readonly hvf:       Hvf;

  constructor(baseUrl: string, opts: ClientOptions = {}) {
    this.base = baseUrl.replace(/\/+$/, "");
    this.token = opts.accessToken ?? process.env.MDF_ACCESS_TOKEN ?? "";
    this.timeoutMs = opts.timeoutMs ?? 30_000;
    this.fetcher = opts.fetch ?? globalThis.fetch;
    this.warmpool  = new Warmpool(this);
    this.mitm      = new Mitm(this);
    this.recording = new Recording(this);
    this.ota       = new Ota(this);
    this.hvf       = new Hvf(this);
  }

  async _request<T = unknown>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    const headers: Record<string, string> = {
      "User-Agent": "@mayaos/devicefarm/1.0.0",
      "Content-Type": "application/json",
    };
    if (this.token) headers["cf-access-token"] = this.token;
    try {
      const resp = await this.fetcher(this.base + path, {
        method,
        headers,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
      const text = await resp.text();
      if (!resp.ok) throw new MdfApiError(resp.status, method, path, text);
      return text ? (JSON.parse(text) as T) : ({} as T);
    } finally {
      clearTimeout(timer);
    }
  }

  async devices(): Promise<Device[]> {
    const resp = await this._request<{ devices: Device[] }>("GET", "/api/v1/devices");
    return resp.devices ?? [];
  }

  async shell(serial: string, cmd: string | string[]): Promise<string> {
    const c = Array.isArray(cmd) ? cmd.join(" ") : cmd;
    const resp = await this._request<{ stdout: string }>(
      "POST", `/api/v1/devices/${serial}/shell`, { cmd: c });
    return resp.stdout ?? "";
  }
}

class Warmpool {
  constructor(private readonly c: Client) {}
  async checkout(timeoutMs = 5_000): Promise<string> {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      try {
        const r = await this.c._request<{ serial: string }>("POST", "/mdf/warmpool/checkout");
        return r.serial;
      } catch (err) {
        if (err instanceof MdfApiError && err.status === 503) {
          await new Promise(r => setTimeout(r, 500));
          continue;
        }
        throw err;
      }
    }
    throw new Error("warmpool checkout timed out");
  }
  async checkin(serial: string): Promise<void> {
    await this.c._request("POST", `/mdf/warmpool/checkin/${serial}`);
  }
  async poolSize(size: number): Promise<void> {
    await this.c._request("POST", "/mdf/warmpool/pool/size", { size });
  }
}

class Mitm {
  constructor(private readonly c: Client) {}
  async start(serial: string)  { return this.c._request("POST", `/mdf/mitm/devices/${serial}/start`); }
  async stop(serial: string)   { return this.c._request("POST", `/mdf/mitm/devices/${serial}/stop`); }
  async flows(serial: string, limit = 200): Promise<MitmFlow[]> {
    const r = await this.c._request<{ flows: MitmFlow[] }>(
      "GET", `/mdf/mitm/devices/${serial}/flows?limit=${limit}`);
    return r.flows ?? [];
  }
  async addRule(serial: string, rule: InterceptRule): Promise<void> {
    await this.c._request("POST", `/mdf/mitm/devices/${serial}/intercept-rule`, rule);
  }
}

class Recording {
  constructor(private readonly c: Client) {}
  async start(serial: string)  { return this.c._request("POST", `/mdf/recording/devices/${serial}/start`); }
  async stop(serial: string)   { return this.c._request("POST", `/mdf/recording/devices/${serial}/stop`); }
}

class Ota {
  constructor(private readonly c: Client) {}
  async channels()                          { return this.c._request("GET",  "/mdf/ota-channel/channels"); }
  async pin(serial: string, channel: string){ return this.c._request("POST", `/mdf/ota-channel/devices/${serial}/channel`, { channel }); }
  async checkNow(serial: string)            { return this.c._request("POST", `/mdf/ota-channel/devices/${serial}/check-now`); }
}

class Hvf {
  constructor(private readonly c: Client) {}
  async snapshot(serial: string)            { return this.c._request("POST", `/mdf/hvf-preview/devices/${serial}/snapshot`); }
}

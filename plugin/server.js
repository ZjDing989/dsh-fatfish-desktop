import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomBytes, timingSafeEqual } from 'node:crypto';

const VERSION = 1;
const json = (res, status, value) => {
  const body = JSON.stringify(value);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(body);
};
const local = remote => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote);
const equal = (a, b) => { const left = Buffer.from(a ?? ''); const right = Buffer.from(b); return left.length === right.length && timingSafeEqual(left, right); };
async function readBody(req) {
  let size = 0;
  const parts = [];
  for await (const part of req) {
    size += part.length;
    if (size > 16384) throw new Error('body-too-large');
    parts.push(part);
  }
  const value = JSON.parse(Buffer.concat(parts).toString('utf8') || '{}');
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('bad-body');
  return value;
}

/** Loopback-only private bridge. The token is never exposed by an HTTP bootstrap endpoint. */
export async function createBridgeServer({ port = 0, discoveryPath = path.join(os.homedir(), '.dsh', 'fatfish-bridge.json'), profile = 'desktop', getSnapshot, isSession, logger = console, origins = [] } = {}) {
  const token = randomBytes(32).toString('hex');
  const startedAt = Date.now();
  const allowedOrigins = new Set(origins);
  let stopped = false;
  let lastPollAt = 0;
  let seq = 0;
  let activeSessionId = null;
  let lastAction = null;
  const commands = new Map();
  const sockets = new Set();
  const clientConnected = () => Date.now() - lastPollAt < 5000 && lastPollAt > 0;
  const snapshot = () => {
    let base;
    try { base = getSnapshot?.() ?? { tasks: [], recent: [], pet: { state: 'idle', label: '待机' } }; }
    catch { base = { tasks: [], recent: [], pet: { state: 'idle', label: '状态暂不可用' }, degraded: true }; }
    return { v: VERSION, ts: Date.now(), host: { pid: process.pid, uptimeMs: Date.now() - startedAt, clientConnected: clientConnected(), degraded: base.degraded === true }, activeSessionId, dshWindow: null, pet: base.pet, tasks: base.tasks, recent: base.recent, lastAction };
  };
  const server = http.createServer((req, res) => {
    void handle(req, res).catch(error => {
      if (!res.headersSent) json(res, error.message === 'body-too-large' ? 413 : 400, { ok: false, reason: 'bad-request' });
      else res.end();
    });
  });
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); socket.on('error', () => {}); });
  server.on('clientError', (_error, socket) => socket.destroy());
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  async function handle(req, res) {
    if (!local(req.socket.remoteAddress)) return json(res, 403, { ok: false, reason: 'not-loopback' });
    const hostHeader = req.headers.host ?? '';
    if (![`127.0.0.1:${bridge.port}`, `localhost:${bridge.port}`].includes(hostHeader)) return json(res, 403, { ok: false, reason: 'bad-host' });
    const origin = req.headers.origin;
    if (origin && !allowedOrigins.has(origin)) return json(res, 403, { ok: false, reason: 'forbidden-origin' });
    if (origin) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    }
    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const auth = typeof req.headers.authorization === 'string' ? req.headers.authorization.replace(/^Bearer /, '') : url.searchParams.get('token');
    if (!equal(auth, token)) return json(res, 401, { ok: false, reason: 'bad-token' });
    if (url.pathname === '/v1/health' && req.method === 'GET') return json(res, 200, { ok: true, version: VERSION, pid: process.pid, uptimeMs: Date.now() - startedAt });
    if (url.pathname === '/v1/state' && req.method === 'GET') return json(res, 200, snapshot());
    if (url.pathname === '/v1/client/poll' && req.method === 'GET') {
      lastPollAt = Date.now();
      for (const [id, command] of commands) if (Date.now() - command.at > 15000) { commands.delete(id); lastAction = { id, ok: false, reason: 'client-timeout' }; }
      return json(res, 200, { seq, commands: [...commands.values()].map(({ at, ...rest }) => rest) });
    }
    if (req.method !== 'POST') return json(res, 404, { ok: false, reason: 'not-found' });
    if (!String(req.headers['content-type'] ?? '').startsWith('application/json')) return json(res, 415, { ok: false, reason: 'expected-json' });
    const body = await readBody(req);
    if (url.pathname === '/v1/action') {
      if (body.type !== 'open-session') return json(res, 400, { ok: false, reason: 'unsupported-type' });
      if (typeof body.sessionId !== 'string' || !body.sessionId || body.sessionId.length > 512 || /[\x00-\x1f]/.test(body.sessionId) || !isSession?.(body.sessionId)) return json(res, 400, { ok: false, reason: 'unknown-session' });
      if (!clientConnected()) return json(res, 200, { ok: false, reason: 'no-client' });
      if (commands.size >= 32) return json(res, 429, { ok: false, reason: 'queue-full' });
      const id = `fatfish-${++seq}`;
      commands.set(id, { id, type: body.type, sessionId: body.sessionId, at: Date.now() });
      return json(res, 200, { ok: true, commandId: id, queued: true });
    }
    if (url.pathname === '/v1/client/state') {
      lastPollAt = Date.now();
      activeSessionId = typeof body.activeSessionId === 'string' ? body.activeSessionId : null;
      return json(res, 200, { ok: true });
    }
    if (url.pathname === '/v1/client/ack') {
      if (typeof body.id !== 'string' || !commands.has(body.id)) return json(res, 400, { ok: false, reason: 'unknown-command' });
      commands.delete(body.id);
      lastAction = { id: body.id, ok: body.ok === true, reason: body.ok === true ? undefined : String(body.reason ?? 'navigation-failed').slice(0, 200), at: Date.now() };
      return json(res, 200, { ok: true });
    }
    return json(res, 404, { ok: false, reason: 'not-found' });
  }
  const bridge = {
    token, port: 0, discoveryPath, snapshot,
    allowOrigin: origin => { if (origin) allowedOrigins.add(origin); },
    async stop() {
      if (stopped) return;
      stopped = true;
      try { const data = JSON.parse(fs.readFileSync(discoveryPath, 'utf8')); if (data.token === token) fs.unlinkSync(discoveryPath); } catch {}
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    }
  };
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', () => { server.removeListener('error', reject); resolve(); }); });
  bridge.port = server.address().port;
  server.on('error', error => logger.warn?.('[fatfish] local bridge error', error.message));
  try {
    fs.mkdirSync(path.dirname(discoveryPath), { recursive: true });
    const temporary = `${discoveryPath}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify({ version: VERSION, host: '127.0.0.1', port: bridge.port, token, pid: process.pid, startedAt: new Date(startedAt).toISOString(), profile }), { encoding: 'utf8', mode: 0o600 });
    fs.renameSync(temporary, discoveryPath);
  } catch (error) { logger.warn?.('[fatfish] discovery file unavailable', error.message); }
  return bridge;
}

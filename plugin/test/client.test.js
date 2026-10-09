import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

function loadClient(fetchImpl, openSession = () => {}, injected = { port: 12345, token: 'stale'.repeat(16) }) {
  let entry;
  let nextTimer = 0;
  const timers = new Map();
  const disposers = [];
  const window = { __DSH_FATFISH__: injected, __ModuleLoader__: { load(value) { entry = value; } } };
  vm.runInNewContext(fs.readFileSync(new URL('../client.js', import.meta.url), 'utf8'), {
    window, document: { hasFocus: () => true, visibilityState: 'visible' },
    AbortController, AbortSignal, fetch: fetchImpl,
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  const plugin = entry.factory();
  const ctx = { uiWorkspace: { mainReference: { sessionId: 'active' }, openSession }, sessions: { list: { getSnapshot: () => ({ byId: {} }) } }, effect(action) { disposers.push(action()); } };
  plugin.apply(ctx);
  return {
    window, timers, plugin, entry,
    async tick(delay) {
      const found = [...timers].find(([, timer]) => timer.delay === delay);
      assert.ok(found, `scheduled delay ${delay}`);
      timers.delete(found[0]);
      found[1].callback();
      for (let index = 0; index < 3; index++) await new Promise(resolve => setImmediate(resolve));
    },
    stop() { for (const dispose of disposers) dispose(); }
  };
}
const response = (status, value) => ({ ok: status >= 200 && status < 300, status, async json() { return value; } });

test('client uses official service-key inject and retries after auth rotation; ack failures never repeat navigation', async () => {
  const calls = [];
  const opened = [];
  let pollCount = 0;
  let ackCount = 0;
  let configurationCount = 0;
  const client = loadClient(async (url, options) => {
    const pathname = new URL(url, 'dsh-app://app/').pathname;
    calls.push({ pathname, auth: options.headers?.Authorization, credentials: options.credentials, body: options.body ? JSON.parse(options.body) : null });
    if (pathname === '/api/fatfish/client-config') {
      configurationCount++;
      return response(200, { port: 12345, token: (configurationCount === 1 ? 'a' : 'b').repeat(64), version: 1 });
    }
    if (pathname === '/v1/client/poll') {
      pollCount++;
      if (pollCount === 1) return response(401, {});
      return response(200, { commands: [{ id: 'same-command', type: 'open-session', sessionId: 'target' }] });
    }
    if (pathname === '/v1/client/ack') { ackCount++; return response(ackCount === 1 ? 500 : 200, { ok: true }); }
    return response(200, { ok: true });
  }, id => opened.push(id));
  assert.equal(client.entry.id, 'dsh-plugin-fatfish-desktop');
  assert.deepEqual(Array.from(client.plugin.inject), ['uiWorkspace', 'sessions']);
  await client.tick(0);
  assert.equal(pollCount, 1);
  await client.tick(800);
  assert.deepEqual(opened, ['target']);
  assert.equal(calls.find(call => call.pathname === '/v1/client/ack').auth, `Bearer ${'b'.repeat(64)}`);
  await client.tick(800);
  assert.deepEqual(opened, ['target']);
  assert.equal(ackCount, 2);
  assert.equal(configurationCount, 3);
  assert.equal(calls.find(call => call.pathname === '/api/fatfish/client-config').credentials, 'same-origin');
  assert.equal(calls.find(call => call.pathname === '/api/fatfish/client-config').auth, undefined);
  assert.equal(calls.find(call => call.pathname === '/v1/client/poll').credentials, 'omit');
  await client.tick(150);
  assert.equal(calls.find(call => call.pathname === '/v1/client/state').body.activeSessionId, 'active');
  client.stop();
  assert.equal(client.timers.size, 0);
});

test('client navigation exceptions return a negative command acknowledgement and keep polling', async () => {
  const acknowledgements = [];
  const client = loadClient(async (url, options) => {
    if (url === '/api/fatfish/client-config') return response(200, { port: 12345, token: 'a'.repeat(64), version: 1 });
    if (url.endsWith('/v1/client/poll')) return response(200, { commands: [{ id: 'bad', type: 'open-session', sessionId: 'target' }] });
    if (url.endsWith('/v1/client/ack')) acknowledgements.push(JSON.parse(options.body));
    return response(200, { ok: true });
  }, () => { throw new Error('session no longer available'); });
  await client.tick(0);
  assert.deepEqual(acknowledgements, [{ id: 'bad', ok: false, reason: 'session no longer available' }]);
  assert.ok([...client.timers.values()].some(timer => timer.delay === 800));
  client.stop();
  assert.equal(client.timers.size, 0);
});

test('hot-installed client works without cached boot injections and rejects an unauthenticated configuration response', async () => {
  const calls = [];
  let authenticated = false;
  const client = loadClient(async (url, options) => {
    calls.push({ url, options });
    if (url === '/api/fatfish/client-config') return response(authenticated ? 200 : 401, { port: 54321, token: 'c'.repeat(64), version: 1 });
    return response(200, { commands: [] });
  }, undefined, undefined);
  delete client.window.__DSH_FATFISH__;
  await client.tick(0);
  assert.deepEqual(calls.map(call => call.url), ['/api/fatfish/client-config']);
  authenticated = true;
  await client.tick(800);
  assert.equal(calls.at(-1).url, 'http://127.0.0.1:54321/v1/client/poll');
  assert.equal(calls.at(-1).options.headers.Authorization, `Bearer ${'c'.repeat(64)}`);
  client.stop();
  assert.equal(client.timers.size, 0);
});

test('new Host credentials permit a restarted command counter to navigate once again', async () => {
  const opened = [];
  let generation = 1;
  let failNextPoll = false;
  const client = loadClient(async (url, options) => {
    if (url === '/api/fatfish/client-config') return response(200, { port: 12345 + generation, token: String(generation).repeat(64), version: 1 });
    if (url.endsWith('/v1/client/poll')) {
      if (failNextPoll) { failNextPoll = false; return response(401, {}); }
      return response(200, { commands: [{ id: 'fatfish-1', type: 'open-session', sessionId: `session-${generation}` }] });
    }
    return response(200, { ok: true });
  }, id => opened.push(id));
  await client.tick(0);
  await client.tick(800);
  assert.deepEqual(opened, ['session-1']);
  generation = 2;
  failNextPoll = true;
  await client.tick(800);
  await client.tick(800);
  assert.deepEqual(opened, ['session-1', 'session-2']);
  client.stop();
  assert.equal(client.timers.size, 0);
});

test('request timeout covers response bodies and teardown cancels an in-flight read', async () => {
  let requestSignal;
  const client = loadClient(async (_url, options) => {
    requestSignal = options.signal;
    return { ok: true, async json() { return await new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })); } };
  });
  await client.tick(0);
  assert.ok([...client.timers.values()].some(timer => timer.delay === 2500));
  await client.tick(2500);
  assert.equal(requestSignal.aborted, true);
  await client.tick(800);
  client.stop();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requestSignal.aborted, true);
  assert.equal(client.timers.size, 0);
});

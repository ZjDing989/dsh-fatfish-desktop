import { StateCollector } from './state.js';
import { createBridgeServer } from './server.js';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const name = 'dsh-plugin-fatfish-desktop';
export const inject = [];

/** Read-only observer. No model requests, session writes, credential reads or provider changes. */
export async function apply(ctx, config = {}) {
  const logger = ctx.logger ?? console;
  const warn = error => { try { logger.warn?.('[fatfish] ' + String(error?.message ?? error)); } catch {} };
  const service = key => { try { return ctx.get?.(key) ?? ctx[key]; } catch { return undefined; } };
  const collector = new StateCollector();
  const cleanup = [];
  const lifetime = new AbortController();
  const hydrated = new WeakSet();
  const hydrating = new WeakSet();
  const hydrationFailedAt = new WeakMap();
  const pendingHydration = new Set();
  let bridge;
  let disposed = false;
  const teardown = async () => {
    if (disposed) return;
    disposed = true;
    lifetime.abort();
    for (const release of cleanup.splice(0)) { try { release(); } catch {} }
    await Promise.allSettled([...pendingHydration]);
    if (bridge) await bridge.stop().catch(warn);
  };
  try {
    if (config.enabled === false) return;
    ctx.effect(() => teardown, 'fatfish: local bridge lifecycle');
    const remember = session => {
      let title = '';
      try { const snapshot = service('sessionTitle')?.get(session); title = typeof snapshot === 'string' ? snapshot : snapshot?.title ?? ''; } catch {}
      collector.remember(session, title);
    };
    const subscribe = (event, callback) => {
      const release = ctx.on(event, (...args) => { try { callback(...args); } catch (error) { warn(error); } }, { global: true });
      if (typeof release === 'function') cleanup.push(release);
    };
    subscribe('session/created', remember);
    subscribe('session/event', (session, event) => { remember(session); collector.event(session, event); });
    subscribe('agent/created', ({ agent }) => { remember(agent.session); collector.status(agent, agent.status); });
    subscribe('agent/status', ({ agent, status }) => { remember(agent.session); collector.status(agent, status); });
    subscribe('agent/disposed', ({ agent }) => collector.end(agent.id));
    subscribe('agent/assistant-stream', ({ agent, frame }) => collector.stream(agent, frame));

    const recover = agent => {
      const controller = service('sessionController');
      if (!controller?.follow || hydrated.has(agent) || hydrating.has(agent) || disposed || Date.now() - (hydrationFailedAt.get(agent) ?? 0) < 5000) return;
      hydrating.add(agent);
      const operation = (async () => {
        const timeout = new AbortController();
        const timer = setTimeout(() => timeout.abort(), 5000);
        timer.unref?.();
        let iterator;
        try {
          // Follow's first frame is the same public reconnect cut consumed by DSH's UI.
          // Only already-running Agents are observed; no prompt, resume, or model call is made.
          const address = agent.session.header?.origin === 'subagent'
            ? { kind: 'subagent', parentSessionId: agent.session.header.parentSession, childSessionId: agent.session.id, mode: 'unknown' }
            : { kind: 'session', sessionId: agent.session.id };
          iterator = controller.follow({ address, assistantStream: true, maxMessages: 50, turnWindow: { minMessages: 1, minTurns: 1 } }, AbortSignal.any([lifetime.signal, timeout.signal]))[Symbol.asyncIterator]();
          const opening = await iterator.next();
          if (!disposed && !opening.done && collector.restore(agent, opening.value)) hydrated.add(agent);
          else hydrationFailedAt.set(agent, Date.now());
        } catch (error) {
          hydrationFailedAt.set(agent, Date.now());
          if (!lifetime.signal.aborted && !timeout.signal.aborted) warn(error);
        } finally {
          clearTimeout(timer);
          timeout.abort();
          try { await iterator?.return?.(); } catch {}
          hydrating.delete(agent);
        }
      })();
      pendingHydration.add(operation);
      void operation.finally(() => pendingHydration.delete(operation));
    };

    const reconcile = () => {
      try {
        const agents = service('agents');
        collector.degraded = !agents || typeof agents.list !== 'function';
        if (agents?.list) {
          const list = agents.list();
          for (const agent of list) remember(agent.session);
          collector.reconcileAgents(list);
          for (const agent of list) if (agent.status === 'running') recover(agent);
        }
        const sessions = service('sessions');
        if (sessions?.list) for (const session of sessions.list()) remember(session);
        const jobs = service('jobs');
        if (jobs?.list) {
          const all = new Map();
          const owners = new Set(collector.meta.keys());
          for (const owner of [undefined, ...owners]) {
            try { for (const job of jobs.list(owner) ?? []) if (job?.id) all.set(job.id, job); } catch {}
          }
          collector.reconcileJobs([...all.values()]);
        }
      } catch (error) { collector.degraded = true; warn(error); }
    };
    reconcile();
    const timer = setInterval(reconcile, 1000);
    timer.unref?.();
    cleanup.push(() => clearInterval(timer));
    bridge = await createBridgeServer({
      port: Number.isInteger(config.port) && config.port >= 0 && config.port < 65536 ? config.port : 0,
      discoveryPath: typeof config.discoveryPath === 'string' && config.discoveryPath ? config.discoveryPath : undefined,
      profile: typeof config.profile === 'string' ? config.profile : 'desktop',
      getSnapshot: () => collector.snapshot(),
      isSession: id => collector.meta.has(id),
      origins: Array.isArray(config.allowedOrigins) ? config.allowedOrigins.filter(value => typeof value === 'string') : [],
      logger: { warn }
    });
    if (disposed) { await bridge.stop(); return; }
    // Desktop caches initial boot injections for the life of the Host. This exact Fetch route
    // uses Connection's existing authenticated /api carrier, so HMR can obtain current credentials
    // without a Host restart and without exposing a public loopback token-discovery endpoint.
    ctx.inject(['connection'], apiCtx => {
      try {
        apiCtx.effect(() => apiCtx.connection.fetch.register({
          path: '/api/fatfish/client-config',
          methods: ['GET'],
          requestBody: 'buffered',
          fetch: () => new Response(JSON.stringify({ port: bridge.port, token: bridge.token, version: 1 }), {
            headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Cross-Origin-Resource-Policy': 'same-origin' }
          })
        }), 'fatfish: authenticated current client configuration');
      } catch (error) { warn(error); }
    });
    ctx.inject(['webServer'], webCtx => {
      try {
        const web = webCtx.webServer;
        const updateOrigins = () => {
          if (web.port) { bridge.allowOrigin(`http://127.0.0.1:${web.port}`); bridge.allowOrigin(`http://localhost:${web.port}`); }
          bridge.allowOrigin('dsh-app://app');
        };
        updateOrigins();
        // Desktop receives collectIndexInjections() over private IPC; raw tapIndex transforms
        // are only applied to ordinary Web HTML, so a structured global row is essential.
        webCtx.on('webserver/index-inject', table => {
          try { updateOrigins(); table.push({ kind: 'global', name: '__DSH_FATFISH__', value: { port: bridge.port, token: bridge.token, version: 1 } }); }
          catch (error) { warn(error); }
        });
      } catch (error) { warn(error); }
    });
    // The official Electron shell has no public plugin BrowserWindow service. WPF is a Windows
    // rendering helper owned entirely by this plugin's fiber; it is never installed or launched independently.
    if (process.platform === 'win32' && config.desktopPet !== false) {
      const nativeRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), 'native');
      const script = typeof config.nativeScript === 'string' ? config.nativeScript : path.join(nativeRoot, 'pet.ps1');
      const assets = typeof config.assetsPath === 'string' ? config.assetsPath : nativeRoot;
      if (existsSync(script)) {
        const child = spawn('powershell.exe', ['-WindowStyle', 'Hidden', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', script, '-DiscoveryPath', bridge.discoveryPath, '-Assets', assets], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
        child.on('error', warn);
        child.stderr.on('data', data => warn(String(data).slice(0, 1000)));
        child.on('exit', code => { if (!disposed && code) warn(`desktop helper exited (${code})`); });
        cleanup.push(() => { try { child.kill(); } catch {} });
      } else warn('native desktop helper script missing');
    }
  } catch (error) { warn(error); await teardown(); }
}

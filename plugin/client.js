window.__ModuleLoader__.load({
  id: 'dsh-plugin-fatfish-desktop',
  factory: () => {
    const inject = ['uiWorkspace', 'sessions'];
    function apply(ctx) {
      const lifetime = new AbortController();
      const timers = new Set();
      const executed = new Map();
      let currentConfig = null;
      let configRead = null;
      let credentialIdentity = '';
      const later = (operation, ms = 800) => {
        if (lifetime.signal.aborted) return;
        const timer = setTimeout(() => { timers.delete(timer); void operation(); }, ms);
        timers.add(timer);
      };
      const validConfig = value => value?.version === 1 && Number.isInteger(value.port) && value.port > 0 && value.port < 65536 && /^[a-f0-9]{64}$/.test(value.token);
      async function timedJson(url, options) {
        const timeout = new AbortController();
        const timer = setTimeout(() => timeout.abort(), 2500);
        try {
          const response = await fetch(url, { ...options, signal: AbortSignal.any([lifetime.signal, timeout.signal]) });
          if (!response.ok) throw new Error(`fatfish transport ${response.status}`);
          return await response.json();
        }
        finally { clearTimeout(timer); }
      }
      async function credentials() {
        if (currentConfig) return currentConfig;
        if (configRead) return configRead;
        const loading = (async () => {
          // This is DSH's same-origin /api transport, protected by its Host/Origin fence and
          // browser session. Desktop's owned carrier supplies its Host cookie. Cached boot
          // globals are deliberately not used as a token fallback after a Host/plugin reload.
          const value = await timedJson('/api/fatfish/client-config', { method: 'GET', cache: 'no-store', credentials: 'same-origin' });
          if (!validConfig(value)) throw new Error('invalid fatfish configuration');
          const identity = `${value.port}:${value.token}`;
          if (credentialIdentity !== identity) { executed.clear(); credentialIdentity = identity; }
          currentConfig = value;
          return value;
        })();
        configRead = loading;
        try { return await loading; }
        finally { if (configRead === loading) configRead = null; }
      }
      async function request(endpoint, body) {
        const config = await credentials();
        try {
          return await timedJson(`http://127.0.0.1:${config.port}${endpoint}`, {
            method: body === undefined ? 'GET' : 'POST',
            headers: { Authorization: `Bearer ${config.token}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
            body: body === undefined ? undefined : JSON.stringify(body),
            cache: 'no-store', credentials: 'omit'
          });
        } catch (error) {
          if (currentConfig === config) currentConfig = null;
          throw error;
        }
      }
      const activeId = () => {
        // mainReference is the UI owner's authoritative reference; list counts are a compatibility fallback.
        const reference = ctx.uiWorkspace?.mainReference;
        if (reference?.sessionId) return reference.sessionId;
        const list = ctx.sessions?.list?.getSnapshot?.();
        return Object.values(list?.byId ?? {}).find(row => row.retainedBy?.mainView > 0)?.id ?? null;
      };
      async function poll() {
        if (lifetime.signal.aborted) return;
        try {
          const response = await request('/v1/client/poll');
          for (const command of response.commands ?? []) {
            if (lifetime.signal.aborted) return;
            let result = executed.get(command.id);
            if (!result) {
              try {
                if (command.type !== 'open-session' || typeof command.sessionId !== 'string' || !command.sessionId) throw new Error('invalid-command');
                ctx.uiWorkspace.openSession(command.sessionId);
                result = { id: command.id, ok: true };
              } catch (error) { result = { id: command.id, ok: false, reason: String(error.message ?? error).slice(0, 200) }; }
              executed.set(command.id, result);
              while (executed.size > 64) executed.delete(executed.keys().next().value);
            }
            await request('/v1/client/ack', result);
          }
        } catch {
          // Retry forever with a fresh credential read. A token or Host restart never disables the loop.
        } finally { later(poll); }
      }
      async function report() {
        if (lifetime.signal.aborted) return;
        try { await request('/v1/client/state', { activeSessionId: activeId(), focused: document.hasFocus(), visible: document.visibilityState !== 'hidden' }); }
        catch {} finally { later(report, 1500); }
      }
      ctx.effect(() => {
        later(poll, 0);
        later(report, 150);
        return () => { lifetime.abort(); for (const timer of timers) clearTimeout(timer); timers.clear(); };
      }, 'fatfish: client session bridge');
    }
    return { inject, apply };
  }
});

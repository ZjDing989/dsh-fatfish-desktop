import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { StateCollector } from '../state.js';
import { createBridgeServer } from '../server.js';
import { apply } from '../index.js';

test('stream attempts reset independently; reasoning and visible output remain separate', () => {
  let time = 1000;
  const state = new StateCollector({ now: () => time });
  const agent = { id: 's1', status: 'running', session: { id: 's1', header: { cwd: 'D:\\work' } } };
  state.reconcileAgents([agent]);
  let revision = 0;
  const frame = (type, value = {}) => state.stream(agent, { type, attemptId: 'a1', revision: ++revision, ...value });
  frame('start');
  frame('chunk', { index: 0, chunk: { type: 'reasoning-delta', index: 0, text: 'checking ' } });
  frame('chunk', { index: 1, chunk: { type: 'reasoning-delta', index: 0, text: 'source' } });
  frame('chunk', { index: 1, revision, chunk: { type: 'reasoning-delta', index: 0, text: 'DUPLICATE' } });
  frame('chunk', { index: 2, chunk: { type: 'text-delta', index: 1, text: 'visible answer' } });
  frame('end', { outcome: { kind: 'committed' } });
  let row = state.snapshot().tasks[0];
  assert.equal(row.reasoning, 'checking source');
  assert.equal(row.output, 'visible answer');
  assert.equal(row.textKind, 'output');
  assert.equal(row.workspace, 'D:\\work');
  state.stream(agent, { type: 'start', attemptId: 'a2', revision: ++revision });
  row = state.snapshot().tasks[0];
  assert.equal(row.reasoning, '');
  assert.equal(row.output, '');
  state.event(agent.session, { type: 'approval/asked', data: { reason: 'permission' } });
  state.reconcileAgents([agent]);
  assert.equal(state.snapshot().tasks[0].status, 'waiting');
  state.event(agent.session, { type: 'turn/end', data: { reason: { kind: 'error' } } });
  state.status(agent, 'idle');
  assert.equal(state.snapshot().tasks.length, 0);
  assert.equal(state.snapshot().recent[0].status, 'failed');
  time += 31000;
  assert.equal(state.snapshot().recent.length, 0);
});

test('real block-end content replaces deltas and tool-call argument fragments expose the actual command', () => {
  const state = new StateCollector();
  const agent = { id: 's1', status: 'running', session: { id: 's1' } };
  state.stream(agent, { type: 'start', attemptId: 's1:1', revision: 1, turn: 1, step: 1 });
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 2, index: 0, chunk: { type: 'text-delta', index: 0, text: 'visible ' } });
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 3, index: 1, chunk: { type: 'block-end', index: 0, block: { type: 'text', text: 'visible answer' } } });
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 4, index: 2, chunk: { type: 'block-end', index: 1, block: { type: 'reasoning', text: 'public reasoning' } } });
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 5, index: 3, chunk: { type: 'tool-call-delta', index: 2, id: 'call-1', name: 'pwsh', argumentsDelta: '{"command":"Get-' } });
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 6, index: 4, chunk: { type: 'tool-call-delta', index: 2, id: 'call-1', argumentsDelta: 'ChildItem"}' } });
  let row = state.snapshot().tasks[0];
  assert.equal(row.output, 'visible answer');
  assert.equal(row.reasoning, 'public reasoning');
  assert.equal(row.activity, 'pwsh · Get-ChildItem');
  assert.equal(row.activityKind, 'tool');
  state.event(agent.session, { type: 'tool/call', seq: 10, data: { turn: 1, step: 1, callId: 'call-1', name: 'pwsh', arguments: '{"command":"node --test"}' } });
  assert.equal(state.snapshot().tasks[0].text, 'pwsh · node --test');
  state.event(agent.session, { type: 'tool/result', seq: 11, data: { turn: 1, step: 1, message: { role: 'tool', content: [{ type: 'text', text: '7 tests passed' }], isError: false } } });
  row = state.snapshot().tasks[0];
  assert.equal(row.activity, '7 tests passed');
  assert.equal(row.activityKind, 'tool');
  assert.equal(row.output, 'visible answer');
});

test('bubble actions never use reasoning, reply body, tool output, or approval reason', () => {
  const state = new StateCollector();
  const agent = { id: 's1', status: 'running', session: { id: 's1' } };
  state.remember(agent.session, 'Keep the conversation title');
  state.stream(agent, { type: 'start', attemptId: 's1:1', revision: 1 });
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 2, index: 0, chunk: { type: 'reasoning-delta', index: 0, text: 'PRIVATE_REASONING_MARKER\n```code```' } });
  assert.equal(state.snapshot().tasks[0].action, '正在思考下一步');
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 3, index: 1, chunk: { type: 'text-delta', index: 1, text: 'REPLY_BODY_MARKER\nA full answer' } });
  let row = state.snapshot().tasks[0];
  assert.equal(row.action, '正在生成回复');
  assert.equal(row.title, 'Keep the conversation title');
  assert.ok(row.reasoning.includes('PRIVATE_REASONING_MARKER'));
  assert.ok(row.output.includes('REPLY_BODY_MARKER'));
  state.event(agent.session, { type: 'tool/result', seq: 10, data: { message: { content: [{ type: 'text', text: 'TOOL_OUTPUT_MARKER' }], isError: false } } });
  assert.equal(state.snapshot().tasks[0].action, '工具执行完成，准备继续');
  state.event(agent.session, { type: 'tool/result', seq: 11, data: { error: { message: 'ERROR_BODY_MARKER' }, message: { content: [{ type: 'text', text: 'TOOL_ERROR_MARKER' }], isError: true } } });
  assert.equal(state.snapshot().tasks[0].action, '工具执行失败，准备继续');
  state.event(agent.session, { type: 'approval/asked', seq: 12, data: { reason: 'APPROVAL_REASON_MARKER' } });
  state.reconcileAgents([agent]);
  assert.equal(state.snapshot().tasks[0].action, '等待确认');
  state.event(agent.session, { type: 'approval/decided', seq: 13, data: {} });
  assert.equal(state.snapshot().tasks[0].action, '正在思考下一步');
  row = state.snapshot().tasks[0];
  assert.doesNotMatch(row.action, /MARKER|```|\r|\n/);
});

test('tool actions prefer explicit descriptions and summarize only safe command/path/query metadata', () => {
  const state = new StateCollector();
  const session = { id: 's1' };
  state.start(session.id);
  const call = (name, args) => {
    state.event(session, { type: 'tool/call', data: { name, arguments: typeof args === 'string' ? args : JSON.stringify(args) } });
    return state.snapshot().tasks[0].action;
  };
  assert.equal(call('functions.run_code', { description: 'Check workspace', command: 'node -e "RAW_CODE_MARKER"', code: 'RAW_CODE_MARKER' }), '正在运行代码 · Check workspace');
  assert.equal(call('pwsh', { command: 'npm run build && echo FULL_COMMAND_MARKER' }), '正在执行命令 · npm run build');
  assert.equal(call('exec_command', { command: 'node -e "RAW_CODE_MARKER"' }), '正在执行命令 · node');
  assert.equal(call('read_file', { path: 'D:\\project\\package.json' }), '正在读取文件 · D:\\project\\package.json');
  assert.equal(call('web', { query: 'official API documentation' }), '正在搜索资料 · official API documentation');
  assert.equal(call('unknown_tool', { unrecognized: 'RAW_JSON_MARKER', prompt: 'PROMPT_BODY_MARKER' }), '正在执行工具 · unknown_tool');
  assert.equal(call('run_code', { code: 'RAW_CODE_MARKER', description: '```js\nRAW_CODE_MARKER\n```' }), '正在运行代码');
  assert.equal(call('run_code', '{"description":"unfinished RAW_JSON_MARKER'), '正在运行代码');
  const bounded = call('run_code', { description: 'Check workspace\n' + '很长的任务描述'.repeat(30) });
  assert.ok([...bounded].length <= 100);
  assert.doesNotMatch(bounded, /\r|\n|```|RAW_|PROMPT_/);
});

test('streamed tool descriptions update the action only when their public argument object is complete', () => {
  const state = new StateCollector();
  const agent = { id: 's1', status: 'running', session: { id: 's1' } };
  state.stream(agent, { type: 'start', attemptId: 's1:1', revision: 1 });
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 2, index: 0, chunk: { type: 'tool-call-delta', index: 0, name: 'run_code', id: 'call-1', argumentsDelta: '{"code":"RAW_CODE_MARKER",' } });
  assert.equal(state.snapshot().tasks[0].action, '正在运行代码');
  state.stream(agent, { type: 'chunk', attemptId: 's1:1', revision: 3, index: 1, chunk: { type: 'tool-call-delta', index: 0, id: 'call-1', argumentsDelta: '"description":"Inspect files"}' } });
  assert.equal(state.snapshot().tasks[0].action, '正在运行代码 · Inspect files');
});

test('public reconnect compact stream restores a mid-attempt prefix and merges newer notifications in order', () => {
  const state = new StateCollector();
  const agent = { id: 's1', status: 'running', session: { id: 's1', header: { cwd: 'D:\\demo' } } };
  state.reconcileAgents([agent]);
  const suffix = { type: 'chunk', attemptId: 's1:2', revision: 5, index: 3, time: 1200, chunk: { type: 'text-delta', index: 1, text: 'tail' } };
  state.stream(agent, suffix);
  state.event(agent.session, { type: 'tool/call', seq: 13, data: { name: 'bash', arguments: '{"command":"npm run build"}' } });
  const snapshot = {
    type: 'snapshot', cursor: 12,
    records: [{ type: 'event', event: { type: 'turn/start', seq: 10, data: { turn: 2 } } }],
    assistantStream: { revision: 4, activeAttempt: { attemptId: 's1:2', startedAfterSeq: 12, turn: 2, step: 1, nextIndex: 3, stream: [
      { type: 'reasoning-chunks', index: 0, time0: 1000, lastTime: 1100, gaps: [100], texts: ['checking ', 'source'] },
      { type: 'text-chunks', index: 1, time0: 1150, lastTime: 1150, gaps: [], texts: ['prefix '] }
    ] } }
  };
  assert.equal(state.restore(agent, snapshot), true);
  let row = state.snapshot().tasks[0];
  assert.equal(row.reasoning, 'checking source');
  assert.equal(row.output, 'prefix tail');
  assert.equal(row.activity, 'bash · npm run build');
  assert.equal(row.activityKind, 'tool');
  assert.equal(row.action, '正在执行命令 · npm run build');
  state.stream(agent, suffix);
  assert.equal(state.snapshot().tasks[0].output, 'prefix tail');
  state.stream(agent, { type: 'chunk', attemptId: 's1:2', revision: 6, index: 4, chunk: { type: 'reasoning-delta', index: 0, text: ' again' } });
  row = state.snapshot().tasks[0];
  assert.equal(row.reasoning, 'checking source again');
  assert.equal(row.activityKind, 'cot');
  assert.equal(row.action, '正在思考下一步');
  assert.equal(row.output, 'prefix tail');
});

test('mid-tool reconnect recovers only the current turn visible message and complete command arguments', () => {
  const state = new StateCollector();
  const agent = { id: 's1', status: 'running', session: { id: 's1' } };
  state.reconcileAgents([agent]);
  const events = [
    { type: 'assistant/message', seq: 1, data: { message: { content: [{ type: 'text', text: 'obsolete earlier answer' }] } } },
    { type: 'turn/start', seq: 2, data: { turn: 2 } },
    { type: 'assistant/message', seq: 3, data: { turn: 2, step: 1, message: { content: [{ type: 'reasoning', text: 'public current thought' }, { type: 'text', text: 'current answer' }, { type: 'tool-call', id: 'call-1', name: 'web', arguments: '{"query":"official documentation"}' }] } } },
    { type: 'tool/call', seq: 4, data: { turn: 2, step: 1, callId: 'call-1', name: 'web', arguments: '{"query":"official documentation"}' } }
  ];
  state.restore(agent, { type: 'snapshot', cursor: 4, records: events.map(event => ({ type: 'event', event })), assistantStream: { revision: 10 } });
  const row = state.snapshot().tasks[0];
  assert.equal(row.reasoning, 'public current thought');
  assert.equal(row.output, 'current answer');
  assert.equal(row.activity, 'web · official documentation');
  assert.equal(row.activityKind, 'tool');
  assert.equal(row.action, '正在搜索资料 · official documentation');
});

test('a message-capped reconnect page still restores the current tool activity without a turn/start record', () => {
  const state = new StateCollector();
  const agent = { id: 's1', status: 'running', session: { id: 's1' } };
  state.reconcileAgents([agent]);
  state.restore(agent, { type: 'snapshot', cursor: 302, hasMore: true, assistantStream: { revision: 40 }, records: [
    { type: 'event', event: { type: 'assistant/message', seq: 300, data: { turn: 3, step: 30, message: { content: [{ type: 'text', text: 'Still checking the project' }] } } } },
    { type: 'event', event: { type: 'tool/call', seq: 302, data: { turn: 3, step: 30, name: 'pwsh', arguments: '{"command":"Get-Content package.json"}' } } }
  ] });
  const row = state.snapshot().tasks[0];
  assert.equal(row.output, 'Still checking the project');
  assert.equal(row.activity, 'pwsh · Get-Content package.json');
  assert.equal(row.activityKind, 'tool');
  assert.equal(row.action, '正在执行命令 · Get-Content');
});

test('reconciliation detects startup work and removes disposed agents', () => {
  const state = new StateCollector();
  state.reconcileAgents([{ id: 'child', session: { id: 'child' }, status: 'running' }]);
  assert.equal(state.snapshot().tasks.length, 1);
  state.reconcileAgents([]);
  assert.equal(state.snapshot().tasks.length, 0);
  assert.equal(state.snapshot().recent[0].sessionId, 'child');
});

test('snapshot retains every active Agent and owned job beyond 24 items', () => {
  const state = new StateCollector();
  const agents = Array.from({ length: 30 }, (_, index) => ({ id: `s${index}`, session: { id: `s${index}` }, status: 'running' }));
  state.reconcileAgents(agents);
  state.reconcileJobs(agents.map(agent => ({ id: `shell-${agent.id}`, owner: agent.id, kind: 'shell', label: 'Background command', status: 'running' })));
  const snapshot = state.snapshot();
  assert.equal(snapshot.tasks.length, 60);
  assert.equal(new Set(snapshot.tasks.map(row => row.id)).size, 60);
  for (const agent of agents) {
    assert.ok(snapshot.tasks.some(row => row.id === `agent:${agent.id}`));
    assert.ok(snapshot.tasks.some(row => row.id === `job:shell-${agent.id}`));
  }
  state.reconcileAgents([]);
  assert.equal(state.snapshot().tasks.length, 30);
  assert.ok(state.snapshot().tasks.every(row => row.kind === 'job'));
});

test('jobs expose registry detail, distinguish stopping, and settle killed as cancelled', () => {
  let time = 1000;
  const state = new StateCollector({ now: () => time });
  const job = { id: 'shell-1', owner: 's1', kind: 'shell', label: 'Build project', status: 'running', detail: 'Compiling source files' };
  state.remember({ id: 's1' }, 'Project build');
  state.reconcileJobs([job]);
  let row = state.snapshot().tasks[0];
  assert.equal(row.sessionId, 's1');
  assert.equal(row.detail, 'Compiling source files');
  assert.equal(row.text, 'Compiling source files');
  assert.equal(row.label, 'Build project');
  assert.equal(row.action, '正在执行后台任务 · Build project');
  state.reconcileJobs([{ ...job, status: 'stopping', detail: 'Waiting for process exit' }]);
  row = state.snapshot().tasks[0];
  assert.equal(row.status, 'running');
  assert.equal(row.label, '正在停止 · Build project');
  assert.equal(row.action, '正在停止后台任务 · Build project');
  assert.doesNotMatch(row.action, /Waiting for process exit/);
  assert.equal(row.text, 'Waiting for process exit');
  state.reconcileJobs([{ ...job, detail: '' }]);
  row = state.snapshot().tasks[0];
  assert.equal(row.label, 'Build project');
  assert.equal(row.detail, 'shell');
  state.reconcileJobs([{ ...job, status: 'killed' }]);
  let snapshot = state.snapshot();
  assert.equal(snapshot.tasks.length, 0);
  assert.equal(snapshot.recent[0].status, 'cancelled');
  assert.equal(snapshot.recent[0].label, '已取消');
  assert.deepEqual(snapshot.pet, { state: 'cancelled', label: '已取消' });
  time += 3001;
  assert.equal(state.snapshot().pet.state, 'idle');
  state.reconcileJobs([{ ...job, id: 'shell-2' }]);
  state.reconcileJobs([{ ...job, id: 'shell-2', status: 'completed' }]);
  snapshot = state.snapshot();
  assert.equal(snapshot.recent.at(-1).status, 'done');
  assert.deepEqual(snapshot.pet, { state: 'done', label: '已完成' });
  state.reconcileJobs([{ ...job, id: 'shell-3' }]);
  state.reconcileJobs([{ ...job, id: 'shell-3', status: 'failed' }]);
  snapshot = state.snapshot();
  assert.equal(snapshot.recent.at(-1).status, 'failed');
  assert.deepEqual(snapshot.pet, { state: 'error', label: '执行失败' });
});

test('HTTP token and exact Origin gates; no public bootstrap; commands require known Sessions and acknowledge', async t => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'fatfish-test-'));
  const discoveryPath = path.join(temporary, 'discovery.json');
  const server = await createBridgeServer({ discoveryPath, origins: ['http://127.0.0.1:19387'], isSession: id => id === 'known', getSnapshot: () => new StateCollector().snapshot() });
  t.after(async () => { await server.stop(); fs.rmSync(temporary, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${server.port}`;
  const headers = { Authorization: `Bearer ${server.token}`, 'Content-Type': 'application/json' };
  assert.equal((await fetch(base + '/v1/state')).status, 401);
  assert.equal((await fetch(base + '/v1/client/bootstrap')).status, 401);
  assert.equal((await fetch(base + '/v1/state', { headers: { ...headers, Origin: 'http://127.0.0.1:9999' } })).status, 403);
  assert.equal((await fetch(base + '/v1/state', { headers: { ...headers, Origin: 'http://127.0.0.1:19387' } })).status, 200);
  const post = async (endpoint, body) => await fetch(base + endpoint, { method: 'POST', headers, body: JSON.stringify(body) });
  assert.equal((await post('/v1/action', { type: 'open-session', sessionId: 'invented' })).status, 400);
  assert.equal((await (await post('/v1/action', { type: 'open-session', sessionId: 'known' })).json()).reason, 'no-client');
  await fetch(base + '/v1/client/poll', { headers });
  const action = await (await post('/v1/action', { type: 'open-session', sessionId: 'known' })).json();
  assert.equal(action.ok, true);
  const poll = await (await fetch(base + '/v1/client/poll', { headers })).json();
  assert.equal(poll.commands[0].sessionId, 'known');
  await post('/v1/client/ack', { id: action.commandId, ok: true });
  assert.deepEqual((await (await fetch(base + '/v1/client/poll', { headers })).json()).commands, []);
  assert.equal(JSON.parse(fs.readFileSync(discoveryPath, 'utf8')).port, server.port);
  await server.stop();
  assert.equal(fs.existsSync(discoveryPath), false);
});

test('Host plugin publishes Desktop structured boot injection and owns cleanup', async t => {
  const testRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '.tmp');
  fs.mkdirSync(testRoot, { recursive: true });
  const temporary = fs.mkdtempSync(path.join(testRoot, 'host-'));
  const discoveryPath = path.join(temporary, 'discovery.json');
  const listeners = new Map();
  const effects = [];
  const agent = { id: 'live-before-activation', status: 'running', session: { id: 'live-before-activation', header: { cwd: 'D:\\demo' } } };
  const registrations = [];
  const fetchRoutes = new Map();
  const followCalls = [];
  let closedFollowers = 0;
  const services = {
    agents: { list: () => [agent] }, sessions: { list: () => [agent.session] },
    sessionTitle: { get: () => ({ title: 'Existing task', source: { kind: 'user' } }) },
    webServer: { port: 19387 },
    connection: { fetch: { register(route) { fetchRoutes.set(route.path, route); return () => fetchRoutes.delete(route.path); } } },
    sessionController: { follow(request, signal) {
      followCalls.push({ request, signal });
      return (async function* () {
        try { yield { type: 'snapshot', cursor: 10, records: [{ type: 'event', event: { type: 'turn/start', seq: 10, data: { turn: 1 } } }], assistantStream: { revision: 2, activeAttempt: { attemptId: 'live:1', turn: 1, step: 1, nextIndex: 1, stream: [{ type: 'text-chunks', index: 0, texts: ['already visible before activation'], time0: 1, lastTime: 1, gaps: [] }] } } }; }
        finally { closedFollowers++; }
      })();
    } }
  };
  const context = {
    ...services, logger: { warn: () => {} },
    get: key => services[key],
    on(event, callback, options) { registrations.push({ event, options }); listeners.set(event, callback); return () => listeners.delete(event); },
    effect(action) { const release = action(); effects.push(release); return release; },
    inject(_keys, callback) { callback(context); }
  };
  t.after(async () => { for (const effect of effects.reverse()) await effect(); fs.rmSync(temporary, { recursive: true, force: true }); });
  await apply(context, { discoveryPath, desktopPet: false });
  const boot = [];
  listeners.get('webserver/index-inject')(boot);
  const descriptor = JSON.parse(fs.readFileSync(discoveryPath, 'utf8'));
  assert.equal(boot[0].kind, 'global');
  assert.equal(boot[0].name, '__DSH_FATFISH__');
  assert.equal(boot[0].value.token, descriptor.token);
  assert.deepEqual([...fetchRoutes.keys()], ['/api/fatfish/client-config']);
  const configRoute = fetchRoutes.get('/api/fatfish/client-config');
  assert.deepEqual(configRoute.methods, ['GET']);
  const configResponse = configRoute.fetch(new Request('http://localhost/api/fatfish/client-config'));
  assert.equal(configResponse.headers.get('Cache-Control'), 'no-store');
  assert.equal(configResponse.headers.get('Cross-Origin-Resource-Policy'), 'same-origin');
  assert.deepEqual(await configResponse.json(), { port: descriptor.port, token: descriptor.token, version: 1 });
  const snapshot = await (await fetch(`http://127.0.0.1:${descriptor.port}/v1/state`, { headers: { Authorization: `Bearer ${descriptor.token}` } })).json();
  assert.equal(snapshot.tasks[0].title, 'Existing task');
  assert.equal(snapshot.tasks[0].sessionId, agent.id);
  assert.equal(snapshot.tasks[0].output, 'already visible before activation');
  assert.equal(snapshot.tasks[0].activityKind, 'output');
  assert.equal(followCalls.length, 1);
  assert.deepEqual(followCalls[0].request.address, { kind: 'session', sessionId: agent.id });
  assert.equal(followCalls[0].request.assistantStream, true);
  assert.equal(closedFollowers, 1);
  assert.equal(followCalls[0].signal.aborted, true);
  assert.equal(snapshot.host.degraded, false);
  for (const { event, options } of registrations.filter(entry => entry.event !== 'webserver/index-inject')) assert.equal(options.global, true, event);
  for (const effect of effects.reverse()) await effect();
  effects.length = 0;
  assert.equal(fs.existsSync(discoveryPath), false);
  await assert.rejects(fetch(`http://127.0.0.1:${descriptor.port}/v1/state`));
  assert.equal(listeners.has('agent/status'), false);
  assert.equal(fetchRoutes.size, 0);
});

test('Host disposal cancels a pending public subagent reconnect read and releases its follower', async t => {
  const testRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '.tmp');
  fs.mkdirSync(testRoot, { recursive: true });
  const temporary = fs.mkdtempSync(path.join(testRoot, 'cancel-'));
  const discoveryPath = path.join(temporary, 'discovery.json');
  const effects = [];
  const agent = { id: 'child', status: 'running', session: { id: 'child', header: { cwd: 'D:\\demo', origin: 'subagent', parentSession: 'parent' } } };
  let address;
  let signal;
  let closed = 0;
  const services = {
    agents: { list: () => [agent] }, sessions: { list: () => [agent.session] },
    sessionController: { follow(request, requestSignal) {
      address = request.address;
      signal = requestSignal;
      return (async function* () {
        try {
          await new Promise((_resolve, reject) => {
            if (requestSignal.aborted) reject(new Error('cancelled'));
            else requestSignal.addEventListener('abort', () => reject(new Error('cancelled')), { once: true });
          });
          yield { type: 'snapshot' };
        } finally { closed++; }
      })();
    } }
  };
  const context = {
    ...services, get: key => services[key], logger: { warn() {} },
    on() { return () => {}; }, effect(action) { const release = action(); effects.push(release); return release; },
    inject(keys, callback) { if (keys.every(key => services[key])) callback(context); }
  };
  t.after(async () => { for (const effect of effects.reverse()) await effect(); fs.rmSync(temporary, { recursive: true, force: true }); });
  await apply(context, { discoveryPath, desktopPet: false });
  assert.deepEqual(address, { kind: 'subagent', parentSessionId: 'parent', childSessionId: 'child', mode: 'unknown' });
  assert.equal(signal.aborted, false);
  assert.equal(closed, 0);
  for (const effect of effects.reverse()) await effect();
  effects.length = 0;
  assert.equal(signal.aborted, true);
  assert.equal(closed, 1);
  assert.equal(fs.existsSync(discoveryPath), false);
});

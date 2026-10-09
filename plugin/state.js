const CAP = 8000;
const asText = value => typeof value === 'string' ? value : '';
const clip = value => asText(value).slice(-CAP);
const plain = value => asText(value).replace(/[\r\n\t]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
const failed = reason => ['error', 'failed', 'interrupted', 'max-tokens'].includes(reason?.kind ?? reason);
const contentText = (content, type = 'text') => Array.isArray(content) ? content.filter(block => block?.type === type).map(block => asText(block.text)).join('\n') : '';
const actionLine = value => {
  const text = plain(asText(value).replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/`+/g, ''));
  const characters = [...text];
  return characters.length > 100 ? characters.slice(0, 99).join('') + '…' : text;
};
const metadataSummary = value => {
  const text = asText(value);
  // Explicit descriptions are useful; serialized payloads and code blocks are not action prose.
  return /```|^\s*[{\[]/.test(text) ? '' : actionLine(text);
};
const commandSummary = value => {
  const line = asText(value).split(/[\r\n]/, 1)[0].trim();
  if (!line || /```|^\s*[{\[]/.test(line)) return '';
  const tokens = line.match(/"[^"]*"|'[^']*'|\S+/g) ?? [];
  const executable = (tokens[0] ?? '').replace(/^['"]|['"]$/g, '').split(/[\\/]/).at(-1);
  if (!executable || /[{}()[\]`=;|&]/.test(executable) || /^(const|let|var|function|class|import|from|for|while|if|return|print)$/i.test(executable)) return '';
  const safeToken = token => /^[\p{L}\p{N}_.\/-]{1,50}$/u.test(token ?? '') && !/^--?(token|password|secret|key)$/i.test(token);
  const summary = [executable];
  // Keep an executable/subcommand summary rather than inline scripts, full command lines, or JSON.
  if (/^(npm|pnpm|yarn|git|dotnet|go|cargo)(\.exe)?$/i.test(executable)) {
    for (const token of tokens.slice(1, 3)) { if (!safeToken(token)) break; summary.push(token); }
  } else if (/^(node|python|python3|pytest)(\.exe)?$/i.test(executable)) {
    if (tokens[1] === '--test') summary.push('--test');
    else if (tokens[1] === '-m' && safeToken(tokens[2])) summary.push('-m', tokens[2]);
    else if (/\.(js|mjs|cjs|py)$/i.test(tokens[1] ?? '') && safeToken(tokens[1])) summary.push(tokens[1].split(/[\\/]/).at(-1));
  }
  return actionLine(summary.join(' '));
};
const toolAction = (name, argumentsValue) => {
  const toolName = metadataSummary(name);
  const key = asText(name).split(/[.:/]/).at(-1).toLowerCase().replace(/-/g, '_');
  const labels = {
    run_code: '正在运行代码', exec_command: '正在执行命令', bash: '正在执行命令', pwsh: '正在执行命令', shell: '正在执行命令',
    read_file: '正在读取文件', file_read: '正在读取文件', get_file: '正在读取文件', read: '正在读取文件',
    apply_patch: '正在修改文件', edit_file: '正在修改文件', write_file: '正在写入文件', create_file: '正在创建文件', str_replace_editor: '正在修改文件',
    list_files: '正在查看文件', list_directory: '正在查看文件', fs_search: '正在查找文件', search_files: '正在查找文件',
    web: '正在搜索资料', web_search: '正在搜索资料', search_query: '正在搜索资料', search: '正在搜索资料',
    fetch: '正在读取网页', open_url: '正在读取网页', browser: '正在浏览网页',
    subagent: '正在分派任务', spawn_agent: '正在分派任务', wait: '正在等待任务', job_wait: '正在等待任务'
  };
  let args = argumentsValue;
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch { args = null; } }
  let description = '';
  if (args && typeof args === 'object' && !Array.isArray(args)) {
    description = metadataSummary(args.description);
    if (!description) description = commandSummary(args.command ?? args.cmd);
    if (!description) for (const field of ['path', 'file_path', 'query', 'pattern']) {
      description = metadataSummary(args[field]);
      if (description) break;
    }
  }
  const label = labels[key] ?? '正在执行工具';
  return { action: actionLine([label, ...(labels[key] ? [] : [toolName]), description].filter(Boolean).join(' · ')), toolName, toolDescription: description };
};
const toolDetail = (name, argumentsValue) => {
  let value = argumentsValue;
  if (typeof value === 'string') { try { value = JSON.parse(value); } catch {} }
  let detail = '';
  if (value && typeof value === 'object') {
    for (const key of ['command', 'cmd', 'script', 'query', 'pattern', 'path', 'file_path', 'description', 'prompt']) {
      if (typeof value[key] === 'string' && value[key]) { detail = value[key]; break; }
    }
    if (!detail) { try { detail = JSON.stringify(value); } catch {} }
  } else detail = asText(value);
  return clip([asText(name), detail].filter(Boolean).join(' · '));
};

/** One live bubble per Agent identity. Stream attempts own independent buffers. */
export class StateCollector {
  constructor({ now = Date.now } = {}) {
    this.now = now;
    this.rows = new Map();
    this.recent = new Map();
    this.meta = new Map();
    this.degraded = false;
  }
  remember(session, title = '') {
    if (!session?.id) return;
    const old = this.meta.get(session.id) ?? {};
    const next = { title: asText(title) || old.title || '', workspace: asText(session.header?.cwd ?? session.cwd) || old.workspace || '' };
    this.meta.set(session.id, next);
    for (const row of this.rows.values()) if (row.sessionId === session.id) Object.assign(row, next);
  }
  ensure(sessionId, { kind = 'turn', id = `agent:${sessionId}`, ...extra } = {}) {
    if (!sessionId) return null;
    let row = this.rows.get(id);
    if (!row) {
      row = { id, sessionId, kind, title: '', workspace: '', label: '思考中', status: 'running', textKind: 'cot', action: '正在思考下一步', actionKind: 'thinking', toolName: '', toolDescription: '', reasoning: '', output: '', detail: '', startedAt: this.now(), updatedAt: this.now(), attempt: null, revision: 0, nextIndex: 0, blocks: new Map(), updates: [], ...this.meta.get(sessionId), ...extra };
      this.rows.set(id, row);
      this.recent.delete(id);
    }
    return row;
  }
  start(sessionId) {
    const row = this.ensure(sessionId);
    if (row) { row.status = 'running'; this.setAction(row, 'thinking', '正在思考下一步'); row.updatedAt = this.now(); }
  }
  end(sessionId, reason = 'completed', id = `agent:${sessionId}`) {
    const row = this.rows.get(id);
    if (!row) return;
    row.status = failed(reason) ? 'failed' : (reason?.kind ?? reason) === 'killed' ? 'cancelled' : 'done';
    row.label = row.status === 'failed' ? '执行失败' : row.status === 'cancelled' ? '已取消' : '已完成';
    this.setAction(row, row.status, row.label);
    row.updatedAt = this.now();
    row.endedAt = this.now();
    this.rows.delete(id);
    this.recent.delete(id);
    this.recent.set(id, row);
    while (this.recent.size > 8) this.recent.delete(this.recent.keys().next().value);
  }
  status(agent, status) {
    if (!agent?.id) return;
    this.remember(agent.session);
    if (status === 'running') this.start(agent.id);
    else if (status === 'idle') this.end(agent.id);
  }
  note(row, update) {
    row.updates.push(update);
    // These are public live notifications, retained only to merge a reconnect cut with newer frames.
    if (row.updates.length > 512) row.updates.splice(0, row.updates.length - 512);
  }
  setAction(row, kind, action, metadata = {}) {
    Object.assign(row, { action: actionLine(action), actionKind: kind, toolName: '', toolDescription: '', ...metadata });
  }
  setToolAction(row, name, argumentsValue) {
    const metadata = toolAction(name, argumentsValue);
    this.setAction(row, 'tool', metadata.action, metadata);
  }
  resetAttempt(row, frame) {
    row.attempt = frame.attemptId;
    row.revision = frame.revision ?? 0;
    row.turn = frame.turn;
    row.step = frame.step;
    row.nextIndex = 0;
    row.blocks = new Map();
    row.reasoning = '';
    row.output = '';
    row.textKind = 'cot';
    row.label = '思考中';
    row.status = 'running';
    row.detail = '';
    this.setAction(row, 'thinking', '正在思考下一步');
  }
  chunk(row, chunk) {
    if (!chunk) return;
    const type = chunk.type === 'reasoning-delta' ? 'reasoning' : chunk.type === 'text-delta' ? 'text' : chunk.type === 'tool-call-delta' ? 'tool-call' : chunk.block?.type ?? chunk.blockType;
    if (!['text', 'reasoning', 'tool-call'].includes(type)) return;
    const index = Number.isSafeInteger(chunk.index) ? chunk.index : type;
    let block = row.blocks.get(index);
    if (!block) { block = { type, text: '', arguments: '', name: '' }; row.blocks.set(index, block); }
    if (chunk.type === 'block-start') {
      if (type === 'tool-call') this.setToolAction(row, '', null);
      else this.setAction(row, type === 'text' ? 'reply' : 'thinking', type === 'text' ? '正在生成回复' : '正在思考下一步');
      return;
    }
    if (chunk.type === 'block-end') Object.assign(block, { type: chunk.block.type, text: clip(chunk.block.text), name: asText(chunk.block.name), arguments: clip(chunk.block.arguments), closed: true });
    else if (block.closed) return;
    else if (type === 'tool-call') {
      block.name = asText(chunk.name) || block.name;
      block.arguments = clip(block.arguments + asText(chunk.argumentsDelta));
    } else block.text = clip(block.text + asText(chunk.text));
    row.reasoning = clip([...row.blocks.values()].filter(value => value.type === 'reasoning').map(value => value.text).join(''));
    row.output = clip([...row.blocks.values()].filter(value => value.type === 'text').map(value => value.text).join(''));
    if (type === 'tool-call') { row.detail = toolDetail(block.name, block.arguments); row.textKind = 'tool'; row.label = '正在执行工具'; this.setToolAction(row, block.name, block.arguments); }
    else if (type === 'text') { row.textKind = 'output'; row.label = '正在回答'; this.setAction(row, 'reply', '正在生成回复'); }
    else { row.textKind = 'cot'; row.label = '思考中'; this.setAction(row, 'thinking', '正在思考下一步'); }
  }
  stream(agent, frame) {
    if (!agent?.id || !frame) return;
    if (frame.type === 'end' && !this.rows.has(`agent:${agent.id}`)) return;
    const row = this.ensure(agent.id);
    if (!row) return;
    if (frame.type === 'start') {
      if (row.attempt === frame.attemptId && frame.revision <= row.revision) return;
      this.resetAttempt(row, frame);
    } else if (frame.type === 'chunk') {
      // A plugin attached mid-attempt can still show new deltas, but duplicate/out-of-order frames never append twice.
      // revision advances for EVERY frame in DSH; it is not an attempt version.
      if (row.attempt && row.attempt !== frame.attemptId) return;
      if (!row.attempt) { row.attempt = frame.attemptId; row.revision = 0; row.nextIndex = frame.index; }
      if (frame.index < row.nextIndex) return;
      if (frame.revision <= row.revision) return;
      row.nextIndex = frame.index + 1;
      row.revision = frame.revision;
      this.chunk(row, frame.chunk);
    } else if (frame.type === 'end') {
      if (row.attempt && row.attempt !== frame.attemptId || frame.revision < row.revision) return;
      row.revision = frame.revision;
      // Completion belongs to turn/end / status, not to an Assistant stream ending before tools run.
      if (frame.outcome?.kind === 'abandoned') { row.detail = '本次输出已中断'; this.setAction(row, 'thinking', '本次执行已中断，准备继续'); }
    }
    this.note(row, { type: 'frame', frame });
    row.updatedAt = this.now();
  }
  event(session, event) {
    if (!session?.id || !event) return;
    this.remember(session);
    const data = event.data ?? {};
    let row;
    switch (event.type) {
      case 'turn/start': this.start(session.id); break;
      case 'turn/end': this.end(session.id, data.reason); break;
      case 'session/title': this.remember(session, data.title); break;
      case 'tool/call': row = this.ensure(session.id); row.textKind = 'tool'; row.label = '正在执行工具'; row.detail = toolDetail(data.name, data.arguments); this.setToolAction(row, data.name, data.arguments); break;
      case 'tool/result': row = this.rows.get(`agent:${session.id}`); if (row) { row.detail = clip(contentText(data.message?.content)) || row.detail; row.textKind = 'tool'; const error = data.error || data.message?.isError; row.label = error ? '工具返回错误' : '工具执行完成'; this.setAction(row, 'tool-result', error ? '工具执行失败，准备继续' : '工具执行完成，准备继续'); } break;
      case 'approval/asked': row = this.ensure(session.id); row.status = 'waiting'; row.label = '等待确认'; row.detail = asText(data.reason) || asText(data.toolName); this.setAction(row, 'waiting', '等待确认'); break;
      case 'approval/decided': row = this.rows.get(`agent:${session.id}`); if (row) { row.status = 'running'; row.label = '继续执行'; this.setAction(row, 'thinking', '正在思考下一步'); } break;
      case 'assistant/message': {
        row = this.rows.get(`agent:${session.id}`);
        if (!row) break;
        const content = data.message?.content;
        if (Array.isArray(content)) {
          const output = contentText(content);
          const reasoning = contentText(content, 'reasoning');
          if (reasoning) { row.reasoning = clip(reasoning); this.setAction(row, 'thinking', '正在思考下一步'); }
          if (output) { row.output = clip(output); row.textKind = 'output'; row.label = '正在回答'; this.setAction(row, 'reply', '正在生成回复'); }
          const tool = content.filter(block => block?.type === 'tool-call').at(-1);
          if (tool) { row.detail = toolDetail(tool.name, tool.arguments); row.textKind = 'tool'; row.label = '正在执行工具'; this.setToolAction(row, tool.name, tool.arguments); }
        }
        break;
      }
      default: break;
    }
    row ??= this.rows.get(`agent:${session.id}`);
    if (row) { this.note(row, { type: 'event', event }); row.updatedAt = this.now(); }
  }
  restore(agent, snapshot) {
    const current = this.rows.get(`agent:${agent.id}`);
    if (!current || agent.status !== 'running' || snapshot?.type !== 'snapshot') return false;
    const events = (snapshot.records ?? []).filter(record => record?.type === 'event').map(record => record.event);
    const start = events.findLastIndex(event => event?.type === 'turn/start');
    const baseline = snapshot.assistantStream;
    const attempt = baseline?.activeAttempt;
    // A long turn can hit the public page's message cap before its turn/start marker.
    // Recover the newest explicit turn suffix instead of dropping available current activity.
    const latestTurn = events.findLast(event => Number.isSafeInteger(event?.data?.turn))?.data.turn;
    const from = start >= 0 ? start : latestTurn === undefined ? -1 : events.findIndex(event => event?.data?.turn === latestTurn);
    if (from < 0 && !attempt) return false;
    const recovered = new StateCollector({ now: this.now });
    recovered.meta = new Map(this.meta);
    recovered.start(agent.id);
    for (const event of events.slice(Math.max(0, from))) recovered.event(agent.session, event);
    if (attempt) {
      const row = recovered.ensure(agent.id);
      recovered.resetAttempt(row, { ...attempt, revision: baseline.revision });
      for (const record of attempt.stream ?? []) {
        if (record.type === 'chunk') recovered.chunk(row, record.chunk);
        else if (record.type === 'text-chunks' || record.type === 'reasoning-chunks') recovered.chunk(row, { type: record.type === 'text-chunks' ? 'text-delta' : 'reasoning-delta', index: record.index, text: (record.texts ?? []).join('') });
        else if (record.type === 'tool-call-chunks') recovered.chunk(row, { type: 'tool-call-delta', index: record.index, id: record.id, name: record.name, argumentsDelta: (record.args ?? []).join('') });
      }
      row.nextIndex = attempt.nextIndex;
    }
    // The opening snapshot may race with newer direct notifications. Replay only the suffix
    // outside both of its cuts, in original arrival order, instead of replacing newer activity.
    for (const update of current.updates) {
      if (update.type === 'frame' && update.frame.revision > (baseline?.revision ?? 0)) recovered.stream(agent, update.frame);
      else if (update.type === 'event' && update.event.seq > snapshot.cursor) recovered.event(agent.session, update.event);
    }
    const row = recovered.rows.get(current.id);
    if (!row) return false;
    Object.assign(row, { startedAt: current.startedAt, updatedAt: current.updatedAt, updates: current.updates });
    this.rows.set(current.id, row);
    return true;
  }
  reconcileAgents(agents) {
    const live = new Set();
    for (const agent of agents ?? []) {
      if (!agent?.id) continue;
      this.remember(agent.session);
      if (agent.status === 'running') {
        live.add(agent.id);
        // Preserve approval waits while the Agent driver remains running.
        this.ensure(agent.id);
      } else this.end(agent.id);
    }
    for (const row of [...this.rows.values()]) if (row.kind === 'turn' && !live.has(row.sessionId)) this.end(row.sessionId, 'completed');
  }
  reconcileJobs(jobs) {
    const live = new Set();
    for (const job of jobs ?? []) {
      const owner = typeof job.owner === 'string' ? job.owner : job.sessionId;
      if (!job.id || !owner) continue;
      const id = `job:${job.id}`;
      if (['running', 'stopping'].includes(job.status)) {
        live.add(id);
        const row = this.ensure(owner, { id, kind: 'job' });
        const label = plain(job.label || job.kind || '后台任务').slice(0, 60);
        row.label = job.status === 'stopping' ? `正在停止 · ${label}` : label;
        row.status = 'running';
        const description = metadataSummary(job.label) || metadataSummary(job.kind) || '后台任务';
        this.setAction(row, 'job', [job.status === 'stopping' ? '正在停止后台任务' : '正在执行后台任务', description].join(' · '));
        row.textKind = 'tool'; row.detail = asText(job.detail) || asText(job.kind); row.updatedAt = this.now();
      } else this.end(owner, job.status, id);
    }
    for (const row of [...this.rows.values()]) if (row.kind === 'job' && !live.has(row.id)) this.end(row.sessionId, 'completed', row.id);
  }
  snapshot() {
    const now = this.now();
    for (const [id, row] of this.recent) if (now - row.endedAt > 30000) this.recent.delete(id);
    const expose = row => {
      const activity = plain(row.textKind === 'cot' ? row.reasoning : row.textKind === 'output' ? row.output : row.detail || row.output).slice(-400);
      return { id: row.id, sessionId: row.sessionId, title: row.title, workspace: row.workspace, kind: row.kind, label: row.label, status: row.status, action: row.status === 'waiting' ? '等待确认' : actionLine(row.action), textKind: row.textKind, text: activity, activity, activityKind: row.textKind, reasoning: row.reasoning, output: row.output, detail: row.detail, startedAt: row.startedAt, updatedAt: row.updatedAt };
    };
    const tasks = [...this.rows.values()].sort((a, b) => a.startedAt - b.startedAt).map(expose);
    const recent = [...this.recent.values()].slice(-8).map(expose);
    const latest = recent.at(-1);
    const settledState = latest && now - latest.updatedAt < 3000 ? latest.status === 'cancelled' ? 'cancelled' : 'done' : 'idle';
    const petState = tasks.some(row => row.status === 'waiting') ? 'waiting' : tasks.some(row => row.textKind === 'tool') ? 'working' : tasks.length ? 'thinking' : recent.some(row => row.status === 'failed' && now - row.updatedAt < 5000) ? 'error' : settledState;
    return { pet: { state: petState, label: { waiting: '等待确认', working: '正在工作', thinking: '思考中', done: '已完成', cancelled: '已取消', error: '执行失败', idle: '待机' }[petState] }, tasks, recent, degraded: this.degraded };
  }
}

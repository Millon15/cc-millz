import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const [verb, ...args] = process.argv.slice(2);
const root = process.env.FAKE_COMPANION_DIR;
const mode = process.env.FAKE_COMPANION_MODE || 'complete';
const option = name => args[args.indexOf(`--${name}`) + 1];
const stateFile = path.join(root, 'state.json');
const emit = value => process.stdout.write(`${JSON.stringify(value)}\n`);
const write = value => fs.writeFileSync(stateFile, JSON.stringify(value));
const read = () => JSON.parse(fs.readFileSync(stateFile, 'utf8'));
const report = verdict => ({ schema: 'codex-report/1', verdict, summary: 'Fixture result', claims: [], blocked: [] });
const raw = mode === 'malformed' ? '```json\n{"schema":"codex-report/1",\n```'
  : mode === 'partial' ? '```json\n{"schema":"codex-report/1"' : `\`\`\`json\n${JSON.stringify(report('pass'))}\n\`\`\``;

if (verb === 'task' && !args.includes('--background')) {
  const reason = process.env.FAKE_PROBE_REASON;
  if (reason) { process.stderr.write(reason); process.exitCode = 1; }
  else emit({ status: 0, rawOutput: 'CODEX_JOB_PROBE_OK' });
} else if (verb === 'task') {
  fs.appendFileSync(path.join(root, 'launches'), 'launch\n');
  const state = { id: 'task-fixture', status: mode.startsWith('cancel-') || mode === 'running' ? 'running' : 'completed',
    workspaceRoot: option('cwd'), threadId: 'thread-fixture', turnId: 'turn-fixture',
    pid: Number(process.env.FAKE_JOB_PID) || null, model: 'fixture-model' };
  if (['cancel-stop', 'cancel-delayed', 'cancel-queued', 'cancel-no-interrupt'].includes(mode)) {
    const delay = mode === 'cancel-delayed' ? 1500 : 100;
    const child = spawn(process.execPath, ['-e',
      `process.on('SIGTERM', () => setTimeout(() => process.exit(0), ${delay})); setTimeout(() => {}, 30000)`],
      { detached: true, stdio: 'ignore' });
    child.unref(); state.pid = child.pid;
  }
  if (mode === 'cancel-queued') { state.threadId = null; state.turnId = null; state.status = 'queued'; }
  if (mode === 'out-of-scope') fs.writeFileSync(path.join(state.workspaceRoot, 'outside.txt'), 'unexpected edit\n');
  if (mode === 'owned-edit') fs.writeFileSync(path.join(state.workspaceRoot, 'source.txt'), 'changed\n');
  if (mode === 'crash') {
    fs.writeFileSync(path.join(state.workspaceRoot, 'source.txt'), 'partial edit\n');
    state.status = 'failed';
    write(state);
    process.stderr.write('Connection failed after turn start');
    process.exitCode = 1;
  } else { write(state); emit({ jobId: state.id, status: 'queued' }); }
} else if (verb === 'status') {
  if (process.env.FAKE_STATUS_DELAY_MS) {
    await new Promise(resolve => setTimeout(resolve, Number(process.env.FAKE_STATUS_DELAY_MS)));
  }
  emit({ job: read() });
}
else if (verb === 'result') {
  const state = read();
  emit({ job: state, storedJob: { ...state, result: { rawOutput: raw } } });
} else if (verb === 'cancel') {
  fs.appendFileSync(path.join(root, 'cancels'), 'cancel\n');
  const state = read();
  if (mode !== 'cancel-live' && state.pid) {
    try { process.kill(state.pid, 'SIGTERM'); } catch { /* The fixture child may have already exited. */ }
  }
  state.status = 'cancelled';
  state.pid = null;
  write(state);
  emit({ jobId: state.id, status: 'cancelled', turnInterrupted: !!state.turnId && mode !== 'cancel-no-interrupt' });
} else { process.stderr.write('Unknown fixture verb'); process.exitCode = 1; }

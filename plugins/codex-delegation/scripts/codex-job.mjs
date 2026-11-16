#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Refusal, now, hash, regularFile, atomicJson, git, workspace, assertWorkspace, ownedPaths,
  alive, withRecord, save, assertRunDirectory, assertProtectedPaths, readJson } from './job-storage.mjs';
import { resolveCompanion, assertRecordedCompanion, callCompanion, callTimeout, availabilityReason,
  explain } from './job-companion.mjs';
import { baselineChanges, saveDiff, saveResult } from './job-evidence.mjs';

const terminal = new Set(['completed', 'failed', 'cancelled']);
const optionsByVerb = {
  probe: ['cwd', 'sandbox', 'model'],
  start: ['run-dir', 'invocation-id', 'cwd', 'prompt-file', 'sandbox', 'write', 'owned', 'model', 'effort'],
  status: ['run-dir', 'invocation-id'], collect: ['run-dir', 'invocation-id', 'wait-seconds'],
  cancel: ['run-dir', 'invocation-id'], dispose: ['run-dir', 'invocation-id', 'decision', 'reason'],
};

function parse(argv) {
  const [verb, ...args] = argv;
  if (!optionsByVerb[verb]) throw new Refusal('Expected probe, start, status, collect, cancel or dispose');
  const options = { owned: [] };
  for (let i = 0; i < args.length; i++) {
    const key = args[i].startsWith('--') ? args[i].slice(2) : '';
    if (!optionsByVerb[verb].includes(key)) throw new Refusal(`Unknown option: ${args[i]}`);
    if (key === 'write') { options.write = true; continue; }
    const value = args[++i];
    if (value === undefined || value.startsWith('--')) throw new Refusal(`Missing value: --${key}`);
    if (key === 'owned') options.owned.push(value);
    else if (options[key] !== undefined) throw new Refusal(`Repeated option: --${key}`);
    else options[key] = value;
  }
  return { verb, options };
}

function guard() {
  if (process.env.CODEX_THREAD_ID || process.env.CODEX_SESSION_ID) {
    throw new Refusal('This Claude-side adapter cannot run from a Codex session');
  }
}

function settings(options) {
  if (!options.cwd) throw new Refusal('--cwd is required');
  const sandbox = options.sandbox || 'read-only';
  if (!['read-only', 'workspace-write'].includes(sandbox)) throw new Refusal('Unsupported sandbox');
  if (options.write && (sandbox !== 'workspace-write' || !options.owned.length)) {
    throw new Refusal('--write requires workspace-write and at least one --owned path');
  }
  if (!options.write && options.owned.length) throw new Refusal('--owned requires --write');
  if (options.effort && !['none', 'minimal', 'low', 'medium', 'high', 'xhigh'].includes(options.effort)) {
    throw new Refusal('Unsupported effort');
  }
  return { ...workspace(options.cwd), sandbox, write: !!options.write,
    owned_paths: ownedPaths(options.owned, options.cwd), model_requested: options.model || null,
    effort_requested: options.effort || null };
}

function companionSettings(companion, input) {
  return { ...input, companion_path: companion.path, companion_version: companion.version };
}

function executionArgs(input) {
  return [...(input.write || input.sandbox === 'workspace-write' ? ['--write'] : []),
    ...(input.model_requested ? ['--model', input.model_requested] : []),
    ...(input.effort_requested ? ['--effort', input.effort_requested] : [])];
}

function probe(options) {
  const input = settings({ ...options, owned: [] });
  const base = { available: false, reason: 'unknown', detail: '', companion: null,
    companion_version: null, cwd: input.cwd, sandbox: input.sandbox, model_requested: input.model_requested };
  let companion;
  try { companion = resolveCompanion(); }
  catch (error) {
    return { value: { ...base, reason: availabilityReason(error.message), detail: error.message }, code: 3 };
  }
  base.companion = companion.path;
  base.companion_version = companion.version;
  assertProtectedPaths(input, path.dirname(fileURLToPath(import.meta.url)),
    fileURLToPath(import.meta.url), companion.path);
  const result = callCompanion(companionSettings(companion, input), 'task', [...executionArgs(input), '--',
    'Do not use tools or change files. Reply with exactly CODEX_JOB_PROBE_OK.']);
  const ready = result.ok && result.payload.status === 0 && result.payload.rawOutput?.trim() === 'CODEX_JOB_PROBE_OK';
  const detail = ready ? 'A probe turn completed under the requested configuration'
    : [result.stderr, result.stdout].filter(Boolean).join('\n');
  return { value: { ...base, available: ready, reason: ready ? 'ok' : availabilityReason(detail), detail },
    code: ready ? 0 : 3 };
}

function retryMatches(record, input, promptHash) {
  for (const key of ['cwd', 'worktree', 'base_sha', 'sandbox', 'write', 'model_requested', 'effort_requested']) {
    if (record[key] !== input[key]) throw new Refusal(`Invocation retry changed ${key}`);
  }
  if (record.prompt_sha256 !== promptHash || JSON.stringify(record.owned_paths) !== JSON.stringify(input.owned_paths)) {
    throw new Refusal('Invocation retry changed its prompt or owned paths');
  }
}

function initialRecord(options, input, companion, promptPath, promptHash) {
  return { schema: 'codex-job/1', invocation_id: options['invocation-id'], lifecycle: 'prepared',
    verdict: 'unknown', disposition: 'pending', backend: 'companion', ...companionSettings(companion, input),
    job_id: null, thread_id: null, turn_id: null, prompt_path: promptPath, prompt_sha256: promptHash,
    model_observed: 'unknown', timestamps: { prepared_at: now(), started_at: null, finished_at: null,
      collected_at: null, disposed_at: null }, raw_output_path: null, report_path: null, diff_path: null,
    baseline_changes: baselineChanges(input), changed_paths: [], job_changed_paths: [],
    out_of_scope_paths: [], blocked: [], error: null };
}

function uncertain(file, record, stage, message) {
  return save(file, { ...record, lifecycle: 'uncertain', verdict: 'unknown', error: { stage, message } });
}

function start(options, context) {
  const input = settings(options);
  const prompt = fs.readFileSync(regularFile(options['prompt-file'] || ''));
  if (!prompt.length) throw new Refusal('The prompt must not be empty');
  if (context.existing) {
    retryMatches(context.existing, input, hash(prompt));
    return recoverIntent(context);
  }
  if (input.write && git(input.cwd, ['status', '--porcelain=v1', '--untracked-files=all'])) {
    throw new Refusal('Write jobs require a clean isolated worktree');
  }
  const companion = resolveCompanion();
  assertProtectedPaths(input, context.directory, fileURLToPath(import.meta.url), companion.path);
  fs.mkdirSync(context.directory, { mode: 0o700 });
  const promptPath = path.join(context.directory, 'prompt.txt');
  fs.writeFileSync(promptPath, prompt, { mode: 0o600, flag: 'wx' });
  const prepared = initialRecord(options, input, companion, promptPath, hash(prompt));
  save(context.file, prepared);
  const launching = save(context.file, { ...prepared, lifecycle: 'starting' });
  const result = callCompanion(launching, 'task', ['--background', '--prompt-file', promptPath,
    ...executionArgs(input)]);
  atomicJson(path.join(context.directory, 'launch.json'), result);
  if (!result.ok || typeof result.payload.jobId !== 'string' || !result.payload.jobId) {
    return uncertain(context.file, launching, 'launch', result.stderr || 'No tracked job id returned after launch');
  }
  return save(context.file, { ...launching, lifecycle: 'running', job_id: result.payload.jobId,
    timestamps: { ...launching.timestamps, started_at: now() } });
}

function recoverIntent(context) {
  const record = context.existing;
  if (!record.job_id && ['prepared', 'starting'].includes(record.lifecycle)) {
    return uncertain(context.file, record, 'launch', 'Interrupted launch intent; inspect companion jobs, do not relaunch');
  }
  return record;
}

function remaining(context) {
  return context.deadline ? Math.max(1, context.deadline - Date.now()) : Infinity;
}

function currentJob(record, timeoutMs = Infinity) {
  const result = callCompanion(record, 'status', [record.job_id], timeoutMs);
  const job = result.payload?.job;
  if (!result.ok || !job || job.id !== record.job_id) {
    const error = new Error(result.stderr || 'The companion status did not identify the recorded job');
    error.timed_out = result.timed_out;
    throw error;
  }
  if (job.workspaceRoot && fs.realpathSync(job.workspaceRoot) !== record.cwd) {
    throw new Refusal('The companion job belongs to another worktree');
  }
  return job;
}

function refresh(context) {
  let record = recoverIntent(context);
  if (!record.job_id || record.timestamps.collected_at || terminal.has(record.lifecycle)) return record;
  let job;
  try { job = currentJob(record, remaining(context)); }
  catch (error) {
    if (error instanceof Refusal) throw error;
    if (error.timed_out && context.deadline) return record;
    return uncertain(context.file, record, 'status', error.message);
  }
  const lifecycle = job.status === 'completed' ? 'completed'
    : ['failed', 'cancelled'].includes(job.status) ? 'uncertain' : 'running';
  record = { ...record, lifecycle, thread_id: job.threadId || record.thread_id,
    turn_id: job.turnId || record.turn_id, companion_pid: job.pid || record.companion_pid || null,
    model_observed: job.model || record.model_observed,
    timestamps: { ...record.timestamps, finished_at: job.completedAt || record.timestamps.finished_at },
    error: lifecycle === 'uncertain' ? { stage: 'execution', message: job.errorMessage || `Companion ${job.status}` } : null };
  return save(context.file, record);
}

function collectOnce(context) {
  const record = refresh(context);
  if (record.timestamps.collected_at || record.lifecycle === 'running') return record;
  if (!record.job_id) {
    return save(context.file, { ...record, ...saveDiff(record, context.directory),
      timestamps: { ...record.timestamps, collected_at: now() } });
  }
  const result = callCompanion(record, 'result', [record.job_id], remaining(context));
  if (!result.ok || result.payload?.job?.id !== record.job_id || !result.payload.storedJob) {
    return uncertain(context.file, record, 'collect', result.stderr || 'Result identity or stored output missing');
  }
  const stored = result.payload.storedJob;
  const evidence = saveResult(record, context.directory, stored);
  return save(context.file, { ...record, ...evidence,
    thread_id: stored.threadId || record.thread_id, turn_id: stored.turnId || record.turn_id,
    timestamps: { ...record.timestamps, collected_at: now() } });
}

async function collect(options, context) {
  const seconds = Number(options['wait-seconds'] || 0);
  if (!Number.isFinite(seconds) || seconds < 0) throw new Refusal('--wait-seconds must be nonnegative');
  const deadline = Date.now() + seconds * 1000;
  if (seconds > 0) context.deadline = deadline;
  let record;
  do {
    record = collectOnce(context);
    context.existing = record;
    if (record.lifecycle !== 'running' || Date.now() >= deadline) return record;
    await new Promise(resolve => setTimeout(resolve, Math.min(250, deadline - Date.now())));
  } while (true);
}

async function observeCancellation(context, record) {
  const attempt = record.cancellation;
  const receiptPath = path.join(context.directory, 'cancel.json');
  const receipt = fs.existsSync(receiptPath) ? readJson(regularFile(receiptPath)) : null;
  const deadline = Date.now() + 1000;
  while (alive(attempt.pid) && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  let after;
  try { after = currentJob(record); }
  catch (error) { return uncertain(context.file, record, 'cancel', error.message); }
  const turnKnown = !!(attempt.turn_id || after.turnId);
  const interruptConfirmed = receipt?.ok && receipt.payload?.jobId === record.job_id
    && (!turnKnown || receipt.payload.turnInterrupted === true);
  const stopped = interruptConfirmed && Number.isInteger(attempt.pid) && !alive(attempt.pid)
    && after.status === 'cancelled';
  const evidence = saveDiff(record, context.directory);
  if (!stopped) return uncertain(context.file, { ...record, ...evidence }, 'cancel',
    'Process exit or required turn interruption remains unproven; ownership remains reserved');
  return save(context.file, { ...record, ...evidence, lifecycle: 'cancelled', verdict: 'unknown', error: null,
    timestamps: { ...record.timestamps, finished_at: now(), collected_at: now() } });
}

async function cancel(context) {
  if (context.existing.lifecycle === 'cancelled') return context.existing;
  if (context.existing.cancellation) return observeCancellation(context, context.existing);
  const record = refresh(context);
  if (terminal.has(record.lifecycle) && record.lifecycle !== 'cancelled') return collectOnce({ ...context, existing: record });
  if (record.lifecycle === 'cancelled') return record;
  if (!record.job_id) return uncertain(context.file, record, 'cancel', 'No job id; stop cannot be established');
  const before = currentJob(record);
  const cancelling = save(context.file, { ...record, cancellation: {
    requested_at: now(), pid: before.pid || record.companion_pid || null,
    turn_id: before.turnId || record.turn_id || null,
  } });
  const result = callCompanion(cancelling, 'cancel', [record.job_id]);
  atomicJson(path.join(context.directory, 'cancel.json'), result);
  return observeCancellation(context, cancelling);
}

function dispose(options, context) {
  const record = context.existing;
  if (!['accepted', 'rejected'].includes(options.decision) || !options.reason?.trim()) {
    throw new Refusal('dispose requires --decision accepted|rejected and a nonempty --reason');
  }
  if (options.decision === 'accepted' && (!terminal.has(record.lifecycle) || !record.timestamps.collected_at)) {
    throw new Refusal('Acceptance requires a collected, reconciled terminal lifecycle');
  }
  if (record.disposition !== 'pending') {
    if (record.disposition === options.decision && record.disposition_reason === options.reason) return record;
    throw new Refusal('The parent disposition has already been recorded');
  }
  return save(context.file, { ...record, disposition: options.decision, disposition_reason: options.reason,
    timestamps: { ...record.timestamps, disposed_at: now() } });
}

function exitFor(record) {
  if (record.lifecycle === 'uncertain') return 5;
  if (['starting', 'running', 'prepared'].includes(record.lifecycle)) return 4;
  return 0;
}

async function main(argv) {
  if (argv.length === 1 && argv[0] === '--explain') {
    return { value: explain(fileURLToPath(import.meta.url)), code: 0 };
  }
  guard();
  const { verb, options } = parse(argv);
  callTimeout();
  if (verb === 'probe') return probe(options);
  if (verb === 'start') assertRunDirectory(options['run-dir'], settings(options).cwd);
  return withRecord(options, async context => {
    if (verb !== 'start' && !context.existing) throw new Refusal('Unknown invocation id');
    if (context.existing) {
      const companion = assertRecordedCompanion(context.existing);
      assertProtectedPaths(context.existing, context.directory, fileURLToPath(import.meta.url), companion.path);
      assertWorkspace(context.existing);
    }
    let record;
    if (verb === 'start') record = start(options, context);
    if (verb === 'status') record = refresh(context);
    if (verb === 'collect') record = await collect(options, context);
    if (verb === 'cancel') record = await cancel(context);
    if (verb === 'dispose') record = dispose(options, context);
    return { value: record, code: verb === 'start' && record.job_id && record.lifecycle === 'running' ? 0
      : verb === 'status' && record.lifecycle === 'running' ? 0 : exitFor(record) };
  });
}

try {
  const { value, code } = await main(process.argv.slice(2));
  process.stdout.write(`${JSON.stringify(value)}\n`);
  process.exitCode = code;
} catch (error) {
  process.stdout.write(`${JSON.stringify({ schema: 'codex-job-error/1', error: { stage: 'adapter',
    message: error.message } })}\n`);
  process.exitCode = Number.isInteger(error.code) ? error.code : 1;
}

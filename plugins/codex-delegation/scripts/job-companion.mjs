import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { Refusal, readJson, regularFile } from './job-storage.mjs';

function versionOf(file) {
  const root = path.resolve(path.dirname(file), '..');
  const manifest = path.join(root, '.claude-plugin', 'plugin.json');
  try { return readJson(regularFile(manifest)).version; }
  catch { throw new Refusal('Unsupported companion: a readable version manifest is required', 3); }
}

function supported(version) {
  const match = /^1\.(\d+)\.(\d+)$/.exec(version);
  return !!match && (Number(match[1]) > 0 || Number(match[2]) >= 6);
}

export function resolveCompanion() {
  const explicit = process.env.CODEX_JOB_COMPANION;
  if (explicit) {
    if (!fs.existsSync(explicit)) throw new Refusal('The configured companion is not installed', 3);
    return resolved(regularFile(explicit), 'detected:CODEX_JOB_COMPANION');
  }
  const cache = path.join(os.homedir(), '.claude', 'plugins', 'cache', 'openai-codex', 'codex');
  if (!fs.existsSync(cache)) throw new Refusal('The official companion is not installed', 3);
  const versions = fs.readdirSync(cache).filter(supported).sort((a, b) => b.localeCompare(a, 'en', { numeric: true }));
  for (const version of versions) {
    const file = path.join(cache, version, 'scripts', 'codex-companion.mjs');
    if (fs.existsSync(file)) return resolved(regularFile(file), 'detected:installed-companion');
  }
  throw new Refusal('No supported official companion found; requires version 1.0.6 or a newer 1.x version', 3);
}

function resolved(file, source) {
  const version = versionOf(file);
  if (!supported(version)) throw new Refusal(`Unsupported companion version: ${version}`, 3);
  return { path: file, version, source };
}

export function callCompanion(record, verb, args = [], timeoutMs = Infinity) {
  const seconds = callTimeout();
  const companion = assertRecordedCompanion(record);
  const command = [companion.path, verb, '--cwd', record.cwd, '--json', ...args];
  const result = spawnSync(process.execPath, command, {
    encoding: 'utf8', timeout: Math.max(1, Math.min(seconds * 1000, timeoutMs)), maxBuffer: 32 * 1024 * 1024,
  });
  let payload = null;
  try { payload = JSON.parse(result.stdout); } catch { /* Raw diagnostics remain available to the caller. */ }
  return { ok: result.status === 0 && payload !== null, payload, stdout: result.stdout || '',
    stderr: result.stderr || String(result.error || ''), exit: result.status,
    timed_out: result.error?.code === 'ETIMEDOUT' };
}

export function assertRecordedCompanion(record) {
  let companion;
  try { companion = resolveCompanion(); }
  catch { throw new Refusal('The recorded companion no longer resolves from the parent environment'); }
  if (companion.path !== record.companion_path || companion.version !== record.companion_version) {
    throw new Refusal('The recorded companion path or version differs from the parent-selected runtime');
  }
  return companion;
}

export function callTimeout() {
  const seconds = Number(process.env.CODEX_JOB_CALL_TIMEOUT_SECONDS || 60);
  if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 600) {
    throw new Refusal('CODEX_JOB_CALL_TIMEOUT_SECONDS must be greater than 0 and at most 600');
  }
  return seconds;
}

export function availabilityReason(detail) {
  if (/permission denied|sandbox|operation not permitted|approval.*denied/i.test(detail)) return 'denied';
  if (/not installed|not found|ENOENT|missing.*runtime/i.test(detail)) return 'absent';
  if (/quota|usage limit|rate.limit|429/i.test(detail)) return 'quota';
  if (/not authenticated|unauthenticated|login required|log.?in|401|refresh token/i.test(detail)) {
    return 'unauthenticated';
  }
  if (/unsupported|unknown model|invalid model|model.*not.*available/i.test(detail)) return 'unsupported';
  return 'unknown';
}

export function explain(script) {
  let companion = null;
  try { companion = resolveCompanion(); } catch { /* Explain describes absence without launching a probe. */ }
  const values = { script, companion: companion?.path || null, companion_version: companion?.version || null,
    call_timeout_seconds: callTimeout(),
    verbs: ['probe', 'start', 'status', 'collect', 'cancel', 'dispose'],
    exit_codes: { ok: 0, internal: 1, refused: 2, unavailable: 3, running: 4, uncertain: 5 } };
  const sources = Object.fromEntries(Object.keys(values).map(key => [key, 'default']));
  sources.companion = companion?.source || 'detected:companion-absent';
  sources.companion_version = sources.companion;
  sources.call_timeout_seconds = process.env.CODEX_JOB_CALL_TIMEOUT_SECONDS
    ? 'detected:CODEX_JOB_CALL_TIMEOUT_SECONDS' : 'default';
  return { plugin: 'codex-delegation', profile_file: null, values, sources };
}

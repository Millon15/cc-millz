import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

export class Refusal extends Error {
  constructor(message, code = 2) { super(message); this.code = code; }
}

export const now = () => new Date().toISOString();
export const hash = value => crypto.createHash('sha256').update(value).digest('hex');
export const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));

export function noSymlinks(file) {
  const absolute = path.resolve(file);
  let current = path.parse(absolute).root;
  for (const part of absolute.slice(current.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    let stat;
    try { stat = fs.lstatSync(current); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    if (stat.isSymbolicLink()) throw new Refusal(`Symlink refused: ${current}`);
  }
  return absolute;
}

export function regularFile(file) {
  const absolute = noSymlinks(file);
  if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
    throw new Refusal(`Regular file required: ${absolute}`);
  }
  return absolute;
}

export function atomicJson(file, value) {
  atomicFile(file, `${JSON.stringify(value, null, 2)}\n`);
}

export function atomicFile(file, value) {
  noSymlinks(file);
  const candidate = `${file}.tmp-${process.pid}-${crypto.randomUUID()}`;
  fs.writeFileSync(candidate, value, { mode: 0o600, flag: 'wx' });
  fs.renameSync(candidate, file);
}

export function git(cwd, args, { binary = false } = {}) {
  const result = spawnSync('git', ['--no-optional-locks', '-C', cwd, ...args], {
    encoding: binary ? null : 'utf8', timeout: 10000, maxBuffer: 32 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Refusal(`Git failed: ${String(result.stderr || result.error)}`);
  return binary ? result.stdout : result.stdout.trimEnd();
}

export function workspace(cwd) {
  const requested = noSymlinks(cwd);
  if (!fs.existsSync(requested) || !fs.statSync(requested).isDirectory()) {
    throw new Refusal('The cwd must be an existing worktree directory');
  }
  const root = fs.realpathSync(git(requested, ['rev-parse', '--show-toplevel']));
  if (requested !== root) throw new Refusal('The cwd must be the worktree root');
  const gitDir = fs.realpathSync(git(root, ['rev-parse', '--absolute-git-dir']));
  return { cwd: root, worktree: gitDir, base_sha: git(root, ['rev-parse', 'HEAD']) };
}

export function assertWorkspace(record) {
  const current = workspace(record.cwd);
  if (current.worktree !== record.worktree || current.base_sha !== record.base_sha) {
    throw new Refusal('The worktree identity or HEAD changed since launch');
  }
}

export function ownedPaths(paths, cwd) {
  return [...new Set(paths.map(value => {
    const clean = value.replace(/\/$/, '');
    if (!clean || path.isAbsolute(clean) || clean.split('/').some(p => !p || p === '..' || p === '.')) {
      throw new Refusal(`Owned path must be repo-relative: ${value}`);
    }
    noSymlinks(path.join(cwd, clean));
    if (clean === '.git' || clean.startsWith('.git/')) throw new Refusal('Git metadata cannot be owned');
    return clean;
  }))].sort();
}

export function alive(pid) {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code !== 'ESRCH'; }
}

function releaseLock(lock) {
  const released = `${lock}.released-${process.pid}-${crypto.randomUUID()}`;
  fs.renameSync(lock, released);
  try { fs.unlinkSync(path.join(released, 'owner.json')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  fs.rmdirSync(released);
}

export function assertRunDirectory(directory, cwd) {
  if (!directory) throw new Refusal('--run-dir is required');
  const root = noSymlinks(directory);
  const relative = path.relative(cwd, root);
  if (relative.startsWith(`..${path.sep}`) || relative === '..' || path.isAbsolute(relative)) return;
  if (!relative) throw new Refusal('The run directory cannot be the worktree root');
  const result = spawnSync('git', ['--no-optional-locks', '-C', cwd, 'check-ignore', '-q', '--', `${relative}/`],
    { encoding: 'utf8', timeout: 10000 });
  if (result.status !== 0) throw new Refusal('A run directory inside the worktree must be gitignored');
}

function canonicalPath(file) {
  const absolute = path.resolve(file);
  if (fs.existsSync(absolute)) return fs.realpathSync(absolute);
  return path.join(canonicalPath(path.dirname(absolute)), path.basename(absolute));
}

function inside(file, root) {
  const key = value => process.platform === 'darwin' || process.platform === 'win32' ? value.toLowerCase() : value;
  const relative = path.relative(key(root), key(file));
  return !relative || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

export function assertProtectedPaths(record, runDirectory, adapterPath, companionPath) {
  if (record.sandbox !== 'workspace-write') return;
  const roots = [record.cwd, '/tmp', '/private/tmp', process.env.TMPDIR].filter(Boolean).map(canonicalPath);
  for (const file of [runDirectory, adapterPath, companionPath]) {
    const canonical = canonicalPath(noSymlinks(file));
    if (roots.some(root => inside(canonical, root))) {
      throw new Refusal('Workspace-write requires records and runtime scripts outside cwd, /tmp and TMPDIR');
    }
  }
}

function takeLock(lock) {
  try { fs.mkdirSync(lock, { mode: 0o700 }); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    recoverLock(lock);
    try { fs.mkdirSync(lock, { mode: 0o700 }); }
    catch { throw new Refusal('Another adapter operation owns this invocation'); }
  }
  atomicJson(path.join(lock, 'owner.json'), { pid: process.pid });
}

function recoverLock(lock) {
  const guard = `${lock}.recovering`;
  try { fs.mkdirSync(guard, { mode: 0o700 }); }
  catch { throw new Refusal('Another adapter operation is recovering this invocation'); }
  try {
    const owner = readJson(regularFile(path.join(lock, 'owner.json')));
    if (alive(owner.pid)) throw new Refusal('Another adapter operation owns this invocation');
    releaseLock(lock);
  } finally { releaseLock(guard); }
}

export async function withRecord(options, callback) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(options['invocation-id'] || '')) {
    throw new Refusal('A safe --invocation-id is required');
  }
  if (!options['run-dir']) throw new Refusal('--run-dir is required');
  const root = noSymlinks(options['run-dir']);
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  const directory = noSymlinks(path.join(root, options['invocation-id']));
  const lock = `${directory}.lock`;
  noSymlinks(lock);
  takeLock(lock);
  try {
    const file = path.join(directory, 'record.json');
    const existing = fs.existsSync(file) ? readJson(regularFile(file)) : null;
    if (existing && (existing.schema !== 'codex-job/1' || existing.invocation_id !== options['invocation-id'])) {
      throw new Refusal('Invalid invocation record');
    }
    return await callback({ directory, file, existing });
  } finally { releaseLock(lock); }
}

export function save(file, record) { atomicJson(file, record); return record; }

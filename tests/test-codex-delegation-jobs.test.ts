import { describe, test, expect } from 'bun:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync, spawn } from 'node:child_process';

const repository = path.resolve(import.meta.dir, '..');
const adapter = path.join(repository, 'plugins/codex-delegation/scripts/codex-job.mjs');
const companion = path.join(repository, 'tests/fixtures/codex-delegation/scripts/codex-companion.mjs');

function fixture(mode = 'complete') {
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'codex-job-test-'));
  const cwd = path.join(root, 'work');
  const state = path.join(root, 'fake');
  const recordParent = path.join(repository, 'tmp');
  fs.mkdirSync(recordParent, { recursive: true });
  const runs = fs.mkdtempSync(path.join(recordParent, 'codex-job-records-'));
  fs.mkdirSync(cwd); fs.mkdirSync(state);
  const git = (...args: string[]) => {
    const result = spawnSync('git', ['-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
      '-C', cwd, ...args], { encoding: 'utf8', timeout: 10000 });
    if (result.status !== 0) throw new Error(result.stderr);
    return result.stdout.trim();
  };
  git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid');
  fs.writeFileSync(path.join(cwd, 'source.txt'), 'original\n');
  git('add', 'source.txt'); git('commit', '-qm', 'Initial fixture');
  const prompt = path.join(root, 'brief.txt'); fs.writeFileSync(prompt, 'A fixture brief with `literal` shell $text.');
  const env = { ...process.env, CODEX_JOB_COMPANION: companion, FAKE_COMPANION_DIR: state, FAKE_COMPANION_MODE: mode };
  delete env.CODEX_THREAD_ID; delete env.CODEX_SESSION_ID;
  const run = (verb: string, args: string[] = [], overrides: Record<string, string> = {}) => {
    const result = spawnSync('node', [adapter, verb, ...args], {
      encoding: 'utf8', env: { ...env, ...overrides }, timeout: 10000,
    });
    if (result.error) throw result.error;
    const value = JSON.parse(result.stdout);
    return { code: result.status, value, stderr: result.stderr };
  };
  const id = ['--run-dir', runs, '--invocation-id', 'one'];
  const start = (args: string[] = [], overrides = {}) => run('start', [...id, '--cwd', cwd,
    '--prompt-file', prompt, ...args], overrides);
  const call = (verb: string, args: string[] = [], overrides = {}) => run(verb, [...id, ...args], overrides);
  const launches = () => fs.existsSync(path.join(state, 'launches'))
    ? fs.readFileSync(path.join(state, 'launches'), 'utf8').trim().split('\n').length : 0;
  return { root, cwd, state, runs, prompt, env, git, run, start, call, launches };
}

describe('tracked companion adapter', () => {
  test('explain is side-effect-free and gives a source for every value', () => {
    const f = fixture();
    const result = f.run('--explain');
    expect(result.code).toBe(0);
    expect(result.value.plugin).toBe('codex-delegation');
    expect(Object.keys(result.value.values).sort()).toEqual(Object.keys(result.value.sources).sort());
    expect(f.launches()).toBe(0);
  });

  test('the session guard refuses both observed markers without launching', () => {
    for (const marker of ['CODEX_THREAD_ID', 'CODEX_SESSION_ID']) {
      const f = fixture();
      expect(f.start([], { [marker]: 'active' }).code).toBe(2);
      expect(f.launches()).toBe(0);
    }
  });

  test('start returns a tracked handle before a running job finishes; collect never cancels', () => {
    const f = fixture('running');
    expect(f.start().value.lifecycle).toBe('running');
    expect(f.call('status').value.job_id).toBe('task-fixture');
    const waiting = f.call('collect', ['--wait-seconds', '0.01']);
    expect(waiting.code).toBe(4); expect(waiting.value.lifecycle).toBe('running');
    expect(f.launches()).toBe(1);
    expect(JSON.parse(fs.readFileSync(path.join(f.state, 'state.json'), 'utf8')).status).toBe('running');
  });

  test('repeat start and collect retain one launch and byte-identical final metadata', () => {
    const f = fixture();
    const first = f.start(); const retry = f.start();
    expect(first.value).toEqual(retry.value);
    const collected = f.call('collect');
    expect(collected.value.lifecycle).toBe('completed'); expect(collected.value.verdict).toBe('pass');
    expect(collected.value.model_requested).toBeNull(); expect(collected.value.model_observed).toBe('fixture-model');
    expect(collected.value.prompt_sha256).toMatch(/^[a-f0-9]{64}$/);
    expect(fs.readFileSync(collected.value.prompt_path, 'utf8')).toBe(fs.readFileSync(f.prompt, 'utf8'));
    expect(f.call('collect').value).toEqual(collected.value); expect(f.launches()).toBe(1);
    expect(collected.value.disposition).toBe('pending');
  });

  test('a crash after edits is uncertain and repeat start never sends the task again', () => {
    const f = fixture('crash');
    const args = ['--write', '--sandbox', 'workspace-write', '--owned', 'source.txt'];
    expect(f.start(args).code).toBe(5);
    expect(fs.readFileSync(path.join(f.cwd, 'source.txt'), 'utf8')).toBe('partial edit\n');
    expect(f.start(args).value.lifecycle).toBe('uncertain'); expect(f.launches()).toBe(1);
    expect(f.call('dispose', ['--decision', 'accepted', '--reason', 'No']).code).toBe(2);
  });

  test('a mismatched prompt or execution setting refuses the retry', () => {
    const f = fixture(); f.start();
    expect(f.start(['--model', 'another-model']).code).toBe(2);
    fs.writeFileSync(f.prompt, 'Changed task'); expect(f.start().code).toBe(2);
    expect(f.launches()).toBe(1);
  });

  for (const mode of ['malformed', 'partial']) test(`${mode} reports keep raw output and verdict unknown`, () => {
    const f = fixture(mode); f.start();
    const result = f.call('collect');
    expect(result.value.verdict).toBe('unknown'); expect(result.value.report_path).toBeNull();
    expect(fs.readFileSync(result.value.raw_output_path, 'utf8')).toContain('codex-report/1');
  });

  test('owned edits and untracked out-of-scope files are in the base diff', () => {
    for (const mode of ['owned-edit', 'out-of-scope']) {
      const f = fixture(mode); f.start(['--write', '--sandbox', 'workspace-write', '--owned', 'source.txt']);
      const result = f.call('collect').value;
      const expected = mode === 'owned-edit' ? 'source.txt' : 'outside.txt';
      expect(result.changed_paths).toEqual([expected]);
      expect(result.out_of_scope_paths).toEqual(mode === 'owned-edit' ? [] : ['outside.txt']);
      expect(fs.readFileSync(result.diff_path, 'utf8')).toContain(mode === 'owned-edit' ? 'changed' : 'unexpected');
    }
  });

  test('a changed HEAD or replacement worktree is refused', () => {
    const f = fixture(); f.start();
    f.git('commit', '--allow-empty', '-qm', 'Moved head');
    expect(f.call('status').code).toBe(2);
    const g = fixture(); g.start();
    const recordPath = path.join(g.runs, 'one', 'record.json');
    const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
    record.worktree = 'a-different-worktree'; fs.writeFileSync(recordPath, JSON.stringify(record));
    expect(g.call('collect').code).toBe(2);
  });

  test('unsafe ownership, dirty writes and symlinked briefs refuse before launch', () => {
    const f = fixture();
    expect(f.start(['--write', '--sandbox', 'workspace-write', '--owned', '../outside']).code).toBe(2);
    fs.writeFileSync(path.join(f.cwd, 'dirty.txt'), 'existing');
    expect(f.start(['--write', '--sandbox', 'workspace-write', '--owned', 'source.txt']).code).toBe(2);
    const g = fixture(); const link = path.join(g.root, 'link.txt'); fs.symlinkSync(g.prompt, link);
    expect(g.run('start', ['--run-dir', g.runs, '--invocation-id', 'link', '--cwd', g.cwd,
      '--prompt-file', link]).code).toBe(2);
    expect(f.launches()).toBe(0); expect(g.launches()).toBe(0);
  });

  test('disposition is a separate idempotent parent decision after collection', () => {
    const f = fixture(); f.start();
    const args = ['--decision', 'accepted', '--reason', 'Independently checked'];
    expect(f.call('dispose', args).code).toBe(2); f.call('collect');
    const first = f.call('dispose', args);
    expect(first.value.disposition).toBe('accepted'); expect(f.call('dispose', args).value).toEqual(first.value);
  });

  test('probe classifies reasons and never launches a background job', () => {
    const f = fixture();
    for (const [detail, reason] of [['login required', 'unauthenticated'], ['quota exceeded', 'quota'],
      ['unsupported model', 'unsupported'], ['sandbox permission denied', 'denied'], ['connection reset', 'unknown']]) {
      const result = f.run('probe', ['--cwd', f.cwd], { FAKE_PROBE_REASON: detail });
      expect(result.code).toBe(3); expect(result.value.reason).toBe(reason);
    }
    expect(f.run('probe', ['--cwd', f.cwd]).value.available).toBe(true); expect(f.launches()).toBe(0);
    expect(f.run('probe', ['--cwd', f.cwd], { CODEX_JOB_COMPANION: path.join(f.root, 'absent.mjs') })
      .value.reason).toBe('absent');
  });

  test('concurrent starts cannot launch the same invocation twice', async () => {
    const f = fixture('running');
    const args = [adapter, 'start', '--run-dir', f.runs, '--invocation-id', 'one', '--cwd', f.cwd,
      '--prompt-file', f.prompt];
    const run = () => new Promise<number | null>(resolve => {
      const child = spawn('node', args, { env: f.env, stdio: 'ignore' });
      child.on('exit', resolve);
    });
    const codes = await Promise.all([run(), run()]);
    expect(codes).toContain(0); expect(codes.every(code => code === 0 || code === 2)).toBe(true);
    expect(f.launches()).toBe(1);
  });

  test('collect bounds a slow status call by its wait budget without cancelling', () => {
    const f = fixture('running'); f.start();
    const before = Date.now();
    const result = f.call('collect', ['--wait-seconds', '0.02'], { FAKE_STATUS_DELAY_MS: '500' });
    expect(result.code).toBe(4); expect(result.value.lifecycle).toBe('running');
    expect(Date.now() - before).toBeLessThan(500); expect(f.launches()).toBe(1);
  });

  test('a collected crash keeps its partial diff and cannot be accepted', () => {
    const f = fixture('crash');
    f.start(['--write', '--sandbox', 'workspace-write', '--owned', 'source.txt']);
    const result = f.call('collect');
    expect(result.code).toBe(5); expect(result.value.changed_paths).toContain('source.txt');
    expect(fs.readFileSync(result.value.diff_path, 'utf8')).toContain('partial edit');
  });

  test('a read-only job preserves existing dirty changes without claiming them as its edits', () => {
    const f = fixture();
    fs.writeFileSync(path.join(f.cwd, 'source.txt'), 'pre-existing work\n');
    fs.writeFileSync(path.join(f.cwd, 'draft.txt'), 'pre-existing untracked work\n');
    expect(f.start().code).toBe(0);
    const record = f.call('collect').value;
    expect(record.changed_paths).toEqual(['draft.txt', 'source.txt']);
    expect(record.job_changed_paths).toEqual([]); expect(record.out_of_scope_paths).toEqual([]);
    expect(fs.readFileSync(record.diff_path, 'utf8')).toContain('pre-existing work');
  });

  test('a cancelled label while the process lives stays uncertain', () => {
    const f = fixture('cancel-live'); f.start([], { FAKE_JOB_PID: String(process.pid) });
    const result = f.call('cancel');
    expect(result.code).toBe(5); expect(result.value.lifecycle).toBe('uncertain');
    expect(result.value.disposition).toBe('pending');
  });

  test('cancelled needs observed process exit and confirmed turn interruption', () => {
    const f = fixture('cancel-stop');
    f.start();
    const result = f.call('cancel');
    expect(result.code).toBe(0); expect(result.value.lifecycle).toBe('cancelled');
    expect(result.value.diff_path).toBeString();
    expect(f.call('cancel').value).toEqual(result.value);
  });

  test('a delayed worker exit can be reconciled without sending cancel twice', async () => {
    const f = fixture('cancel-delayed'); f.start();
    const first = f.call('cancel');
    expect(first.code).toBe(5); expect(first.value.cancellation.pid).toBeNumber();
    await new Promise(resolve => setTimeout(resolve, 600));
    const second = f.call('cancel');
    expect(second.code).toBe(0); expect(second.value.lifecycle).toBe('cancelled');
    expect(fs.readFileSync(path.join(f.state, 'cancels'), 'utf8')).toBe('cancel\n');
  });

  test('a queued job with no turn can be cancelled after the worker exits', () => {
    const f = fixture('cancel-queued'); f.start();
    const result = f.call('cancel');
    expect(result.code).toBe(0); expect(result.value.lifecycle).toBe('cancelled');
    expect(result.value.cancellation.turn_id).toBeNull();
  });

  test('a known turn without a confirmed interrupt stays uncertain even after process exit', () => {
    const f = fixture('cancel-no-interrupt'); f.start();
    expect(f.call('cancel').code).toBe(5); expect(f.call('cancel').code).toBe(5);
    expect(fs.readFileSync(path.join(f.state, 'cancels'), 'utf8')).toBe('cancel\n');
  });

  test('completed adapter operations do not retain released lock directories', () => {
    const f = fixture('running'); f.start();
    for (let i = 0; i < 5; i++) f.call('status');
    expect(fs.readdirSync(f.runs)).toEqual(['one']);
  });

  test('an unignored run directory inside the worktree is refused before creating state', () => {
    const f = fixture(); const runDir = path.join(f.cwd, 'job-output');
    const result = f.run('start', ['--run-dir', runDir, '--invocation-id', 'one', '--cwd', f.cwd,
      '--prompt-file', f.prompt]);
    expect(result.code).toBe(2); expect(fs.existsSync(runDir)).toBe(false); expect(f.launches()).toBe(0);
    fs.writeFileSync(path.join(f.cwd, '.gitignore'), 'job-output/\n');
    expect(f.run('start', ['--run-dir', runDir, '--invocation-id', 'one', '--cwd', f.cwd,
      '--prompt-file', f.prompt]).code).toBe(0);
  });

  test('a dangling output symlink cannot create an outside file', () => {
    const f = fixture(); f.start();
    const outside = path.join(f.root, 'outside-output.txt');
    fs.symlinkSync(outside, path.join(f.runs, 'one', 'raw-output.txt'));
    expect(f.call('collect').code).toBe(2); expect(fs.existsSync(outside)).toBe(false);
  });

  test('record tampering cannot choose a script for any later record verb', () => {
    for (const verb of ['status', 'collect', 'cancel', 'dispose']) {
      const f = fixture('running'); expect(f.start(['--sandbox', 'workspace-write']).code).toBe(0);
      const marker = path.join(f.root, 'planted-ran');
      const planted = path.join(f.cwd, 'planted.mjs');
      fs.writeFileSync(planted, `import fs from 'node:fs'; fs.writeFileSync(${JSON.stringify(marker)}, 'ran');`);
      const recordPath = path.join(f.runs, 'one', 'record.json');
      const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
      fs.writeFileSync(recordPath, JSON.stringify({ ...record, companion_path: planted }));
      const result = f.call(verb, verb === 'dispose' ? ['--decision', 'rejected', '--reason', 'Checked'] : []);
      expect(result.code).toBe(2); expect(fs.existsSync(marker)).toBe(false);
    }
  });

  test('a companion-version mismatch refuses even a cached collection', () => {
    const f = fixture(); f.start(); f.call('collect');
    const recordPath = path.join(f.runs, 'one', 'record.json');
    const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
    fs.writeFileSync(recordPath, JSON.stringify({ ...record, companion_version: '1.0.7' }));
    expect(f.call('collect').code).toBe(2);
  });

  test('workspace-write refuses its cwd, system temp and TMPDIR for records', () => {
    const f = fixture();
    fs.writeFileSync(path.join(f.cwd, '.gitignore'), 'tmp/\n');
    for (const runDir of [path.join(f.cwd, 'tmp', 'records'), path.join(f.root, 'records')]) {
      const result = f.run('start', ['--run-dir', runDir, '--invocation-id', 'one', '--cwd', f.cwd,
        '--prompt-file', f.prompt, '--sandbox', 'workspace-write']);
      expect(result.code).toBe(2); expect(result.value.error.message).toContain('outside cwd, /tmp and TMPDIR');
    }
    const result = f.start(['--sandbox', 'workspace-write'], { TMPDIR: f.runs });
    expect(result.code).toBe(2); expect(f.launches()).toBe(0);
  });

  test('workspace-write refuses a companion script inside its writable cwd', () => {
    const f = fixture(); const plugin = path.join(f.cwd, 'runtime');
    fs.mkdirSync(path.join(plugin, 'scripts'), { recursive: true });
    fs.mkdirSync(path.join(plugin, '.claude-plugin'));
    fs.copyFileSync(companion, path.join(plugin, 'scripts', 'codex-companion.mjs'));
    fs.writeFileSync(path.join(plugin, '.claude-plugin', 'plugin.json'), '{"version":"1.0.6"}');
    const result = f.start(['--sandbox', 'workspace-write'], {
      CODEX_JOB_COMPANION: path.join(plugin, 'scripts', 'codex-companion.mjs'),
    });
    expect(result.code).toBe(2); expect(f.launches()).toBe(0);
  });

  test('workspace-write refuses an adapter installed inside its writable cwd', () => {
    const f = fixture(); const copy = path.join(f.cwd, 'adapter');
    fs.cpSync(path.dirname(adapter), copy, { recursive: true });
    const result = spawnSync('node', [path.join(copy, 'codex-job.mjs'), 'start', '--run-dir', f.runs,
      '--invocation-id', 'one', '--cwd', f.cwd, '--prompt-file', f.prompt, '--sandbox', 'workspace-write'],
    { env: f.env, encoding: 'utf8', timeout: 10000 });
    expect(result.status).toBe(2); expect(f.launches()).toBe(0);
    expect(JSON.parse(result.stdout).error.message).toContain('runtime scripts outside');
  });

  test('atomic evidence publication does not modify a hard-linked outside file', () => {
    const f = fixture(); f.start();
    for (const file of ['raw-output.txt', 'diff.patch']) {
      const outside = path.join(f.root, `outside-${file}`);
      fs.writeFileSync(outside, 'outside sentinel');
      fs.linkSync(outside, path.join(f.runs, 'one', file));
    }
    expect(f.call('collect').code).toBe(0);
    for (const file of ['raw-output.txt', 'diff.patch']) {
      expect(fs.readFileSync(path.join(f.root, `outside-${file}`), 'utf8')).toBe('outside sentinel');
    }
  });
});

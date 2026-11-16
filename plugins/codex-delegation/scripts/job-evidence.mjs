import fs from 'node:fs';
import path from 'node:path';
import { atomicJson, atomicFile, git, hash, noSymlinks, Refusal } from './job-storage.mjs';

const verdicts = new Set(['pass', 'fail', 'blocked', 'unknown']);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = value => typeof value === 'string' && value.length > 0;
const blockedEntry = value => object(value) && text(value.operation) && text(value.reason);

function validClaim(claim) {
  if (!object(claim)) return false;
  if (claim.type === 'code') {
    return text(claim.path) && Number.isInteger(claim.line) && claim.line > 0 && text(claim.snapshot);
  }
  return claim.type === 'runtime' && text(claim.command) && 'expected' in claim && 'observed' in claim
    && Number.isInteger(claim.exit) && text(claim.evidence_path);
}

export function validateReport(report) {
  return object(report) && report.schema === 'codex-report/1' && verdicts.has(report.verdict)
    && text(report.summary) && Array.isArray(report.claims) && report.claims.every(validClaim)
    && Array.isArray(report.blocked) && report.blocked.every(blockedEntry);
}

export function extractReport(raw) {
  const blocks = [...raw.matchAll(/^```json[ \t]*\r?\n([\s\S]*?)^```[ \t]*$/gm)];
  if (!blocks.length) return null;
  try {
    const report = JSON.parse(blocks.at(-1)[1]);
    return validateReport(report) ? report : null;
  } catch { return null; }
}

function withinOwned(file, owned) {
  return owned.some(entry => file === entry || file.startsWith(`${entry}/`));
}

function untrackedFiles(cwd) {
  return git(cwd, ['ls-files', '--others', '--exclude-standard', '-z'], { binary: true })
    .toString('utf8').split('\0').filter(Boolean);
}

function changedFiles(record) {
  const tracked = git(record.cwd, ['diff', '--name-only', '--no-renames', '-z', record.base_sha, '--'],
    { binary: true }).toString('utf8').split('\0').filter(Boolean);
  return [...new Set([...tracked, ...untrackedFiles(record.cwd)])].sort();
}

function fingerprint(cwd, file) {
  const absolute = path.join(cwd, file);
  let stat;
  try { stat = fs.lstatSync(absolute); } catch (error) { if (error.code === 'ENOENT') return 'missing'; throw error; }
  if (stat.isSymbolicLink()) return `symlink:${fs.readlinkSync(absolute)}`;
  if (!stat.isFile()) return 'non-regular';
  return `${stat.mode & 0o777}:${hash(fs.readFileSync(absolute))}`;
}

export function baselineChanges(record) {
  return Object.fromEntries(changedFiles(record).map(file => [file, fingerprint(record.cwd, file)]));
}

export function saveDiff(record, directory) {
  const changed = changedFiles(record);
  const untracked = untrackedFiles(record.cwd);
  const baseline = record.baseline_changes || {};
  const jobChanged = [...new Set([...changed, ...Object.keys(baseline)])].filter(file =>
    !(file in baseline) || baseline[file] !== fingerprint(record.cwd, file));
  const diffPath = noSymlinks(path.join(directory, 'diff.patch'));
  const parts = [git(record.cwd, ['diff', '--no-ext-diff', '--no-textconv', '--binary', '--no-renames',
    record.base_sha, '--'], { binary: true })];
  for (const file of untracked) {
    const absolute = path.join(record.cwd, file);
    const stat = fs.lstatSync(absolute);
    if (stat.isSymbolicLink()) {
      parts.push(Buffer.from(`\nUntracked symlink: ${JSON.stringify(file)} -> ${fs.readlinkSync(absolute)}\n`));
      continue;
    }
    if (!stat.isFile()) throw new Refusal(`Non-regular untracked path: ${file}`);
    parts.push(Buffer.from(`\nUntracked file: ${JSON.stringify(file)}\n`), fs.readFileSync(absolute), Buffer.from('\n'));
  }
  atomicFile(diffPath, Buffer.concat(parts));
  const violations = record.write ? jobChanged.filter(file => !withinOwned(file, record.owned_paths)) : jobChanged;
  return { diff_path: diffPath, changed_paths: changed, job_changed_paths: jobChanged.sort(),
    out_of_scope_paths: violations.sort() };
}

export function saveResult(record, directory, stored) {
  const raw = stored.result?.rawOutput;
  const output = typeof raw === 'string' ? raw : stored.rendered || stored.errorMessage || '';
  const rawPath = noSymlinks(path.join(directory, 'raw-output.txt'));
  atomicFile(rawPath, output);
  const report = extractReport(output);
  const reportPath = report ? noSymlinks(path.join(directory, 'report.json')) : null;
  if (reportPath) atomicJson(reportPath, report);
  return { raw_output_path: rawPath, report_path: reportPath, verdict: report?.verdict || 'unknown',
    blocked: report?.blocked || [], ...saveDiff(record, directory) };
}

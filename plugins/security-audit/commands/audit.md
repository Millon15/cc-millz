---
description: >
  Pre-adoption security audit of an open-source repository, MCP server, package
  or standalone script. Adaptive phases based on target type. Dual output:
  terminal verdict + full report file.
argument-hint: <repo-url | package-name | local-path | raw-url>
disable-model-invocation: true
---

# Section 1 — Orchestration

## Input Variants

- `/security-audit:audit {repo_url}` — GitHub/GitLab/Bitbucket repository
- `/security-audit:audit {package_name}` — resolve npm/pypi package to source repo
- `/security-audit:audit {local_path}` — locally cloned repository
- `/security-audit:audit {raw_url}` — standalone script (`.sh`, `.py`, etc.)

If no argument: MANDATORY ask the user.

## Instruments

| Tool | Phases | Purpose |
| --- | --- | --- |
| `rg --files <dir> -g '<glob>'` + `Read` | 0, all | File discovery, read source/configs. Dir = path argument; `-g '<dir>/…'` misses dot-dirs and gitignored paths |
| Text search — see the adapter below | 2-8 | Pattern matching on local clone |
| Semgrep — see the adapter below | 3, 4, 8 | Structured vuln scanning, secret detection, taint analysis |
| `Explore` agents | 1 | Parallel codebase reconnaissance (2-3 agents) |
| `WebSearch` | 1, 6 | CVE/advisory lookup, project history |
| `grep_app_searchGitHub` | 6 | Real-world usage patterns |
| `gh api` | 1 | Repo metadata (stars, contributors, last commit) |
| `context7_query-docs` | any | Library docs when behavior is ambiguous |
| `tirith scan {clone} --sarif` (optional) | 2,4,6,8 | Auto-flags hidden Unicode / bidi / homograph / pipe-to-shell / install-bypass — triage its SARIF into the phases. Run only `if command -v tirith`; NEVER a hard dependency |

## Tool Availability Adapter

Every external tool this audit uses is OPTIONAL, and each one has a named fallback. A bare machine with nothing but `rg` still produces a full report — with less structure, never with fewer phases.

| Capability | Preferred | Fallback when absent |
| --- | --- | --- |
| Text search | An **IDE search surface** when the editor's MCP tools are exposed in this session (indexed, reaches dot-dirs and ignored paths with no flags) | **ripgrep** via Bash — `rg -n '<pattern>' <dir>`, naming the directory as a path ARGUMENT so the search reaches dot-dirs and gitignored files |
| Structured scanning | **`semgrep`** when `command -v semgrep` succeeds — `semgrep scan --config=<ruleset>` | **An `rg` pattern pass** over the same sink list, one `rg -n` per pattern group, findings reported with the same `file:line` shape |

- MUST probe before choosing: `command -v semgrep` for the scanner, the session's tool list for the IDE surface. NEVER assume either is present.
- MUST record which branch ran in the report header — `scanner: semgrep` or `scanner: rg pattern pass`, `search: ide` or `search: ripgrep`. A reader has to know how much of the coverage was structural.
- A missing tool NEVER skips a phase. It downgrades the evidence, and the finding says so.

## Report Output Directory

Reports are written under `${SECURITY_AUDIT_REPORT_DIR}` when that variable is set, and under the system temp directory otherwise — `${TMPDIR:-/tmp}/security-audits/`. Create the directory before writing. A project that wants its audits versioned sets the variable to a path inside the repo; nothing is written into a repo by default.

## Operating Rules

- Adversarial stance — assume malicious until proven otherwise
- Every finding MUST include `file:line` evidence (paths relative to clone dir)
- Report only — NEVER fix issues
- Insufficient evidence -> explicit "needs manual verification"
- MUST produce BOTH terminal verdict AND file report
- Terminal verdict MUST be under 40 lines
- MUST end the whole run with the **Final Verdict Banner** (Section 3) — fancy boxed install/no-install decision, printed LAST, after the terminal verdict table
- MUST skip irrelevant phases with one-line reason
- MUST clone target to `${TMPDIR:-/tmp}/security-audit/{slug}` before analysis

## Step 1: Acquire Target

| Input type | Action |
| --- | --- |
| Repo URL | `git clone --depth 1 {url} {clone_dir}` |
| Package name | `WebSearch` registry -> find repo URL -> shallow clone |
| Local path | No clone — analyze in place |
| Raw URL | `curl -fsSL {url} -o {clone_dir}/{filename}` |

`{clone_dir}` = `${TMPDIR:-/tmp}/security-audit/{slug}`.

## Step 2: Detect Target Type (Phase 0)

Read project files and classify into one type:

| Type | Signals |
| --- | --- |
| `installer-script` | Single `.sh`/`.ps1`, `curl \ | sh` pattern |
| `mcp-server` | `@modelcontextprotocol` dep, MCP tool definitions |
| `cli-tool` | `bin` in package.json, CLI entry point, arg parsing |
| `library` | Exports API, consumed as dep, no entry point |
| `sdk` | API client, auth handling, request building |
| `framework` | App structure, lifecycle hooks, middleware pipeline |
| `plugin` | Extends host system, hook registration, peer deps |
| `web-app` | HTTP handlers, routes, templates, `listen`/`serve` |
| `github-action` | `action.yml`/`action.yaml`, composite/node/docker runner |
| `docker-image` | `Dockerfile` primary, registry publishing |
| `browser-extension` | `manifest.json` with `permissions`, content scripts |
| `mobile-app` | `AndroidManifest.xml`, `Info.plist`, RN/Flutter |
| `ai-agent` | LLM API calls, prompt templates, tool use (non-MCP) |
| `infra-config` | Terraform/Pulumi/CloudFormation, Helm, k8s |
| `middleware` | Request interceptor/transformer, proxy |
| `database-driver` | DB protocol impl, connection pooling |
| `orm` | Schema mapping, query builder, migrations |
| `template-engine` | Template parsing, variable interpolation |
| `vscode-extension` | `contributes` in package.json, `vscode` engine |
| `bot` | Chat/social platform listeners, webhook handlers |
| `monorepo` | Multiple packages, workspaces config |

If no type fits — use best-match and own judgment for phase applicability.

## Step 3: Run Phases

| Phase | Applicability |
| --- | --- |
| 1 (Recon) | Always |
| 2 (Network) | Adapt per type |
| 3 (Secrets/Privacy) | Adapt per type |
| 4 (Code Exec) | Always |
| 5 (MCP/AI) | Only `mcp-server` / `ai-agent` |
| 6 (Supply Chain) | Adapt per type |
| 7 (Controls) | Full for `web-app`/`mcp-server`/`bot`/`browser-extension`; adapted for others |
| 8 (Suspicious) | Always |

---

# Section 2 — Phase Definitions

## Phase 1: Recon

**Goal**: Map project identity, health signals, and attack surface.

- Languages, frameworks, entry points, exports
- Project age, contributor count, last commit date
- Typosquatting + homograph check against popular package names (punycode, mixed-script labels, lookalike TLDs, confusable chars — on package names AND any domains/URLs in install scripts)
- Build/install pipeline scripts

**Tools**: Explore agents (2-3 parallel), `gh api`, `WebSearch`.

## Phase 2: Network & Data Exfiltration

**Goal**: Map all outbound communications and data flows.

Search for:
- HTTP clients: fetch, axios, http.request, curl_exec, Guzzle, requests, urllib, reqwest
- WebSocket connections
- Hardcoded URLs and IP addresses
- Telemetry SDKs: Segment, Mixpanel, PostHog, Sentry, Bugsnag, Datadog
- Background transmitters, dynamic config loading
- Insecure transport / disabled TLS verification: `curl -k`/`--insecure`, `wget --no-check-certificate`, `verify=False` (requests), `rejectUnauthorized:false` / `NODE_TLS_REJECT_UNAUTHORIZED=0`, Go `InsecureSkipVerify`, plain `http://` for code/secret fetch
- Homograph/punycode destinations: lookalike domains, mixed-script hostnames, `xn--` punycode, shortened URLs hiding the real host

Per finding determine: destination, data transmitted, TLS enforced, documented, opt-out available.

**Tools**: text search per the adapter. **Severity**: CRITICAL if PII/secrets undocumented, HIGH if telemetry without opt-out, MEDIUM if documented.

## Phase 3: Secrets & Privacy

**Goal**: Find exposed credentials, PII leaks, and unsafe data handling.

Structured pass — `semgrep scan --config=p/secrets` when the scanner is present. Without it, run the `rg` pattern pass over the same list below and mark the evidence as pattern-derived.

Also search for:
- Hardcoded API keys, JWT secrets, DB credentials, OAuth secrets, cloud creds
- Committed `.env` files
- Base64-encoded secrets (decode suspicious strings)
- PII in logs, admin/debug endpoints

**Tools**: scanner per the adapter + text search. **Severity**: CRITICAL production secrets, HIGH PII logged, MEDIUM debug routes.

## Phase 4: Code Execution & Dangerous Patterns

**Goal**: Find all dynamic execution sinks and trace taint from source to sink.

Structured pass — `semgrep scan --config=p/default --config=p/owasp-top-ten` when the scanner is present. Without it, run the `rg` pattern pass over the sink list below; taint tracing then happens by reading each hit rather than by the scanner's dataflow.

Also search for:
- JS/TS: eval, Function constructor, vm.runInContext
- Python: eval, compile, dynamic imports
- PHP: preg_replace with e modifier, assert as function
- Ruby: `instance_eval`, `send` with user input
- Go/Rust: `exec.Command` with a shell, `std::process::Command` with `sh -c`
- Shell execution via child_process, subprocess, shell_exec, system
- Unsafe deserialization (pickle, unserialize, yaml.load without SafeLoader)
- Download-and-execute, auto-update, dynamic require/import with user paths
- Encoded decode-then-execute chains: `base64 -d | bash`, `eval(atob(...))`, `exec(b64decode(...))`, `powershell -EncodedCommand`, hex/rot13 unwrap → interpreter, decode through `sudo`/`env` wrappers

Taint trace each: source -> validation -> sink. "Prompt instructions" are NOT validation. Only CODE-level checks count.

**Tools**: scanner per the adapter + text search + `Read`. Always runs. **Severity**: CRITICAL unvalidated taint, HIGH weak validation, MEDIUM partially trusted source.

## Phase 5: MCP & AI Agent Risks

**Goal**: Assess tool poisoning, prompt injection, transport security, and filesystem scope.

> ONLY for `mcp-server` and `ai-agent`. Skip with one-line reason for all other types.

Search for:
- Hidden prompt-injection planted in the repo's OWN agent-facing files — MCP tool names/descriptions, `.cursorrules`, `AGENTS.md`/`CLAUDE.md`, system prompts, README/code comments, HTML attributes/CSS. Scan raw AND deobfuscated (invisible-Unicode, confusable, spaced-out, leetspeak, short base64/hex evasions)
- Unsanitized tool outputs from external data (DB, API, web pages)
- Untrusted content feeding LLM context
- Read-only tools that allow state changes
- Destructive tools without confirmation
- Binding `0.0.0.0` (NeighborJack vulnerability)
- Missing auth on HTTP/SSE transport
- Filesystem scope: mounts `/`, `~`, path traversal

**Tools**: text search + `Read`. **Severity**: CRITICAL NeighborJack/unauthed transport, HIGH tool poisoning, MEDIUM broad filesystem.

## Phase 6: Supply Chain & Build Integrity

**Goal**: Evaluate dependency health, build hooks, and project governance.

Search for:
- preinstall/postinstall/prepare hooks (auto-execute on install)
- Install-command signature bypass (install.sh / Dockerfile / CI): `curl|bash` / `wget|sh` pipe-to-shell, apt `[trusted=yes]` / `--allow-unauthenticated`, `--nogpgcheck`, pacman `SigLevel = Never`, `--no-verify`, `kubectl apply -f <remote/shortened>`, Helm/Terraform modules from untrusted remotes, `brew install`/`tap` from arbitrary URLs
- Typosquat/homograph on dependency names (mixed-script, lookalike, punycode)
- pull_request_target in GitHub Actions
- Git/URL-based deps (bypass registry integrity)
- Floating versions, lockfile presence
- Deps with <100 downloads, single maintainer, ownership transfers
- Obfuscated source committed to repo
- Known CVEs via `WebSearch`
- Real-world usage via `grep_app_searchGitHub`

**Tools**: `WebSearch` + `grep_app` + `Read` + `gh api`. **Severity**: CRITICAL install hooks execute, HIGH abandoned deps/known CVEs, MEDIUM floating versions.

## Phase 7: Security Controls

**Goal**: Evaluate defensive controls appropriate to the target type.

Full assessment for `web-app`/`mcp-server`/`bot`/`browser-extension`: input validation, output encoding, auth, authz, CSRF, rate limiting, password hashing, crypto randomness, cookie flags, CSP, error handling, resource limits.

Adapted for other types: input validation, error handling, resource limits only.

**Tools**: `Read` + text search. **Severity**: HIGH auth bypass, MEDIUM missing non-critical controls.

## Phase 8: Suspicious & Hidden Behavior

**Goal**: Hunt for obfuscation, time bombs, environment-conditional logic, and anti-analysis.

Search for:
- Invisible / hidden Unicode in source, docs, configs: zero-width chars, bidi overrides (Trojan-Source CVE-2021-42574), Unicode tags, variation selectors, invisible-whitespace stego, Hangul/Mongolian fillers — code that renders benign to a reviewer but compiles/executes differently
- ANSI / terminal escape injection in README/output (OSC 8 hyperlinks, OSC 52 clipboard writes, title / clear-screen manipulation)
- Obfuscated code blocks, unusual encoding
- Large base64/hex strings (decode them)
- Silent error suppression (empty catch/except blocks)
- Environment-conditional behavior (different logic per env/hostname/IP/identity)
- Persistence footholds / writes outside project dir: shell rc (`.bashrc`/`.zshrc`), `~/.ssh/authorized_keys`, crontab, systemd units, macOS LaunchAgents/LaunchDaemons, git `core.hooksPath`, PATH-hijack ordering
- Timer/date-based triggers
- Anti-debugging techniques

**Tools**: scanner per the adapter + text search. Always runs. **Severity**: CRITICAL obfuscated execution/exfiltration, HIGH env-conditional suspicious, MEDIUM silent suppression.

---

# Section 3 — Output Contract

## Terminal Verdict (under 40 lines)

```
## Security Audit: {name}

| Field | Value |
| --- | --- |
| Target | {url_or_path} |
| Type | {detected_type} |
| Clone | {clone_dir} |
| Scanner | semgrep | rg pattern pass |
| Search | ide | ripgrep |
| Verdict | **{verdict}** |

### Findings ({N})

| # | Sev | Category | Finding | Evidence |
| --- | --- | --- | --- | --- |
| 1 | HIGH | supply-chain | No checksum on downloaded binary | install.sh:187 |

### Skipped Phases
- Phase 5: Not MCP server or AI agent

### Mitigations
1. {specific mitigation with config snippet if applicable}

Full report: {report_dir}/{slug}-{date}.md
```

## Full Report Structure

Save to `{report_dir}/{slug}-YYYY-MM-DD.md`, where `{report_dir}` is `${SECURITY_AUDIT_REPORT_DIR}` or `${TMPDIR:-/tmp}/security-audits`:

1. Header — target, type, date, verdict, and which tool branch ran (scanner, search)
2. Each applicable phase — full evidence with `file:line` refs
3. Skipped phases — one-line reason each
4. Risk matrix:

| Risk Category | Level | Evidence |
| --- | --- | --- |
| Malicious code | | `file:line` |
| Data exfiltration | | `file:line` |
| Secrets exposure | | `file:line` |
| Supply chain | | `file:line` |
| Code execution | | `file:line` |
| MCP/Agent risks | | `file:line` |

5. Verdict with mitigations and config snippets
6. Manual verification items

## Finding Categories

`supply-chain`, `code-exec`, `data-exfil`, `secrets`, `transport`, `auth`, `injection`, `mcp-ai`, `permissions`, `obfuscation`

## Verdicts

| Verdict | Meaning |
| --- | --- |
| **SAFE TO ADOPT** | No significant risks. Standard dependency management applies |
| **ADOPT WITH CONTROLS** | Usable with specific mitigations (list them) |
| **NEEDS MANUAL VERIFICATION** | Insufficient evidence. List what a human must verify |
| **REJECT** | Confirmed malicious behavior or unacceptable risk |

## Final Verdict Banner (print LAST)

MUST print after the terminal-verdict table — answers the user's real question ("can I install/use it?") at a glance. Box first, then a direct one-line answer, then emoji bullets, then commands.

Verdict → banner icon + decision line:

| Verdict | Icon | Decision line |
| --- | --- | --- |
| SAFE TO ADOPT | ✅ | `YES — SAFE TO INSTALL & USE` |
| ADOPT WITH CONTROLS | ✅ | `YES — SAFE TO INSTALL & USE (with controls)` |
| NEEDS MANUAL VERIFICATION | ⚠️ | `MAYBE — VERIFY FIRST` |
| REJECT | ⛔ | `NO — DO NOT INSTALL` |

Template — emoji-safe rule style. NEVER use a right-edge border / trailing `║`: emojis are double-width and content length varies, so a trailing border ALWAYS misaligns in a terminal. Top+bottom rules only, icon at line start, fixed 60-char rules:

````
```
────────────────────────────────────────────────────────────
  {ICON}  {DECISION LINE}
  {NAME} — {url_or_slug}
────────────────────────────────────────────────────────────
```

**Short answer: {direct install/no-install sentence}.**

{Why-safe 🔐/🌐/🧪 bullets, OR why-not ⛔ bullets for REJECT — 3-5 lines}

{Controls — numbered, only if ADOPT WITH CONTROLS or MAYBE}
{Refuted — list any agent or scanner findings downgraded to false-positive, if any}
{Ignore-for-adoption — one line, e.g. vendor backend / dev-only paths, if any}

```
{2-3 copy-paste commands: recommended signed install, minimal/offline use, full opt-in use}
```

Full report → {report_dir}/{slug}-{date}.md
````

- MUST be honest to the verdict — REJECT prints ⛔ + why-not + NO install command (give the safe alternative or "do not run").
- Terse prose. The banner is the one place emojis belong; the rest of the report stays plain.

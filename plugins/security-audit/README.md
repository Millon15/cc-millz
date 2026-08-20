# 🛡 security-audit

    /plugin install security-audit@cc-millz

Audit something before you adopt it. Point `/security-audit:audit` at a repository, a package name, a local clone or a raw script URL, and it clones the target into a temp directory, classifies what kind of thing it is, and runs the phases that apply to that kind — recon, outbound network, secrets, code execution, MCP and agent risks, supply chain, defensive controls, hidden behaviour. Output is a terminal verdict under 40 lines plus a full report file with `file:line` evidence for every finding.

## Core ideas

- **Adversarial stance** — assume malicious until proven otherwise, and report only. The command never fixes anything.
- **Every tool is optional** — Semgrep when `semgrep` is on PATH, an IDE search surface when the editor's MCP tools are in the session, ripgrep otherwise. A missing tool downgrades the evidence and says so in the header; it never skips a phase.
- **Phases adapt to the target type** — 21 types, from `installer-script` to `orm`. An irrelevant phase is skipped with a one-line reason, not silently.
- **Cross-language on purpose** — the sink lists name PHP's `curl_exec` and Guzzle beside Node's `axios`, Python's `requests` and `pickle`, Go's `InsecureSkipVerify` and Rust's `reqwest`. A polyglot repo gets one pass, not one per ecosystem.
- **The last line is a decision** — a boxed banner answering the question you actually asked: install it or do not.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| command | `/security-audit:audit <target>` | 🛡 Nine-phase pre-adoption audit — terminal verdict, full report file, final install/no-install banner |

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `SECURITY_AUDIT_REPORT_DIR` | `${TMPDIR:-/tmp}/security-audits` | Where the full report is written. Set it to a path inside a repo to version audits; nothing is written into a repo by default |

## Provenance

Extracted from a private monorepo.

---

Part of [cc-millz](../../README.md).

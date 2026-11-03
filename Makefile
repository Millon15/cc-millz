# Root task runner. Every target discovers its suites rather than listing them,
# so a new suite is picked up by adding the file and nothing else.
#
# The whole test surface is flat, at the repo root: a plugin install copies
# that plugin's directory out of the marketplace clone, so tests and fixtures
# under plugins/<name>/ would be downloaded by every user of the plugin.

SHELL := /usr/bin/env bash

.PHONY: help test test-bats test-ts test-python test-generated test-mods export hooks

help:
	@echo 'make test       run every suite and generated-source checks'
	@echo 'make test-bats  run the bats suites only'
	@echo 'make test-ts    run the TypeScript suites only'
	@echo 'make export     regenerate export/ from plugins/'
	@echo 'make hooks      install the tracked pre-commit gate (core.hooksPath = .githooks)'

# Generation stays a deliberate step; the pre-commit hook only checks the staged snapshot.
export:
	scripts/apm-export.sh

# A foreign core.hooksPath is someone's deliberate choice: refuse to replace it.
hooks:
	@command -v bun >/dev/null 2>&1 || { echo 'bun not installed — see https://bun.sh'; exit 1; }
	@command -v trash >/dev/null 2>&1 || { echo 'trash CLI not installed — the hook needs it to discard its snapshot'; exit 1; }
	@current=$$(git config --get core.hooksPath || true); \
	if [ -n "$$current" ] && [ "$$current" != .githooks ]; then \
	echo "core.hooksPath is already '$$current'; unset it or chain .githooks/pre-commit from there"; exit 1; fi; \
	git config core.hooksPath .githooks && echo 'core.hooksPath = .githooks'

test: test-generated test-python test-bats test-ts test-mods

test-generated:
	python3 scripts/sync-peer-chat-shared.py --check
	python3 scripts/sync-peer-chat-protocol.py --check

test-python:
	@set -e; for suite in tests/test-*.py; do \
	[ -f "$$suite" ] || continue; python3 "$$suite"; done

test-bats:
	@command -v bats >/dev/null 2>&1 || { echo 'bats-core not installed — run: brew install bats-core'; exit 127; }
	@suites=$$(ls tests/test-*.bats 2>/dev/null); \
	if [ -z "$$suites" ]; then echo 'no bats suites found'; exit 0; fi; \
	echo "bats: $$(echo "$$suites" | wc -l | tr -d ' ') suite(s)"; \
	bats $$suites

# A ported TypeScript test that no runner discovers is not coverage.
test-ts:
	@command -v bun >/dev/null 2>&1 || { echo 'bun not installed — see https://bun.sh'; exit 127; }
	@suites=$$(ls tests/*.test.ts 2>/dev/null); \
	if [ -z "$$suites" ]; then echo 'no TypeScript suites found'; exit 0; fi; \
	echo "bun test: $$(echo "$$suites" | wc -l | tr -d ' ') suite(s)"; \
	bun test $$suites

# A mod's native test imports claude-code/testing, which only `claude plugin test` provides,
# and that command discovers tests inside the plugin folder alone: scripts/test-mod.sh stages both.
test-mods:
	@command -v claude >/dev/null 2>&1 || { echo 'claude CLI not installed, native mod suites skipped'; exit 0; }
	@set -e; for suite in tests/test-*-mod.test.tsx; do \
	[ -f "$$suite" ] || continue; \
	plugin=$$(basename "$$suite" -mod.test.tsx); plugin=$${plugin#test-}; \
	echo "mod suite: $$plugin"; scripts/test-mod.sh "$$plugin"; done

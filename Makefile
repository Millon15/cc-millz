# Root task runner. Every target discovers its suites rather than listing them,
# so a new suite is picked up by adding the file and nothing else.
#
# The whole test surface is flat, at the repo root: a plugin install copies
# that plugin's directory out of the marketplace clone, so tests and fixtures
# under plugins/<name>/ would be downloaded by every user of the plugin.

SHELL := /usr/bin/env bash

.PHONY: help test test-bats test-ts

help:
	@echo 'make test       run every suite, both kinds'
	@echo 'make test-bats  run the bats suites only'
	@echo 'make test-ts    run the TypeScript suites only'

test: test-bats test-ts

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

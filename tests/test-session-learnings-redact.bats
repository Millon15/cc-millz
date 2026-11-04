#!/usr/bin/env bats
#
# tests/test-session-learnings-redact.bats: sl-redact.sh scrubs every secret kind,
# keeps JSON valid, and --check reports hits through its exit code alone.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	REDACT="${REPO_ROOT}/plugins/session-learnings/scripts/sl-redact.sh"
}

redacts_as() {
	local input="$1" kind="$2" secret="$3"
	run "$REDACT" <<<"$input"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[REDACTED:${kind}]"* ]]
	[[ "$output" != *"$secret"* ]]
}

@test "private key block is replaced whole" {
	redacts_as $'-----BEGIN RSA PRIVATE KEY-----\nMIIEsecretbody\n-----END RSA PRIVATE KEY-----' private-key MIIEsecretbody
}

@test "provider tokens are replaced" {
	redacts_as 'AKIAABCDEFGHIJKLMNOP' aws-key AKIAABCDEFGHIJKLMNOP
	redacts_as 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' github ghp_abcdefghij
	redacts_as 'xoxb-1234567890-abcdefghij' slack xoxb-1234567890
	redacts_as 'sk-ant-api03-abcdefghijklmnopqrstuvwxyz' anthropic sk-ant-api03
	redacts_as 'sk-proj-abcdefghijklmnopqrstuvwxyz' openai sk-proj-abcdefghij
	redacts_as 'AIzaSyA1234567890abcdefghijklmnopqrstuv' google AIzaSyA1234567890
	redacts_as 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abcdefghijk' jwt eyJzdWIiOiIxMjM0NSJ9
}

@test "credentials in urls, bearer headers and assignments are replaced, the key name stays" {
	redacts_as 'git clone https://bob:s3cr3t@github.com/x/y' url-cred s3cr3t
	redacts_as 'Authorization: Bearer opaque-token-value' bearer opaque-token-value
	redacts_as 'MY_API_KEY=abc123' assignment abc123
	run "$REDACT" <<<'DB_PASSWORD: "zz9"'
	[ "$output" = 'DB_PASSWORD: "[REDACTED:assignment]"' ]
}

@test "text without secrets passes through unchanged" {
	run "$REDACT" <<<'tokenizer=fine; sed -i "" file'
	[ "$output" = 'tokenizer=fine; sed -i "" file' ]
}

@test "a JSONL stream stays valid JSON after the scrub" {
	run bash -c "printf '%s\n' '{\"t\":\"password=hunter2\\\" token: abc, -----BEGIN EC PRIVATE KEY-----\\\\nAAA\\\\n-----END EC PRIVATE KEY-----\"}' | '$REDACT' | jq -e '.t | test(\"REDACTED\")'"
	[ "$status" -eq 0 ]
}

@test "--check exits 1 on a hit and 0 on clean text, printing nothing" {
	run "$REDACT" --check <<<'token=abc'
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	run "$REDACT" --check <<<'nothing here'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "an unknown flag is a usage error" {
	run "$REDACT" --bogus
	[ "$status" -eq 64 ]
}

@test "--jsonl scrubs escaped quoted values inside JSON strings, spaces included, and keeps numbers" {
	run "$REDACT" --jsonl <<<'{"line":5,"text":"password=\"syntheticQuotedSecret\" token=\"synthetic token with spaces\""}'
	[ "$status" -eq 0 ]
	[[ "$output" != *syntheticQuotedSecret* ]]
	[[ "$output" != *"token with spaces"* ]]
	[[ "$output" != *spaces* ]]
	[ "$(jq -r '.line | type' <<<"$output")" = number ]
}

@test "--jsonl --check reports a hit hidden behind JSON escaping" {
	run "$REDACT" --jsonl --check <<<'{"text":"token=\"a b\""}'
	[ "$status" -eq 1 ]
}

@test "--jsonl scrubs a line that is not JSON as plain text" {
	run "$REDACT" --jsonl <<<'not json token=abc'
	[ "$output" = 'not json token=[REDACTED:assignment]' ]
}

@test "plain mode scrubs a whole double- or single-quoted value" {
	run "$REDACT" <<<"password=\"two words\" secret='three more words'"
	[ "$output" = "password=\"[REDACTED:assignment]\" secret='[REDACTED:assignment]'" ]
}

@test "plain mode also scrubs an escaped quoted value, so JSON text never leaks through either mode" {
	run "$REDACT" <<<'{"text":"password=\"syntheticQuotedSecret\" token=\"synthetic token with spaces\""}'
	[[ "$output" != *synthetic* ]]
	jq -e . <<<"$output" >/dev/null
}

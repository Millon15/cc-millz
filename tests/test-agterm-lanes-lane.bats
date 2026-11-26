#!/usr/bin/env bats
# agterm-lane.sh against a stubbed agtermctl: the lane names, tints and colours the row, never writes status.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	LANE="$REPO_ROOT/plugins/agterm-lanes/scripts/agterm-lane.sh"
	HOOKS="$REPO_ROOT/plugins/agterm-lanes/hooks/hooks.json"
	export AGTERM_SESSION_ID=11111111-2222-3333-4444-555555555555
	export AGTERM_LANE_STATE_DIR="$TMP/state" AGTERMCTL="$STUB_BIN/agtermctl" LANE_TYPE_RENAME=0
	unset AGTERM_SOCKET
	stub_agtermctl
	tree_with_title "✳ Fix login crash"
}

teardown() { teardown_tmp; }

stub_agtermctl() {
	cat >"$STUB_BIN/agtermctl" <<AGTERM
#!/usr/bin/env bash
printf '%s\x1f' "\$@" >> '$TMP/agterm.log'
printf '\n' >> '$TMP/agterm.log'
[ "\$1" = tree ] && cat '$TMP/tree.json'
exit 0
AGTERM
	chmod +x "$STUB_BIN/agtermctl"
}

tree_with_title() {
	jq -n --arg id "$AGTERM_SESSION_ID" --arg title "$1" \
		'{result:{tree:{idleMs:99999,workspaces:[{sessions:[{id:$id,name:"zsh",title:$title,active:false}]}]}}}' \
		>"$TMP/tree.json"
}

calls() {
	tr '\037' ' ' <"$TMP/agterm.log"
}

@test "agterm-lanes names the lane, tints the pane and colours the name" {
	run sh "$LANE" </dev/null
	[ "$status" -eq 0 ]
	calls | grep -qx "session rename 🐛 Fix-Login-Crash --target $AGTERM_SESSION_ID "
	calls | grep -qx "session background color #3b1218 --target $AGTERM_SESSION_ID "
	calls | grep -qx "session tint red --on name --target $AGTERM_SESSION_ID "
}

@test "agterm-lanes never writes agent status" {
	run sh "$LANE" </dev/null
	[ "$status" -eq 0 ]
	! calls | grep -q '^session status'
	[ ! -e "$AGTERM_LANE_STATE_DIR/shape-$AGTERM_SESSION_ID" ]
}

@test "agterm-lanes passes a socket path with a space as one argument" {
	export AGTERM_SOCKET="$TMP/Application Support/agterm.sock"
	run sh "$LANE" </dev/null
	[ "$status" -eq 0 ]
	grep -q "^session$(printf '\037')tint$(printf '\037').*--socket$(printf '\037')$AGTERM_SOCKET$(printf '\037')\$" "$TMP/agterm.log"
}

@test "agterm-lanes ships no status hook" {
	run jq -r '[.hooks | keys[]] | join(" ")' "$HOOKS"
	[ "$output" = "PreToolUse SessionStart Stop" ]
	run jq -r '[.hooks[][].hooks[].command | select(test("status"))] | length' "$HOOKS"
	[ "$output" = "0" ]
	[ ! -e "$REPO_ROOT/plugins/agterm-lanes/scripts/agterm-status.sh" ]
}

@test "agterm-lanes outside agterm is a silent no-op" {
	unset AGTERM_SESSION_ID
	run sh "$LANE" </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ ! -e "$TMP/agterm.log" ]
}

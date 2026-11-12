#!/usr/bin/env bats
# sl-install.sh --review-weekly, --check and --uninstall with a stubbed launchctl; worker-only install lives in
# test-session-learnings-hook.bats.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	INSTALL="${REPO_ROOT}/plugins/session-learnings/scripts/sl-install.sh"
	export SESSION_LEARNINGS_HOME="$TMP/store" SESSION_LEARNINGS_LAUNCH_AGENTS="$TMP/agents"
	unset SESSION_LEARNINGS_REVIEW_WEEKDAY SESSION_LEARNINGS_REVIEW_HOUR SESSION_LEARNINGS_REVIEW_CWD
	WORKER="$TMP/agents/io.github.millon15.session-learnings.plist"
	REVIEW="$TMP/agents/io.github.millon15.session-learnings.review.plist"
	stub launchctl "printf '%s\n' \"\$*\" >> '$TMP/launchctl.log'; [ \"\$1\" != print ] || [ -e '$TMP/loaded' ]"
}

teardown() { teardown_tmp; }

plist_value() {
	plutil -extract "$2" raw "$1"
}

@test "plain install leaves the review agent out" {
	run "$INSTALL"
	assert_status 0
	[ -f "$WORKER" ]
	[ ! -e "$REVIEW" ]
	[ ! -e "$SESSION_LEARNINGS_HOME/bin/sl-review" ]
}

@test "--review-weekly installs both agents, Monday 10:00 in HOME by default" {
	run "$INSTALL" --review-weekly
	assert_status 0
	plutil -lint "$WORKER" "$REVIEW"
	[ "$(plist_value "$REVIEW" StartCalendarInterval.Weekday)" = 1 ]
	[ "$(plist_value "$REVIEW" StartCalendarInterval.Hour)" = 10 ]
	[ "$(plist_value "$REVIEW" StartCalendarInterval.Minute)" = 0 ]
	[ "$(plist_value "$REVIEW" EnvironmentVariables.SESSION_LEARNINGS_REVIEW_CWD)" = "$HOME" ]
	[ "$(plist_value "$REVIEW" EnvironmentVariables.SESSION_LEARNINGS_HOME)" = "$SESSION_LEARNINGS_HOME" ]
	[ "$(plist_value "$REVIEW" ProgramArguments.1)" = "$SESSION_LEARNINGS_HOME/bin/sl-review" ]
	[ "$(plist_value "$WORKER" StartInterval)" = 3600 ]
	grep -q '^bootstrap .*session-learnings.review.plist$' "$TMP/launchctl.log"
}

@test "the review shim follows plugin-root to the launcher" {
	"$INSTALL" --review-weekly
	grep -q 'scripts/sl-review-launch.sh' "$SESSION_LEARNINGS_HOME/bin/sl-review"
	echo "$TMP/gone" >"$SESSION_LEARNINGS_HOME/plugin-root"
	run "$SESSION_LEARNINGS_HOME/bin/sl-review"
	assert_status 78
	assert_contains "$output" "sl-review: no sl-review-launch.sh under '$TMP/gone'"
}

@test "schedule and cwd overrides reach the plist and --explain names their source" {
	export SESSION_LEARNINGS_REVIEW_WEEKDAY=5 SESSION_LEARNINGS_REVIEW_HOUR=17 SESSION_LEARNINGS_REVIEW_CWD="$TMP/project"
	"$INSTALL" --review-weekly
	[ "$(plist_value "$REVIEW" StartCalendarInterval.Weekday)" = 5 ]
	[ "$(plist_value "$REVIEW" StartCalendarInterval.Hour)" = 17 ]
	[ "$(plist_value "$REVIEW" EnvironmentVariables.SESSION_LEARNINGS_REVIEW_CWD)" = "$TMP/project" ]
	run "$INSTALL" --explain
	assert_explain_complete "$output"
	assert_explain_source "$output" review_weekday detected:SESSION_LEARNINGS_REVIEW_WEEKDAY
	assert_explain_source "$output" review_cwd detected:SESSION_LEARNINGS_REVIEW_CWD
}

@test "an out-of-range schedule is a usage error and writes no review plist" {
	for bad in "WEEKDAY=8" "HOUR=24" "HOUR=ten"; do
		env "SESSION_LEARNINGS_REVIEW_$bad" "$INSTALL" --review-weekly >/dev/null 2>&1 && return 1
		[ ! -e "$REVIEW" ]
	done
}

@test "--check passes without the review agent and fails when its plist is not loaded" {
	"$INSTALL"
	touch "$TMP/loaded"
	run "$INSTALL" --check
	assert_status 0
	assert_contains "$output" "review agent not installed"
	"$INSTALL" --review-weekly
	run "$INSTALL" --check
	assert_status 0
	assert_contains "$output" "session-learnings.review loaded"
	rm "$TMP/loaded"
	run "$INSTALL" --check
	assert_status 1
}

@test "--uninstall removes both plists and keeps the store" {
	"$INSTALL" --review-weekly
	run "$INSTALL" --uninstall
	assert_status 0
	[ ! -e "$WORKER" ]
	[ ! -e "$REVIEW" ]
	[ -d "$SESSION_LEARNINGS_HOME" ]
	grep -q 'bootout gui/.*/io.github.millon15.session-learnings.review' "$TMP/launchctl.log"
}

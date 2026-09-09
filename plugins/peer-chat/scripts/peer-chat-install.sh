#!/usr/bin/env bash
# peer-chat-install — put the pieces both agents need where each of them looks.
#
#   peer-chat-install.sh          # install or refresh everything, print what changed
#   peer-chat-install.sh --check  # report only; exit 0 when every piece is in place, 1 otherwise
#
# Three pieces, because the two agents resolve files differently:
#   1. peer-chat.py on PATH — both skills invoke it as a bare command. Copied, not symlinked: a
#      symlink into the plugin cache dies on the next plugin version bump.
#   2. ~/.codex/skills/peer-chat/SKILL.md — Codex reads skills from its own home, never from a
#      Claude plugin.
#   3. two prefix_rule lines in ~/.codex/rules/default.rules — without them every Codex send stops
#      for approval.
# The Claude side needs nothing here: the skill ships in the plugin and Claude Code loads it.
#
# Re-run after a plugin update; --check is what the skill runs as its preflight.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
BIN_DIR="${PEER_CHAT_BIN_DIR:-$HOME/.local/bin}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILL_DIR="$CODEX_HOME/skills/peer-chat"
RULES_FILE="$CODEX_HOME/rules/default.rules"

SRC_SCRIPT="$PLUGIN_ROOT/scripts/peer-chat.py"
SRC_PASTE="$PLUGIN_ROOT/scripts/peer-chat-paste.py"
SRC_SKILL="$PLUGIN_ROOT/codex/SKILL.md"
RULE_PREPARE='prefix_rule(pattern=["peer-chat.py", "--prepare-message"], decision="allow")'
RULE_SEND='prefix_rule(pattern=["peer-chat.py", "--to", "claude", "--message-file"], decision="allow")'
RULE_PASTE='prefix_rule(pattern=["peer-chat-paste.py", "--to", "claude", "--message-file"], decision="allow")'

say() { printf 'peer-chat-install: %s\n' "$1"; }
die() {
	printf 'peer-chat-install: %s\n' "$1" >&2
	exit "$2"
}

same_file() { cmp -s "$1" "$2"; }

on_path() {
	case ":$PATH:" in
	*":$1:"*) return 0 ;;
	esac
	return 1
}

has_rule() { [ -f "$RULES_FILE" ] && grep -qF -- "$1" "$RULES_FILE"; }

# ------------------------------------------------------------------ check --

check() {
	local missing=0
	if same_file "$SRC_SCRIPT" "$BIN_DIR/peer-chat.py" && [ -x "$BIN_DIR/peer-chat.py" ]; then
		say "ok   $BIN_DIR/peer-chat.py"
	else
		say "MISSING or stale  $BIN_DIR/peer-chat.py"
		missing=1
	fi
	if same_file "$SRC_PASTE" "$BIN_DIR/peer-chat-paste.py" && [ -x "$BIN_DIR/peer-chat-paste.py" ]; then
		say "ok   $BIN_DIR/peer-chat-paste.py"
	else
		say "MISSING or stale  $BIN_DIR/peer-chat-paste.py"
		missing=1
	fi
	on_path "$BIN_DIR" || {
		say "WARN $BIN_DIR is not on PATH; both skills call peer-chat.py by bare name"
		missing=1
	}
	if same_file "$SRC_SKILL" "$SKILL_DIR/SKILL.md"; then
		say "ok   $SKILL_DIR/SKILL.md"
	else
		say "MISSING or stale  $SKILL_DIR/SKILL.md"
		missing=1
	fi
	if has_rule "$RULE_PREPARE" && has_rule "$RULE_SEND" && has_rule "$RULE_PASTE"; then
		say "ok   $RULES_FILE carries the three peer-chat rules"
	else
		say "MISSING  peer-chat rules in $RULES_FILE"
		missing=1
	fi
	return "$missing"
}

# ---------------------------------------------------------------- install --

install_script() {
	mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR" 1
	if same_file "$SRC_SCRIPT" "$BIN_DIR/peer-chat.py"; then
		say "unchanged $BIN_DIR/peer-chat.py"
	else
		cat "$SRC_SCRIPT" >"$BIN_DIR/peer-chat.py" || die "cannot write $BIN_DIR/peer-chat.py" 1
		say "wrote     $BIN_DIR/peer-chat.py"
	fi
	chmod +x "$BIN_DIR/peer-chat.py"
	if same_file "$SRC_PASTE" "$BIN_DIR/peer-chat-paste.py"; then
		say "unchanged $BIN_DIR/peer-chat-paste.py"
	else
		cat "$SRC_PASTE" >"$BIN_DIR/peer-chat-paste.py" || die "cannot write $BIN_DIR/peer-chat-paste.py" 1
		say "wrote     $BIN_DIR/peer-chat-paste.py"
	fi
	chmod +x "$BIN_DIR/peer-chat-paste.py"
	on_path "$BIN_DIR" || say "WARN      add $BIN_DIR to PATH; both skills call peer-chat.py by bare name"
}

install_codex_skill() {
	mkdir -p "$SKILL_DIR" || die "cannot create $SKILL_DIR" 1
	if same_file "$SRC_SKILL" "$SKILL_DIR/SKILL.md"; then
		say "unchanged $SKILL_DIR/SKILL.md"
		return
	fi
	cat "$SRC_SKILL" >"$SKILL_DIR/SKILL.md" || die "cannot write $SKILL_DIR/SKILL.md" 1
	say "wrote     $SKILL_DIR/SKILL.md"
}

append_rule() {
	if has_rule "$1"; then
		say "present   $1"
		return
	fi
	printf '%s\n' "$1" >>"$RULES_FILE" || die "cannot append to $RULES_FILE" 1
	say "appended  $1"
}

install_codex_rules() {
	mkdir -p "$(dirname "$RULES_FILE")" || die "cannot create $(dirname "$RULES_FILE")" 1
	[ -f "$RULES_FILE" ] || : >"$RULES_FILE"
	append_rule "$RULE_PREPARE"
	append_rule "$RULE_SEND"
	append_rule "$RULE_PASTE"
}

install_all() {
	[ -f "$SRC_SCRIPT" ] || die "missing $SRC_SCRIPT; is this script inside the plugin?" 2
	[ -f "$SRC_SKILL" ] || die "missing $SRC_SKILL; is this script inside the plugin?" 2
	[ -f "$SRC_PASTE" ] || die "missing $SRC_PASTE; is this script inside the plugin?" 2
	install_script
	install_codex_skill
	install_codex_rules
	say "done. Start Codex in the right pane with the session id injected, or let peer-chat-spawn.sh do it."
}

main() {
	case "${1:-}" in
	--check) check ;;
	'') install_all ;;
	*) die "usage: peer-chat-install.sh [--check]" 2 ;;
	esac
}

main "$@"

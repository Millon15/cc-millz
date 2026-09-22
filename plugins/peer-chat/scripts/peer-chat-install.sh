#!/usr/bin/env bash
# peer-chat-install — put the pieces both agents need where each of them looks.
#
#   peer-chat-install.sh          # install or refresh everything, print what changed
#   peer-chat-install.sh --check  # report only; exit 0 when every piece is in place, 1 otherwise
#
# Three pieces, the same for every harness:
#   1. peer-chat.py, its engine peer-chat-engine.py and peer-chat-paste.py on PATH — the skill
#      invokes them as bare commands. Copied, not symlinked: a symlink into the plugin cache dies on
#      the next plugin version bump.
#   2. the skill: Claude Code and Codex both load skills/peer-chat/SKILL.md from their plugin copy.
#      A standalone copy in ~/.codex/skills/peer-chat/ serves a Codex whose plugin is missing,
#      disabled or cached at an older body. Once config.toml enables the plugin and its cache holds
#      this exact body, a standalone copy this script wrote is renamed to SKILL.md.retired.
#   3. three prefix_rule lines in ~/.codex/rules/default.rules — without them every Codex send stops
#      for approval.
#
# Re-run after a plugin update; --check is what the skill runs as its preflight. The installed
# version is stamped in ~/.codex/skills/peer-chat/.version, kept there so older installers still
# see it, and a copy of this script from an OLDER plugin never overwrites a newer install: a
# session still holding last week's skill in context would otherwise "refresh" the files back to
# its own version on every preflight.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
BIN_DIR="${PEER_CHAT_BIN_DIR:-$HOME/.local/bin}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILL_DIR="$CODEX_HOME/skills/peer-chat"
RULES_FILE="$CODEX_HOME/rules/default.rules"

SRC_SCRIPT="$PLUGIN_ROOT/scripts/peer-chat.py"
SRC_ENGINE="$PLUGIN_ROOT/scripts/vendor/peer-chat.py"
SRC_PASTE="$PLUGIN_ROOT/scripts/peer-chat-paste.py"
SRC_SKILL="$PLUGIN_ROOT/skills/peer-chat/SKILL.md"
RULE_PREPARE='prefix_rule(pattern=["peer-chat.py", "--prepare-message"], decision="allow")'
RULE_SEND='prefix_rule(pattern=["peer-chat.py", "--to", "peer", "--message-file"], decision="allow")'
RULE_PASTE='prefix_rule(pattern=["peer-chat-paste.py", "--to", "peer", "--message-file"], decision="allow")'
MANIFEST="$PLUGIN_ROOT/.claude-plugin/plugin.json"
STAMP="$SKILL_DIR/.version"

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

plugin_version() { jq -r '.version // "0"' "$MANIFEST" 2>/dev/null || printf '0'; }
installed_version() { [ -f "$STAMP" ] && tr -d '[:space:]' <"$STAMP" || printf '0'; }

# newer_installed: the stamp names a version above this plugin copy's own.
newer_installed() {
	local mine theirs
	mine="$(plugin_version)"
	theirs="$(installed_version)"
	[ "$mine" != "$theirs" ] && [ "$(printf '%s\n%s\n' "$mine" "$theirs" | sort -V | tail -n 1)" = "$theirs" ]
}

refuse_downgrade() {
	newer_installed || return 1
	say "ok   peer-chat $(installed_version) is installed; this $(plugin_version) copy is older and changes nothing"
	return 0
}

# bin_copies: one "<name on PATH><TAB><source>" line per file the skill calls by bare name.
bin_copies() {
	printf '%s\t%s\n' \
		peer-chat.py "$SRC_SCRIPT" \
		peer-chat-engine.py "$SRC_ENGINE" \
		peer-chat-paste.py "$SRC_PASTE"
}

# codex_plugin_enabled: config.toml has a [plugins."peer-chat@<marketplace>"] table with enabled = true.
codex_plugin_enabled() {
	[ -f "$CODEX_HOME/config.toml" ] || return 1
	awk '
		/^\[/ { in_plugin = ($0 ~ /^\[plugins\."peer-chat@[^"]+"\]/); next }
		in_plugin && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true/ { found = 1 }
		END { exit !found }
	' "$CODEX_HOME/config.toml"
}

# codex_cache_has_skill: a cached plugin copy carries this exact skill body, not an older one.
codex_cache_has_skill() {
	local cached
	for cached in "$CODEX_HOME"/plugins/cache/*/peer-chat/*/skills/peer-chat/SKILL.md; do
		same_file "$SRC_SKILL" "$cached" && return 0
	done
	return 1
}

# codex_plugin_skill: Codex loads this skill body from its enabled plugin, so a standalone copy is a duplicate.
codex_plugin_skill() { codex_plugin_enabled && codex_cache_has_skill; }

# ------------------------------------------------------------------ check --

check_bin() {
	if same_file "$2" "$BIN_DIR/$1" && [ -x "$BIN_DIR/$1" ]; then
		say "ok   $BIN_DIR/$1"
		return 0
	fi
	say "MISSING or stale  $BIN_DIR/$1"
	return 1
}

check_codex_skill() {
	if codex_plugin_skill && [ ! -f "$SKILL_DIR/SKILL.md" ]; then
		say "ok   Codex loads the skill from its peer-chat plugin"
		return 0
	fi
	if codex_plugin_skill; then
		say "STALE  $SKILL_DIR/SKILL.md duplicates the skill the Codex plugin ships"
		return 1
	fi
	if same_file "$SRC_SKILL" "$SKILL_DIR/SKILL.md"; then
		say "ok   $SKILL_DIR/SKILL.md"
		return 0
	fi
	say "MISSING or stale  $SKILL_DIR/SKILL.md"
	return 1
}

check_rules() {
	if has_rule "$RULE_PREPARE" && has_rule "$RULE_SEND" && has_rule "$RULE_PASTE"; then
		say "ok   $RULES_FILE carries the three peer-chat rules"
		return 0
	fi
	say "MISSING  peer-chat rules in $RULES_FILE"
	return 1
}

check() {
	local missing=0 name src
	refuse_downgrade && return 0
	while IFS=$'\t' read -r name src; do
		check_bin "$name" "$src" || missing=1
	done < <(bin_copies)
	on_path "$BIN_DIR" || {
		say "WARN $BIN_DIR is not on PATH; the skill calls peer-chat.py by bare name"
		missing=1
	}
	check_codex_skill || missing=1
	check_rules || missing=1
	return "$missing"
}

# ---------------------------------------------------------------- install --

install_bin() {
	if same_file "$2" "$BIN_DIR/$1"; then
		say "unchanged $BIN_DIR/$1"
	else
		cat "$2" >"$BIN_DIR/$1" || die "cannot write $BIN_DIR/$1" 1
		say "wrote     $BIN_DIR/$1"
	fi
	chmod +x "$BIN_DIR/$1"
}

install_scripts() {
	local name src
	mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR" 1
	while IFS=$'\t' read -r name src; do
		install_bin "$name" "$src"
	done < <(bin_copies)
	on_path "$BIN_DIR" || say "WARN      add $BIN_DIR to PATH; the skill calls peer-chat.py by bare name"
}

retire_standalone_skill() {
	if [ ! -f "$SKILL_DIR/SKILL.md" ]; then
		say "ok        Codex loads the skill from its peer-chat plugin"
		return
	fi
	if [ ! -f "$STAMP" ]; then
		say "WARN      $SKILL_DIR/SKILL.md was not written by this installer; left beside the plugin's skill"
		return
	fi
	mv -f "$SKILL_DIR/SKILL.md" "$SKILL_DIR/SKILL.md.retired" || die "cannot retire $SKILL_DIR/SKILL.md" 1
	say "retired   $SKILL_DIR/SKILL.md to SKILL.md.retired; Codex loads the skill from its peer-chat plugin"
}

install_codex_skill() {
	if codex_plugin_skill; then
		retire_standalone_skill
		return
	fi
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

write_stamp() {
	mkdir -p "$SKILL_DIR" || die "cannot create $SKILL_DIR" 1
	printf '%s\n' "$(plugin_version)" >"$STAMP" || die "cannot write $STAMP" 1
}

install_all() {
	local source
	for source in "$SRC_SCRIPT" "$SRC_ENGINE" "$SRC_PASTE" "$SRC_SKILL"; do
		[ -f "$source" ] || die "missing $source; is this script inside the plugin?" 2
	done
	refuse_downgrade && return 0
	install_scripts
	install_codex_skill
	install_codex_rules
	write_stamp
	say "done. peer-chat-spawn.sh opens the peer pane; either side sends with peer-chat-paste.py --to peer."
}

main() {
	case "${1:-}" in
	--check) check ;;
	'') install_all ;;
	*) die "usage: peer-chat-install.sh [--check]" 2 ;;
	esac
}

main "$@"

#!/usr/bin/env bash
# Claude Code status line — robbyrussell palette, two lines.
#   L1  {dir} ❯ {branch} ✗{N} ❯ [{model} {window} {effort}] ❯ {tokens}·{pct}
#   L2  5h:{pct}·{reset} ❯ wk:{pct}·{reset} ❯ {model}:{pct} | … ❯ {spend} ❯ ${session}
# Quota numbers come from Anthropic OAuth /api/oauth/usage, cached to TMPDIR.
# Colors stay as literal escapes until the final printf '%b'.

readonly CYAN='\e[96m'
readonly BLUE='\e[0;34m'
readonly BLUE_BOLD='\e[1;34m'
readonly GREEN='\e[0;32m'
readonly YELLOW='\e[93m'
readonly YELLOW_BOLD='\e[1;93m'
readonly RED='\e[0;31m'
readonly RED_BOLD='\e[1;31m'
readonly DARK_YELLOW='\e[0;33m'
readonly DARK_RED='\e[38;5;88m'
readonly WHITE='\e[0;37m'
readonly GREY='\e[38;5;244m'
readonly LIGHT_GREY='\e[38;5;250m'
readonly DIM_GREY='\e[38;5;240m'
readonly RESET='\e[0m'
readonly SEP='\e[38;5;240m ❯ \e[0m'

# Unit separator: a whitespace IFS would collapse consecutive empty fields
readonly FS=$'\x1f'

readonly USAGE_CACHE="${TMPDIR:-/tmp}/claude-usage-${USER}.json"
readonly USAGE_TTL="${CLAUDE_USAGE_TTL:-45}"
readonly USAGE_URL='https://api.anthropic.com/api/oauth/usage'

# One clock read for the whole render; bash 3.2 (macOS) has no EPOCHSECONDS
NOW=$(date +%s)
USAGE_CACHE_MTIME=0
DIRTY_CACHE_MTIME=0

# Branch names that mean "nothing in flight" — exact match, never a suffix test:
# a feature branch may legitimately END in "-release", which a suffix rule would eat.
# MCP tool schemas never reach the transcript, so their weight is an estimate;
# skill weight is measured from SKILL.md on disk.
readonly MCP_TOKENS_PER_TOOL="${CLAUDE_MCP_TOKENS_PER_TOOL:-280}"
readonly BYTES_PER_TOKEN=4
readonly TAB=$'\t'

readonly TRUNK_BRANCHES=' master main stage staging release '
# Landing on these needs a PR, never a direct commit — the branch key turns red
readonly PROTECTED_BRANCHES=' master main release '
readonly CAUTION_BRANCHES=' stage staging '
readonly DIRTY_TTL="${CLAUDE_DIRTY_TTL:-60}"
readonly MAX_TICKET_GROUPS=2

# --- Quota cache -------------------------------------------------------------

# stat accepts many paths per call — every caller batches rather than looping.
# Callers must pass only paths that exist; a missing one shifts every later line.
stat_values() {
	local bsd="$1" gnu="$2"
	shift 2
	[ "$#" -eq 0 ] && return 0
	stat -f "$bsd" "$@" 2>/dev/null || stat -c "$gnu" "$@" 2>/dev/null
}

file_mtime() {
	[ -e "$1" ] || {
		printf '0'
		return 0
	}
	local value
	value=$(stat_values '%m' '%Y' "$1")
	printf '%d' "${value:-0}"
}

usage_cache_is_fresh() {
	[ "$USAGE_CACHE_MTIME" -gt 0 ] 2>/dev/null || return 1
	[ $((NOW - USAGE_CACHE_MTIME)) -lt "$USAGE_TTL" ]
}

oauth_token() {
	local cred=""
	command -v security >/dev/null 2>&1 &&
		cred=$(security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null)
	[ -z "$cred" ] && [ -f "$HOME/.claude/.credentials.json" ] && cred=$(cat "$HOME/.claude/.credentials.json")
	printf '%s' "$cred" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

refresh_usage_cache() {
	usage_cache_is_fresh && return 0
	local token response
	token=$(oauth_token)
	[ -z "$token" ] && return 0
	response="${USAGE_CACHE}.tmp"
	if curl -fsS --max-time 3 \
		-H "Authorization: Bearer $token" \
		-H "anthropic-beta: oauth-2025-04-20" \
		"$USAGE_URL" -o "$response" 2>/dev/null; then
		mv "$response" "$USAGE_CACHE"
	else
		rm -f "$response" 2>/dev/null
	fi
	return 0
}

read_quota_fields() {
	[ -s "$USAGE_CACHE" ] || return 0
	jq -r '
		# ISO8601 with microseconds and a +00:00 offset is not fromdateiso8601-
		# parseable; normalising here keeps two `date` forks out of every render.
		def epoch: . // "" | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
			| (try fromdateiso8601 catch 0);
		(.limits // []) as $limits |
		[
			(.five_hour.utilization // 0 | floor),
			(.five_hour.resets_at | epoch),
			([$limits[] | select(.group == "session") | .severity] | first // "normal"),
			(.seven_day.utilization // 0 | floor),
			(.seven_day.resets_at | epoch),
			([$limits[] | select(.kind == "weekly_all") | .severity] | first // "normal"),
			([$limits[] | select(.kind == "weekly_scoped")
				| "\(.scope.model.display_name // "?" | ascii_downcase):\(.percent)%"] | join(" | ")),
			(.spend.used.amount_minor // 0),
			(.spend.limit.amount_minor // 0),
			(.spend.limit.exponent // 2),
			(.spend.limit.currency // ""),
			(.spend.severity // "normal")
		] | map(tostring) | join($sep)' --arg sep "$FS" "$USAGE_CACHE" 2>/dev/null
}

# --- Formatting primitives ---------------------------------------------------

remaining_minutes() {
	local reset_epoch="${1:-0}"
	[ "$reset_epoch" -gt "$NOW" ] 2>/dev/null || return 0
	printf '%d' $(((reset_epoch - NOW) / 60))
}

format_duration() {
	local minutes="${1:-0}"
	[ "$minutes" -gt 0 ] 2>/dev/null || return 0
	local days=$((minutes / 1440)) hours=$(((minutes % 1440) / 60)) mins=$((minutes % 60))
	[ "$days" -gt 0 ] && {
		printf '%dd%dh' "$days" "$hours"
		return 0
	}
	[ "$hours" -gt 0 ] && {
		printf '%dh%dm' "$hours" "$mins"
		return 0
	}
	printf '%dm' "$mins"
}

# A separator must recede from whatever it sits between, so it takes one step
# down the same hue rather than a fixed grey
dim_of() {
	case "$1" in
	"$LIGHT_GREY") printf '%s' "$GREY" ;;
	"$GREY") printf '%s' "$DIM_GREY" ;;
	"$YELLOW") printf '%s' "$DARK_YELLOW" ;;
	"$RED") printf '%s' "$DARK_RED" ;;
	*) printf '%s' "$DIM_GREY" ;;
	esac
}

severity_color() {
	case "$1" in
	critical) printf '%s' "$RED" ;;
	warning) printf '%s' "$YELLOW" ;;
	*) printf '%s' "$WHITE" ;;
	esac
}

# <25% dim · 25–50% light · 50–75% yellow · 75%+ red; API severity can only escalate
quota_color() {
	local pct="${1:-0}" severity="$2"
	[ "$severity" = "critical" ] && {
		printf '%s' "$RED"
		return 0
	}
	[ "$pct" -ge 75 ] 2>/dev/null && {
		printf '%s' "$RED"
		return 0
	}
	[ "$pct" -ge 50 ] 2>/dev/null || [ "$severity" = "warning" ] && {
		printf '%s' "$YELLOW"
		return 0
	}
	[ "$pct" -ge 25 ] 2>/dev/null && {
		printf '%s' "$LIGHT_GREY"
		return 0
	}
	printf '%s' "$GREY"
}

# <120k dim · 120–240k light · 240–360k yellow · 360k+ red
context_color() {
	local tokens="${1:-0}"
	[ "$tokens" -ge 360000 ] 2>/dev/null && {
		printf '%s' "$RED"
		return 0
	}
	[ "$tokens" -ge 240000 ] 2>/dev/null && {
		printf '%s' "$YELLOW"
		return 0
	}
	[ "$tokens" -ge 120000 ] 2>/dev/null && {
		printf '%s' "$LIGHT_GREY"
		return 0
	}
	printf '%s' "$GREY"
}

currency_symbol() {
	case "$1" in
	EUR) printf '€' ;;
	USD) printf '$' ;;
	GBP) printf '£' ;;
	JPY) printf '¥' ;;
	*) printf '%s' "$1" ;;
	esac
}

join_with() {
	local separator="$1" joined="" segment
	shift
	for segment in "$@"; do
		[ -z "$segment" ] && continue
		[ -n "$joined" ] && joined="${joined}${separator}"
		joined="${joined}${segment}"
	done
	printf '%s' "$joined"
}

join_segments() { join_with "$SEP" "$@"; }

# --- Segments ----------------------------------------------------------------

dir_segment() {
	local dir="$1"
	[ -z "$dir" ] && return 0
	[ "$dir" = "$HOME" ] && {
		printf '%s~%s' "$CYAN" "$RESET"
		return 0
	}
	printf '%s%s%s' "$CYAN" "${dir##*/}" "$RESET"
}

# --- Git scopes: cd = repo holding cwd, sd = monorepo subrepos off trunk ------

# Project-declared nested repos, one relative path per line ('#' comments ok).
# No file = no sd: scope, the right default outside a monorepo. A depth walk is
# deliberately NOT used: 50ms, and it drags in scratch clones under tmp/.
subrepo_registry() {
	local root="$1" candidate
	for candidate in \
		"${STATUSLINE_REPOS_FILE:-}" \
		"$root/.claude/statusline-repos.txt" \
		"$root/.rulesync/statusline-repos.txt"; do
		[ -n "$candidate" ] && [ -f "$candidate" ] && {
			local line
			while IFS= read -r line || [ -n "$line" ]; do
				line="${line%%#*}"
				line="${line//[[:space:]]/}"
				[ -n "$line" ] && printf '%s\n' "$line"
			done <"$candidate"
			return 0
		}
	done
}

# Reading .git/HEAD beats spawning git, and assigning to BRANCH rather than
# echoing avoids a subshell fork per repo — 17 of them on a monorepo render.
read_branch() {
	BRANCH=""
	local head_file="$1/.git/HEAD" ref
	[ -f "$head_file" ] || return 0
	read -r ref <"$head_file"
	case "$ref" in
	"ref: refs/heads/"*) BRANCH="${ref#ref: refs/heads/}" ;;
	*) BRANCH="@${ref:0:7}" ;;
	esac
}

# Innermost enclosing repo, without spawning git rev-parse
repo_root_of() {
	local dir="$1"
	while [ -n "$dir" ] && [ "$dir" != "/" ]; do
		[ -e "$dir/.git" ] && {
			printf '%s' "$dir"
			return 0
		}
		dir="${dir%/*}"
	done
}

is_trunk_branch() {
	case "$TRUNK_BRANCHES" in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

ticket_key() {
	local branch="$1"
	[[ "$branch" =~ ^([A-Z][A-Z0-9]*-[0-9]+) ]] && {
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	}
	printf '%s' "$branch"
}

# "<tracked>\t<untracked>\t<conflicts>\t<ahead>\t<behind>"; -1 ahead = no upstream
count_dirty() {
	local repo="$1" porcelain sync ahead=-1 behind=-1
	porcelain=$(git -C "$repo" --no-optional-locks status --porcelain 2>/dev/null |
		awk '
			/^\?\?/                     {u++; next}
			/^(DD|AU|UD|UA|DU|AA|UU)/   {c++; next}
			                            {t++}
			END {printf "%d\t%d\t%d", t+0, u+0, c+0}')
	sync=$(git -C "$repo" --no-optional-locks rev-list --count --left-right '@{upstream}...HEAD' 2>/dev/null)
	[ -n "$sync" ] && {
		behind="${sync%%"${TAB}"*}"
		ahead="${sync##*"${TAB}"}"
	}
	printf '%s\t%s\t%s' "$porcelain" "$ahead" "$behind"
}

dirty_cache_path() {
	local slug="${1//\//_}"
	printf '%s/claude-git-%s-%s.tsv' "${TMPDIR:-/tmp}" "$USER" "${slug// /_}"
}

# Fresh means young AND same HEADs — a checkout invalidates instantly,
# only the file counts are allowed to age
# Everything after the header line, without forking tail
read_cache_facts() {
	local line first=1
	while IFS= read -r line || [ -n "$line" ]; do
		[ "$first" = "1" ] && {
			first=0
			continue
		}
		printf '%s\n' "$line"
	done <"$1"
}

dirty_cache_is_fresh() {
	local cache="$1" signature="$2" stored
	[ -f "$cache" ] || return 1
	[ $((NOW - DIRTY_CACHE_MTIME)) -lt "$DIRTY_TTL" ] || return 1
	read -r stored <"$cache"
	[ "$stored" = "$signature" ]
}

dirty_table() {
	local root="$1" signature="$2"
	shift 2
	local cache repo
	cache=$(dirty_cache_path "$root")
	dirty_cache_is_fresh "$cache" "$signature" && {
		read_cache_facts "$cache"
		return 0
	}
	# Each repo costs a git status plus a rev-list; run them concurrently so the
	# cold path is the slowest single repo, not their sum.
	local parts="${cache}.parts" index=0
	mkdir -p "$parts"
	for repo in "$@"; do
		printf '%s\t%s\n' "$repo" "$(count_dirty "$repo")" >"$parts/$index" &
		index=$((index + 1))
	done
	wait
	{
		printf '%s\n' "$signature"
		local part=0
		while [ "$part" -lt "$index" ]; do
			cat "$parts/$part" 2>/dev/null
			part=$((part + 1))
		done
	} >"${cache}.tmp" && mv "${cache}.tmp" "$cache"
	read_cache_facts "$cache"
}

lookup_dirty() {
	local table="$1" repo="$2" line
	while IFS= read -r line; do
		case "$line" in
		"$repo"$'\t'*)
			printf '%s' "${line#*$'\t'}"
			return 0
			;;
		esac
	done <<<"$table"
}

# ⚔ conflicts, ✗ tracked, ? untracked; each omitted when zero
dirty_counters() {
	local tracked="${1:-0}" untracked="${2:-0}" conflicts="${3:-0}" rendered=""
	[ "$conflicts" -gt 0 ] 2>/dev/null && rendered="${RED}⚔${conflicts}${RESET}"
	[ "$tracked" -gt 0 ] 2>/dev/null && rendered="${rendered:+${rendered} }${RED}✗${tracked}${RESET}"
	[ "$untracked" -gt 0 ] 2>/dev/null && rendered="${rendered:+${rendered} }${YELLOW}?${untracked}${RESET}"
	printf '%s' "$rendered"
}

# ⇡ = no upstream configured at all, so the branch cannot be pushed as-is
sync_counters() {
	local ahead="${1:-0}" behind="${2:-0}" rendered=""
	[ "$ahead" -lt 0 ] 2>/dev/null && {
		printf '%s⇡%s' "$YELLOW" "$RESET"
		return 0
	}
	[ "$ahead" -gt 0 ] 2>/dev/null && rendered="${YELLOW}↑${ahead}${RESET}"
	[ "$behind" -gt 0 ] 2>/dev/null && rendered="${rendered:+${rendered} }${GREY}↓${behind}${RESET}"
	printf '%s' "$rendered"
}

# An interrupted operation you'd otherwise forget you were inside
operation_badge() {
	local git_dir="$1/.git"
	{ [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; } && {
		printf '%s⎇rebase%s' "$RED" "$RESET"
		return 0
	}
	[ -f "$git_dir/MERGE_HEAD" ] && {
		printf '%s⎇merge%s' "$RED" "$RESET"
		return 0
	}
	[ -f "$git_dir/CHERRY_PICK_HEAD" ] && {
		printf '%s⎇cherry%s' "$RED" "$RESET"
		return 0
	}
	[ -f "$git_dir/REVERT_HEAD" ] && {
		printf '%s⎇revert%s' "$RED" "$RESET"
		return 0
	}
	[ -f "$git_dir/BISECT_LOG" ] && printf '%s⎇bisect%s' "$RED" "$RESET"
}

# Same rule for both scopes; cd renders it bold, sd plain
branch_color() {
	local branch="$1" weight="${2:-plain}" tier=blue
	case "$PROTECTED_BRANCHES" in
	*" $branch "*) tier=red ;;
	esac
	case "$CAUTION_BRANCHES" in
	*" $branch "*) tier=yellow ;;
	esac
	case "${tier}:${weight}" in
	red:bold) printf '%s' "$RED_BOLD" ;;
	red:*) printf '%s' "$RED" ;;
	yellow:bold) printf '%s' "$YELLOW_BOLD" ;;
	yellow:*) printf '%s' "$YELLOW" ;;
	blue:bold) printf '%s' "$BLUE_BOLD" ;;
	*) printf '%s' "$BLUE" ;;
	esac
}

# Red = tracked edits or conflicts, yellow = untracked only, grey = clean
repo_name_color() {
	local tracked="${1:-0}" untracked="${2:-0}" conflicts="${3:-0}"
	{ [ "$tracked" -gt 0 ] || [ "$conflicts" -gt 0 ]; } 2>/dev/null && {
		printf '%s' "$RED"
		return 0
	}
	[ "$untracked" -gt 0 ] 2>/dev/null && {
		printf '%s' "$YELLOW"
		return 0
	}
	printf '%s' "$GREY"
}

cd_segment() {
	local repo="$1" table="$2" branch tracked untracked conflicts ahead behind
	read_branch "$repo"
	branch="$BRANCH"
	[ -z "$branch" ] && return 0
	IFS="$TAB" read -r tracked untracked conflicts ahead behind <<<"$(lookup_dirty "$table" "$repo")"
	join_with " " \
		"$(branch_color "$branch" bold)cd:$(ticket_key "$branch")${RESET}" \
		"$(operation_badge "$repo")" \
		"$(dirty_counters "$tracked" "$untracked" "$conflicts")" \
		"$(sync_counters "$ahead" "$behind")"
}

# Groups off-trunk subrepos by ticket key: sd:KEY(repo·repo·repo)
sd_segment() {
	local root="$1" table="$2"
	local keys=() members=() tints=() repo branch key index slot rendered="" group_count=0
	while read -r repo; do
		[ -z "$repo" ] && continue
		read_branch "$root/$repo"
		branch="$BRANCH"
		{ [ -z "$branch" ] || is_trunk_branch "$branch"; } && continue
		key=$(ticket_key "$branch")
		slot=-1
		for ((index = 0; index < ${#keys[@]}; index++)); do
			[ "${keys[$index]}" = "$key" ] && slot=$index && break
		done
		[ "$slot" -lt 0 ] && {
			keys+=("$key")
			members+=("")
			tints+=("$(branch_color "$branch")")
			slot=$((${#keys[@]} - 1))
		}
		# shellcheck disable=SC2046  # lookup_dirty emits two tab-separated args on purpose
		members[slot]="${members[$slot]:+${members[$slot]}${DIM_GREY}·${RESET}}$(repo_name_color $(lookup_dirty "$table" "$root/$repo"))${repo##*/}${RESET}"
	done <<<"$(subrepo_registry "$root")"

	local total="${#keys[@]}"
	[ "$total" -eq 0 ] && return 0
	for ((index = 0; index < total; index++)); do
		[ "$group_count" -ge "$MAX_TICKET_GROUPS" ] && {
			printf '%ssd:%s%s %s+%d%s' "${tints[0]}" "$RESET" "$rendered" "$DIM_GREY" $((total - group_count)) "$RESET"
			return 0
		}
		rendered="${rendered:+${rendered} }${tints[$index]}${keys[$index]}${RESET}${DIM_GREY}(${RESET}${members[$index]}${DIM_GREY})${RESET}"
		group_count=$((group_count + 1))
	done
	printf '%ssd:%s%s' "${tints[0]}" "$RESET" "$rendered"
}

# --- Context load: what this session actually pulled into the window ----------

# The payload carries transcript_path; session_id + cwd slug reconstructs it if not
transcript_file() {
	local explicit="$1" session="$2" dir="$3"
	[ -f "$explicit" ] && {
		printf '%s' "$explicit"
		return 0
	}
	[ -z "$session" ] && return 0
	local candidate="$HOME/.claude/projects/${dir//\//-}/${session}.jsonl"
	[ -f "$candidate" ] && printf '%s' "$candidate"
}

# Emits deduped "TAG<TAB>value" facts. Only the bytes appended since the last
# render are scanned, so a growing multi-MB transcript stays ~1ms per turn.
# Structural extraction only — a raw-text grep also scrapes the assistant's own
# prose about these very patterns, inventing skills that were never loaded.
scan_transcript_delta() {
	local file="$1" offset="$2" known="$3"
	{
		[ -n "$known" ] && printf '%s\n' "$known"
		tail -c "+$((offset + 1))" "$file" 2>/dev/null | jq -r '
			select(.isSidechain != true) |
			(.message.content? // []) as $content |
			[
				(.attributionSkill? // empty | "SK\t" + .),
				($content | if type == "array" then .[] else empty end
					| select(.type == "tool_use" and .name == "Skill")
					| .input.skill? // empty | "SK\t" + .),
				($content | if type == "array" then .[] else empty end
					| select(.type == "tool_use") | .name? // empty
					| select(startswith("mcp__")) | "MCP\t" + (split("__")[1])),
				(select(.type == "user")
					| [$content] | flatten
					| map(if type == "object" then ((.text? // "") + ([.content] | flatten | map(.text? // (if type == "string" then . else "" end)) | join("\n"))) else tostring end)
					| join("\n")
					| capture("Base directory for this skill: (?<path>[^\n]+)")?
					| "DIR\t" + .path),
				(.toolUseResult.matches? // [] | .[]? | "TOOL\t" + .)
			] | .[]' 2>/dev/null
	} | LC_ALL=C grep -v '^$' | LC_ALL=C sort -u
}

format_tokens() {
	local tokens="${1:-0}"
	[ "$tokens" -ge 10000 ] 2>/dev/null && {
		printf '%dk' $((tokens / 1000))
		return 0
	}
	[ "$tokens" -ge 100 ] 2>/dev/null && {
		printf '%d.%dk' $((tokens / 1000)) $(((tokens % 1000) / 100))
		return 0
	}
	printf '%d' "$tokens"
}

# plugin_slack_slack -> slack; phpstorm, grep_app, smartbear pass through
normalize_mcp_server() {
	local server="${1#plugin_}"
	[ "$server" = "$1" ] && {
		printf '%s' "$1"
		return 0
	}
	printf '%s' "${server#*_}"
}

# Single bash pass over the (already deduped) fact list — awk would cost more in
# process spawns than it saves on a dozen lines
render_context_load() {
	local facts="$1" tag value server bytes rendered=""
	local skills=0 tools=0 server_count=0 seen_servers=" " skill_bytes=0 skill_files=()
	while IFS="$TAB" read -r tag value; do
		case "$tag" in
		SK) skills=$((skills + 1)) ;;
		TOOL) tools=$((tools + 1)) ;;
		MCP)
			server=$(normalize_mcp_server "$value")
			case "$seen_servers" in
			*" $server "*) ;;
			*)
				seen_servers="${seen_servers}${server} "
				server_count=$((server_count + 1))
				;;
			esac
			;;
		DIR) [ -f "$value/SKILL.md" ] && skill_files+=("$value/SKILL.md") ;;
		esac
	done <<<"$facts"

	# One stat for every loaded skill rather than one per skill
	[ "${#skill_files[@]}" -gt 0 ] && while IFS= read -r bytes; do
		skill_bytes=$((skill_bytes + bytes))
	done <<<"$(stat_values '%z' '%s' "${skill_files[@]}")"

	local dot
	dot="$(dim_of "$LIGHT_GREY")·${LIGHT_GREY}"
	[ "$skills" -gt 0 ] && {
		rendered="sk:${skills}"
		[ "$skill_bytes" -gt 0 ] && rendered="${rendered}${dot}$(format_tokens $((skill_bytes / BYTES_PER_TOKEN)))"
	}
	{ [ "$tools" -gt 0 ] || [ "$server_count" -gt 0 ]; } && {
		rendered="${rendered:+${rendered} }mcp:${server_count}(${tools})"
		[ "$tools" -gt 0 ] && rendered="${rendered}${dot}$(format_tokens $((tools * MCP_TOKENS_PER_TOOL)))"
	}
	[ -z "$rendered" ] && return 0
	printf '%s%s%s' "$LIGHT_GREY" "$rendered" "$RESET"
}

session_segment() {
	local session="$1"
	[ -z "$session" ] && return 0
	printf '%s%s%s' "$DIM_GREY" "$session" "$RESET"
}

context_load_segment() {
	local file="$1" size="$2"
	[ -f "$file" ] || return 0
	local cache offset=0 known=""
	cache="${TMPDIR:-/tmp}/claude-ctxload-v3-${USER}-${file##*/}.txt"
	[ "${size:-0}" -eq 0 ] 2>/dev/null && return 0
	[ -f "$cache" ] && {
		read -r offset <"$cache"
		known=$(read_cache_facts "$cache")
		[ "${offset:-0}" -gt "$size" ] 2>/dev/null && {
			offset=0
			known=""
		}
	}
	[ "$size" -gt "${offset:-0}" ] 2>/dev/null && {
		known=$(scan_transcript_delta "$file" "${offset:-0}" "$known")
		{
			printf '%s\n' "$size"
			printf '%s\n' "$known"
		} >"${cache}.tmp" && mv "${cache}.tmp" "$cache"
	}
	render_context_load "$known"
}

# "(1M context)" in the display name wins over the raw window size
window_label() {
	local model_raw="$1" size="$2"
	[[ "$model_raw" =~ \(([0-9]+)[[:space:]]*([kKmM]) ]] && {
		case "${BASH_REMATCH[2]}" in
		k | K) printf ' %sK' "${BASH_REMATCH[1]}" ;;
		*) printf ' %sM' "${BASH_REMATCH[1]}" ;;
		esac
		return 0
	}
	[ -z "$size" ] && return 0
	[ "$size" -ge 1000000 ] 2>/dev/null && {
		printf ' %dM' $((size / 1000000))
		return 0
	}
	[ "$size" -ge 1000 ] 2>/dev/null && printf ' %dk' $((size / 1000))
}

model_segment() {
	local model_raw="$1" size="$2" effort="$3" style="$4"
	[ -z "$model_raw" ] && return 0
	local name effort_label="" fast_label=""
	name="${model_raw%% (*}"
	[ -n "$effort" ] && [ "$effort" != "default" ] &&
		effort_label=" $(printf '%s' "$effort" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
	[ "$style" = "fast" ] && fast_label=" Fast"
	printf '%s[%s%s%s%s]%s' "$GREEN" "$name" "$(window_label "$model_raw" "$size")" "$effort_label" "$fast_label" "$RESET"
}

context_segment() {
	local tokens="$1" pct="$2"
	[ -z "$tokens" ] || [ "$tokens" -le 0 ] 2>/dev/null && return 0
	local thousands color
	thousands=$(awk -v t="$tokens" 'BEGIN{k=int((t+500)/1000); if(k==0) k=1; printf "%d", k}')
	color=$(context_color "$tokens")
	[ -z "$pct" ] && {
		printf '%s%dk%s' "$color" "$thousands" "$RESET"
		return 0
	}
	printf '%s%dk%s·%s%d%%%s' "$color" "$thousands" "$(dim_of "$color")" "$color" "${pct%%.*}" "$RESET"
}

window_segment() {
	local label="$1" pct="$2" resets_at="$3" severity="$4"
	[ -z "$pct" ] && return 0
	local color left
	color=$(quota_color "$pct" "$severity")
	left=$(format_duration "$(remaining_minutes "$resets_at")")
	[ -n "$left" ] && {
		printf '%s%s:%d%%%s·%s%s%s' "$color" "$label" "$pct" "$(dim_of "$color")" "$color" "$left" "$RESET"
		return 0
	}
	printf '%s%s:%d%%%s' "$color" "$label" "$pct" "$RESET"
}

scoped_segment() {
	[ -z "$1" ] && return 0
	printf '%s%s%s' "$GREY" "$1" "$RESET"
}

spend_segment() {
	local used="$1" limit="$2" exponent="$3" currency="$4" severity="$5"
	[ -z "$limit" ] || [ "$limit" -le 0 ] 2>/dev/null && return 0
	local divisor
	divisor=$(awk -v e="${exponent:-2}" 'BEGIN{printf "%d", 10^e}')
	printf '%s%s%d/%d%s' "$(severity_color "$severity")" "$(currency_symbol "$currency")" \
		$((used / divisor)) $((limit / divisor)) "$RESET"
}

# Reference figure — fixed color, never recolored by usage
session_cost_segment() {
	local cost="$1"
	[ -z "$cost" ] && return 0
	printf '%s$%.2f%s' "$GREEN" "$cost" "$RESET"
}

# --- Orchestration -----------------------------------------------------------

IFS= read -r -d '' input || true

settings_file="$HOME/.claude/settings.json"
[ -f "$settings_file" ] || settings_file=/dev/null

IFS="$FS" read -r cwd project_dir transcript_path session_id model_raw used_tokens used_pct ctx_size output_style effort session_cost <<<"$(
	printf '%s' "$input" | jq -r --arg sep "$FS" --slurpfile settings "$settings_file" '[
		(.cwd // .workspace.current_dir // ""),
		(.workspace.project_dir // .cwd // ""),
		(.transcript_path // ""),
		(.session_id // ""),
		(.model.display_name // ""),
		(.context_window.used_tokens // ""),
		(.context_window.used_percentage // ""),
		(.context_window.context_window_size // ""),
		(.output_style.name // "default"),
		(.effortLevel // $settings[0].effortLevel // ""),
		(.cost.total_cost_usd // "")
	] | map(tostring) | join($sep)'
)"

[ -z "$used_tokens" ] && [ -n "$used_pct" ] && [ -n "$ctx_size" ] &&
	used_tokens=$(awk -v p="$used_pct" -v s="$ctx_size" 'BEGIN{printf "%d", p*s/100}')
[ -z "$used_pct" ] && [ -n "$used_tokens" ] && [ -n "$ctx_size" ] &&
	used_pct=$(awk -v t="$used_tokens" -v s="$ctx_size" 'BEGIN{printf "%d", (t/s)*100}')

project_root="${project_dir:-$cwd}"
cwd_repo=$(repo_root_of "$cwd")

# One pass over every HEAD: builds the cache-invalidation signature and the
# scan set (cwd repo + off-trunk subrepos) without spawning a single git
git_signature=""
scan_targets=()
[ -n "$cwd_repo" ] && {
	read_branch "$cwd_repo"
	git_signature="${cwd_repo}=${BRANCH};"
	scan_targets+=("$cwd_repo")
}
while read -r registry_repo; do
	registry_path="$project_root/$registry_repo"
	read_branch "$registry_path"
	registry_branch="$BRANCH"
	[ -z "$registry_branch" ] && continue
	git_signature="${git_signature}${registry_repo}=${registry_branch};"
	is_trunk_branch "$registry_branch" && continue
	[ "$registry_path" = "$cwd_repo" ] && continue
	scan_targets+=("$registry_path")
done <<<"$(subrepo_registry "$project_root")"

# --- Rendered-line cache ------------------------------------------------------
# Every fast-moving input is in this fingerprint; the slow ones (working-tree
# dirt, quota) are already TTL-cached, so a hit is never staler than those TTLs
# already allow. Both TTLs must still be live, otherwise a hit would keep
# serving a line whose caches were due for a refresh.
transcript=$(transcript_file "$transcript_path" "$session_id" "$project_root")
dirty_cache=$(dirty_cache_path "$project_root")
DIRTY_CACHE_MTIME=$(file_mtime "$dirty_cache")
USAGE_CACHE_MTIME=$(file_mtime "$USAGE_CACHE")
transcript_size=0
[ -n "$transcript" ] && transcript_size=$(stat_values '%z' '%s' "$transcript")

line_cache="${TMPDIR:-/tmp}/claude-statusline-line-${USER}-${session_id:-none}.txt"
fingerprint="${cwd}|${used_tokens}|${used_pct}|${model_raw}|${effort}|${output_style}|${session_cost}|${transcript_size:-0}|${DIRTY_CACHE_MTIME}|${USAGE_CACHE_MTIME}|${git_signature}"

usage_cache_is_fresh &&
	[ $((NOW - DIRTY_CACHE_MTIME)) -lt "$DIRTY_TTL" ] 2>/dev/null &&
	[ -f "$line_cache" ] && {
	read -r cached_fingerprint <"$line_cache"
	[ "$cached_fingerprint" = "$fingerprint" ] && {
		IFS= read -r -d '' cached_line <"$line_cache" || true
		printf '%s' "${cached_line#*$'\n'}"
		exit 0
	}
}

dirty_counts=""
[ "${#scan_targets[@]}" -gt 0 ] &&
	dirty_counts=$(dirty_table "$project_root" "$git_signature" "${scan_targets[@]}")

refresh_usage_cache
IFS="$FS" read -r block_pct block_reset block_severity \
	week_pct week_reset week_severity scoped \
	spend_used spend_limit spend_exponent spend_currency spend_severity <<<"$(read_quota_fields)"

line1=$(join_segments \
	"$(dir_segment "$cwd")" \
	"$(cd_segment "$cwd_repo" "$dirty_counts")" \
	"$(sd_segment "$project_root" "$dirty_counts")" \
	"$(model_segment "$model_raw" "$ctx_size" "$effort" "$output_style")" \
	"$(context_segment "$used_tokens" "$used_pct")")

line2=$(join_segments \
	"$(context_load_segment "$transcript" "$transcript_size")" \
	"$(window_segment "5h" "$block_pct" "$block_reset" "$block_severity")" \
	"$(window_segment "wk" "$week_pct" "$week_reset" "$week_severity")" \
	"$(scoped_segment "$scoped")" \
	"$(spend_segment "$spend_used" "$spend_limit" "$spend_exponent" "$spend_currency" "$spend_severity")" \
	"$(session_cost_segment "$session_cost")" \
	"$(session_segment "$session_id")")

rendered=$(printf '%b' "$line1")
[ -n "$line2" ] && rendered="${rendered}"$'\n'"$(printf '%b' "$line2")"

{
	printf '%s\n' "$fingerprint"
	printf '%s' "$rendered"
} >"${line_cache}.tmp" && mv "${line_cache}.tmp" "$line_cache"

printf '%s' "$rendered"

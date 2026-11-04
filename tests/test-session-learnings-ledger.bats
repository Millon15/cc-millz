#!/usr/bin/env bats
#
# tests/test-session-learnings-ledger.bats: status derivation, score, review events, TTL and the
# link gate in the merger. Real merger and ledger, no model.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	SCRIPTS="${REPO_ROOT}/plugins/session-learnings/scripts"
	FIX="${REPO_ROOT}/tests/fixtures/session-learnings/candidates"
	STORE="$TMP/store"
	cp "$FIX/valid.json" "$TMP/input.json"
	cp "$FIX/digest.jsonl" "$TMP/digest.jsonl"
}

teardown() { teardown_tmp; }

merge() {
	"$SCRIPTS/sl-merge.sh" --store="$STORE" --session="$1" --project=project-a --digest="$TMP/digest.jsonl" \
		${2:+--links="$2"} <"$TMP/input.json"
}
ledger() { "$SCRIPTS/sl-ledger.sh" "$1" --store="$STORE" "${@:2}"; }
card_id() { ledger list | jq -r "select(.trigger == \"$1\") | .id"; }
first_id() { ledger list | head -n 1 | jq -r .id; }
view() { ledger list | jq -c "select(.id == \"$1\")"; }
cards_in() { find "$STORE" -path "*/$1/lsn-*.md" | wc -l | tr -d ' '; }

# Shifts every event of the ledger back by $1 days, so one run can stand for several days.
age_ledger() {
	jq -c --argjson d "$1" '.ts |= ((sub("\\.[0-9]+Z$"; "Z") | fromdate) - $d * 86400 | todate)' \
		"$STORE/ledger.jsonl" >"$TMP/aged" && mv "$TMP/aged" "$STORE/ledger.jsonl"
}

two_day_candidate() {
	merge s1
	age_ledger 1
	merge s2
}

@test "list on a store without a ledger prints nothing and exits 0" {
	run ledger list
	assert_status 0
	[ -z "$output" ]
}

@test "sightings on two days make a candidate in candidates/ with its score" {
	two_day_candidate
	id="$(first_id)"
	[ "$(view "$id" | jq -r .status)" = candidate ]
	[ "$(view "$id" | jq -r .score)" = 2.5 ]
	[ "$(cards_in candidates)" = 1 ]
	[ "$(cards_in drafts)" = 0 ]
}

@test "one day of sightings stays a draft however many sessions" {
	merge s1
	merge s2
	merge s3
	[ "$(view "$(first_id)" | jq -r .status)" = draft ]
}

@test "promoted moves the card to stable/ with skill and path; rejected moves it to archive/" {
	two_day_candidate
	id="$(first_id)"
	ledger event --type=promoted --id="$id" --skill=learned-modules --path=/repo/.claude/skills/learned-modules/SKILL.md
	[ "$(view "$id" | jq -r '.status + " " + .skill')" = "stable learned-modules" ]
	[ "$(cards_in stable)" = 1 ]
	ledger event --type=rejected --id="$id" --note="wrong root cause"
	[ "$(view "$id" | jq -r .status)" = rejected ]
	[ "$(cards_in archive)" = 1 ]
	[ "$(cards_in stable)" = 0 ]
}

@test "two failed applications demote a candidate back to draft" {
	two_day_candidate
	id="$(first_id)"
	printf '%s\n' "{\"type\":\"applied_fail\",\"id\":\"$id\",\"session\":\"a\"}" \
		"{\"type\":\"applied_fail\",\"id\":\"$id\",\"session\":\"b\"}" | ledger events
	[ "$(view "$id" | jq -r '.status + " " + (.score|tostring)')" = "draft -0.5" ]
	[ "$(cards_in drafts)" = 1 ]
}

@test "an application is counted once per session" {
	merge s1
	id="$(first_id)"
	ledger event --type=applied_ok --id="$id" --session=x
	ledger event --type=applied_ok --id="$id" --session=x
	[ "$(view "$id" | jq .counts.applied_ok)" = 1 ]
}

@test "invalid events exit 2 and write nothing; a batch is all or nothing" {
	merge s1
	id="$(first_id)"
	before="$(shasum "$STORE/ledger.jsonl")"
	run ledger event --type=promoted --id="$id"
	assert_status 2
	run ledger event --type=bogus --id="$id"
	assert_status 2
	run ledger event --type=rejected --id="lsn-$(printf '0%.0s' {1..64})"
	assert_status 2
	run ledger events <<<"{\"type\":\"applied\",\"id\":\"$id\",\"session\":\"ok\"}
{\"type\":\"applied\",\"id\":\"$id\"}"
	assert_status 2
	[ "$(shasum "$STORE/ledger.jsonl")" = "$before" ]
}

@test "events on stdin cannot backdate themselves" {
	merge s1
	id="$(first_id)"
	ledger events <<<"{\"type\":\"applied\",\"id\":\"$id\",\"session\":\"x\",\"ts\":\"2001-01-01T00:00:00Z\"}"
	[ "$(tail -n 1 "$STORE/ledger.jsonl" | jq -r '.ts[:4]')" != 2001 ]
}

@test "maintain expires a draft idle past 90 days into archive/; a new sighting revives it" {
	merge s1
	id="$(first_id)"
	ledger maintain --now="$(date -u -v+89d +%Y-%m-%dT%H:%M:%SZ)"
	[ "$(view "$id" | jq -r .status)" = draft ]
	ledger maintain --now="$(date -u -v+92d +%Y-%m-%dT%H:%M:%SZ)"
	[ "$(view "$id" | jq -r .status)" = expired ]
	[ "$(cards_in archive)" = 1 ]
	merge s2
	[ "$(view "$id" | jq -r .status)" = draft ]
	[ "$(cards_in archive)" = 0 ]
}

@test "maintain flags a stable card stale after 60 unused days; usage or an application clears it" {
	two_day_candidate
	id="$(first_id)"
	ledger event --type=promoted --id="$id" --skill=learned-modules --path=/x/SKILL.md
	recent="$(($(date +%s) * 1000 + 50 * 86400000))"
	echo "{\"skill\":\"learned-modules\",\"usageCount\":3,\"lastUsedAt\":$recent}" >"$TMP/usage.jsonl"
	ledger maintain --now="$(date -u -v+62d +%Y-%m-%dT%H:%M:%SZ)" --usage="$TMP/usage.jsonl"
	[ "$(view "$id" | jq -c .flags)" = '[]' ]
	ledger maintain --now="$(date -u -v+62d +%Y-%m-%dT%H:%M:%SZ)"
	[ "$(view "$id" | jq -c .flags)" = '["stale"]' ]
	[ "$(view "$id" | jq -r .status)" = stable ]
	ledger event --type=applied --id="$id" --session=later
	[ "$(view "$id" | jq -c .flags)" = '[]' ]
}

@test "list --project returns that project's cards and every global card" {
	merge s1
	jq '.lessons[0].scope = "global"' "$FIX/valid.json" >"$TMP/input.json"
	merge s1
	"$SCRIPTS/sl-merge.sh" --store="$STORE" --session=s9 --project=project-b --digest="$TMP/digest.jsonl" <"$FIX/valid.json"
	[ "$(ledger list | wc -l | tr -d ' ')" = 3 ]
	[ "$(ledger list --project=project-a | jq -r '.scope + ":" + (.project // "-")' | sort | tr '\n' ' ')" = "global:- project:project-a " ]
	[ "$(ledger list --status=draft --scope=global | wc -l | tr -d ' ')" = 1 ]
}

@test "a same link confirms the target and writes no new card" {
	merge s1
	target="$(first_id)"
	jq '.lessons[0].claim = "Always generate the modules before the package tests."' "$FIX/valid.json" >"$TMP/input.json"
	echo "{\"links\":[{\"index\":0,\"relation\":\"same\",\"target\":\"$target\",\"similarity\":0.7,\"by\":\"judge\"}]}" >"$TMP/links.json"
	merge s2 "$TMP/links.json"
	[ "$(ledger list | wc -l | tr -d ' ')" = 1 ]
	[ "$(view "$target" | jq .counts.sessions)" = 2 ]
}

@test "a refines link confirms the target and keeps the new claim as a proposed revision" {
	merge s1
	target="$(first_id)"
	jq '.lessons[0].claim = "Run make generate before the package tests."' "$FIX/valid.json" >"$TMP/input.json"
	echo "{\"links\":[{\"index\":0,\"relation\":\"refines\",\"target\":\"$target\",\"similarity\":0.5,\"by\":\"judge\"}]}" >"$TMP/links.json"
	merge s2 "$TMP/links.json"
	card="$(find "$STORE" -name "$target.md")"
	[ "$(sed '1d;/^---$/,$d' "$card" | jq -r '.revisions[0].claim')" = "Run make generate before the package tests." ]
}

@test "a contradicts link writes the new card and flags both" {
	merge s1
	target="$(first_id)"
	jq '.lessons[0].claim = "Never generate the modules before the package tests."' "$FIX/valid.json" >"$TMP/input.json"
	echo "{\"links\":[{\"index\":0,\"relation\":\"contradicts\",\"target\":\"$target\",\"similarity\":0.8,\"by\":\"judge\"}]}" >"$TMP/links.json"
	merge s2 "$TMP/links.json"
	[ "$(ledger list | jq -c .flags | sort -u)" = '["contradiction"]' ]
	[ "$(ledger list | wc -l | tr -d ' ')" = 2 ]
}

@test "a quarantined lesson ignores its link and leaves the target untouched" {
	merge s1
	target="$(first_id)"
	jq '.lessons[0].evidence_line = 5 | .lessons[0].claim = "Read says generate."' "$FIX/valid.json" >"$TMP/input.json"
	echo "{\"links\":[{\"index\":0,\"relation\":\"same\",\"target\":\"$target\",\"similarity\":1,\"by\":\"exact\"}]}" >"$TMP/links.json"
	merge s2 "$TMP/links.json"
	[ "$(view "$target" | jq .counts.sessions)" = 1 ]
	[ "$(cards_in quarantine)" = 1 ]
}

@test "a malformed links file or a link to an unknown card never fails the merge" {
	echo 'not json' >"$TMP/links.json"
	run merge s1 "$TMP/links.json"
	assert_status 0
	echo "{\"links\":[{\"index\":0,\"relation\":\"same\",\"target\":\"lsn-$(printf 'a%.0s' {1..64})\"}]}" >"$TMP/links.json"
	run merge s2 "$TMP/links.json"
	assert_status 0
	[ "$(view "$(first_id)" | jq .counts.sessions)" = 2 ]
}

@test "fresh skill usage clears a stale flag at the next maintain" {
	two_day_candidate
	id="$(first_id)"
	ledger event --type=promoted --id="$id" --skill=learned-modules --path=/x/SKILL.md
	at="$(date -u -v+62d +%Y-%m-%dT%H:%M:%SZ)"
	ledger maintain --now="$at"
	[ "$(view "$id" | jq -c .flags)" = '["stale"]' ]
	echo "{\"skill\":\"learned-modules\",\"usageCount\":4,\"lastUsedAt\":$(($(date +%s) * 1000 + 61 * 86400000))}" >"$TMP/usage.jsonl"
	ledger maintain --now="$at" --usage="$TMP/usage.jsonl"
	[ "$(view "$id" | jq -c .flags)" = '[]' ]
	ledger maintain --now="$at" --usage="$TMP/usage.jsonl"
	[ "$(jq -s '[.[] | select(.event == "used")] | length' "$STORE/ledger.jsonl")" = 1 ]
}

@test "an idle quarantine card expires once into archive/ and stays expired" {
	jq '.lessons[0].evidence_line = 5' "$FIX/valid.json" >"$TMP/input.json"
	merge s1
	id="$(first_id)"
	at="$(date -u -v+92d +%Y-%m-%dT%H:%M:%SZ)"
	ledger maintain --now="$at"
	ledger maintain --now="$at"
	[ "$(view "$id" | jq -r .status)" = expired ]
	[ "$(jq -s '[.[] | select(.event == "expired")] | length' "$STORE/ledger.jsonl")" = 1 ]
	[ "$(cards_in archive)" = 1 ]
	[ "$(cards_in quarantine)" = 0 ]
}

@test "replaying a decision restores a card lost after the event was saved" {
	two_day_candidate
	id="$(first_id)"
	ledger event --type=promoted --id="$id" --skill=learned-modules --path=/x/SKILL.md
	card="$(find "$STORE" -name "$id.md")"
	rm "$card"
	ledger event --type=promoted --id="$id" --skill=learned-modules --path=/x/SKILL.md
	[ -f "$card" ]
	[ "$(jq -s '[.[] | select(.event == "promoted")] | length' "$STORE/ledger.jsonl")" = 1 ]
}

# tests/helpers/short-video-fixtures.bash — fixture BUILDERS for the video suites.
#
# Source it AFTER common.bash, from a suite's setup():
#
#     setup() {
#         REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
#         source "${REPO_ROOT}/tests/helpers/common.bash"
#         source "${REPO_ROOT}/tests/helpers/short-video-fixtures.bash"
#         setup_tmp
#         svr_home                    # UNSUBSTITUTED — see below
#         seed_base_utils
#         seed_toolchain_stubs
#         PATH="${STUB_BIN}"          # the stub dir ALONE, never prepended
#     }
#
# `svr_home` is called plainly, never as `$(svr_home)`: a command substitution
# runs in a subshell, so the export would die with it and the suite would go on
# walking up through the executor's real home directory. The builders are the
# ones invoked through $(...), because what a case needs back from them is a
# path — so they REFUSE to build until HOME is already redirected, rather than
# redirecting into a subshell nobody will see.
#
# Two rules run through every function here, and both exist because the reader
# resolves its scratch directory by WALKING UP from the current directory.
#
#   1. Nothing is committed as a directory SHAPE. Git tracks files, so a
#      committed `bare/` or `profile/nested/deeper/` simply would not exist in a
#      fresh checkout and its case would error there while passing locally. The
#      fixture ships FILES under tests/fixtures/short-video-reader/ and these
#      builders assemble the trees at setup time.
#
#   2. Every tree is built under a REDIRECTED HOME at $TMP/home. A tree built
#      inside this repository would let the repository's own configuration
#      answer for the rung under test, and a tree outside any HOME would walk up
#      through whatever the executor happens to keep in their home directory.
#      Under $TMP/home the walk halts at a directory this file created, so the
#      $HOME halt is exercised rather than assumed — and every builder asserts
#      that no ancestor of what it just built carries a profile, so a stray
#      profile on someone's machine fails the suite loudly instead of quietly
#      deciding a rung.
#
# No builder writes anywhere under tests/fixtures/: the committed files are
# copied OUT of it, never edited in place, so a full suite run leaves the
# repository clean.
#
# Requires common.bash for $TMP, $STUB_BIN, `stub`/`unstub` and make_git_repo.

SVR_FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/short-video-reader" && pwd)"

# The profile file the reader walks up looking for, and the magic marker that
# proves a run directory belongs to it. Named once, here, so a suite asserting
# either never spells it out a second time.
SVR_PROFILE_NAME=".short-video-reader.json"
SVR_RUN_MARKER=".short-video-reader-run"

# The POSIX utilities the reader legitimately shells out to. `bash` is on the
# list because the stubs carry a `#!/usr/bin/env bash` shebang and env resolves
# that name through PATH — with the stub directory alone on PATH, an unlinked
# bash makes every stub unrunnable. The list is deliberately EXHAUSTIVE for the
# reader: anything missing from it is absent by construction, which is the whole
# mechanism behind the missing-dependency cases.
# `chmod` is on it for this file's own sake rather than the reader's: the stub
# bodies are installed by seed_toolchain_stubs, which a case may re-run after an
# `unstub` — with PATH already replaced, an unlinked chmod leaves the re-seeded
# stub non-executable and every later invocation exits 126 instead of running.
SVR_BASE_UTILS=(
	bash jq
	awk basename cat chmod cp cut date dirname find grep mkdir mktemp mv rm sed tr wc
)

# The toolchain the reader probes for. jq is NOT here and never will be: the
# reader writes its report with `jq -n` and assert_explain_source shells out to
# jq itself, so a stub that exits 0 empties the report and turns every explain
# assertion into "not valid JSON".
SVR_TOOLCHAIN=(yt-dlp ffmpeg ffprobe whisper-cli)

# ------------------------------------------------------------ the redirected --

# svr_home — creates $TMP/home and exports it as HOME. Idempotent, prints
# nothing, and MUST be called unsubstituted from setup().
svr_home() {
	[ -n "${TMP:-}" ] || {
		printf 'svr_home: $TMP is unset — call setup_tmp first\n' >&2
		return 1
	}
	HOME="${TMP}/home"
	mkdir -p "${HOME}"
	export HOME
}

# ------------------------------------------------------------ the invocation --

# svr_run <script> <args...> — run the reader with PATH set to the stub
# directory ALONE, never prepended.
#
# The replacement is applied to the INVOCATION rather than to the suite's own
# shell, and that is not a softening of it: the code under test is what has to be
# hermetic, and a tool seed_base_utils did not link is absent from this command
# whatever the suite's shell can still see. Replacing the suite's PATH instead
# breaks bats itself — its per-test cleanup runs after teardown, outside any
# restore a suite can make, and by then teardown_tmp has deleted the very
# directory that PATH points at, so `rm` no longer resolves and a green suite
# exits 1.
svr_run() {
	[ -n "${STUB_BIN:-}" ] || {
		printf 'svr_run: $STUB_BIN is unset — call setup_tmp first\n' >&2
		return 1
	}
	run env PATH="${STUB_BIN}" "$@"
}

# ------------------------------------------------------------- assertions --

# svr_phys <dir> — the PHYSICAL path of a directory. Every fixture root here is
# handed out as a path under $TMP, and on macOS mktemp -d hands back a symlinked
# one (/var/... for /private/var/...). The reader resolves its anchors with
# `pwd -P`, so an expectation built from the fixture path alone compares two
# spellings of the same directory and fails on a difference that is not one.
svr_phys() {
	(cd "$1" && pwd -P)
}

# svr_assert_workdir <json> <expected-absolute> — the half of a rung assertion
# that assert_explain_source cannot make.
#
# The source word alone is not acceptance for any rung: a relative profile
# workdir resolved against $PWD instead of against the profile's own directory
# reports `profile` while writing into whatever directory the caller happened to
# be standing in — the right word over the wrong path.
svr_assert_workdir() {
	local json="$1" expected="$2" actual
	actual="$(printf '%s' "${json}" | jq -r '.values.workdir')" || {
		printf 'svr_assert_workdir: not valid JSON:\n%s\n' "${json}" >&2
		return 1
	}
	if [ "${actual}" != "${expected}" ]; then
		printf 'svr_assert_workdir: workdir is %s, expected %s\n' "${actual}" "${expected}" >&2
		return 1
	fi
}

# svr_require_home — the precondition every builder asserts. It is louder than
# it looks: a suite that forgot svr_home builds a perfectly correct tree whose
# ancestors are the executor's real home directory, and the rung under test is
# then decided by whatever that operator keeps there.
svr_require_home() {
	[ -n "${TMP:-}" ] || {
		printf 'svr_require_home: $TMP is unset — call setup_tmp first\n' >&2
		return 1
	}
	if [ "${HOME:-}" != "${TMP}/home" ]; then
		printf 'svr_require_home: HOME is %s, not %s/home — call svr_home in setup(), and call it plainly: inside $(...) the export dies with the subshell\n' \
			"${HOME:-<unset>}" "${TMP}" >&2
		return 1
	fi
}

# svr_assert_no_profile_above <dir> — walks from <dir>'s PARENT up to $HOME
# inclusive and fails if any of them carries a profile file. The parent, not the
# directory itself: a profile fixture's own profile is the point of it.
svr_assert_no_profile_above() {
	local dir="$1" cur home_p
	cur="$(cd "${dir}" 2>/dev/null && pwd -P)" || {
		printf 'svr_assert_no_profile_above: not a directory: %s\n' "${dir}" >&2
		return 1
	}
	home_p="$(cd "${HOME}" 2>/dev/null && pwd -P)" || {
		printf 'svr_assert_no_profile_above: HOME is not a directory: %s\n' "${HOME}" >&2
		return 1
	}

	cur="$(dirname "${cur}")"
	while :; do
		if [ -e "${cur}/${SVR_PROFILE_NAME}" ]; then
			printf 'svr_assert_no_profile_above: a stray %s sits at %s, above the fixture %s — it would decide the rung under test\n' \
				"${SVR_PROFILE_NAME}" "${cur}" "${dir}" >&2
			return 1
		fi
		[ "${cur}" = "${home_p}" ] && break
		[ "${cur}" = "/" ] && break
		cur="$(dirname "${cur}")"
	done
}

# ------------------------------------------------------------------ builders --

# write_profile <dir> <json> — plants a profile carrying <json> and re-runs the
# ancestor guard. For the cases that need contents the committed template does
# not carry; the template itself goes in through make_profile_fixture.
write_profile() {
	local dir="$1" json="$2"
	mkdir -p "${dir}"
	printf '%s\n' "${json}" >"${dir}/${SVR_PROFILE_NAME}"
	svr_assert_no_profile_above "${dir}" || return 1
	printf '%s\n' "${dir}/${SVR_PROFILE_NAME}"
}

# make_profile_fixture [name] — the `profile` rung, and the walk-up with it.
#
#   <root>/.short-video-reader.json    the committed template, workdir RELATIVE
#   <root>/nested/deeper/              somewhere to stand two levels down
#
# The workdir is relative on purpose: it is what makes the relative-anchor case
# possible, where the same fixture is driven from <root> and from nested/deeper/
# and must resolve to ONE absolute path.
make_profile_fixture() {
	local root
	svr_require_home || return 1
	root="${HOME}/${1:-profile-fixture}"
	mkdir -p "${root}/nested/deeper"
	cp "${SVR_FIXTURES}/profile.json" "${root}/${SVR_PROFILE_NAME}"
	svr_assert_no_profile_above "${root}" || return 1
	printf '%s\n' "${root}"
}

# make_nested_git_fixture [name] — the same tree with an initialised repository
# planted BETWEEN the profile and the nested directory:
#
#   <root>/.short-video-reader.json
#   <root>/nested/.git/                a toplevel the walk-up must pass THROUGH
#   <root>/nested/deeper/
#
# This is the shape of a monorepo whose sub-directories are independent
# repositories, and it is the case a walk-up that stops at a repository boundary
# fails: it would halt at <root>/nested, find no profile and fall to the last
# rung while a profile sits one directory above.
make_nested_git_fixture() {
	local root
	root="$(make_profile_fixture "${1:-nested-git-fixture}")" || return 1
	make_git_repo "${root}/nested"
	printf '%s\n' "${root}"
}

# make_bare_fixture [name] — the `default` rung: a directory with no profile
# anywhere above it, up to the redirected HOME.
make_bare_fixture() {
	local root
	svr_require_home || return 1
	root="${HOME}/${1:-bare-fixture}"
	mkdir -p "${root}"
	[ -e "${root}/${SVR_PROFILE_NAME}" ] && {
		printf 'make_bare_fixture: %s already carries a profile\n' "${root}" >&2
		return 1
	}
	svr_assert_no_profile_above "${root}" || return 1
	printf '%s\n' "${root}"
}

# make_malformed_fixture [name] — a directory whose profile is not parseable, so
# an unreadable profile can be proven to be a usage error rather than a silent
# fall-through to the next rung.
make_malformed_fixture() {
	local root
	svr_require_home || return 1
	root="${HOME}/${1:-malformed-fixture}"
	mkdir -p "${root}"
	cp "${SVR_FIXTURES}/malformed.json" "${root}/${SVR_PROFILE_NAME}"
	svr_assert_no_profile_above "${root}" || return 1
	printf '%s\n' "${root}"
}

# make_whisper_home — seeds the redirected HOME with a GGML model at one of the
# known paths the model scan reads, and prints the model's path.
#
# It exists for one case: proving that an inspection-only invocation writes
# NOTHING. The model cache is only written when a whisper binary AND a model are
# both found, so without this seeding that case is green against the unfixed
# reader on any machine with no dictation app installed — it would assert the
# absence of a write down a branch that never ran.
make_whisper_home() {
	local dir
	svr_require_home || return 1
	dir="${HOME}/Library/Application Support/whisper"
	mkdir -p "${dir}"
	printf 'short-video-reader fixture — not a real GGML model\n' >"${dir}/ggml-base.bin"
	printf '%s\n' "${dir}/ggml-base.bin"
}

# make_foreign_dir <base> [name] — a directory INSIDE a resolved base that this
# tool never created: somebody else's output, carrying an unrelated report.json
# and no ownership marker.
#
# It is the guard's hardest case in both directions. As a delete target it must
# be REFUSED even though it sits under the base, and as a run target it must be
# refused rather than adopted by planting a marker into it.
make_foreign_dir() {
	local base="${1:?usage: make_foreign_dir <base> [name]}" dir
	dir="${base}/${2:-foreign-run}"
	mkdir -p "${dir}"
	cat >"${dir}/report.json" <<'JSON'
{
  "numTotalTestSuites": 2,
  "numPassedTests": 7,
  "success": true,
  "startTime": 0
}
JSON
	[ -e "${dir}/${SVR_RUN_MARKER}" ] && {
		printf 'make_foreign_dir: %s already carries the ownership marker\n' "${dir}" >&2
		return 1
	}
	printf '%s\n' "${dir}"
}

# ------------------------------------------------------------------- the PATH --

# seed_base_utils — links the real utilities into $STUB_BIN so a suite can set
# PATH to that directory ALONE.
#
# Replacing PATH rather than prepending to it is what makes an absent tool
# absent: with the stub directory merely in front, the executor's own ffmpeg and
# jq stay visible behind it, and a missing-dependency case would pass or fail on
# what happens to be installed on the machine running it.
#
# `unstub <name>` afterwards is how a case removes exactly one of them.
seed_base_utils() {
	[ -n "${STUB_BIN:-}" ] || {
		printf 'seed_base_utils: $STUB_BIN is unset — call setup_tmp first\n' >&2
		return 1
	}
	local u path
	for u in "${SVR_BASE_UTILS[@]}"; do
		path="$(command -v "${u}" 2>/dev/null)"
		if [ -z "${path}" ]; then
			printf 'seed_base_utils: %s is not on PATH — the hermetic PATH cannot be built without it\n' "${u}" >&2
			return 1
		fi
		ln -sf "${path}" "${STUB_BIN}/${u}"
	done
}

# seed_toolchain_stubs — installs the committed behavioural stub bodies for the
# four external tools.
#
# They write the artifacts the reader goes on to read — an info.json, a media
# file, frames, contact sheets, a stream inventory — because the reader counts
# and moves what the toolchain leaves on disk. An `exit 0` stub leaves nothing,
# every count comes back zero and the assertions pass over work that never
# happened.
seed_toolchain_stubs() {
	[ -n "${STUB_BIN:-}" ] || {
		printf 'seed_toolchain_stubs: $STUB_BIN is unset — call setup_tmp first\n' >&2
		return 1
	}
	if [ -f "${STUB_BIN}/jq" ] && [ ! -L "${STUB_BIN}/jq" ]; then
		printf 'seed_toolchain_stubs: %s/jq is a stub body — jq is never stubbed\n' "${STUB_BIN}" >&2
		return 1
	fi
	local t
	for t in "${SVR_TOOLCHAIN[@]}"; do
		cp "${SVR_FIXTURES}/stubs/${t}.bash" "${STUB_BIN}/${t}"
		chmod +x "${STUB_BIN}/${t}"
		[ -x "${STUB_BIN}/${t}" ] || {
			printf 'seed_toolchain_stubs: %s is not executable — an invocation would exit 126, which reads as a tool failure rather than a broken fixture\n' \
				"${STUB_BIN}/${t}" >&2
			return 1
		}
	done
}

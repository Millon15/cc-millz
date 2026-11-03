#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "$REPO_ROOT/tests/helpers/common.bash"
    CASE_DIR="$BATS_TEST_TMPDIR/case"
    FIXTURE="$CASE_DIR/repo"
    STUB_BIN="$CASE_DIR/bin"
    export TRASH_DIR="$CASE_DIR/trashed" TMPDIR="$CASE_DIR/snapshots"
    mkdir -p "$FIXTURE" "$STUB_BIN" "$TRASH_DIR" "$TMPDIR"
    FIXTURE=$(cd "$FIXTURE" && pwd -P)
    export PATH="$STUB_BIN:$PATH"
    cat > "$STUB_BIN/trash" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for path in "$@"; do
    printf '%s\n' "$path" >> "$TRASH_DIR/paths"
    mv "$path" "$TRASH_DIR/"
done
SH
    chmod +x "$STUB_BIN/trash"
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/.githooks" "$FIXTURE/plugins/example/skills/example"
    cp "$REPO_ROOT/scripts/apm-export.sh" "$REPO_ROOT/scripts/apm-export.ts" "$FIXTURE/scripts/"
    cp "$REPO_ROOT/.githooks/pre-commit" "$FIXTURE/.githooks/"
    cp "$REPO_ROOT/Makefile" "$FIXTURE/"
    printf 'Fixture license.\n' > "$FIXTURE/LICENSE"
    printf '%s\n' '---' 'name: example' 'description: A portable fixture.' '---' 'Initial instructions.' > "$FIXTURE/plugins/example/skills/example/SKILL.md"
    SOURCE="$FIXTURE/plugins/example/skills/example/SKILL.md"
    EXPORTED="$FIXTURE/export/example/.apm/skills/example/SKILL.md"
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" config user.name 'Hook test'
    git -C "$FIXTURE" config user.email 'hook@example.invalid'
    git -C "$FIXTURE" config commit.gpgsign false
    regenerate
    git -C "$FIXTURE" add .
    git -C "$FIXTURE" -c core.hooksPath=/dev/null commit -qm 'Fixture'
    git -C "$FIXTURE" config core.hooksPath .githooks
}

regenerate() {
    bash "$FIXTURE/scripts/apm-export.sh"
}

run_hook() {
    run git -C "$FIXTURE" hook run pre-commit
}

tree_digest() {
    bun -e '
      const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
      const hash = crypto.createHash("sha256");
      function walk(dir) {
        for (const name of fs.readdirSync(dir).sort()) {
          if (name === ".git") continue;
          const file = path.join(dir, name), stat = fs.lstatSync(file);
          hash.update(file + ":" + stat.mode + "\n");
          if (stat.isDirectory()) walk(file);
          else hash.update(fs.readFileSync(file));
        }
      }
      walk(process.argv[1]); console.log(hash.digest("hex"));
    ' "$FIXTURE"
}

save_state() {
    cp "$FIXTURE/.git/index" "$CASE_DIR/index.before"
    tree_digest > "$CASE_DIR/tree.before"
}

assert_preserved_and_cleaned() {
    cmp "$FIXTURE/.git/index" "$CASE_DIR/index.before"
    tree_digest > "$CASE_DIR/tree.after"
    cmp "$CASE_DIR/tree.before" "$CASE_DIR/tree.after"
    [ -s "$TRASH_DIR/paths" ]
    while IFS= read -r path; do [ ! -e "$path" ]; done < "$TRASH_DIR/paths"
    local snapshots
    snapshots=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)
    [ -z "$snapshots" ]
}

@test "export hook refuses staged source with regenerated but unstaged export" {
    printf '\nStaged instructions.\n' >> "$SOURCE"
    git -C "$FIXTURE" add plugins
    regenerate
    save_state
    run_hook
    assert_status 1
    assert_contains "$output" 'Export drift:'
    assert_contains "$output" 'Run scripts/apm-export.sh and commit export/.'
    assert_preserved_and_cleaned
}

@test "export hook accepts staged source and export despite newer unstaged source edits" {
    printf '\nStaged instructions.\n' >> "$SOURCE"
    regenerate
    git -C "$FIXTURE" add plugins export
    printf '\nUnstaged instructions.\n' >> "$SOURCE"
    save_state
    run_hook
    assert_status 0
    assert_contains "$output" 'APM export is current.'
    assert_preserved_and_cleaned
}

@test "export hook detects a staged source deletion" {
    trash "$SOURCE"
    git -C "$FIXTURE" add -u plugins
    save_state
    run_hook
    assert_status 1
    assert_contains "$output" 'Export drift:'
    assert_preserved_and_cleaned
}

@test "export hook runs the staged generator instead of the live generator" {
    cp "$FIXTURE/scripts/apm-export.ts" "$CASE_DIR/generator.before"
    bun -e 'const f = process.argv[1]; await Bun.write(f, (await Bun.file(f).text()).replace("format: 1, packages", "format: 2, packages"));' "$FIXTURE/scripts/apm-export.ts"
    git -C "$FIXTURE" add scripts/apm-export.ts
    cp "$CASE_DIR/generator.before" "$FIXTURE/scripts/apm-export.ts"
    run_hook
    assert_status 1
    assert_contains "$output" 'changed report.json'
}

@test "export hook detects a staged root license change" {
    printf '\nAmended license.\n' >> "$FIXTURE/LICENSE"
    git -C "$FIXTURE" add LICENSE
    run_hook
    assert_status 1
    assert_contains "$output" 'changed example/LICENSE'
}

@test "export hook chains the original local hook after snapshot cleanup and propagates its status" {
    cat > "$FIXTURE/.git/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
printf 'local hook cwd: %s\n' "$PWD"
if [ -n "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print)" ]; then exit 99; fi
exit 23
SH
    chmod +x "$FIXTURE/.git/hooks/pre-commit"
    save_state
    run_hook
    assert_status 23
    assert_contains "$output" "local hook cwd: $FIXTURE"
    assert_preserved_and_cleaned
}

@test "export hook avoids recursion when the original local hook links to the tracked hook" {
    ln -s ../../.githooks/pre-commit "$FIXTURE/.git/hooks/pre-commit"
    run_hook
    assert_status 0
}

@test "export hook honors an inherited alternate index without modifying either index" {
    cp "$FIXTURE/.git/index" "$CASE_DIR/alternate-index"
    printf '\nAlternate index instructions.\n' >> "$SOURCE"
    GIT_INDEX_FILE="$CASE_DIR/alternate-index" git -C "$FIXTURE" add plugins
    cp "$CASE_DIR/alternate-index" "$CASE_DIR/alternate.before"
    save_state
    export GIT_INDEX_FILE="$CASE_DIR/alternate-index"
    run_hook
    assert_status 1
    assert_contains "$output" 'Export drift:'
    cmp "$CASE_DIR/alternate.before" "$CASE_DIR/alternate-index"
    assert_preserved_and_cleaned
}

@test "export hook cleans a failed index checkout and propagates its status" {
    printf 'invalid index\n' > "$FIXTURE/.git/index"
    save_state
    run_hook
    assert_status 128
    assert_contains "$output" 'index'
    assert_preserved_and_cleaned
}

@test "export hook normalizes snapshot permissions under a restrictive umask" {
    run bash -c 'umask 077; git -C "$1" hook run pre-commit' -- "$FIXTURE"
    assert_status 0
}

@test "make hooks installs and confirms the tracked hook path" {
    git -C "$FIXTURE" config --unset core.hooksPath
    run make -C "$FIXTURE" hooks
    assert_status 0
    [ "$(git -C "$FIXTURE" config core.hooksPath)" = .githooks ]
    run make -C "$FIXTURE" hooks
    assert_status 0
}

@test "make hooks refuses an unknown hook path without changing it" {
    git -C "$FIXTURE" config core.hooksPath custom-hooks
    run make -C "$FIXTURE" hooks
    [ "$status" -ne 0 ]
    assert_contains "$output" "core.hooksPath is already 'custom-hooks'"
    [ "$(git -C "$FIXTURE" config core.hooksPath)" = custom-hooks ]
}

@test "make hooks propagates a failed git config write" {
    touch "$FIXTURE/.git/config.lock"
    run make -C "$FIXTURE" hooks
    [ "$status" -ne 0 ]
    assert_contains "$output" 'could not lock config file'
    assert_not_contains "$output" 'core.hooksPath = .githooks'
}

restricted_path() {
    local missing=$1 tool executable
    mkdir -p "$CASE_DIR/restricted-bin"
    for tool in bash bun trash git; do
        [ "$tool" = "$missing" ] && continue
        executable=$(command -v "$tool")
        ln -s "$executable" "$CASE_DIR/restricted-bin/$tool"
    done
}

@test "export hook refuses a missing trash command before creating a snapshot" {
    restricted_path trash
    run env PATH="$CASE_DIR/restricted-bin" bash "$FIXTURE/.githooks/pre-commit"
    assert_status 1
    assert_contains "$output" 'pre-commit: trash is required'
    [ ! -e "$TRASH_DIR/paths" ]
}

@test "make hooks refuses missing bun without installing hooks" {
    local make_bin
    make_bin=$(command -v make)
    git -C "$FIXTURE" config --unset core.hooksPath
    restricted_path bun
    run env PATH="$CASE_DIR/restricted-bin" "$make_bin" -C "$FIXTURE" hooks
    [ "$status" -ne 0 ]
    assert_contains "$output" 'bun not installed'
    run git -C "$FIXTURE" config --get core.hooksPath
    assert_status 1
}

@test "make hooks refuses missing trash without installing hooks" {
    local make_bin
    make_bin=$(command -v make)
    git -C "$FIXTURE" config --unset core.hooksPath
    restricted_path trash
    run env PATH="$CASE_DIR/restricted-bin" "$make_bin" -C "$FIXTURE" hooks
    [ "$status" -ne 0 ]
    assert_contains "$output" 'trash CLI not installed'
    run git -C "$FIXTURE" config --get core.hooksPath
    assert_status 1
}

@test "export hook does not mask export failure when cleanup also fails" {
    printf '#!/usr/bin/env bash\nexit 29\n' > "$STUB_BIN/trash"
    printf '\nStaged instructions.\n' >> "$SOURCE"
    git -C "$FIXTURE" add plugins
    run_hook
    assert_status 1
    assert_contains "$output" 'Export drift:'
    regenerate
    git -C "$FIXTURE" add export
    run_hook
    assert_status 29
}

@test "export hook works during a real partial commit" {
    printf '\nSelective instructions.\n' >> "$SOURCE"
    regenerate
    printf 'Unrelated staged content.\n' > "$FIXTURE/unrelated.txt"
    git -C "$FIXTURE" add unrelated.txt
    run git -C "$FIXTURE" commit --only -m 'Selective commit' -- plugins export
    assert_status 0
    assert_contains "$output" 'APM export is current.'
    run git -C "$FIXTURE" diff --cached --name-only
    assert_status 0
    [ "$output" = unrelated.txt ]
}

#!/usr/bin/env bats

setup() {
    REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    SCRIPT="${REPO_ROOT}/plugins/idea-config/scripts/idea-config.sh"
    PROJECT="${TMP}/project with spaces"
    mkdir -p "${PROJECT}"
    PROJECT="$(realpath "${PROJECT}")"
    cp -R "${REPO_ROOT}/tests/fixtures/idea-config/clean/." "${PROJECT}/"
    mkdir -p "${PROJECT}/.git" "${PROJECT}/nested/.git"
    stub ps 'printf "%s\n" /bin/bash /usr/bin/python3'
}

teardown() { teardown_tmp; }

@test "clean fixture reports exactly zero findings" {
    before="$(tar -cf - -C "${PROJECT}" . | shasum -a 256)"
    run bash "${SCRIPT}" doctor --root "${PROJECT}" --json
    assert_status 0
    [ "$(printf '%s' "${output}" | jq '.findings | length')" = 0 ]
    after="$(tar -cf - -C "${PROJECT}" . | shasum -a 256)"
    [ "${before}" = "${after}" ]
}

@test "broken fixture reports exactly the planted kind and file pairs" {
    cp -R "${REPO_ROOT}/tests/fixtures/idea-config/broken/." "${PROJECT}/"
    run bash "${SCRIPT}" doctor --root "${PROJECT}" --json
    assert_status 1
    actual="$(printf '%s' "${output}" | jq -c '[.findings[] | [.kind,.file]] | sort')"
    expected="$(jq -c 'sort' "${PROJECT}/expected.json")"
    [ "${actual}" = "${expected}" ]
    [ "$(printf '%s' "${output}" | jq '[.findings[] | select(.kind == "duplicate-entry") | .line]')" = '[
  6
]' ]
}

@test "nearest ancestor root is detected without rewriting any input" {
    before="$(tar -cf - -C "${PROJECT}" . | shasum -a 256)"
    mkdir -p "${TMP}/cwd"
    pushd "${PROJECT}/nested" >/dev/null
    run bash "${SCRIPT}" --explain
    popd >/dev/null
    assert_status 0
    assert_explain_complete "${output}"
    assert_explain_source "${output}" root detected:.idea-ancestor
    [ "$(printf '%s' "${output}" | jq -r '.values.root')" = "${PROJECT}" ]
    after="$(tar -cf - -C "${PROJECT}" . | shasum -a 256)"
    [ "${before}" = "${after}" ]
}

@test "profile values have profile provenance and relative backup paths use project root" {
    printf '%s\n' '{"ide":"goland","backup_dir":"snapshots"}' >"${PROJECT}/.idea-config.json"
    run bash "${SCRIPT}" --root "${PROJECT}" --explain
    assert_status 0
    assert_explain_complete "${output}"
    assert_explain_source "${output}" ide profile
    assert_explain_source "${output}" backup_dir profile
    [ "$(printf '%s' "${output}" | jq -r '.values.ide')" = goland ]
    [ "$(printf '%s' "${output}" | jq -r '.values.backup_dir')" = "${PROJECT}/snapshots" ]
    [ ! -e "${PROJECT}/snapshots" ]
}

@test "missing profile and unknown IDE preserve null and default provenance" {
    run bash "${SCRIPT}" --explain --root "${PROJECT}"
    assert_status 0
    assert_explain_source "${output}" ide default
    [ "$(printf '%s' "${output}" | jq -r '.profile_file')" = null ]
    [ "$(printf '%s' "${output}" | jq -r '.values.ide')" = unknown ]
}

@test "PHP marker is an IDE hint with a detected source" {
    printf '<project/>' >"${PROJECT}/.idea/php.xml"
    run bash "${SCRIPT}" --explain --root "${PROJECT}"
    assert_status 0
    assert_explain_source "${output}" ide detected:.idea/php.xml
    [ "$(printf '%s' "${output}" | jq -r '.values.ide')" = phpstorm ]
}

@test "TMPDIR and absent TMPDIR have different provenance" {
    run env TMPDIR="${TMP}/unused" bash "${SCRIPT}" --explain --root "${PROJECT}"
    assert_status 0
    assert_explain_source "${output}" backup_dir detected:TMPDIR
    [ ! -e "${TMP}/unused" ]
    run env -u TMPDIR bash "${SCRIPT}" --explain --root "${PROJECT}"
    assert_status 0
    assert_explain_source "${output}" backup_dir default
}

@test "no .idea is a usage error for every verb" {
    for verb in --explain doctor backup; do
        run bash "${SCRIPT}" "${verb}" --root "${TMP}/absent"
        assert_status 2
        assert_contains "${output}" 'usage:'
    done
}

@test "malformed and incorrectly typed profiles are usage errors" {
    for profile in '{' '[]' '{"ide":3}' '{"ide":[]}' '{"ide":"eclipse"}' '{"backup_dir":null}' '{"backup_dir":""}' '{"extra":true}'; do
        printf '%s' "${profile}" >"${PROJECT}/.idea-config.json"
        run bash "${SCRIPT}" --explain --root "${PROJECT}"
        assert_status 2
        assert_not_contains "${output}" Traceback
    done
}

@test "conflicting commands and misplaced JSON switches are usage errors" {
    run bash "${SCRIPT}" --explain doctor --root "${PROJECT}"
    assert_status 2
    run bash "${SCRIPT}" backup --json --root "${PROJECT}"
    assert_status 2
    run bash "${SCRIPT}" --root "${PROJECT}"
    assert_status 2
}

@test "IDE executable creates one informational finding and exit one" {
    stub ps 'printf "%s\n" "/Applications/Some IDE.app/Contents/MacOS/phpstorm"'
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 1
    [ "$(printf '%s' "${output}" | jq -c '[.findings[].kind]')" = '["ide-running"]' ]
}

@test "process inspection failures never claim the IDE is stopped" {
    stub ps 'exit 1'
    run bash "${SCRIPT}" --explain --root "${PROJECT}"
    assert_status 2
    assert_not_contains "${output}" Traceback
}

@test "module macro resolves beside nested module and URL escapes are decoded" {
    mkdir -p "${PROJECT}/nested/src space"
    printf '<module><content url="file://$MODULE_DIR$"><sourceFolder url="file://$MODULE_DIR$/src%%20space" /></content></module>' >"${PROJECT}/nested/library.iml"
    printf '<project><component><module fileurl="file://$PROJECT_DIR$/nested/library.iml" filepath="$PROJECT_DIR$/nested/library.iml" /></component></project>' >"${PROJECT}/.idea/modules.xml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
}

@test "module at project root resolves its source beside the module file" {
    printf '<module><content url="file://$MODULE_DIR$"><sourceFolder url="file://$MODULE_DIR$/src" /></content></module>' >"${PROJECT}/root.iml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
}

@test "module directly in a nested .idea uses that .idea parent rather than the outer project" {
    mkdir -p "${PROJECT}/service/.idea" "${PROJECT}/service/src"
    printf '<module><content url="file://$MODULE_DIR$"><sourceFolder url="file://$MODULE_DIR$/src" /></content></module>' >"${PROJECT}/service/.idea/service.iml"
    printf '<project><component><module filepath="$PROJECT_DIR$/service/.idea/service.iml" /></component></project>' >"${PROJECT}/.idea/modules.xml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
}

@test "module in a subdirectory below .idea retains its immediate parent" {
    mkdir -p "${PROJECT}/.idea/modules/src"
    printf '<module><content url="file://$MODULE_DIR$"><sourceFolder url="file://$MODULE_DIR$/src" /></content></module>' >"${PROJECT}/.idea/modules/nested.iml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
}

@test "unknown macros are left unresolved rather than called stale" {
    printf '<module><content url="file://$UNKNOWN$/path" /></module>' >"${PROJECT}/extra.iml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
}

@test "archive roots check the containing file without treating members as disk paths" {
    cp "${REPO_ROOT}/tests/fixtures/idea-config/archive-roots.iml" "${PROJECT}/archive-roots.iml"
    printf 'synthetic archive existence marker' >"${PROJECT}/present archive.jar"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 1
    [ "$(printf '%s' "${output}" | jq -c '[.findings[] | [.kind,.file,.line]]')" = '[["stale-path","archive-roots.iml",7],["stale-path","archive-roots.iml",8]]' ]
    assert_not_contains "${output}" 'unverified/member'
    assert_not_contains "${output}" 'Example.class'
}

@test "nested Git scan honors exclusions dependencies depth and worktree files" {
    mkdir -p "${PROJECT}/vendor/dep/.git" "${PROJECT}/node_modules/dep/.git" "${PROJECT}/excluded/repo/.git"
    mkdir -p "${PROJECT}/one/two/three/.git" "${PROJECT}/one/two/three/four/.git" "${PROJECT}/worktree"
    printf 'gitdir: elsewhere\n' >"${PROJECT}/worktree/.git"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 1
    [ "$(printf '%s' "${output}" | jq '.findings | length')" = 2 ]
    assert_contains "${output}" 'one/two/three'
    assert_contains "${output}" 'worktree'
    assert_not_contains "${output}" '/four'
    assert_not_contains "${output}" 'excluded/repo'
}

@test "a parent Git mapping does not cover an unmapped nested repository" {
    mkdir -p "${PROJECT}/nested/child/.git"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 1
    [ "$(printf '%s' "${output}" | jq -c '[.findings[].kind]')" = '["unmapped-git"]' ]
}

@test "empty VCS directory means the project root and non Git mappings stay untouched" {
    printf '<project><component><mapping directory="" vcs="Git"/><mapping directory="$PROJECT_DIR$/nested" vcs="Git"/><mapping directory="absent" vcs="svn"/></component></project>' >"${PROJECT}/.idea/vcs.xml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
}

@test "duplicate folder checks are scoped to one parent and distinguish attributes" {
    printf '<module><content url="file://$PROJECT_DIR$"><sourceFolder url="file://$PROJECT_DIR$/src" isTestSource="false"/><sourceFolder url="file://$PROJECT_DIR$/src" isTestSource="true"/></content><content url="file://$PROJECT_DIR$"><sourceFolder url="file://$PROJECT_DIR$/src" isTestSource="false"/></content></module>' >"${PROJECT}/extra.iml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
}

@test "repeated excludeFolder elements are reported" {
    printf '<module><content><excludeFolder url="file://$PROJECT_DIR$/excluded"/><excludeFolder url="file://$PROJECT_DIR$/excluded"/></content></module>' >"${PROJECT}/extra.iml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 1
    [ "$(printf '%s' "${output}" | jq -c '[.findings[] | [.kind,.file]]')" = '[["duplicate-entry","extra.iml"]]' ]
}

@test "entry script works when invoked by basename from its directory" {
    pushd "${REPO_ROOT}/plugins/idea-config/scripts" >/dev/null
    run bash idea-config.sh doctor --json --root "${PROJECT}"
    popd >/dev/null
    assert_status 0
}

@test "DTD input is rejected without expanding external files" {
    printf '<!DOCTYPE project [<!ENTITY secret SYSTEM "file:///etc/passwd">]><project>&secret;</project>' >"${PROJECT}/.idea/entity.xml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 1
    [ "$(printf '%s' "${output}" | jq -c '[.findings[].kind]')" = '["invalid-xml"]' ]
    assert_not_contains "${output}" 'root:'
}

@test "human findings use tab separated fields and an exact XML line" {
    printf '<project>\n<broken>\n</project>\n' >"${PROJECT}/.idea/broken.xml"
    run bash "${SCRIPT}" doctor --root "${PROJECT}"
    assert_status 1
    assert_contains "${output}" $'invalid-xml\t.idea/broken.xml:3\t'
}

@test "backup preserves all contracted bytes paths and excludes unrelated files" {
    printf '%s\n' '{"backup_dir":"backups"}' >"${PROJECT}/.idea-config.json"
    printf 'private scratch' >"${PROJECT}/.idea/notes.txt"
    run bash "${SCRIPT}" backup --root "${PROJECT}"
    assert_status 0
    snapshot="${output}"
    [ -d "${snapshot}" ]
    [[ "${snapshot##*/}" =~ ^idea-config-backup\.[0-9]{8}T[0-9]{6}\.[0-9]{6}Z$ ]]
    for file in .idea/modules.xml .idea/vcs.xml .idea/demo.iml .idea/runConfigurations/legacy.xml .run/demo.run.xml root.iml; do
        cmp "${PROJECT}/${file}" "${snapshot}/${file}"
    done
    [ ! -e "${snapshot}/.idea/notes.txt" ]
    [ ! -e "${snapshot}/.idea-config.json" ]
    run bash "${SCRIPT}" backup --root "${PROJECT}"
    assert_status 0
    [ "${output}" != "${snapshot}" ]
}

@test "backup refuses recursive destinations" {
    printf '%s\n' '{"backup_dir":".idea/snapshots"}' >"${PROJECT}/.idea-config.json"
    run bash "${SCRIPT}" backup --root "${PROJECT}"
    assert_status 2
    [ ! -e "${PROJECT}/.idea/snapshots" ]
}

@test "symlinks are not followed during scanning or backup" {
    mkdir -p "${TMP}/external/.git"
    printf '<broken>' >"${TMP}/external/private.xml"
    ln -s "${TMP}/external" "${PROJECT}/linked"
    ln -s "${TMP}/external/private.xml" "${PROJECT}/.idea/private.xml"
    run bash "${SCRIPT}" doctor --json --root "${PROJECT}"
    assert_status 0
    run env TMPDIR="${TMP}" bash "${SCRIPT}" backup --root "${PROJECT}"
    assert_status 0
    [ ! -e "${output}/.idea/private.xml" ]
}

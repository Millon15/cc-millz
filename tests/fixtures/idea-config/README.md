# Synthetic project fixtures

Copy `clean/` or `broken/` into a temporary directory, then create empty `.git/` and `nested/.git/` directories
in that copy. Git metadata is created by the test setup because it cannot be stored as ordinary fixture content
inside another Git repository. These are existence markers for the checker, not usable Git repositories.

Stub `ps -ax -o comm=` to print a non-IDE executable when asserting exact findings. `expected.json` contains
the expected `[kind, file]` pairs; compare sorted arrays, retaining duplicates. `broken/` is a complete project
with planted missing paths, duplicate entries, missing Git mappings, and invalid XML.

The CLI suite also creates temporary worktree markers, excluded repositories, dependency directories, symlinks,
and a fourth-level Git root to check scan boundaries. All names and contents are synthetic.

`archive-roots.iml` is copied into the temporary project by its dedicated case. The case creates a file named
`present archive.jar` as an existence marker; the two missing archive files must be reported, while the member
path inside the present archive must not be treated as a filesystem path. The checker does not inspect archive
contents or validate a member's existence.

The `.idea/demo.iml` modules use `$MODULE_DIR$` as the project root, matching JetBrains' exception for modules
whose immediate parent directory is named `.idea`. The suite also checks modules at the project root, in an
ordinary subdirectory, directly in a nested project's `.idea`, and in a subdirectory below `.idea`.

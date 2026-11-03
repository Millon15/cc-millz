# Project model: `.idea/`, modules, roots, VCS mappings

Checked on 2026-10-24 against JetBrains Help labelled 2026.2 and intellij-community master at
`b56d564b9f20751b3c9444d1f1ed644adb64e4a1` (cited below as `ic:<path>:<line>`, a permalink at that commit).
PhpStorm, GoLand and the Database, JavaScript and Deployment plugins are closed source: their file shapes come from
IDE-saved files and public repos (tier T3 in `corpus.md`), not from a schema.

## What lives where

The directory format is the default; `.ipr`/`.iws` is the outdated file-based format
([projects](https://www.jetbrains.com/help/idea/creating-and-managing-projects.html)). A component with no explicit
storage lands in `misc.xml`; `workspace.xml` holds per-user state (`ic:platform/configuration-store-impl/src/ProjectStoreImpl.kt:155-156`).

| Path | Commit? | Holds |
| --- | --- | --- |
| `workspace.xml` | NO | per-user state: unshared run configs (`RunManager`), unshared PHP servers (`PhpServers`), GOROOT, ignored VCS roots, local scopes |
| `shelf/`, `dictionaries/`, `usage.statistics.xml`, `tasks.xml` | NO | per-user; the last two are legacy, now application-level |
| `dataSources.local.xml`, `dataSources/`, `httpRequests/`, `aws.xml` | NO | credentials, schema caches, request history |
| `modules.xml`, `*.iml` | yes | module list and roots; NOT when Maven/Gradle regenerates them |
| `vcs.xml` | yes | `VcsDirectoryMappings` |
| `misc.xml` | yes, with care | `ProjectRootManager` names a machine-local SDK |
| `encodings.xml`, `codeStyles/`, `inspectionProfiles/`, `scopes/`, `copyright/` | yes | team settings |
| `runConfigurations/`, `../.run/` | yes | shared run configurations; see `run-configurations.md` |
| `php.xml` | yes, review | language level, include paths, project-visible interpreters, tool paths that may hold `$USER_HOME$` |
| `dataSources.xml`, `sqldialects.xml`, `jsLibraryMappings.xml` | optional | data sources without passwords, SQL dialect per file, JS libraries |
| `deployment.xml`, `webServers.xml` | review first | `webServers.xml` can hold a username and an encoded password |

Sources: [share settings](https://www.jetbrains.com/help/idea/configure-project-settings.html) (official do-not-share
list), [JetBrains.gitignore](https://github.com/github/gitignore/blob/main/Global/JetBrains.gitignore),
`ic:platform/vcs-impl/src/com/intellij/openapi/vcs/impl/ProjectLevelVcsManagerImpl.kt:80`.
Some per-user state lives outside the project, in `<config>/workspace/<projectId>.xml` (`ProjectStoreImpl.kt:193-205`).

Minimal ignore block for a repo that commits `.idea/`:

```gitignore
.idea/**/workspace.xml
.idea/**/usage.statistics.xml
.idea/**/dictionaries
.idea/**/shelf
.idea/**/aws.xml
.idea/**/dataSources/
.idea/**/dataSources.ids
.idea/**/dataSources.local.xml
.idea/httpRequests
```

## Macros

| Macro | Expands to | Write it in |
| --- | --- | --- |
| `$PROJECT_DIR$` | project base directory | project files: `modules.xml`, `vcs.xml`, `misc.xml`, `php.xml`, `workspace.xml` |
| `$MODULE_DIR$` | directory of the `.iml`; when that directory is named `.idea`, its parent (the project base) | `.iml` files |
| `$USER_HOME$` | user home | machine paths the IDE collapsed; never hand-write one into a shared file |
| `$APPLICATION_HOME_DIR$`, `$MAVEN_REPOSITORY$` | IDE install, local Maven repo | written by the IDE only |
| custom `$NAME$` | value in `<config>/options/path.macros.xml`, component `PathMacrosImpl` | only when the team defines it in Settings ▸ Path Variables |

- `.idea/<dir>.iml` with `<content url="file://$MODULE_DIR$" />` covers the whole project, because the
  `.iml`'s immediate parent is named `.idea` (`ic:jps/model-serialization/src/org/jetbrains/jps/model/serialization/PathMacroUtil.java:48-53`).
  The rule checks the immediate parent only: `.idea/modules/app.iml` keeps `$MODULE_DIR$` = `.idea/modules`.
- On save the IDE collapses absolute paths: exact `$PROJECT_DIR$`/`$MODULE_DIR$` wins, then custom macros, then
  `$PROJECT_DIR$/..` chains and `$USER_HOME$` (`ic:platform/projectModel-impl/src/com/intellij/application/options/ReplacePathToMacroMap.java:183-216`).
  Write the macro form by hand and the next save produces no diff.
- URLs: `file://$PROJECT_DIR$/src` for directories, no trailing slash; `jar://$PROJECT_DIR$/tool.phar!/` for
  archives, where `!/` splits the archive from the path inside it. Bare paths (`filepath`, php.xml `<path value>`)
  carry no scheme.

Sources: [path variables](https://www.jetbrains.com/help/idea/absolute-path-variables.html),
`ic:platform/projectModel-impl/src/com/intellij/openapi/components/PathMacroManager.kt:58-88`,
`ic:jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsGlobalLoader.java:70-76`.

## `modules.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="ProjectModuleManager">
    <modules>
      <module fileurl="file://$PROJECT_DIR$/.idea/myproj.iml" filepath="$PROJECT_DIR$/.idea/myproj.iml" />
    </modules>
  </component>
</project>
```

- Write both `fileurl` and `filepath`, the same path. Keep modules sorted by name, as the IDE writes them
  (`ic:platform/workspace/jps/src/com/intellij/platform/workspace/jps/serialization/impl/ModuleImlFileEntitiesSerializer.kt:1290-1305`).
- The module name is the `.iml` file name; the file carries no name attribute (`ic:jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsProjectLoader.java:439-441`).
- A listed `.iml` that does not exist is skipped with a log line, not an error (`JpsProjectLoader.java:317`), so a
  stale entry fails silently. `doctor` reports it as `stale-path`.

## The `.iml` file

```xml
<?xml version="1.0" encoding="UTF-8"?>
<module type="WEB_MODULE" version="4">
  <component name="NewModuleRootManager">
    <content url="file://$MODULE_DIR$">
      <sourceFolder url="file://$MODULE_DIR$/src" isTestSource="false" packagePrefix="App\" />
      <sourceFolder url="file://$MODULE_DIR$/tests" isTestSource="true" packagePrefix="App\Tests\" />
      <excludeFolder url="file://$MODULE_DIR$/var" />
      <excludePattern pattern="*.cache" />
    </content>
    <orderEntry type="inheritedJdk" />
    <orderEntry type="sourceFolder" forTests="false" />
  </component>
</module>
```

| Element | Rule |
| --- | --- |
| `content url` | required; one per content root; a module may have several |
| `sourceFolder`, `excludeFolder` | MUST be children of a `content` and carry `url`; a missing required attribute fails the whole module load (`ic:jps/model-serialization/src/org/jetbrains/jps/model/serialization/module/JpsModuleRootModelSerializer.java:68-80`) |
| `excludePattern` | MUST be a child of a `content` and carry `pattern`, not `url` (`JpsModuleRootModelSerializer.java:78-79`) |
| `isTestSource` | always written; with no `type`, `true` = test root, `false` = source root (`JpsModuleRootModelSerializer.java:168-171`) |
| `type` | `java-resource`, `java-test-resource`; an unknown value is kept, not dropped (`:179-180`) |
| `packagePrefix` | namespace or package of the root; PHP keeps the trailing backslash: `App\` |
| `excludePattern pattern` | one element per pattern; matches file and directory names only, `vendor/bin/*` does not work ([content roots](https://www.jetbrains.com/help/idea/content-roots.html)) |
| `orderEntry` | `inheritedJdk` · `jdk jdkName jdkType` · `sourceFolder` · `library name level` · `module module-name`; SDK details in `interpreters-sdks.md` |

Excluded folders drop out of completion, navigation and inspections
([content roots](https://www.jetbrains.com/help/idea/content-roots.html)). An identical element repeated is harmless
to the IDE but noise; `doctor` reports it as `duplicate-entry`.

| IDE | Module file habits (T3 unless cited) |
| --- | --- |
| PhpStorm | single `.idea/<dir>.iml`, `WEB_MODULE`; `packagePrefix` = PSR-4 root. Settings ▸ PHP ▸ Composer ▸ "Synchronize IDE Settings with composer.json" maps `autoload` to Sources, `autoload-dev` to Tests, `require.php` to the language level, and excludes `vendor/` while adding it back through php.xml include paths ([composer](https://www.jetbrains.com/help/phpstorm/composer-dependency-manager.html)). Each nested `composer.json` is a separate Composer "module" there; whether sync writes its roots into the one shared `.iml` is unverified, so add nested PSR-4 roots by hand and check |
| GoLand | `WEB_MODULE` or no `type`, plus `<component name="Go" enabled="true" />` in the `.iml`; GOROOT sits in `workspace.xml` |
| PyCharm | `PYTHON_MODULE`; source roots seed import resolution ([content root](https://www.jetbrains.com/help/pycharm/content-root.html)); exclude the venv: `<excludeFolder url="file://$MODULE_DIR$/.venv" />` |
| WebStorm | `WEB_MODULE`, often with `jsLibraryMappings.xml` |
| IntelliJ IDEA | `JAVA_MODULE`, `.iml` beside the module or under `.idea/modules/` for build-tool imports; `inherit-compiler-output`, `java-resource` roots |

## `vcs.xml` and nested repositories

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="VcsDirectoryMappings">
    <mapping directory="" vcs="Git" />
    <mapping directory="$PROJECT_DIR$/services/api" vcs="Git" />
  </component>
</project>
```

- `directory=""` is the project root (`<Project>` in the UI); `vcs=""` means `<none>`
  (`ic:platform/vcs-api/src/com/intellij/openapi/vcs/VcsDirectoryMapping.java:61-73`).
- The IDE auto-registers detected Git and Mercurial roots by default (registry `vcs.root.auto.add=true`,
  `ic:platform/util/resources/misc/registry.properties:787-790`), and they persist into `vcs.xml`.
- It skips a candidate root that the parent repo ignores or that the project excludes
  (`ic:platform/vcs-impl/src/com/intellij/openapi/vcs/roots/VcsRootErrorsHandler.java:196-205`). A nested repo
  listed in the parent `.gitignore` is therefore neither registered nor reported: it shows with the ignored-file
  colour and no Git features until someone maps it by hand. This is the usual cause of grey folders in a monorepo
  of independent checkouts.
- "Ignore" on the unregistered-roots notification writes to `workspace.xml`, not `vcs.xml`
  (`ic:platform/vcs-api/shared/src/com/intellij/openapi/vcs/VcsConfiguration.java:35,38,81`).
- UI route: Settings ▸ Version Control ▸ Directory Mappings ▸ `+`
  ([version control](https://www.jetbrains.com/help/idea/enabling-version-control.html)).

## Recipe: grey nested repos and a renamed directory

1. `doctor` lists `unmapped-git` for each nested repo and `stale-path` for every url under the old name.
2. Add one `<mapping directory="$PROJECT_DIR$/<dir>" vcs="Git" />` per `unmapped-git`, in path order.
3. Repoint the old name in every url of the `.iml` and `modules.xml`: replace `$MODULE_DIR$/<old>/` with
   `$MODULE_DIR$/<new>/`, as a literal text substitution with the trailing slash, so `<old>-other/` survives.
4. Add the new directory's roots from its build manifest (`composer.json` psr-4, `pyproject.toml`
   packages, `go.mod` module): one `sourceFolder` per root, `excludeFolder` for its build or cache output.
5. Validate, run `doctor` again, then reload (SKILL.md protocol steps 5-6).

## Edits while the IDE runs

- The IDE sees a disk change only after a VFS refresh, by default when its window regains focus
  ([VFS](https://plugins.jetbrains.com/docs/intellij/virtual-file-system.html),
  [system settings](https://www.jetbrains.com/help/idea/system-settings.html)).
- After the refresh it reloads changed config files in place. A component it cannot reload produces "components
  were changed externally and cannot be reloaded… reload project?"
  (`ic:platform/configuration-store-impl/src/StoreReloadManagerImpl.kt:277-330`). Accept it.
- The IDE saves state on frame deactivation and on close
  ([persisting state](https://plugins.jetbrains.com/docs/intellij/persisting-state-of-components.html)). A save
  before the reload writes the in-memory model over the edit.
- Safest order for `modules.xml`, `*.iml`, `vcs.xml` and `misc.xml`: close the project, edit, reopen. With the
  project open: edit, then File ▸ Reload All from Disk, and accept any reload prompt before touching a setting.
- JetBrains publishes no statement on hand-editing `.idea/`. File ▸ Invalidate Caches clears caches and
  indexes only; it never repairs or rewrites `.idea/` ([invalidate caches](https://www.jetbrains.com/help/idea/invalidate-caches.html)).

## Which IDE wrote it

All signals are hints; one project often collects files from several IDEs. `scripts/idea-config.sh --explain`
reports its guess in `ide`, and a profile overrides it.

| Signal | Suggests |
| --- | --- |
| `php.xml` with `PhpProjectSharedConfiguration`, backslash `packagePrefix` | PhpStorm |
| `.iml` `<component name="Go" enabled="true" />`, `GOROOT` in `workspace.xml` | GoLand |
| `PYTHON_MODULE`, `project-jdk-type="Python SDK"` | PyCharm |
| `JAVA_MODULE`, `compiler.xml`, `gradle.xml`, `.idea/libraries/` | IntelliJ IDEA |
| `.idea/.idea.<Name>/.idea/` nested layout | Rider |

Config directories per OS (`options/jdk.table.xml`, `options/path.macros.xml`): see `interpreters-sdks.md`.

## Sources

https://www.jetbrains.com/help/idea/creating-and-managing-projects.html
https://www.jetbrains.com/help/idea/configure-project-settings.html
https://www.jetbrains.com/help/idea/absolute-path-variables.html
https://www.jetbrains.com/help/idea/content-roots.html
https://www.jetbrains.com/help/phpstorm/configuring-content-roots.html
https://www.jetbrains.com/help/phpstorm/composer-page.html
https://www.jetbrains.com/help/phpstorm/composer-dependency-manager.html
https://www.jetbrains.com/help/pycharm/content-root.html
https://www.jetbrains.com/help/idea/enabling-version-control.html
https://www.jetbrains.com/help/idea/set-up-a-git-repository.html
https://www.jetbrains.com/help/idea/system-settings.html
https://www.jetbrains.com/help/idea/invalidate-caches.html
https://plugins.jetbrains.com/docs/intellij/persisting-state-of-components.html
https://plugins.jetbrains.com/docs/intellij/virtual-file-system.html
https://plugins.jetbrains.com/docs/intellij/project.html
https://github.com/github/gitignore/blob/main/Global/JetBrains.gitignore
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsProjectLoader.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/module/JpsModuleRootModelSerializer.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/PathMacroUtil.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsGlobalLoader.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/configuration-store-impl/src/ProjectStoreImpl.kt
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/configuration-store-impl/src/StoreReloadManagerImpl.kt
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/projectModel-impl/src/com/intellij/openapi/components/PathMacroManager.kt
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/projectModel-impl/src/com/intellij/application/options/ReplacePathToMacroMap.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/workspace/jps/src/com/intellij/platform/workspace/jps/serialization/impl/ModuleImlFileEntitiesSerializer.kt
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-impl/src/com/intellij/openapi/vcs/impl/ProjectLevelVcsManagerImpl.kt
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-impl/src/com/intellij/openapi/vcs/roots/VcsRootErrorsHandler.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-api/src/com/intellij/openapi/vcs/VcsDirectoryMapping.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-api/shared/src/com/intellij/openapi/vcs/VcsConfiguration.java
https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/util/resources/misc/registry.properties

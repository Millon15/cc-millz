# Interpreters and SDKs

Checked on 2026-10-24. UI guidance uses JetBrains Help labelled 2026.2. Project/module SDK XML below was
checked against IntelliJ Platform 2025.2 source at `idea/252.23892.409`. Product-specific interpreter internals
are not a public stable format. PHP fragments below are local IDE-saved observations with the writer version
unrecorded, inspected alongside installed PhpStorm 2026.3, build 263.6949. Preserve existing connection IDs and
runtime URIs when using those fragments to edit a definition.

## Project reference, module override, machine definition

An SDK definition tells the IDE where the runtime and its libraries exist on this machine. A project references
that definition; a module either inherits the project choice or names its own. Changing a project XML name does
not install a runtime or create its global definition.
[SDK settings](https://www.jetbrains.com/help/idea/sdk.html)

The pinned `JpsProjectLoader` reads project defaults from `.idea/misc.xml`.
`JpsProjectConfigurationLoading.readProjectSdkTypeAndName` reads `ProjectRootManager` and its
`project-jdk-name` and `project-jdk-type` attributes. The following fragments illustrate the reference relationship;
keep the other existing components and attributes when making a targeted edit.

```xml
<project version="4">
  <component name="ProjectRootManager" version="2"
             project-jdk-name="project-python" project-jdk-type="Python SDK" />
</project>
```

Inside a module's `NewModuleRootManager`, inherit the project SDK:

```xml
<orderEntry type="inheritedJdk" />
```

Or select a configured SDK explicitly:

```xml
<orderEntry type="jdk" jdkName="project-python" jdkType="Python SDK" />
```

`JpsModuleRootModelSerializer` reads these alternatives. `PythonSdkType` identifies the type as `Python SDK`;
Java's serializer uses `JavaSDK`. The example name `project-python` must match a definition on the current machine.
Do not substitute a filesystem path for the SDK name or add both alternatives to one module.

## Locate the machine's SDK table

The application storage test in the pinned release identifies `options/jdk.table.xml`; `ProjectJdkTableImpl`
owns the SDK table state. Its `<jdk>` records contain a name, type, home path, roots, and type-specific additional
state, as read by `JpsSdkTableSerializer`. This is not a file to copy into each project's `.idea` directory.

Find the active configuration directory through **Help > Diagnostic Tools > Special Files and Folders**.
Default configuration roots are:

| OS | Configuration root |
| --- | --- |
| macOS | `~/Library/Application Support/JetBrains/<product><version>/` |
| Linux | `~/.config/JetBrains/<product><version>/` |
| Windows | `%APPDATA%\JetBrains\<product><version>\` |

Append `options/jdk.table.xml` to the active configuration root. `idea.config.path` can override the defaults;
use the running IDE's reported path rather than guessing from an installed version directory.
[IDE directories](https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html)

Global configuration edits affect other projects. Prefer the SDK/interpreter UI; if an offline repair is necessary,
close that IDE and back up the exact global file separately. The plugin's project backup does not include it.
Never commit global SDK tables, credential stores, SSH keys, local executable paths, or generated interpreter caches.

## PHP

Set the project's **PHP language level** independently from its **CLI Interpreter** in **Settings > PHP**.
The language level controls code assistance, while the selected executable controls runtime behavior.
Composer synchronization can determine the language level, so inspect `composer.json` and the Composer settings
before changing the saved project preference.
[PHP settings](https://www.jetbrains.com/help/phpstorm/php.html)

For a local interpreter, choose its executable and verify the detected version and loaded debugger in the
CLI Interpreters dialog. **Visible only for this project** controls availability; it does not make a local
executable path portable.
[Local PHP interpreters](https://www.jetbrains.com/help/phpstorm/configuring-local-interpreter.html)

An observed `.idea/php.xml` language-level setting is:

```xml
<component name="PhpProjectSharedConfiguration" php_language_level="8.4" />
```

Merge this component into the existing `project` element, or change only `php_language_level` if the component
already exists. Evidence: local IDE-saved observation, writer version unrecorded, inspected alongside PhpStorm
2026.3 on 2026-10-24. Use a language level supported by the target IDE and required by the project; changing this
attribute does not replace its PHP executable.

The same inspection found a project-visible Docker Compose interpreter in `.idea/php.xml` with this structure:

```xml
<component name="PhpInterpreters">
  <interpreters>
    <interpreter id="KEEP_EXISTING_ID" name="project-php" home="KEEP_EXISTING_HOME_URI"
                 auto="false" debugger_id="KEEP_EXISTING_DEBUGGER_ID">
      <remote_data INTERPRETER_PATH="php" HELPERS_PATH="/opt/.phpstorm_helpers" VALID="true"
                   RUN_AS_ROOT_VIA_SUDO="false" DOCKER_ACCOUNT_NAME="KEEP_EXISTING_DOCKER_ACCOUNT"
                   DOCKER_COMPOSE_SERVICE_NAME="php" DOCKER_REMOTE_PROJECT_PATH="/app">
        <type_data command="EXEC" />
        <dockerComposeConfigurationPaths>
          <item value="$PROJECT_DIR$/compose.yaml" />
        </dockerComposeConfigurationPaths>
        <envs />
      </remote_data>
    </interpreter>
  </interpreters>
</component>
```

Evidence: the same local IDE-saved observation, with synthetic project values. This is an **edit template** for
an existing interpreter, not a new Docker connection definition. Replace every `KEEP_EXISTING_*` marker with the
value from the original entry; keep its helper path and validity state unless the requested change concerns them.
Update the Compose file, service, executable, and remote project path together. If no interpreter exists yet,
create the Docker connection/interpreter in the UI once, then use this shape for subsequent file edits.

Do not infer from the filename that every `php.xml` component is shareable or that it contains every interpreter
setting. Review its connection details before committing. PHP servers are a separate component: shared server
storage in `php.xml` is documented, while private `PhpServers` was observed in `workspace.xml`; see `debuggers.md`.
[PHP debug servers](https://www.jetbrains.com/help/phpstorm/creating-a-php-debug-server-configuration.html)

For remote interpreters, inspect SSH credentials or Docker/Compose connection, selected image/service,
executable, and path mappings. A generic shared runtime name cannot supply another user's connection definition.
Keep credentials and local connection details outside committed project files.
[Remote PHP interpreters](https://www.jetbrains.com/help/phpstorm/configuring-remote-interpreters.html)

## Python

Use **Settings > Python > Interpreter** to select a system Python or a virtual environment. Verify its executable,
environment packages, and project association; the display name alone does not prove that it points to the intended
environment. Renaming a virtual environment directory may leave an existing SDK definition invalid.
[Python interpreters](https://www.jetbrains.com/help/pycharm/configuring-python-interpreter.html)

When a committed `project-jdk-name` has no corresponding local definition, select or create the interpreter in
the UI, then inspect the changed project reference. Use the interpreter's actual configured name instead of
guessing `Python 3.x (project)`. For SSH, Docker, Docker Compose, or WSL, create the target-specific interpreter
first and verify mappings before trying a run configuration.

## Go

**Settings > Go > GOROOT** selects the Go SDK installation. **Go > GOPATH** configures workspace/cache locations;
these are different paths. GoLand supports global, project, and module GOPATH scopes, with the more specific
scope taking precedence. A module-based project still uses GOPATH for caches and installed binaries.
[GOROOT and GOPATH](https://www.jetbrains.com/help/go/configuring-goroot-and-gopath.html)

Inspect `go env GOROOT GOPATH` in the actual execution environment and compare it with GoLand's selected SDK.
Do not commit one developer's SDK installation or cache directories. Go plugin XML component names are not
verified here; change the SDK in the installed UI and preserve the resulting representation.

## Sources

https://www.jetbrains.com/help/idea/sdk.html
https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html
https://www.jetbrains.com/help/phpstorm/php.html
https://www.jetbrains.com/help/phpstorm/configuring-local-interpreter.html
https://www.jetbrains.com/help/phpstorm/configuring-remote-interpreters.html
https://www.jetbrains.com/help/phpstorm/creating-a-php-debug-server-configuration.html
https://www.jetbrains.com/help/pycharm/configuring-python-interpreter.html
https://www.jetbrains.com/help/go/configuring-goroot-and-gopath.html
https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsProjectLoader.java
https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsProjectConfigurationLoading.java
https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/module/JpsModuleRootModelSerializer.java
https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/library/JpsSdkTableSerializer.java
https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/platform/lang-impl/src/com/intellij/openapi/projectRoots/impl/ProjectJdkTableImpl.kt
https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/platform/configuration-store-impl/testSrc/ApplicationStoreTest.kt
https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/python/src/com/jetbrains/python/sdk/PythonSdkType.java

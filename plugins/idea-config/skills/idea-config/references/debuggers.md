# Debugger configuration

Checked on 2026-10-24 against JetBrains Help labelled PhpStorm, GoLand, PyCharm, and WebStorm 2026.2.
XML examples are labelled with their evidence: local IDE-saved observations or pinned public configurations.
The local PHP files do not record their writer version; they were inspected alongside installed PhpStorm 2026.3,
build 263.6949. Public samples likewise do not establish a writer version. The examples support direct text edits;
substitute project values, preserve unknown existing fields, then validate the reloaded configuration in the target IDE.

## PHP and Xdebug

Xdebug connects from the PHP process to the IDE. The PHP web server's HTTP port and the Xdebug connection port
are different settings. For Xdebug 3, enable `xdebug.mode=debug`, choose a reachable `xdebug.client_host`,
and match `xdebug.client_port` to **Settings > PHP > Debug**; the default is 9003. Older Xdebug 2 uses
`xdebug.remote_*` settings and default port 9000. Do not mix the two sets.
[Configure Xdebug](https://www.jetbrains.com/help/phpstorm/configuring-xdebug.html)

In **Settings > PHP > Servers**, configure the HTTP host/port, debugger, and **Use path mappings**.
Map the local project directory to its absolute path inside the container or remote host, for example `/app`.
The local XML path should retain `$PROJECT_DIR$` when the IDE supports it; the remote `/app` path is deliberately
absolute. An excluded local directory cannot receive a server mapping. With **Shared** enabled, PhpStorm stores
the server settings and in-project mappings in `.idea/php.xml`.
[PHP debug server](https://www.jetbrains.com/help/phpstorm/creating-a-php-debug-server-configuration.html)

An unshared server was observed in `.idea/workspace.xml`, component `PhpServers`. Merge this component into
the existing `project` element, or add its `server` to the existing `servers` collection:

```xml
<component name="PhpServers">
  <servers>
    <server host="localhost" id="2b630d9a-7880-4c8d-a212-49f21ed78d11" name="local-app"
            port="8080" use_path_mappings="true">
      <path_mappings>
        <mapping local-root="$PROJECT_DIR$" remote-root="/app" />
      </path_mappings>
    </server>
  </servers>
</component>
```

Evidence: local IDE-saved observation, writer version unrecorded, inspected alongside PhpStorm 2026.3 on
2026-10-24. The example substitutes a synthetic ID, host, port, name, and paths. Preserve the original server ID
when editing an existing entry; use a fresh ID for a new entry. Shared server storage in `.idea/php.xml` is
documented by JetBrains; the private workspace storage above was observed locally. Do not commit workspace.xml
to share a server.

For **PHP Remote Debug**, select the server and the session IDE key in **Run > Edit Configurations**.
The PHP interpreter still needs a working Xdebug installation and a way to trigger the session.
Saving the run configuration alone does not enable Xdebug or establish network connectivity.
[PHP Remote Debug](https://www.jetbrains.com/help/phpstorm/run-debug-configuration-php-remote-debug.html)

For the server named `local-app`, create `.run/php-remote.run.xml`:

```xml
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="PHP remote" type="PhpRemoteDebugRunConfigurationType"
                 factoryName="PHP Remote Debug" filter_connections="FILTER"
                 server_name="local-app" session_id="PHPSTORM">
    <method v="2" />
  </configuration>
</component>
```

Evidence: the same local IDE-saved observation, with the standard shared-file envelope from the platform source
in `run-configurations.md`. `server_name` matches the server's **name**, not its ID; `session_id` must match the
triggered debugging session. Keep this relationship intact when renaming a server.

For an SSH, Docker, or Docker Compose CLI interpreter, configure the interpreter through **Settings > PHP** first.
Inspect its executable, container/service, and local-to-remote path mappings; these are separate from PHP server
mappings. In a container, `127.0.0.1` identifies that container, so it is not generally the IDE's address.
Use the host address reachable from the actual runtime.
[Remote interpreters](https://www.jetbrains.com/help/phpstorm/configuring-remote-interpreters.html)

Verify in order: the chosen PHP runtime loads Xdebug; its destination reaches the IDE; the IDE is listening;
the incoming remote filename maps to the intended local file. Static XML checks establish none of these runtime
facts. For live PhpStorm sessions, route to `phpstorm:phpstorm-debug` or `phpstorm:phpstorm-mcp` when installed.

## Go and Delve

For an IDE-launched program, use a Go build configuration and select **Debug**. For an already running local
program, use **Run > Attach to Process**. For a remote process, start Delve on the target and use **Go Remote**.
Build without optimization/inlining and retain debug symbols:

```bash
go build -gcflags="all=-N -l" -o app .
dlv --listen=127.0.0.1:2345 --headless=true --api-version=2 exec ./app
```

The loopback example requires the IDE on the same host or a tunnel to that host. Choose the host and port in
**Go Remote** to reach that Delve listener. To attach Delve to an existing target instead, use its `attach <PID>`
form. Check Go/Delve compatibility and source paths; stripping DWARF information prevents debugging.
[Attach to Go processes](https://www.jetbrains.com/help/go/attach-to-running-go-processes-with-debugger.html)

Check **On disconnect** in the Go Remote configuration before using it: stopping Delve and leaving it running
have different effects. Keep the application's HTTP port separate from the Delve port.
[Go Remote](https://www.jetbrains.com/help/go/go-remote.html)

For the Delve listener above, create `.run/go-remote.run.xml`:

```xml
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="Go remote" type="GoRemoteDebugConfigurationType"
                 factoryName="Go Remote" host="127.0.0.1" port="2345">
    <option name="disconnectOption" value="STOP" />
    <disconnect value="STOP" />
    <method v="2" />
  </configuration>
</component>
```

Evidence: [public Go Remote configuration, pinned revision](https://github.com/DataDog/datadog-agent/blob/2742effdb48d0ec33f842e9e2d401edd714b0ccd/.run/Debug%20agent.run.xml), T3, writer version unrecorded.
This source writes both disconnect representations. The example explicitly stops Delve on disconnect; check
that behavior before running it. For a local IDE-launched binary, use the Go build example in `run-configurations.md`.

## Python: select the protocol

| Workflow | Listener | Configuration |
| --- | --- | --- |
| IDE launches through a configured remote interpreter | Managed by the IDE | Python using that interpreter |
| Application calls `pydevd_pycharm.settrace(...)` | PyCharm | Python Debug Server |
| Application exposes a debugpy DAP server | Application/debugpy | Attach to DAP |
| Attach to an existing local Python process | Local attach mechanism | Run > Attach to Process |

For **Python Debug Server**, set the IDE host, port, and path mappings in the UI. Use the installation command
shown by that IDE for the matching `pydevd-pycharm` version. Start the IDE's debug server, then run the target
with the generated `pydevd_pycharm.settrace(...)` call. The target must reach the IDE listener.
[Remote debugging](https://www.jetbrains.com/help/pycharm/remote-debugging-with-product.html)

For a target whose source lives at `/app`, create `.run/python-debug-server.run.xml`:

```xml
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="Python debug server" type="PyRemoteDebugConfigurationType"
                 factoryName="Python Remote Debug">
    <module name="app" />
    <option name="PORT" value="5678" />
    <option name="HOST" value="localhost" />
    <PathMappingSettings>
      <option name="pathMappings">
        <list><mapping local-root="$PROJECT_DIR$" remote-root="/app" /></list>
      </option>
    </PathMappingSettings>
    <option name="REDIRECT_OUTPUT" value="true" />
    <option name="SUSPEND_AFTER_CONNECT" value="false" />
    <method v="2" />
  </configuration>
</component>
```

Evidence: [public Python remote debugger with mappings, pinned revision](https://github.com/okteto/python-getting-started/blob/0addeda0b089c626909fa30429415fe474699d4d/.idea/runConfigurations/Remote.xml), T3, writer version unrecorded.
Replace the IDE module name and the remote source root. The host/port must agree with the target's
`pydevd_pycharm.settrace` call; `localhost` needs a local target or an appropriate reverse tunnel.
The factory ID is **Python Remote Debug**, although the UI labels this workflow **Python Debug Server**.

PyCharm introduced **Attach to DAP** in 2026.1. The 2026.2 help documents attaching to a debugpy server, including
local/remote path mappings. On an older IDE, check whether that configuration type exists before proposing it.
One target-side startup example is:

```bash
python -m debugpy --listen 127.0.0.1:5678 --wait-for-client app.py
```

Point **Attach to DAP** at that listener, directly or through a tunnel; set the remote root to the path seen by
the target Python process. `--wait-for-client` intentionally blocks application startup until attachment.
[Attach to DAP](https://www.jetbrains.com/help/pycharm/run-debug-configuration-attach-to-dap.html)

The current help verifies this workflow but does not document its XML type or field names. This reference has
no verified saved XML shape for it. For **Attach to DAP** specifically, obtain one
saved configuration from the installed PyCharm version before editing XML; do not relabel the pydevd example.

Do not point Python Debug Server at a debugpy listener; these workflows use different connection directions and
protocols. **Attach to Process** is for a local process and uses pydevd regardless of the debugger mode selected
in settings.
[Attach to process](https://www.jetbrains.com/help/pycharm/attach-to-process.html)

## Node.js and JavaScript

Use **Node.js** to launch with the IDE, or start the runtime with an inspector and use **Attach to Node.js/Chrome**:

```bash
node --inspect-brk=127.0.0.1:9229 app.js
```

Set the configuration's host and inspector port, which is separate from the application's HTTP port. For code
running at another filesystem location, configure remote paths and check source maps for transpiled code.
`--inspect-brk` pauses at startup; `--inspect` does not. Confirm the Node.js and JavaScript Debugger plugins are
enabled. Browser JavaScript debugging and attaching to the Node inspector are separate targets.
[Node.js debugging](https://www.jetbrains.com/help/webstorm/running-and-debugging-node-js.html)

For a local inspector at port 9229, create `.run/node-attach.run.xml`:

```xml
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="Node attach" type="ChromiumRemoteDebugType"
                 factoryName="Chromium Remote" port="9229">
    <method v="2" />
  </configuration>
</component>
```

Evidence: [public Node inspector attachment, pinned revision](https://github.com/openrewrite/rewrite/blob/e42fb0a08b85a8b86a3608ccea81e8d7c42a0350/.run/node%20rewrite-rpc.run.xml), T3, writer version unrecorded.
The UI label **Attach to Node.js/Chrome** differs from both XML identifiers. A tunnel can expose a remote
inspector on that local port; non-local host and mapping fields should be copied from the target version's
saved configuration. This configuration does not launch Node or a browser.

## Sources

https://www.jetbrains.com/help/phpstorm/configuring-xdebug.html
https://www.jetbrains.com/help/phpstorm/creating-a-php-debug-server-configuration.html
https://www.jetbrains.com/help/phpstorm/run-debug-configuration-php-remote-debug.html
https://www.jetbrains.com/help/phpstorm/configuring-remote-interpreters.html
https://www.jetbrains.com/help/go/attach-to-running-go-processes-with-debugger.html
https://www.jetbrains.com/help/go/go-remote.html
https://www.jetbrains.com/help/pycharm/remote-debugging-with-product.html
https://www.jetbrains.com/help/pycharm/attach-to-process.html
https://www.jetbrains.com/help/pycharm/run-debug-configuration-attach-to-dap.html
https://www.jetbrains.com/pycharm/whatsnew/2026-1/
https://www.jetbrains.com/help/webstorm/running-and-debugging-node-js.html
https://github.com/DataDog/datadog-agent/blob/2742effdb48d0ec33f842e9e2d401edd714b0ccd/.run/Debug%20agent.run.xml
https://github.com/okteto/python-getting-started/blob/0addeda0b089c626909fa30429415fe474699d4d/.idea/runConfigurations/Remote.xml
https://github.com/openrewrite/rewrite/blob/e42fb0a08b85a8b86a3608ccea81e8d7c42a0350/.run/node%20rewrite-rpc.run.xml

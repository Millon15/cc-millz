# Source corpus

Every URL cited in a `## Sources` section of this skill's references, with its tier. Checked 2026-10-24.

| Tier | What | Trust it for |
| --- | --- | --- |
| T1 | jetbrains.com/help, JetBrains release notes, intellij-community source at a pinned commit or tag | UI routes, documented behaviour, exact XML tag and attribute names for open-source platform components |
| T2 | JetBrains Platform SDK docs, the github/gitignore JetBrains template | storage mechanics, save and reload timing, which files to ignore |
| T3 | `.idea/` or `.run/` files committed to public repos, pinned to a commit; local IDE-saved files (writer version unrecorded) | that a shape exists in a committed or saved file; NOT that it loads in your IDE version, and NOT a schema, since closed-source plugins (PHP, Go, Database, JavaScript) change fields between versions |

Code baselines: intellij-community master `b56d564b9f20751b3c9444d1f1ed644adb64e4a1` for `project-model.md`, tag
`idea/252.23892.409` (platform 2025.2) for the other references. Help pages are the 2026.2 release.

When sources disagree, prefer the higher tier; when help and code disagree, the code describes what the IDE does
(example: help says detected VCS roots raise a notification, while `vcs.root.auto.add=true` registers them
silently; see `project-model.md`).

Unreachable during research: the JetBrains support article "How to manage projects under Version Control Systems"
(intellij-support.jetbrains.com, article 206544839) and JetBrains community forum threads answer HTTP 403 to
automated fetches. Facts that only those pages state are absent here.

| URL | Owner | Tier | Covers | Cited in |
| --- | --- | --- | --- | --- |
| https://www.jetbrains.com/pycharm/whatsnew/2026-1/ | JetBrains | T1 | PyCharm 2026.1 release notes | debuggers.md |
| https://www.jetbrains.com/help/go/attach-to-running-go-processes-with-debugger.html | JetBrains Help | T1 | go: attach to running go processes with debugger | debuggers.md |
| https://www.jetbrains.com/help/go/configuring-goroot-and-gopath.html | JetBrains Help | T1 | go: configuring goroot and gopath | interpreters-sdks.md |
| https://www.jetbrains.com/help/go/go-remote.html | JetBrains Help | T1 | go: go remote | debuggers.md, run-configurations.md |
| https://www.jetbrains.com/help/go/run-debug-configuration.html | JetBrains Help | T1 | go: run debug configuration | run-configurations.md |
| https://www.jetbrains.com/help/idea/absolute-path-variables.html | JetBrains Help | T1 | idea: absolute path variables | project-model.md |
| https://www.jetbrains.com/help/idea/configure-project-settings.html | JetBrains Help | T1 | idea: configure project settings | project-model.md |
| https://www.jetbrains.com/help/idea/content-roots.html | JetBrains Help | T1 | idea: content roots | project-model.md |
| https://www.jetbrains.com/help/idea/creating-and-managing-projects.html | JetBrains Help | T1 | idea: creating and managing projects | project-model.md |
| https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html | JetBrains Help | T1 | idea: directories used by the ide to store settings caches plugins and logs | interpreters-sdks.md |
| https://www.jetbrains.com/help/idea/enabling-version-control.html | JetBrains Help | T1 | idea: enabling version control | project-model.md |
| https://www.jetbrains.com/help/idea/invalidate-caches.html | JetBrains Help | T1 | idea: invalidate caches | project-model.md |
| https://www.jetbrains.com/help/idea/run-debug-configuration-java-application.html | JetBrains Help | T1 | idea: run debug configuration java application | run-configurations.md |
| https://www.jetbrains.com/help/idea/run-debug-configuration.html | JetBrains Help | T1 | idea: run debug configuration | run-configurations.md |
| https://www.jetbrains.com/help/idea/run-debug-multiple.html | JetBrains Help | T1 | idea: run debug multiple | run-configurations.md |
| https://www.jetbrains.com/help/idea/sdk.html | JetBrains Help | T1 | idea: sdk | interpreters-sdks.md |
| https://www.jetbrains.com/help/idea/set-up-a-git-repository.html | JetBrains Help | T1 | idea: set up a git repository | project-model.md |
| https://www.jetbrains.com/help/idea/system-settings.html | JetBrains Help | T1 | idea: system settings | project-model.md |
| https://www.jetbrains.com/help/phpstorm/composer-dependency-manager.html | JetBrains Help | T1 | phpstorm: composer dependency manager | project-model.md |
| https://www.jetbrains.com/help/phpstorm/composer-page.html | JetBrains Help | T1 | phpstorm: composer page | project-model.md |
| https://www.jetbrains.com/help/phpstorm/configuring-content-roots.html | JetBrains Help | T1 | phpstorm: configuring content roots | project-model.md |
| https://www.jetbrains.com/help/phpstorm/configuring-local-interpreter.html | JetBrains Help | T1 | phpstorm: configuring local interpreter | interpreters-sdks.md |
| https://www.jetbrains.com/help/phpstorm/configuring-remote-interpreters.html | JetBrains Help | T1 | phpstorm: configuring remote interpreters | debuggers.md, interpreters-sdks.md |
| https://www.jetbrains.com/help/phpstorm/configuring-xdebug.html | JetBrains Help | T1 | phpstorm: configuring xdebug | debuggers.md |
| https://www.jetbrains.com/help/phpstorm/creating-a-php-debug-server-configuration.html | JetBrains Help | T1 | phpstorm: creating a php debug server configuration | debuggers.md, interpreters-sdks.md |
| https://www.jetbrains.com/help/phpstorm/php.html | JetBrains Help | T1 | phpstorm: php | interpreters-sdks.md |
| https://www.jetbrains.com/help/phpstorm/run-debug-configuration-php-remote-debug.html | JetBrains Help | T1 | phpstorm: run debug configuration php remote debug | debuggers.md, run-configurations.md |
| https://www.jetbrains.com/help/phpstorm/run-debug-configuration-php-script.html | JetBrains Help | T1 | phpstorm: run debug configuration php script | run-configurations.md |
| https://www.jetbrains.com/help/pycharm/attach-to-process.html | JetBrains Help | T1 | pycharm: attach to process | debuggers.md |
| https://www.jetbrains.com/help/pycharm/configuring-python-interpreter.html | JetBrains Help | T1 | pycharm: configuring python interpreter | interpreters-sdks.md |
| https://www.jetbrains.com/help/pycharm/content-root.html | JetBrains Help | T1 | pycharm: content root | project-model.md |
| https://www.jetbrains.com/help/pycharm/remote-debugging-with-product.html | JetBrains Help | T1 | pycharm: remote debugging with product | debuggers.md |
| https://www.jetbrains.com/help/pycharm/run-debug-configuration-attach-to-dap.html | JetBrains Help | T1 | pycharm: run debug configuration attach to dap | debuggers.md, run-configurations.md |
| https://www.jetbrains.com/help/pycharm/run-debug-configuration-python.html | JetBrains Help | T1 | pycharm: run debug configuration python | run-configurations.md |
| https://www.jetbrains.com/help/webstorm/running-and-debugging-node-js.html | JetBrains Help | T1 | webstorm: running and debugging node js | debuggers.md, run-configurations.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsGlobalLoader.java | JetBrains source | T1 | `JpsGlobalLoader.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsProjectLoader.java | JetBrains source | T1 | `JpsProjectLoader.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/module/JpsModuleRootModelSerializer.java | JetBrains source | T1 | `JpsModuleRootModelSerializer.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/jps/model-serialization/src/org/jetbrains/jps/model/serialization/PathMacroUtil.java | JetBrains source | T1 | `PathMacroUtil.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/configuration-store-impl/src/ProjectStoreImpl.kt | JetBrains source | T1 | `ProjectStoreImpl.kt` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/configuration-store-impl/src/StoreReloadManagerImpl.kt | JetBrains source | T1 | `StoreReloadManagerImpl.kt` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/projectModel-impl/src/com/intellij/application/options/ReplacePathToMacroMap.java | JetBrains source | T1 | `ReplacePathToMacroMap.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/projectModel-impl/src/com/intellij/openapi/components/PathMacroManager.kt | JetBrains source | T1 | `PathMacroManager.kt` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/util/resources/misc/registry.properties | JetBrains source | T1 | `registry.properties` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-api/shared/src/com/intellij/openapi/vcs/VcsConfiguration.java | JetBrains source | T1 | `VcsConfiguration.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-api/src/com/intellij/openapi/vcs/VcsDirectoryMapping.java | JetBrains source | T1 | `VcsDirectoryMapping.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-impl/src/com/intellij/openapi/vcs/impl/ProjectLevelVcsManagerImpl.kt | JetBrains source | T1 | `ProjectLevelVcsManagerImpl.kt` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/vcs-impl/src/com/intellij/openapi/vcs/roots/VcsRootErrorsHandler.java | JetBrains source | T1 | `VcsRootErrorsHandler.java` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/b56d564b9f20751b3c9444d1f1ed644adb64e4a1/platform/workspace/jps/src/com/intellij/platform/workspace/jps/serialization/impl/ModuleImlFileEntitiesSerializer.kt | JetBrains source | T1 | `ModuleImlFileEntitiesSerializer.kt` @ b56d564b9f20 | project-model.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/java/execution/impl/src/com/intellij/execution/application/ApplicationConfigurationType.java | JetBrains source | T1 | `ApplicationConfigurationType.java` @ idea | run-configurations.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsProjectConfigurationLoading.java | JetBrains source | T1 | `JpsProjectConfigurationLoading.java` @ idea | interpreters-sdks.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/JpsProjectLoader.java | JetBrains source | T1 | `JpsProjectLoader.java` @ idea | interpreters-sdks.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/library/JpsSdkTableSerializer.java | JetBrains source | T1 | `JpsSdkTableSerializer.java` @ idea | interpreters-sdks.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/jps/model-serialization/src/org/jetbrains/jps/model/serialization/module/JpsModuleRootModelSerializer.java | JetBrains source | T1 | `JpsModuleRootModelSerializer.java` @ idea | interpreters-sdks.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/platform/configuration-store-impl/testSrc/ApplicationStoreTest.kt | JetBrains source | T1 | `ApplicationStoreTest.kt` @ idea | interpreters-sdks.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/platform/execution-impl/src/com/intellij/execution/impl/RCInArbitraryFileManager.kt | JetBrains source | T1 | `RCInArbitraryFileManager.kt` @ idea | run-configurations.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/platform/execution-impl/src/com/intellij/execution/impl/RunManagerImpl.kt | JetBrains source | T1 | `RunManagerImpl.kt` @ idea | run-configurations.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/platform/execution-impl/src/com/intellij/execution/impl/RunnerAndConfigurationSettingsImpl.kt | JetBrains source | T1 | `RunnerAndConfigurationSettingsImpl.kt` @ idea | run-configurations.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/platform/lang-impl/src/com/intellij/openapi/projectRoots/impl/ProjectJdkTableImpl.kt | JetBrains source | T1 | `ProjectJdkTableImpl.kt` @ idea | interpreters-sdks.md |
| https://github.com/JetBrains/intellij-community/blob/idea/252.23892.409/python/src/com/jetbrains/python/sdk/PythonSdkType.java | JetBrains source | T1 | `PythonSdkType.java` @ idea | interpreters-sdks.md |
| https://github.com/github/gitignore/blob/main/Global/JetBrains.gitignore | github/gitignore | T2 | official JetBrains.gitignore template | project-model.md |
| https://plugins.jetbrains.com/docs/intellij/persisting-state-of-components.html | JetBrains Platform SDK | T2 | SDK: persisting state of components | project-model.md |
| https://plugins.jetbrains.com/docs/intellij/project.html | JetBrains Platform SDK | T2 | SDK: project | project-model.md |
| https://plugins.jetbrains.com/docs/intellij/virtual-file-system.html | JetBrains Platform SDK | T2 | SDK: virtual file system | project-model.md |
| https://github.com/DataDog/datadog-agent/blob/2742effdb48d0ec33f842e9e2d401edd714b0ccd/.run/Debug%20agent.run.xml | DataDog/datadog-agent | T3 | committed sample `Debug agent.run.xml` @ 2742effdb48d | debuggers.md |
| https://github.com/mlrun/mlrun/blob/e1775fe5e366f59e153fa0e5b9233c1dc02d48b9/.run/MLRun%20API.run.xml | mlrun/mlrun | T3 | committed sample `MLRun API.run.xml` @ e1775fe5e366 | run-configurations.md |
| https://github.com/mvdbos/php-spider/blob/e676149d0b7b61cee61424dfa849d03ceffb7070/.run/%5BCHECK%5D%20Phan.run.xml | mvdbos/php-spider | T3 | committed sample `[CHECK] Phan.run.xml` @ e676149d0b7b | run-configurations.md |
| https://github.com/nuclio/nuclio/blob/90a7d6476a7f64db34112d5e10c498fab7e4b8e1/.run/controller-kube.run.xml | nuclio/nuclio | T3 | committed sample `controller-kube.run.xml` @ 90a7d6476a7f | run-configurations.md |
| https://github.com/nuxt/nuxt/blob/194b1fe25c56616d98ede9a944974a3e1030875d/docs/3.guide/6.going-further/9.debugging.md | nuxt/nuxt | T3 | committed sample `9.debugging.md` @ 194b1fe25c56 | run-configurations.md |
| https://github.com/okteto/python-getting-started/blob/0addeda0b089c626909fa30429415fe474699d4d/.idea/runConfigurations/Remote.xml | okteto/python-getting-started | T3 | committed sample `Remote.xml` @ 0addeda0b089 | debuggers.md |
| https://github.com/openrewrite/rewrite/blob/e42fb0a08b85a8b86a3608ccea81e8d7c42a0350/.run/node%20rewrite-rpc.run.xml | openrewrite/rewrite | T3 | committed sample `node rewrite-rpc.run.xml` @ e42fb0a08b85 | debuggers.md |
| https://github.com/skylot/jadx/blob/b86c58aca10831459a338a8e5771de292697bf8c/.run/jadx-gui.run.xml | skylot/jadx | T3 | committed sample `jadx-gui.run.xml` @ b86c58aca108 | run-configurations.md |

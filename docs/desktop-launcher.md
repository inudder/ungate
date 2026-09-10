# Desktop launcher architecture

`scripts/start-codex-desktop-ungate.ps1` remains the public PowerShell 7.4+
entry point. It retains the existing parameters and defaults, creates a
per-invocation context, calls the launcher and translates its result to a
process exit code. Existing shortcuts and command lines do not need changes.

## Module ownership

Implementation lives in `scripts/codex-desktop-launcher/`.

| Module | Responsibility | Module dependencies |
| --- | --- | --- |
| Context | Paths, endpoint defaults, launch options, history diagnostics | None |
| Models | Builtins, identities, custom model registry, context windows | None |
| Toml | Pure TOML text transformations | None |
| Desktop | CLI/AppX discovery, process lifecycle, MSIX fallback, sandbox, workspace roots | None |
| Routing | Providers, shell IDs and route records, provider TOML | Toml |
| Logging | Log preferences, menu, event formatting and live watch | Desktop |
| Picker | Model selection, picker preferences and add-model wizard | Models, Logging |
| ProxyRuntime | Credentials, bridge/router lifecycle, provider preflight | Routing, existing common helpers |
| Catalog | Model catalog generation, catalog/config verification | Models, Routing, Toml, Desktop |
| Profile | Initial config, MCP transaction/rollback, shared skills, AGENTS and auth | Routing, Toml, Desktop |
| Launcher | Selection, transport, profile preparation and launch orchestration | Above modules, existing plugin-isolation module |

Modules use explicit local imports and explicit exports; internal helpers
remain private. Importing a module does not prepare a profile, discover an
installed Desktop, call a provider or launch/stop a process. There is no
mutable per-launch module or global state and no dependency cycle.

`environment-instructions.txt` contains the unchanged instruction text used
to build model identities. The context factory reads it explicitly. Builtin
definitions are newly constructed on each call to `New-UngateModelSet`.

## Internal interfaces

- `New-CodexDesktopLaunchContext -CustomCodexHome ... -LaunchParameters ...
  -ScriptsRoot ...` returns an object with resolved paths, endpoint/provider
  defaults, shell pool, instruction text, `Options` and `BoundParameterNames`.
  The entry point passes its actual `$PSBoundParameters`, preserving the
  difference between an omitted switch/model and an explicitly supplied one.
- `Invoke-CodexDesktopLauncher -Context ...` owns execution. It returns only
  the integer exit code on the success stream; diagnostic text stays on the
  host/warning streams. Failures remain terminating errors.
- Selection is a separate, invocation-local object: `Definitions`,
  `FallbackDefinition`, `EnableProviderFallback`, `SelectedModel`,
  `LaunchModel`, `LaunchProvider`. Functions that need it accept `-Selection`
  explicitly. Menu choices do not mutate the original context options.
- Paths and infrastructure settings are passed as `-Context`; other inputs
  are regular parameters. No function resolves caller variables dynamically.
  Provider keys remain local to transport preparation and are passed only to
  operations that need them; they are not stored in module state or fixtures.

Functions explicitly set their local `ErrorActionPreference` to `Stop` to
retain the original entry point's fail-fast behavior across module session
states. They do not rely on caller preference inheritance. Existing targeted
`SilentlyContinue`/best-effort operations retain their original policy.

`ScriptsRoot` is the original `scripts` directory, not the module directory
or current working directory. Existing router, bridge, package helper and
plugin-isolation paths are resolved from it. The shared
`ungate-codex-common.ps1` is loaded privately by `ProxyRuntime` only.

The Desktop-specific `Invoke-DesktopOmniRoutePreflight` deliberately differs
from the shared `Invoke-OmniRoutePreflight`: it accepts the discovered
`deepseek/` and `ds/` model aliases and requests 512 output tokens. Its unique
name avoids import-order-dependent overriding. Other launchers keep their
existing common preflight behavior.

## Execution contract

1. Validate launcher dependencies and handle standalone `AddModel`.
2. Resolve registry/picker selection and launch model/provider; print history
   diagnostics; discover the Beta package and close it unless `PrepareOnly`.
3. Resolve provider keys, ensure required bridge/router, then preflight.
   Normal preflight has two attempts; fallback has one. Preflight failure
   remains a warning and does not skip profile preparation.
4. Initialize config, write the model catalog **before** MCP validation,
   synchronize MCP/skills/instructions/auth, prepare isolated plugins, verify
   the config, initialize sandbox and restore workspace roots.
5. `PrepareOnly` returns `0` on success or `2` after a preflight warning.
   Normal execution starts Desktop and optionally watches logs. `NoLogWatch`
   overrides log preferences; otherwise a nonempty explicit level overrides
   persisted preferences. `Off` starts Desktop without watching.

The existing public parameters, persisted file formats, model order, shell
mapping and [routing matrix](model-routing.md) are unchanged. Normal Codex
config remains read-only. MCP rollback is preserved. Temporarily changed
environment values are restored on failure, including removing provider
variables that were originally absent (rather than leaving an empty value
on newer .NET versions).

## Safe verification

From the repository root:

```powershell
pnpm --filter @ungate/scripts run launcher:test
```

The runner parses all launcher modules and related PowerShell sources, then
runs Pester **5.8.0** over the original launcher scenarios, module/flow tests,
common helper tests and plugin-isolation tests. It exits nonzero for syntax,
discovery, container or test failures. Pester 5.8.0 must already be installed;
the runner does not install dependencies or change the machine.

Tests import actual modules, pass explicit contexts and use module-scoped
mocks at network/process boundaries. File-writing scenarios use `TestDrive`;
the add-model CLI test runs against a disposable profile. The frozen model
fixture was captured from the pre-refactor definitions; identity SHA256
values verify instruction bytes without repeating the text in each record.
JSON object key order is irrelevant, but model/array order is significant.

Do not use the real launcher `-PrepareOnly` as a read-only check: it writes
the target profile and can restart the model-shell router. Automated
refactoring verification must not stop a working Beta instance or query live
providers. No API rebuild or `ungate-api` service restart is needed for
launcher-only changes.

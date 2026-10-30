# Codex Desktop launcher

Vocabulary of the Ungate launcher that prepares an isolated Codex Beta profile
and starts the Beta desktop app. This glossary covers the launcher context
only; the API proxy and the dashboard have their own vocabulary.

## Language

**Launcher**:
The script that prepares the isolated Codex Beta profile and then starts the
Beta desktop app.
_Avoid_: start script, start-codex

**Beta profile**:
The launcher's own Codex home, prepared and owned by the launcher. Separate from
the normal profile and from any other Codex home.
_Avoid_: custom home, ungate home, .codex-ungate

**Normal profile**:
The non-Beta Codex home owned by the stock Codex desktop app. The launcher
reads from it and never writes into it.
_Avoid_: prod profile, .codex

**Beta package**:
The MSIX package the launcher starts. It ships its own CLI build, which is the
one the launcher must drive.
_Avoid_: Codex Beta app, Beta app

**Service CLI**:
The `codex.exe` the launcher runs to provision and verify the profile: plugin
store, MCP inventory, model catalog. It is the launcher's own copy of the CLI
that ships with the Beta package, so its version matches the app that later
reads the prepared profile.
_Avoid_: custom CLI, launcher CLI

**CLI resolution**:
Choosing which `codex.exe` serves as the service CLI. It must belong to the
package being launched, because helper binaries and plugin-store formats are
version-specific.
_Avoid_: CLI lookup, CLI discovery

**Gate**:
A preparation check that can abort the launch before the app starts.
_Avoid_: check, validation step

**Fatal gate**:
A gate whose failure means the launch cannot proceed at all: no package, no
profile, no usable config.
_Avoid_: blocking gate, hard gate

**Soft gate**:
A gate whose failure degrades one function but still lets Beta open and work.
The failure is reported as a warning and the launch continues.
_Avoid_: best-effort check, non-blocking gate

**Degraded launch**:
A launch that opened Beta but carried one or more soft-gate warnings.
_Avoid_: failed launch, partial launch

**Sandbox provisioning**:
One-time preparation of the Windows sandbox for the profile: access rules for
the sandbox accounts and the command runner installed for that profile.
_Avoid_: sandbox init, sandbox setup, настройка песочницы

**Sandbox readiness**:
Whether the profile already carries the command runner that the Beta CLI of the
exact current version needs. The launcher reports readiness; it does not
provision the sandbox.
_Avoid_: sandbox state, sandbox prepared

**Plugin isolation**:
Building a Beta-only plugin store in the Beta profile, so the normal profile's
plugins and marketplaces do not leak into the isolated profile.
_Avoid_: plugin sync, plugin copy

**Model catalog**:
The launcher's own list of models, loaded by Codex through a catalog pointer.
The launcher verifies that Codex actually resolved it, not merely that the
pointer is written.
_Avoid_: model list, models.json

---
type: "query"
date: "2026-07-19T08:06:50.721031+00:00"
question: "J:\\Dev\\ungate-local\\scripts\\start-codex-desktop-ungate.ps1 после обновления Codex Beta перестал запускаться: plugin list --json reports openai-bundled marketplace root does not contain a supported manifest."
contributor: "graphify"
outcome: "useful"
source_nodes: ["start-codex-desktop-ungate.ps1", "Initialize-CodexBetaPluginIsolation()", "Get-CodexPluginInventory()", "Invoke-BundledPluginReconciliation()"]
---

# Q: J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 после обновления Codex Beta перестал запускаться: plugin list --json reports openai-bundled marketplace root does not contain a supported manifest.

## Answer

Expanded from original query via graph vocab: [bundled, catalog, codex, command, config, desktop, marketplace, plugin, snapshot, start, script, ungate]. Root cause: the isolated config retained the removed Codex Beta 26.707.3351.0 openai-bundled marketplace path after Beta updated to 26.715.3651.0, so plugin list failed before reconciliation. The launcher now atomically refreshes the stale marketplace source before inventory and forces reconciliation. A second update regression blocked direct execution from WindowsApps; the launcher now falls back to Invoke-CommandInDesktopPackage and transfers CODEX_HOME/provider keys through a transient named pipe to a helper inside the MSIX package. Pester passed 14/14, plugin list and marketplace list succeeded, and two full launches started Beta with grok-4.5 and the isolated CODEX_HOME.

## Outcome

- Signal: useful

## Source Nodes

- start-codex-desktop-ungate.ps1
- Initialize-CodexBetaPluginIsolation()
- Get-CodexPluginInventory()
- Invoke-BundledPluginReconciliation()
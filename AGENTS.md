## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## ungate-api NSSM service

The `ungate-api` NSSM service runs `apps/api/bundle/main.cjs`. A normal API
`build` updates `dist/` only and does not update the running service artifact.

After changing API runtime code or anything bundled into it (including
`apps/api/src/**`, API dependencies/config, or shared packages imported by the
API), the agent must update the local service before finishing:

```powershell
pnpm --filter @ungate/api build
pnpm --filter @ungate/api build:bundle
nssm restart ungate-api
pwsh .\scripts\start-codex-ungate.ps1 -PreflightOnly
```

Run these commands sequentially. Restart the service only when both builds
succeed. Treat a failed restart or preflight as an unresolved task and report
it explicitly.

Do not rebuild or restart `ungate-api` for changes limited to tests,
documentation, graphify output, frontend code, or scripts that are not loaded
by the API process.

## CLIProxy namespace bridge

`scripts/cliproxy-namespace-bridge.mjs` is a local compatibility proxy for
CLIProxyAPI models, currently Grok 4.5. The Desktop launcher starts or reuses
it on port `8318`; it forwards to CLIProxyAPI on port `8317`.

Codex Responses sends MCP tools as `type: "namespace"`, while the CLIProxyAPI
upstream expects ordinary flat function tools. The bridge flattens namespace
tools, tool-call history, and tool choice on the request, then restores the
`namespace` and original tool name in JSON and SSE responses for Codex.

Do not use this bridge for direct Ungate models (`ungate-opus-4-8`,
`ungate-fable-5`, or `miniMax-M3`): they call `ungate-api` on port `47821`.
Their namespace-tool compatibility belongs in the API Responses route, not in
the CLIProxy bridge. After changing the bridge, run:

```powershell
pnpm --filter @ungate/scripts run bridge:test
```

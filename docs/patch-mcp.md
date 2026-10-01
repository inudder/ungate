# Ungate patch MCP

`scripts/ungate-patch-mcp.mjs` implements the transactional `ungate_patch`
MCP source editor used by Codex Beta. `working_directory` is absolute;
paths inside `patch` are relative to it. The entire patch is parsed and
prepared before any file changes. `dry_run: true` validates without writing.

## Building patches in exec

Every patch array entry must be a string. Diff markers belong inside its
quotes. For example, `"+];"` adds the line `];`, while `+"];"` applies
JavaScript unary plus to a string and produces the number `NaN`. Joining
the array then sends the text `NaN` to the MCP server; the original line
has already been lost. The same mistake affects `@@`, context and deletion
lines when an extra `+` is placed outside their quotes.

Use a checked string array instead of an interpolated template literal:

```javascript
const patchLines = [
  "*** Begin Patch",
  "*** Add File: relative/path.ts",
  "+export const values = [",
  "+];",
  "*** End Patch"
];
if (patchLines.some((line) => typeof line !== "string")) {
  throw new Error("Patch lines must all be strings");
}
const result = await tools.mcp__ungate_patch__apply_patch({
  working_directory: "J:/Dev/example",
  patch: patchLines.join("\n")
});
text(result);
```

An unprefixed `NaN` in an Add or Update body returns `invalid_patch`, the
one-based `error.line` in the normalized patch, and remediation explaining
numeric coercion. Rebuild all affected strings in the exec call and retry;
splitting the same corrupted array into smaller patches does not repair it.
The diagnostic is a likely cause, not automatic reconstruction of source.
Properly prefixed `+NaN`, `-NaN` and ` NaN` remain ordinary file content.

Other invalid body lines also return `error.line`. The MCP response does
not expose the offending source text, internal error details or hashes.
All parse failures leave every file in a multi-file patch unchanged.

## Validation and activation

```powershell
node --check scripts/ungate-patch-mcp.mjs
node --check scripts/ungate-patch-mcp.test.mjs
pnpm --filter @ungate/scripts run patch-mcp:test
```

The MCP server loads its module when its process starts. Existing Codex Beta
sessions retain the previous code and tool descriptions until their MCP
process restarts. Relaunch Beta through the Desktop launcher after active
work finishes to load the new diagnostics and schema descriptions.

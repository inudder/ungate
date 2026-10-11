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
lines when an extra `+` is placed outside their quotes. In recorded
sessions the plus slipped outside mostly on added lines whose text starts
with a backtick, `-`, `}`, `]`, `/` or a space, for example
`` +"`tsc` check" `` instead of `` "+`tsc` check" ``.

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
  patch: patchLines.join(String.fromCharCode(10))
});
text(JSON.stringify(result, null, 2));
```

An unprefixed `NaN` in an Add or Update body returns `invalid_patch`, the
one-based `error.line` in the normalized patch, and remediation explaining
numeric coercion. Rebuild all affected strings in the exec call and retry;
splitting the same corrupted array into smaller patches does not repair it.
The diagnostic is a likely cause, not automatic reconstruction of source.
Properly prefixed `+NaN`, `-NaN` and ` NaN` remain ordinary file content.

A patch sent as a JSON-stringified line array is joined. A patch that
arrived as one line with literal `\n` sequences returns `invalid_patch`
with an `escaped_newlines` remediation instead of the generic sentinel
error.

## Operation semantics

- An Update File must change at least one line. A context-only `@@`
  section, or an `@@ anchor` with no lines, only moves the search position
  for the hunks after it, as in Codex's native `apply_patch`. An Update
  File with no `-` or `+` line in any hunk returns `no_change_hunk`.
- `*** Delete File: path` followed by `*** Add File: path` replaces the
  file atomically and reports `operation: "replace"`. Add File alone never
  overwrites; it returns `target_exists` with that remediation.
- Several Update File sections for one path without Move to are applied in
  order; each searches from the top of the file.
- Missing parent directories of Add File and Move to targets are created
  inside `working_directory` and listed in `created_directories`. A failed
  commit removes the directories it created. An existing non-directory on
  the path returns `parent_not_directory`.
- Each line keeps its own terminator. A file that mixes CRLF and LF keeps
  both; inserted lines use the file's majority terminator. Lone CR is still
  rejected.

## Context matching

A hunk is first matched exactly. If that fails, three fallbacks are tried
in order. Each must match exactly one location after the current position;
an ambiguous fallback fails. Context lines always keep the live file text.

1. Trailing whitespace and Unicode dash, quote and space variants are
   ignored, as in native `apply_patch`.
2. Context lines may lack the leading marker space: an indented file line
   copied as is reads one space shallower than the file.
3. Every non-blank `-` and `+` line has a space after its marker, as in
   `- old` / `+ new`. That space is removed from the `+` lines.

A successful fallback adds a short line to the result's `adjustments`.

When no location matches, `hunk_not_found` names the patch line that
differs and quotes the live file line at the best partial match, or the
first line that does not occur in the file. It also reports a hunk that
matches only with different indentation, a match above the previous hunk,
and a context line repeated on both sides of the added lines.
`error.line` is the patch line. Messages quote at most one patch line and
one file line, truncated to 160 characters; `details`, hashes and the full
patch are never returned.

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

import assert from 'node:assert/strict';
import { lstat, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

import { PatchError, applyPatchTransaction, createPatchMcpServer, parsePatch, parseServerOptions } from './ungate-patch-mcp.mjs';

const UTF8_BOM = Buffer.from([0xef, 0xbb, 0xbf]);

async function temporaryDirectory(t) {
	const { mkdtemp } = await import('node:fs/promises');
	const root = await mkdtemp(join(tmpdir(), 'ungate-patch-'));
	t.after(() => rm(root, { force: true, recursive: true }));

	return root;
}

function unrestrictedOptions(overrides = {}) {
	return { allowRoots: ['*'], ...overrides };
}

function errorCode(expectedCode) {
	return (error) => error instanceof PatchError && error.code === expectedCode;
}

async function createInMemoryPatchClient(options) {
	const server = createPatchMcpServer(options);
	const client = new Client({ name: 'ungate-patch-test-client', version: '1.0.0' });
	const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
	await Promise.all([client.connect(clientTransport), server.connect(serverTransport)]);

	return { client, server };
}

test('parses the native-style patch operation family', () => {
	const operations = parsePatch(`*** Begin Patch
*** Add File: added.txt
+hello
*** Update File: source.txt
*** Move to: moved.txt
@@
-old
+new
*** Delete File: deleted.txt
*** End Patch`);

	assert.deepEqual(
		operations.map((operation) => ({
			kind: operation.kind,
			path: operation.path,
			movePath: operation.movePath ?? null
		})),
		[
			{ kind: 'add', path: 'added.txt', movePath: null },
			{ kind: 'update', path: 'source.txt', movePath: 'moved.txt' },
			{ kind: 'delete', path: 'deleted.txt', movePath: null }
		]
	);
});

test('accepts a BOM, Markdown fence, or patch XML envelope around a native patch', () => {
	const patch = `*** Begin Patch
*** Add File: added.txt
+hello
*** End Patch`;
	for (const wrappedPatch of [
		`\uFEFF${patch}`,
		`\n${patch}\n`,
		`\`\`\`patch
${patch}
\`\`\``,
		`<patch>
${patch}
</patch>`
	]) {
		assert.equal(parsePatch(wrappedPatch)[0].path, 'added.txt');
	}
});

test('applies add, multiple update hunks, delete, and move while preserving BOM and CRLF', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.txt'), Buffer.concat([UTF8_BOM, Buffer.from('one\r\ntwo\r\nthree\r\nfour\r\n')]));
	await writeFile(join(root, 'delete.txt'), 'remove me\n');
	await writeFile(join(root, 'move.txt'), 'old\n');

	const result = await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: `*** Begin Patch
*** Update File: source.txt
@@
 one
-two
+TWO
 three
@@
 three
-four
+FOUR
*** Add File: added.txt
+hello
+world
*** Delete File: delete.txt
*** Update File: move.txt
*** Move to: moved.txt
@@
-old
+new
*** End Patch`
		},
		unrestrictedOptions()
	);

	assert.equal(result.changed_files, 4);
	const sourceBuffer = await readFile(join(root, 'source.txt'));
	assert.equal(sourceBuffer.subarray(0, 3).equals(UTF8_BOM), true);
	assert.equal(sourceBuffer.subarray(3).toString('utf8'), 'one\r\nTWO\r\nthree\r\nFOUR\r\n');
	assert.equal(await readFile(join(root, 'added.txt'), 'utf8'), 'hello\nworld\n');
	await assert.rejects(readFile(join(root, 'delete.txt')), { code: 'ENOENT' });
	await assert.rejects(readFile(join(root, 'move.txt')), { code: 'ENOENT' });
	assert.equal(await readFile(join(root, 'moved.txt'), 'utf8'), 'new\n');
});

test('supports anchors and the end-of-file marker', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.txt'), 'header\nsection\nold\n');

	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: `*** Begin Patch
*** Update File: source.txt
@@ section
-old
+new
*** End of File
*** End Patch`
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'source.txt'), 'utf8'), 'header\nsection\nnew\n');
});

test('accepts patch sentinels decorated with trailing Markdown emphasis stars', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.txt'), 'old\n');

	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: `*** Begin Patch ***
*** Update File: source.txt
@@
-old
+new
*** End of File ***
*** End Patch ***`
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'source.txt'), 'utf8'), 'new\n');
});

test('dry_run validates and reports without writing files', async (t) => {
	const root = await temporaryDirectory(t);
	const patch = `*** Begin Patch
*** Add File: dry-run.txt
+not written
*** End Patch`;
	const result = await applyPatchTransaction({ workingDirectory: root, patch, dryRun: true }, unrestrictedOptions());

	assert.equal(result.dry_run, true);
	assert.deepEqual(result.operations, [{ operation: 'add', path: 'dry-run.txt' }]);
	await assert.rejects(readFile(join(root, 'dry-run.txt')), { code: 'ENOENT' });
});

test('rejects malformed patches and unmatched exact context', async (t) => {
	assert.throws(() => parsePatch('*** Begin Patch\n*** End Patch'), errorCode('invalid_patch'));
	assert.throws(
		() =>
			parsePatch(`*** Begin Patch
*** Update File: unchanged.txt
@@
 context only
*** End Patch`),
		errorCode('no_change_hunk')
	);
	assert.throws(
		() =>
			parsePatch(`*** Begin Patch
*** Replace File: wrong-header.txt
*** End Patch`),
		errorCode('invalid_patch_header')
	);
	assert.throws(
		() =>
			parsePatch(`*** Begin Patch
*** Add File: invalid.txt
missing-prefix
*** End Patch`),
		errorCode('invalid_patch')
	);

	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.txt'), 'actual\n');
	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: `*** Begin Patch
*** Update File: source.txt
@@
-expected
+replacement
*** End Patch`
			},
			unrestrictedOptions()
		),
		errorCode('hunk_not_found')
	);
});

test('rejects traversal, absolute paths, device paths, and alternate data streams', () => {
	for (const pathValue of ['../outside.txt', 'C:\\outside.txt', '\\\\.\\PhysicalDrive0', 'file.txt:stream']) {
		assert.throws(
			() =>
				parsePatch(`*** Begin Patch
*** Add File: ${pathValue}
+blocked
*** End Patch`),
			(error) =>
				error instanceof PatchError &&
				['absolute_path_rejected', 'device_path_rejected', 'invalid_path', 'path_traversal_rejected'].includes(error.code)
		);
	}
});

test('rejects binary, oversized, and existing move targets', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'binary.dat'), Buffer.from([0x61, 0x00, 0x62]));
	await writeFile(join(root, 'move.txt'), 'old\n');
	await writeFile(join(root, 'occupied.txt'), 'occupied\n');
	const binaryPatch = `*** Begin Patch
*** Update File: binary.dat
@@
-a
+b
*** End Patch`;
	await assert.rejects(
		applyPatchTransaction({ workingDirectory: root, patch: binaryPatch }, unrestrictedOptions()),
		errorCode('binary_file_rejected')
	);

	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: `*** Begin Patch
*** Update File: move.txt
*** Move to: occupied.txt
@@
-old
+new
*** End Patch`
			},
			unrestrictedOptions()
		),
		errorCode('target_exists')
	);

	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: `*** Begin Patch
*** Add File: too-large.txt
+1234567890
*** End Patch`
			},
			unrestrictedOptions({ maxFileBytes: 5 })
		),
		errorCode('file_too_large')
	);
});

test('rejects paths that pass through a junction', async (t) => {
	const root = await temporaryDirectory(t);
	const outside = await temporaryDirectory(t);
	const junctionPath = join(root, 'junction');
	try {
		await symlink(outside, junctionPath, 'junction');
	} catch (error) {
		t.skip(`Junction creation is unavailable: ${error.message}`);

		return;
	}

	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: `*** Begin Patch
*** Add File: junction/blocked.txt
+blocked
*** End Patch`
			},
			unrestrictedOptions()
		),
		errorCode('reparse_point_rejected')
	);
});

test('rolls back earlier writes when a later commit operation fails', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'existing.txt'), 'old\n');
	const patch = `*** Begin Patch
*** Add File: added.txt
+created
*** Update File: existing.txt
@@
-old
+new
*** End Patch`;

	await assert.rejects(
		applyPatchTransaction(
			{ workingDirectory: root, patch },
			unrestrictedOptions({
				testHooks: {
					beforeCommitOperation(index) {
						if (index === 1) {
							throw new Error('forced failure');
						}
					}
				}
			})
		),
		errorCode('commit_failed')
	);
	await assert.rejects(readFile(join(root, 'added.txt')), { code: 'ENOENT' });
	assert.equal(await readFile(join(root, 'existing.txt'), 'utf8'), 'old\n');
});

test('requires an explicit allow root and parses unrestricted server options', () => {
	assert.throws(() => parseServerOptions([]), errorCode('missing_allow_root'));
	assert.deepEqual(parseServerOptions(['--allow-root', '*']), {
		allowRoots: ['*'],
		maxFileBytes: 32 * 1024 * 1024,
		maxPatchBytes: 8 * 1024 * 1024
	});
});

test('exposes apply_patch through MCP tools/list and tools/call', async (t) => {
	const root = await temporaryDirectory(t);
	const { client, server } = await createInMemoryPatchClient(unrestrictedOptions());
	t.after(async () => {
		await Promise.allSettled([client.close(), server.close()]);
	});

	const inventory = await client.listTools();
	assert.equal(
		inventory.tools.some((tool) => tool.name === 'apply_patch'),
		true
	);
	const result = await client.callTool({
		name: 'apply_patch',
		arguments: {
			working_directory: root,
			patch: `*** Begin Patch
*** Add File: via-mcp.txt
+created by MCP
*** End Patch`
		}
	});

	assert.equal(result.isError, undefined);
	assert.deepEqual(JSON.parse(result.content[0].text), {
		ok: true,
		dry_run: false,
		operations: [{ operation: 'add', path: 'via-mcp.txt' }],
		changed_files: 1
	});
	assert.equal(await readFile(join(root, 'via-mcp.txt'), 'utf8'), 'created by MCP\n');
});

test('returns structured MCP errors without leaking patch content', async (t) => {
	const root = await temporaryDirectory(t);
	const { client, server } = await createInMemoryPatchClient(unrestrictedOptions());
	t.after(async () => {
		await Promise.allSettled([client.close(), server.close()]);
	});

	const result = await client.callTool({
		name: 'apply_patch',
		arguments: {
			working_directory: root,
			patch: `*** Begin Patch
*** Delete File: missing-secret-name.txt
*** End Patch`
		}
	});
	const payload = JSON.parse(result.content[0].text);

	assert.equal(result.isError, true);
	assert.equal(payload.ok, false);
	assert.equal(payload.error.code, 'file_not_found');
	assert.equal('details' in payload.error, false);
});

test('returns safe remediation for patch authoring errors', async (t) => {
	const root = await temporaryDirectory(t);
	const { client, server } = await createInMemoryPatchClient(unrestrictedOptions());
	t.after(async () => {
		await Promise.allSettled([client.close(), server.close()]);
	});

	await writeFile(join(root, 'source.txt'), 'actual\n');

	const cases = [
		{
			patch: `*** Begin Patch
*** Update File: source.txt
@@
-expected
+replacement
*** End Patch`,
			code: 'hunk_not_found',
			line: 4,
			remediation:
				'The message names the patch line that does not match the live file and quotes the file line found there. Fix the hunk from the live lines and retry this same apply_patch tool once.\n' +
				'Do not switch to native apply_patch, a different exec wrapper, or Shell. Do not reuse a hunk that already applied.\n' +
				'If exec output is empty (Wall time 0.0s), you forgot text(result); the UI result is authoritative.\n' +
				'Context before and after the + lines must be different file lines. Do not repeat the line you insert next to on both sides of the insertion.'
		},
		{
			patch: `*** Begin Patch
*** Update File: unchanged.txt
@@
 context only
*** End Patch`,
			code: 'no_change_hunk',
			remediation:
				"This Update File has no '-' or '+' line in any hunk. Add the intended change, or remove the unchanged operation. A context-only @@ section is allowed only next to hunks that change lines."
		},
		{
			patch: `*** Begin Patch
*** Replace File: wrong-header.txt
*** End Patch`,
			code: 'invalid_patch_header',
			remediation:
				'Use only the exact supported headers: *** Begin Patch, *** End Patch, *** Add File: path, *** Update File: path, *** Delete File: path, and *** Move to: path.\n' +
				'For Add File, copy this exact grammar and replace only the path and content:\n' +
				'*** Begin Patch\n' +
				'*** Add File: relative/path\n' +
				'+content\n' +
				'*** End Patch\n' +
				'There must be exactly one ASCII space after the colon. Every content line must start with a literal + in column 1. Do not add @@, indent the +, or escape it.\n' +
				'If validation returns invalid_patch for a missing +, rebuild the affected Add File body and call apply_patch again; do not use shell edits.\n' +
				'For Update File, copy this exact grammar and replace only the path and lines:\n' +
				'*** Begin Patch\n' +
				'*** Update File: relative/path\n' +
				'@@\n' +
				' unchanged context\n' +
				'-removed line\n' +
				'+added line\n' +
				'*** End Patch\n' +
				'Every hunk body line must start in column 1 with a space for context, - for deletion, or + for addition. Never emit a raw empty line inside a hunk: preserve an existing blank line as a line containing exactly one ASCII space, add a blank line as a line containing only +, and delete one as a line containing only -.' +
				'\n' +
				'The first character is the marker. After it, copy the exact file line including its indent; file indent is not the marker, so a copied indented line needs one extra leading space.'
		},
		{
			patch: `*** Begin Patch
*** Add File: missing-plus.txt
content without the required marker
*** End Patch`,
			code: 'invalid_patch',
			line: 3,
			remediation:
				'For Add File, copy this exact grammar and replace only the path and content:\n' +
				'*** Begin Patch\n' +
				'*** Add File: relative/path\n' +
				'+content\n' +
				'*** End Patch\n' +
				'There must be exactly one ASCII space after the colon. Every content line must start with a literal + in column 1. Do not add @@, indent the +, or escape it.\n' +
				'If validation returns invalid_patch for a missing +, rebuild the affected Add File body and call apply_patch again; do not use shell edits.'
		},
		{
			patch: `*** Begin Patch
*** Update File: missing-marker.txt
@@
 context before
invalid line without marker
+replacement
*** End Patch`,
			code: 'invalid_patch',
			line: 5,
			remediation:
				'For Update File, copy this exact grammar and replace only the path and lines:\n' +
				'*** Begin Patch\n' +
				'*** Update File: relative/path\n' +
				'@@\n' +
				' unchanged context\n' +
				'-removed line\n' +
				'+added line\n' +
				'*** End Patch\n' +
				'Every hunk body line must start in column 1 with a space for context, - for deletion, or + for addition. Never emit a raw empty line inside a hunk: preserve an existing blank line as a line containing exactly one ASCII space, add a blank line as a line containing only +, and delete one as a line containing only -.' +
				'\n' +
				'The first character is the marker. After it, copy the exact file line including its indent; file indent is not the marker, so a copied indented line needs one extra leading space.'
		}
	];

	for (const testCase of cases) {
		const result = await client.callTool({
			name: 'apply_patch',
			arguments: { working_directory: root, patch: testCase.patch }
		});
		const payload = JSON.parse(result.content[0].text);

		assert.equal(result.isError, true);
		assert.deepEqual(payload.error, {
			code: testCase.code,
			message: payload.error.message,
			...(testCase.line ? { line: testCase.line } : {}),
			remediation: testCase.remediation
		});
		assert.equal('details' in payload.error, false);
		assert.equal(payload.error.message.includes(testCase.patch), false);
	}
});

test('diagnoses unary plus in exec arrays without applying any part of the patch', async (t) => {
	const root = await temporaryDirectory(t);
	const { client, server } = await createInMemoryPatchClient(unrestrictedOptions());
	t.after(async () => {
		await Promise.allSettled([client.close(), server.close()]);
	});
	await writeFile(join(root, 'source.txt'), 'old\n');

	const cases = [
		{
			patch: [
				'*** Begin Patch',
				'*** Add File: earlier.txt',
				'+private-earlier-content',
				'*** Add File: users.ts',
				'+const users = [',
				+'];',
				'*** End Patch'
			].join('\n'),
			line: 6,
			operation: 'Add File'
		},
		{
			patch: [
				'*** Begin Patch',
				'*** Add File: earlier.txt',
				'+private-earlier-content',
				'*** Update File: source.txt',
				+'@@',
				+'-old',
				+'+private-new-content',
				'*** End Patch'
			].join('\n'),
			line: 5,
			operation: 'Update File'
		}
	];

	for (const testCase of cases) {
		const result = await client.callTool({
			name: 'apply_patch',
			arguments: { working_directory: root, patch: testCase.patch }
		});
		const payload = JSON.parse(result.content[0].text);

		assert.equal(result.isError, true);
		assert.equal(payload.ok, false);
		assert.equal(payload.error.code, 'invalid_patch');
		assert.equal(payload.error.line, testCase.line);
		assert.ok(payload.error.message.includes(testCase.operation));
		assert.match(payload.error.message, /bare NaN/);
		assert.match(payload.error.remediation, /unary \+ outside a JavaScript string/);
		assert.match(payload.error.remediation, /original line content was lost/);
		assert.match(payload.error.remediation, /Splitting the patch does not fix/);
		assert.match(payload.error.remediation, /typeof line !== "string"/);
		assert.equal('details' in payload.error, false);
		assert.doesNotMatch(result.content[0].text, /private-earlier-content|private-new-content/);
		assert.equal(await readFile(join(root, 'source.txt'), 'utf8'), 'old\n');
		await assert.rejects(readFile(join(root, 'earlier.txt')), { code: 'ENOENT' });
		await assert.rejects(readFile(join(root, 'users.ts')), { code: 'ENOENT' });
	}
});

test('accepts NaN as literal file content when patch markers are present', async (t) => {
	const root = await temporaryDirectory(t);
	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: ['*** Begin Patch', '*** Add File: values.txt', '+NaN', '+NaN', '*** End Patch'].join('\n')
		},
		unrestrictedOptions()
	);
	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: ['*** Begin Patch', '*** Update File: values.txt', '@@', ' NaN', '-NaN', '+Number.NaN', '*** End Patch'].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'values.txt'), 'utf8'), 'NaN\nNumber.NaN\n');
});

test('documents exact Add File and Update File grammar', async (t) => {
	const { client, server } = await createInMemoryPatchClient(unrestrictedOptions());
	t.after(async () => {
		await Promise.allSettled([client.close(), server.close()]);
	});

	const inventory = await client.listTools();
	const tool = inventory.tools.find((entry) => entry.name === 'apply_patch');
	assert.ok(tool);
	assert.match(tool.description, /Begin Patch/iu);
	assert.match(tool.description, /End Patch/iu);
	assert.match(tool.description, /\*\*\* Add File: relative\/path\n\+content/iu);
	assert.match(tool.description, /exactly one ASCII space after the colon/iu);
	assert.match(tool.description, /literal \+ in column 1/iu);
	assert.match(
		tool.description,
		/Every hunk body line must start in column 1 with a space for context, - for deletion, or \+ for addition/iu
	);
	assert.match(tool.description, /Never emit a raw empty line inside a hunk/iu);
	assert.match(tool.description, /at least one - or \+ line/iu);
	assert.match(tool.description, /Delete File: path followed by \*\*\* Add File: path/u);
	assert.match(tool.description, /String\.fromCharCode\(10\)/u);
	assert.match(tool.description, /exec template literal/iu);
	assert.match(tool.description, /\$\{\}/u);
	assert.match(tool.description, /text\(/u);
	assert.match(tool.description, /Put patch markers inside the quotes/);
	assert.match(tool.description, /Never write \+"\.\.\."/);
	assert.match(tool.description, /typeof line !== "string"/);
	assert.match(tool.description, /Required source-edit tool/iu);
	assert.doesNotMatch(tool.description, /when the native Codex apply_patch tool is unavailable/iu);
	assert.match(tool.inputSchema.properties.patch.description, /Every Update File needs at least one - or \+ line/u);
	assert.match(tool.inputSchema.properties.patch.description, /context-only @@ section between changing hunks only moves/u);
	assert.match(tool.inputSchema.properties.patch.description, /\*\*\* Add File: relative\/path\n\+content/iu);
	assert.match(tool.inputSchema.properties.patch.description, /\*\*\* Update File: relative\/path\n@@\n unchanged context/iu);
	assert.match(tool.inputSchema.properties.patch.description, /typeof line !== "string"/);
	assert.doesNotMatch(tool.description, /\*\*\* Begin Patch \*\*\*/u);
});

test('accepts raw empty lines in update hunks and add files gracefully', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'update.txt'), 'line 1\n\nline 3\n');

	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: `*** Begin Patch
*** Update File: update.txt
@@
 line 1

-line 3
+line THREE
*** Add File: added.txt
+item 1

+item 2
*** End Patch`
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'update.txt'), 'utf8'), 'line 1\n\nline THREE\n');
	assert.equal(await readFile(join(root, 'added.txt'), 'utf8'), 'item 1\n\nitem 2\n');
});

test('treats context-only and anchor-only sections as navigation between changing hunks', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.txt'), 'call(a)\nvalue = 1\ncall(a)\nvalue = 1\nclass Second\n  value = 1\n');

	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: [
				'*** Begin Patch',
				'*** Update File: source.txt',
				'@@',
				' call(a)',
				' value = 1',
				'@@',
				' call(a)',
				'-value = 1',
				'+value = 2',
				'@@ class Second',
				'@@',
				'-  value = 1',
				'+  value = 3',
				'*** End Patch'
			].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(
		await readFile(join(root, 'source.txt'), 'utf8'),
		'call(a)\nvalue = 1\ncall(a)\nvalue = 2\nclass Second\n  value = 3\n'
	);
});

test('repairs context lines that lost their marker space and keeps the file text', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.ps1'), 'function A {\n    $x = 1\n    return $x\n}\n');

	const result = await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: [
				'*** Begin Patch',
				'*** Update File: source.ps1',
				'@@',
				' function A {',
				'-    $x = 1',
				'+    $x = 2',
				'    return $x',
				'*** End Patch'
			].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'source.ps1'), 'utf8'), 'function A {\n    $x = 2\n    return $x\n}\n');
	assert.equal(result.adjustments.length, 1);
	assert.match(result.adjustments[0], /missing the marker space/u);
});

test('removes a consistent space written after every change marker', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'notes.md'), '# Notes\n\n- old item\n- keep\n');

	const result = await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: [
				'*** Begin Patch',
				'*** Update File: notes.md',
				'@@',
				' ',
				'- - old item',
				'+ - new item',
				'  - keep',
				'*** End Patch'
			].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'notes.md'), 'utf8'), '# Notes\n\n- new item\n- keep\n');
	assert.match(result.adjustments[0], /space after the marker/u);
});

test('matches trailing whitespace and typographic punctuation like native apply_patch', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.txt'), 'say(“hello”)   \nold — value\n');

	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: [
				'*** Begin Patch',
				'*** Update File: source.txt',
				'@@',
				' say("hello")',
				'-old - value',
				'+new value',
				'*** End Patch'
			].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'source.txt'), 'utf8'), 'say(“hello”)   \nnew value\n');
});

test('treats a context line repeated as the removed line as one removed line', async (t) => {
	const root = await temporaryDirectory(t);
	const source = [
		'import asyncio',
		'from datetime import datetime, timezone',
		'from typing import Any',
		'',
		'from app.database import get_db, get_frozen_hosts',
		'from app.ssh_config import get_hosts',
		''
	].join('\n');
	await writeFile(join(root, 'disk_usage.py'), source);

	// Recorded Grok hunk: the import it replaces is listed as context and then again as removed.
	const result = await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: [
				'*** Begin Patch',
				'*** Update File: disk_usage.py',
				'@@',
				' from datetime import datetime, timezone',
				'-from datetime import datetime, timezone',
				'+from datetime import datetime, timedelta, timezone',
				' from typing import Any',
				' ',
				'-from app.database import get_db, get_frozen_hosts',
				'+from app.database import get_db, get_frozen_hosts, is_host_frozen',
				' from app.ssh_config import get_hosts',
				'*** End Patch'
			].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(
		await readFile(join(root, 'disk_usage.py'), 'utf8'),
		[
			'import asyncio',
			'from datetime import datetime, timedelta, timezone',
			'from typing import Any',
			'',
			'from app.database import get_db, get_frozen_hosts, is_host_frozen',
			'from app.ssh_config import get_hosts',
			''
		].join('\n')
	);
	assert.equal(result.adjustments.length, 1);
	assert.match(result.adjustments[0], /repeated as the removed line/u);
});

test('keeps the repeated context line when the file repeats it, and refuses an ambiguous collapse', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'repeated.txt'), 'start\nvalue\nvalue\nend\n');

	const repeated = await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: ['*** Begin Patch', '*** Update File: repeated.txt', '@@', ' value', '-value', '+changed', '*** End Patch'].join(
				'\n'
			)
		},
		unrestrictedOptions()
	);
	assert.equal(await readFile(join(root, 'repeated.txt'), 'utf8'), 'start\nvalue\nchanged\nend\n');
	assert.equal('adjustments' in repeated, false);

	await writeFile(join(root, 'ambiguous.txt'), 'value\nother\nvalue\n');
	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: ['*** Begin Patch', '*** Update File: ambiguous.txt', '@@', ' value', '-value', '+changed', '*** End Patch'].join(
					'\n'
				)
			},
			unrestrictedOptions()
		),
		errorCode('hunk_not_found')
	);
	assert.equal(await readFile(join(root, 'ambiguous.txt'), 'utf8'), 'value\nother\nvalue\n');
});

test('refuses a whitespace-tolerant match that is not unique', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.txt'), 'value = 1 \nvalue = 1  \n');

	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: ['*** Begin Patch', '*** Update File: source.txt', '@@', '-value = 1', '+value = 2', '*** End Patch'].join('\n')
			},
			unrestrictedOptions()
		),
		(error) => error instanceof PatchError && error.code === 'hunk_not_found' && error.message.includes('several places')
	);
	assert.equal(await readFile(join(root, 'source.txt'), 'utf8'), 'value = 1 \nvalue = 1  \n');
});

test('names the first mismatching line and duplicated insertion context', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'source.ps1'), '}\n\nfunction Reset-Model {\n    param()\n}\n');

	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: [
					'*** Begin Patch',
					'*** Update File: source.ps1',
					'@@',
					' }',
					' ',
					' function Reset-Model {',
					'+function Update-Model {',
					'+}',
					'+',
					' function Reset-Model {',
					'*** End Patch'
				].join('\n')
			},
			unrestrictedOptions()
		),
		(error) =>
			error instanceof PatchError &&
			error.code === 'hunk_not_found' &&
			error.details.line === 10 &&
			error.message.includes('differs from file line 4 "    param()"') &&
			error.message.includes('appears both before and after the added lines')
	);

	await assert.rejects(
		applyPatchTransaction(
			{
				workingDirectory: root,
				patch: [
					'*** Begin Patch',
					'*** Update File: source.ps1',
					'@@',
					' function Reset-Model {',
					'-  param()',
					'+  param($Name)',
					'*** End Patch'
				].join('\n')
			},
			unrestrictedOptions()
		),
		(error) =>
			error instanceof PatchError && error.code === 'hunk_not_found' && error.message.includes('only when indentation is ignored')
	);
});

test('creates missing parent directories and removes them on rollback', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'existing.txt'), 'old\n');
	const patch = [
		'*** Begin Patch',
		'*** Add File: deep/nested/new.txt',
		'+created',
		'*** Update File: existing.txt',
		'@@',
		'-old',
		'+new',
		'*** End Patch'
	].join('\n');

	const dryRun = await applyPatchTransaction({ workingDirectory: root, patch, dryRun: true }, unrestrictedOptions());
	assert.deepEqual(dryRun.created_directories, ['deep', 'deep/nested']);
	await assert.rejects(lstat(join(root, 'deep')), { code: 'ENOENT' });

	await assert.rejects(
		applyPatchTransaction(
			{ workingDirectory: root, patch },
			unrestrictedOptions({
				testHooks: {
					beforeCommitOperation(index) {
						if (index === 1) {
							throw new Error('forced failure');
						}
					}
				}
			})
		),
		errorCode('commit_failed')
	);
	await assert.rejects(lstat(join(root, 'deep')), { code: 'ENOENT' });

	await applyPatchTransaction({ workingDirectory: root, patch }, unrestrictedOptions());
	assert.equal(await readFile(join(root, 'deep', 'nested', 'new.txt'), 'utf8'), 'created\n');

	await writeFile(join(root, 'blocker'), 'file\n');
	await assert.rejects(
		applyPatchTransaction(
			{ workingDirectory: root, patch: ['*** Begin Patch', '*** Add File: blocker/child.txt', '+x', '*** End Patch'].join('\n') },
			unrestrictedOptions()
		),
		errorCode('parent_not_directory')
	);
});

test('preserves each line ending in a file that mixes CRLF and LF', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'mixed.txt'), 'one\r\ntwo\nthree\r\nfour\r\n');

	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: [
				'*** Begin Patch',
				'*** Update File: mixed.txt',
				'@@',
				' two',
				'-three',
				'+THREE',
				'+inserted',
				'*** End Patch'
			].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'mixed.txt'), 'utf8'), 'one\r\ntwo\nTHREE\r\ninserted\r\nfour\r\n');
});

test('replaces a file atomically with Delete File followed by Add File', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'page.svelte'), 'old\n');

	await assert.rejects(
		applyPatchTransaction(
			{ workingDirectory: root, patch: ['*** Begin Patch', '*** Add File: page.svelte', '+new', '*** End Patch'].join('\n') },
			unrestrictedOptions()
		),
		(error) => error instanceof PatchError && error.code === 'target_exists' && error.details.operation === 'add'
	);

	const result = await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: ['*** Begin Patch', '*** Delete File: page.svelte', '*** Add File: page.svelte', '+new', '*** End Patch'].join('\n')
		},
		unrestrictedOptions()
	);

	assert.deepEqual(result.operations, [{ operation: 'replace', path: 'page.svelte' }]);
	assert.equal(await readFile(join(root, 'page.svelte'), 'utf8'), 'new\n');
	assert.throws(
		() => parsePatch(['*** Begin Patch', '*** Add File: a.txt', '+x', '*** Delete File: a.txt', '*** End Patch'].join('\n')),
		errorCode('path_conflict')
	);
});

test('applies repeated Update File sections for one path in order', async (t) => {
	const root = await temporaryDirectory(t);
	await writeFile(join(root, 'README.md'), 'alpha\nbeta\n');

	await applyPatchTransaction(
		{
			workingDirectory: root,
			patch: [
				'*** Begin Patch',
				'*** Update File: README.md',
				'@@',
				'-beta',
				'+BETA',
				'*** Update File: README.md',
				'@@',
				'-alpha',
				'+ALPHA',
				'*** End Patch'
			].join('\n')
		},
		unrestrictedOptions()
	);

	assert.equal(await readFile(join(root, 'README.md'), 'utf8'), 'ALPHA\nBETA\n');
});

test('joins a JSON line array and explains literal backslash-n patches', () => {
	const lines = ['*** Begin Patch', '*** Add File: a.txt', '+x', '*** End Patch'];
	assert.equal(parsePatch(JSON.stringify(lines))[0].path, 'a.txt');
	assert.throws(
		() => parsePatch(lines.join('\\n')),
		(error) => error instanceof PatchError && error.code === 'invalid_patch' && error.details.reason === 'escaped_newlines'
	);
});

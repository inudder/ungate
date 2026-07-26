import assert from 'node:assert/strict';
import { readFile, rm, symlink, writeFile } from 'node:fs/promises';
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

	const cases = [
		{
			patch: `*** Begin Patch
*** Update File: unchanged.txt
@@
 context only
*** End Patch`,
			code: 'no_change_hunk',
			remediation: "Add at least one '-' or '+' line to every Update File hunk, or remove the unchanged operation."
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
				'For Update File, copy this exact grammar and replace only the path and lines:\n' +
				'*** Begin Patch\n' +
				'*** Update File: relative/path\n' +
				'@@\n' +
				' unchanged context\n' +
				'-removed line\n' +
				'+added line\n' +
				'*** End Patch\n' +
				'Every hunk body line must start in column 1 with a space for context, - for deletion, or + for addition. Never emit a raw empty line inside a hunk: preserve an existing blank line as a line containing exactly one ASCII space, add a blank line as a line containing only +, and delete one as a line containing only -.'
		},
		{
			patch: `*** Begin Patch
*** Add File: missing-plus.txt
content without the required marker
*** End Patch`,
			code: 'invalid_patch',
			remediation:
				'For Add File, copy this exact grammar and replace only the path and content:\n' +
				'*** Begin Patch\n' +
				'*** Add File: relative/path\n' +
				'+content\n' +
				'*** End Patch\n' +
				'There must be exactly one ASCII space after the colon. Every content line must start with a literal + in column 1. Do not add @@, indent the +, or escape it.'
		},
		{
			patch: `*** Begin Patch
*** Update File: missing-marker.txt
@@
 context before

+replacement
*** End Patch`,
			code: 'invalid_patch',
			remediation:
				'For Update File, copy this exact grammar and replace only the path and lines:\n' +
				'*** Begin Patch\n' +
				'*** Update File: relative/path\n' +
				'@@\n' +
				' unchanged context\n' +
				'-removed line\n' +
				'+added line\n' +
				'*** End Patch\n' +
				'Every hunk body line must start in column 1 with a space for context, - for deletion, or + for addition. Never emit a raw empty line inside a hunk: preserve an existing blank line as a line containing exactly one ASCII space, add a blank line as a line containing only +, and delete one as a line containing only -.'
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
			remediation: testCase.remediation
		});
		assert.equal('details' in payload.error, false);
		assert.equal(payload.error.message.includes(testCase.patch), false);
	}
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
	assert.match(
		tool.inputSchema.properties.patch.description,
		/context-only hunks? are invalid|each Update File hunk must include at least one - or \+ line/iu
	);
	assert.match(tool.inputSchema.properties.patch.description, /\*\*\* Add File: relative\/path\n\+content/iu);
	assert.match(tool.inputSchema.properties.patch.description, /\*\*\* Update File: relative\/path\n@@\n unchanged context/iu);
	assert.doesNotMatch(tool.description, /\*\*\* Begin Patch \*\*\*/u);
});

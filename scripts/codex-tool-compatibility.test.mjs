import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { createShellRouterServer } from './codex-model-shell-router.mjs';
import { classifyError, individualTools, probeSchema, reportExitCode, runCompatibility } from './codex-tool-compatibility.mjs';
import { createToolsCacheWriter, readToolsSnapshot } from './codex-tools-schema-cache.mjs';

const tools = [
	{ type: 'function', name: 'shell_command', parameters: { type: 'object', properties: { command: { type: 'string' } } } },
	{ type: 'custom', name: 'apply_patch', format: { type: 'text' } },
	{
		type: 'namespace',
		name: 'mcp__example',
		description: 'Keep namespace metadata',
		tools: [
			{ type: 'function', name: 'lookup', parameters: { type: 'object' } },
			{ type: 'function', name: 'read', parameters: { type: 'object' } }
		]
	}
];

async function temporary(t) {
	const directory = await mkdtemp(path.join(os.tmpdir(), 'codex-tools-'));
	t.after(() => rm(directory, { recursive: true, force: true }));

	return directory;
}

async function serve(t, handler) {
	const server = typeof handler === 'function' ? http.createServer(handler) : handler;
	await new Promise((resolve) => server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve));
	t.after(
		() =>
			new Promise((resolve) => {
				server.close(resolve);
				server.closeAllConnections();
			})
	);

	return `http://127.0.0.1:${server.address().port}`;
}

function completed(response) {
	response.writeHead(200, { 'content-type': 'text/event-stream' });
	response.end('data: {"type":"response.completed","response":{"id":"r_test","status":"completed","output":[]}}\n\n');
}

test('snapshot preserves original namespace/custom schemas and no request content', async (t) => {
	const directory = await temporary(t);
	const filename = path.join(directory, 'cache.json');
	const copy = structuredClone(tools);
	const save = createToolsCacheWriter(filename);
	const saving = save(copy, 'source-model');
	copy[0].name = 'mutated';
	await saving;
	await save([], 'ignored');
	const snapshot = await readToolsSnapshot(filename);
	assert.deepEqual(snapshot.tools, tools);
	assert.deepEqual(Object.keys(snapshot).sort(), ['version', 'capturedAt', 'sourceModel', 'schemaHash', 'tools'].sort());
	assert.deepEqual(await readdir(directory), ['cache.json']);
	snapshot.tools[0].name = 'tampered';
	await writeFile(filename, JSON.stringify(snapshot));
	await assert.rejects(readToolsSnapshot(filename), /checksum/);
});

test('router captures before Mimo flattening and tolerates cache write failure', async (t) => {
	const directory = await temporary(t);
	const filename = path.join(directory, 'cache.json');
	let received;
	const upstream = await serve(t, async (request, response) => {
		let body = '';
		for await (const chunk of request) body += chunk;
		received = JSON.parse(body);
		response.writeHead(200, { 'content-type': 'application/json' });
		response.end('{"id":"r_test","output":[]}');
	});
	const router = await serve(
		t,
		createShellRouterServer({
			toolsCachePath: filename,
			routes: [
				{
					clientModel: 'shell',
					upstreamModel: 'mimo',
					upstreamBaseUrl: upstream,
					apiKey: 'secret',
					responsesAdapter: 'mimo-textual-tools'
				}
			]
		})
	);
	const request = () =>
		fetch(`${router}/v1/responses`, {
			method: 'POST',
			body: JSON.stringify({ model: 'shell', tools, input: 'PRIVATE TEXT', stream: false })
		});
	const routerResponse = await request();
	assert.equal(routerResponse.status, 200);
	for (let count = 0; count < 100; count++) {
		try {
			await readToolsSnapshot(filename);
			break;
		} catch {
			await new Promise((resolve) => setTimeout(resolve, 10));
		}
	}
	const cachedSnapshot = await readToolsSnapshot(filename);
	assert.deepEqual(cachedSnapshot.tools, tools);
	assert.ok(received.tools.every((tool) => tool.type !== 'namespace'));
	assert.doesNotMatch(await readFile(filename, 'utf8'), /PRIVATE TEXT|secret/);
	await rm(filename);
	await writeFile(path.join(directory, 'block'), 'file');
	const failedRouter = await serve(
		t,
		createShellRouterServer({
			toolsCachePath: path.join(directory, 'block', 'cache.json'),
			routes: [{ clientModel: 'shell', upstreamModel: 'model', upstreamBaseUrl: upstream, apiKey: 'secret' }]
		})
	);
	const failedCacheResponse = await fetch(`${failedRouter}/v1/responses`, {
		method: 'POST',
		body: JSON.stringify({ model: 'shell', tools })
	});
	assert.equal(failedCacheResponse.status, 200);
});

test('individual checks keep namespace wrappers and custom formats', () => {
	const checks = individualTools(tools);
	assert.deepEqual(
		checks.map((check) => check.name),
		['shell_command', 'apply_patch', 'mcp__example.lookup', 'mcp__example.read']
	);
	assert.equal(checks[2].tools[0].description, tools[2].description);
	assert.deepEqual(checks[2].tools[0].tools, [tools[2].tools[0]]);
	assert.deepEqual(checks[1].tools, [tools[1]]);
});

test('classification distinguishes schema rejection from auth/rate/general errors', () => {
	assert.equal(classifyError(400, { message: 'Invalid schema for tool shell_command' }).status, 'schema_rejected');
	assert.equal(classifyError(400, { code: 'invalid_function_parameters' }).status, 'schema_rejected');
	assert.equal(
		classifyError(400, { message: "Mimo flattened tool name 'mcp_lookup' collides with another tool" }).status,
		'schema_rejected'
	);
	for (const status of [401, 403, 429, 500, 504]) {
		assert.equal(classifyError(status, { message: 'Invalid tool schema' }).status, 'provider_error');
	}
	assert.equal(classifyError(400, { message: 'Invalid model' }).status, 'provider_error');
	assert.equal(
		classifyError(200, { code: 'authentication_error', message: 'Invalid key for tool schema endpoint' }).status,
		'provider_error'
	);
	assert.equal(classifyError(400, { message: 'Unsupported tool_choice: none', param: 'tool_choice' }).status, 'provider_error');
});

test('SSE requires terminal response and sees errors despite HTTP 200', async (t) => {
	const cases = [
		[': heartbeat\n\n', 'invalid_response'],
		['data: {"type":"response.created"}\n\n', 'invalid_response'],
		['data: {"type":"response.completed"}\n\n', 'invalid_response'],
		['data: [DONE]\n\n', 'invalid_response'],
		['data: broken\n\n', 'invalid_response'],
		[
			'data: {"type":"response.failed","response":{"error":{"message":"Unsupported namespace tool schema"}}}\n\n',
			'schema_rejected'
		],
		['data: {"type":"error","error":{"message":"Rate limit exceeded"}}\n\n', 'provider_error'],
		['data: {"type":"response.completed","response":{"status":"completed"}}\r\n\r\n', 'accepted'],
		['data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}\n\n', 'accepted']
	];
	for (const [body, expected] of cases) {
		const base = await serve(t, (_request, response) => {
			response.writeHead(200, { 'content-type': 'text/event-stream' });
			response.end(body);
		});
		const result = await probeSchema(base, 'test', tools);
		assert.equal(result.status, expected, body);
	}
	const json = await serve(t, (_request, response) => {
		response.writeHead(200, { 'content-type': 'application/json' });
		response.end('{}');
	});
	const jsonResult = await probeSchema(json, 'test', tools);
	assert.equal(jsonResult.status, 'invalid_response');
});

test('timeout and cancellation never claim schema compatibility', async (t) => {
	const base = await serve(t, (_request, response) => {
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		response.write(': ping\n\n');
	});
	const timedOut = await probeSchema(base, 'test', tools, { timeoutMs: 30 });
	const cancelled = await probeSchema(base, 'test', tools, { signal: AbortSignal.abort() });
	assert.equal(timedOut.status, 'timeout');
	assert.equal(cancelled.status, 'cancelled');
});

test('run freezes snapshot, covers direct/bridge/Mimo routes, disables tool use and closes listeners', async (t) => {
	const directory = await temporary(t);
	const cachePath = path.join(directory, 'cache.json');
	await createToolsCacheWriter(cachePath)(tools, 'real-model');
	const originalSnapshot = await readToolsSnapshot(cachePath);
	const bodies = [];
	const upstream = await serve(t, async (request, response) => {
		let raw = '';
		for await (const chunk of request) raw += chunk;
		bodies.push(JSON.parse(raw));
		if (bodies.length === 1) await createToolsCacheWriter(cachePath)([tools[0]], 'newer-source');
		completed(response);
	});
	const models = [
		{ model: 'direct', upstreamBaseUrl: upstream },
		{ model: 'bridge', upstreamBaseUrl: 'unused', bridgeUpstreamUrl: upstream },
		{ model: 'mimo', upstreamBaseUrl: upstream, responsesAdapter: 'mimo-textual-tools' }
	].map((model) => ({ ...model, displayName: model.model, apiKey: 'private-key' }));
	const logs = [];
	const result = await runCompatibility({ cachePath, reportDirectory: directory, models }, { log: (value) => logs.push(value) });
	assert.equal(result.exitCode, 0);
	assert.equal(result.report.models.length, 3);
	assert.equal(result.report.snapshot.schemaHash, originalSnapshot.schemaHash);
	assert.equal(bodies.length, 18);
	assert.ok(bodies.every((body) => body.stream === true && (!body.tools || body.tool_choice === 'none')));
	assert.ok(
		bodies.filter((body) => body.model === 'mimo').every((body) => !body.tools?.some((tool) => tool.type === 'namespace'))
	);
	const reportContent = await readFile(result.reportPath, 'utf8');
	assert.equal(JSON.parse(reportContent).exitCode, 0);
	assert.doesNotMatch(await readFile(result.reportPath, 'utf8'), /private-key/);
	assert.doesNotMatch(logs.join('\n'), /private-key/);
});

test('failed control skips tool requests; cancellation saves partial report; technical errors win', async (t) => {
	const directory = await temporary(t);
	const cachePath = path.join(directory, 'cache.json');
	await createToolsCacheWriter(cachePath)(tools, 'source');
	let requests = 0;
	const upstream = await serve(t, (_request, response) => {
		requests++;
		response.writeHead(401, { 'content-type': 'application/json' });
		response.end('{"error":{"message":"Invalid key private-key"}}');
	});
	const config = {
		cachePath,
		reportDirectory: directory,
		models: [{ model: 'model', displayName: 'model', apiKey: 'private-key', upstreamBaseUrl: upstream }]
	};
	const result = await runCompatibility(config, { log: () => {} });
	assert.equal(result.exitCode, 2);
	assert.equal(requests, 1);
	assert.equal(result.report.models[0].checks.length, 1);
	assert.doesNotMatch(await readFile(result.reportPath, 'utf8'), /private-key/);
	const cancelled = await runCompatibility(config, { signal: AbortSignal.abort(), log: () => {} });
	assert.equal(cancelled.exitCode, 2);
	const cancelledContent = await readFile(cancelled.reportPath, 'utf8');
	assert.equal(JSON.parse(cancelledContent).cancelled, true);
	assert.equal(reportExitCode({ models: [{ checks: [{ status: 'schema_rejected' }] }] }), 1);
	assert.equal(reportExitCode({ models: [{ checks: [{ status: 'schema_rejected' }, { status: 'timeout' }] }] }), 2);
});

test('cancellation and timeouts close upstream connections through router and bridge', async (t) => {
	const directory = await temporary(t);
	const cachePath = path.join(directory, 'cache.json');
	await createToolsCacheWriter(cachePath)(tools, 'source');
	for (const bridge of [false, true]) {
		const controller = new AbortController();
		let disconnected;
		const closed = new Promise((resolve) => {
			disconnected = resolve;
		});
		const upstream = await serve(t, (_request, response) => {
			response.once('close', disconnected);
			response.writeHead(200, { 'content-type': 'text/event-stream' });
			response.write(': ping\n\n');
			if (bridge) setTimeout(() => controller.abort(), 20);
		});
		const result = await runCompatibility(
			{
				cachePath,
				reportDirectory: directory,
				models: [
					{
						model: 'test',
						displayName: 'test',
						apiKey: 'test-key',
						upstreamBaseUrl: upstream,
						bridgeUpstreamUrl: bridge ? upstream : null
					}
				]
			},
			{ signal: controller.signal, timeoutMs: 100, log: () => {} }
		);
		assert.equal(result.exitCode, 2);
		assert.equal(result.report.models[0].checks[0].status, bridge ? 'cancelled' : 'timeout');
		await Promise.race([
			closed,
			new Promise((_resolve, reject) => {
				const timer = setTimeout(() => reject(new Error('Upstream socket was not closed')), 1000);
				timer.unref();
			})
		]);
	}
});

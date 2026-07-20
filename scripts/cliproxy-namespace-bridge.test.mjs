import assert from 'node:assert/strict';
import http from 'node:http';
import { Readable } from 'node:stream';
import test from 'node:test';

import {
	canonicalizeArguments,
	createBridgeServer,
	createSseTransform,
	flattenResponsesRequest,
	rewriteResponseForCodex
} from './cliproxy-namespace-bridge.mjs';

function namespaceTool(namespace, name, schema = { type: 'object', properties: {} }) {
	return {
		type: 'namespace',
		name: namespace,
		tools: [{ type: 'function', name, description: `${name} tool`, inputSchema: schema }]
	};
}

function listen(server) {
	return new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => {
			server.removeListener('error', reject);
			resolve(server.address().port);
		});
	});
}

function close(server) {
	return new Promise((resolveClose) => {
		server.closeAllConnections?.();
		server.close(() => resolveClose());
	});
}

async function readRequestBody(request) {
	const chunks = [];
	for await (const chunk of request) {
		chunks.push(chunk);
	}

	return Buffer.concat(chunks).toString('utf8');
}

function withTimeout(promise, timeoutMs = 2_000) {
	return Promise.race([
		promise,
		new Promise((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error(`Timed out after ${timeoutMs}ms`)), timeoutMs);
			timer.unref();
		})
	]);
}

test('flattens namespace tools, history, schemas, and tool choice', () => {
	const request = {
		model: 'grok-4.5',
		tools: [
			namespaceTool('mcp__node_repl', 'js', {
				type: 'object',
				properties: { code: { type: 'string' } },
				required: ['code']
			}),
			{ type: 'function', name: 'ordinary', parameters: { type: 'object' } }
		],
		input: [
			{
				type: 'function_call',
				call_id: 'call_1',
				name: 'js',
				namespace: 'mcp__node_repl',
				arguments: '{"code":"1+1"}'
			}
		],
		tool_choice: { type: 'function', name: 'js', namespace: 'mcp__node_repl' }
	};

	const { body, mapping } = flattenResponsesRequest(request);

	assert.deepEqual(body.tools[0], {
		type: 'function',
		name: 'mcp__node_repl__js',
		description: 'js tool',
		parameters: {
			type: 'object',
			properties: { code: { type: 'string' } },
			required: ['code']
		}
	});
	assert.equal(body.tools[1].name, 'ordinary');
	assert.equal(body.input[0].name, 'mcp__node_repl__js');
	assert.equal('namespace' in body.input[0], false);
	assert.deepEqual(body.tool_choice, { type: 'function', name: 'mcp__node_repl__js' });
	assert.deepEqual(mapping.fullToOriginal.get('mcp__node_repl__js'), {
		namespace: 'mcp__node_repl',
		name: 'js'
	});
});

test('restores full and unique bare names but leaves ambiguous bare names untouched', () => {
	const unique = flattenResponsesRequest({ tools: [namespaceTool('mcp__node_repl', 'js')] }).mapping;
	const restoredFull = rewriteResponseForCodex(
		{ type: 'function_call', name: 'mcp__node_repl__js', arguments: '{"timeout":16185.0}' },
		unique
	);
	const restoredBare = rewriteResponseForCodex({ type: 'function_call', name: 'js', arguments: '{"timeout":16185.0}' }, unique);

	assert.deepEqual(restoredFull, {
		type: 'function_call',
		name: 'js',
		namespace: 'mcp__node_repl',
		arguments: '{"timeout":16185}'
	});
	assert.deepEqual(restoredBare, restoredFull);

	const ambiguous = flattenResponsesRequest({
		tools: [namespaceTool('mcp__one', 'js'), namespaceTool('mcp__two', 'js')]
	}).mapping;
	assert.deepEqual(rewriteResponseForCodex({ type: 'function_call', name: 'js', arguments: '{}' }, ambiguous), {
		type: 'function_call',
		name: 'js',
		arguments: '{}'
	});
});

test('rejects flattened name collisions', () => {
	assert.throws(
		() =>
			flattenResponsesRequest({
				tools: [namespaceTool('mcp__node_repl', 'js'), { type: 'function', name: 'mcp__node_repl__js' }]
			}),
		(error) => error.statusCode === 400 && error.code === 'tool_name_collision'
	);
});

test('canonicalizes complete argument JSON without changing malformed fragments', () => {
	assert.equal(canonicalizeArguments('{"timeout":42.0,"ratio":1.25}'), '{"timeout":42,"ratio":1.25}');
	assert.equal(canonicalizeArguments('{"incomplete":'), '{"incomplete":');
	assert.equal(
		rewriteResponseForCodex(
			{ type: 'response.function_call_arguments.done', arguments: '{"timeout":42.0}' },
			{ fullToOriginal: new Map(), uniqueBareToOriginal: new Map() }
		).arguments,
		'{"timeout":42}'
	);
});

test('rewrites fragmented UTF-8 SSE events and preserves non-JSON events', async () => {
	const mapping = flattenResponsesRequest({ tools: [namespaceTool('mcp__node_repl', 'js')] }).mapping;
	const event =
		'event: response.output_item.done\r\n' +
		'data: {"type":"response.output_item.done","item":{"type":"function_call","name":"js","arguments":"{\\"timeout\\":15.0,\\"note\\":\\"check ✓\\"}"}}\r\n\r\n' +
		'data: [DONE]\r\n\r\n';
	const bytes = Buffer.from(event);
	const utf8Start = bytes.indexOf(Buffer.from('✓'));
	const chunks = [bytes.subarray(0, 13), bytes.subarray(13, utf8Start + 1), bytes.subarray(utf8Start + 1)];
	const transformed = Readable.from(chunks).pipe(createSseTransform(mapping));
	let output = '';
	for await (const chunk of transformed) {
		output += chunk.toString('utf8');
	}

	assert.match(output, /"name":"js","arguments":"\{\\"timeout\\":15,\\"note\\":\\"check ✓\\"\}","namespace":"mcp__node_repl"/u);
	assert.match(output, /data: \[DONE\]/u);
});

test('proxies JSON Responses and passthrough routes end to end', async (t) => {
	let capturedResponseRequest;
	let capturedAuthorization;
	const upstream = http.createServer(async (request, response) => {
		capturedAuthorization = request.headers.authorization;
		if (request.url === '/v1/models') {
			response.writeHead(207, { 'content-type': 'application/json', 'x-upstream': 'models' });
			response.end('{"data":[{"id":"grok-4.5"}]}');

			return;
		}
		const requestBody = await readRequestBody(request);
		capturedResponseRequest = JSON.parse(requestBody);
		response.writeHead(200, { 'content-type': 'application/json' });
		response.end(
			JSON.stringify({
				output: [{ type: 'function_call', name: 'mcp__node_repl__js', arguments: '{"timeout":9.0}' }]
			})
		);
	});
	const upstreamPort = await listen(upstream);
	const bridge = createBridgeServer({ upstreamUrl: `http://127.0.0.1:${upstreamPort}`, buildId: 'test' });
	const bridgePort = await listen(bridge);
	t.after(async () => {
		await close(bridge);
		await close(upstream);
	});

	const response = await fetch(`http://127.0.0.1:${bridgePort}/v1/responses`, {
		method: 'POST',
		headers: { authorization: 'Bearer secret', 'content-type': 'application/json' },
		body: JSON.stringify({
			model: 'grok-4.5',
			input: 'run it',
			tools: [namespaceTool('mcp__node_repl', 'js')]
		})
	});
	const result = await response.json();

	assert.equal(capturedAuthorization, 'Bearer secret');
	assert.equal(capturedResponseRequest.tools[0].name, 'mcp__node_repl__js');
	assert.deepEqual(result.output[0], {
		type: 'function_call',
		name: 'js',
		namespace: 'mcp__node_repl',
		arguments: '{"timeout":9}'
	});

	const modelsResponse = await fetch(`http://127.0.0.1:${bridgePort}/v1/models`, {
		headers: { authorization: 'Bearer secret' }
	});
	assert.equal(modelsResponse.status, 207);
	assert.equal(modelsResponse.headers.get('x-upstream'), 'models');
	assert.equal(await modelsResponse.text(), '{"data":[{"id":"grok-4.5"}]}');
});

test('rewrites streaming Responses end to end', async (t) => {
	const upstream = http.createServer(async (request, response) => {
		await readRequestBody(request);
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		response.write('event: response.output_item.added\n');
		response.write(
			'data: {"type":"response.output_item.added","item":{"type":"function_call","name":"browser_navigate","arguments":"{\\"timeout\\":20.0}"}}\n\n'
		);
		response.end('data: [DONE]\n\n');
	});
	const upstreamPort = await listen(upstream);
	const bridge = createBridgeServer({ upstreamUrl: `http://127.0.0.1:${upstreamPort}`, buildId: 'test' });
	const bridgePort = await listen(bridge);
	t.after(async () => {
		await close(bridge);
		await close(upstream);
	});

	const response = await fetch(`http://127.0.0.1:${bridgePort}/v1/responses`, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({
			stream: true,
			tools: [namespaceTool('mcp__browser', 'browser_navigate')]
		})
	});
	const output = await response.text();

	assert.match(output, /"name":"browser_navigate"/u);
	assert.match(output, /"namespace":"mcp__browser"/u);
	assert.match(output, /"timeout\\":20\}/u);
});

test('aborts the upstream response when the downstream client disconnects', async (t) => {
	let markUpstreamStarted;
	const upstreamStarted = new Promise((resolveStarted) => {
		markUpstreamStarted = resolveStarted;
	});
	let markBridgeAborted;
	const bridgeAborted = new Promise((resolveAborted) => {
		markBridgeAborted = resolveAborted;
	});
	const upstream = http.createServer(async (request, _response) => {
		await readRequestBody(request);
		markUpstreamStarted();
	});
	const upstreamPort = await listen(upstream);
	const bridge = createBridgeServer({
		upstreamUrl: `http://127.0.0.1:${upstreamPort}`,
		buildId: 'test',
		onUpstreamAbort: markBridgeAborted
	});
	const bridgePort = await listen(bridge);
	t.after(async () => {
		await close(bridge);
		await close(upstream);
	});

	const requestBody = JSON.stringify({ model: 'grok-4.5', input: 'wait', tools: [] });
	let downstreamSocket;
	const clientRequest = http.request({
		host: '127.0.0.1',
		port: bridgePort,
		path: '/v1/responses',
		method: 'POST',
		headers: {
			'content-type': 'application/json',
			'content-length': Buffer.byteLength(requestBody)
		}
	});
	clientRequest.on('error', () => {});
	clientRequest.on('socket', (socket) => {
		downstreamSocket = socket;
	});
	clientRequest.end(requestBody);

	await withTimeout(upstreamStarted);
	downstreamSocket.destroy();
	await withTimeout(bridgeAborted);
});

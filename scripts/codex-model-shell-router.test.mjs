import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';

import { createShellRouterServer } from './codex-model-shell-router.mjs';

function listen(server) {
	return new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => resolve(server.address().port));
	});
}

function close(server) {
	return new Promise((resolve, reject) =>
		server.close((error) => {
			if (error) {
				reject(error instanceof Error ? error : new Error('Server close failed.'));

				return;
			}
			resolve();
		})
	);
}

function sse(type, data) {
	return `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
}

test('lists shells and rewrites a Responses request to its upstream model', async () => {
	let upstreamRequest;
	const upstream = http.createServer(async (request, response) => {
		const chunks = [];
		for await (const chunk of request) {
			chunks.push(chunk);
		}
		upstreamRequest = {
			authorization: request.headers.authorization,
			body: JSON.parse(Buffer.concat(chunks).toString('utf8'))
		};
		const payload = JSON.stringify({ object: 'response', output: [] });
		response.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
		response.end(payload);
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		buildId: 'test-build',
		routes: [
			{
				clientModel: 'gpt-5.6-sol',
				upstreamModel: 'ungate-opus-4-8',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const modelsResponse = await fetch(`http://127.0.0.1:${routerPort}/v1/models`);
		assert.equal(modelsResponse.status, 200);
		const models = await modelsResponse.json();
		assert.deepEqual(
			models.data.map((model) => model.id),
			['gpt-5.6-sol']
		);

		const response = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { authorization: 'Bearer client-key', 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'gpt-5.6-sol', input: 'ping', stream: false })
		});
		assert.equal(response.status, 200);
		assert.deepEqual(await response.json(), { object: 'response', output: [] });
		assert.equal(upstreamRequest.authorization, 'Bearer target-key');
		assert.equal(upstreamRequest.body.model, 'ungate-opus-4-8');
	} finally {
		await close(router);
		await close(upstream);
	}
});

test('preserves streaming upstream responses and rejects unmapped models', async () => {
	const upstream = http.createServer((_request, response) => {
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		response.end('event: response.completed\ndata: {"type":"response.completed"}\n\n');
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		routes: [
			{
				clientModel: 'gpt-5.6-terra',
				upstreamModel: 'grok-4.6',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const streamingResponse = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'gpt-5.6-terra', stream: true })
		});
		assert.equal(streamingResponse.status, 200);
		assert.match(await streamingResponse.text(), /response.completed/);

		const unknownResponse = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'not-a-shell' })
		});
		assert.equal(unknownResponse.status, 400);
		const unknownPayload = await unknownResponse.json();
		assert.equal(unknownPayload.error.code, 'unknown_model_shell');
	} finally {
		await close(router);
		await close(upstream);
	}
});

test('applies the Mimo adapter only to its streaming Responses route', async () => {
	let upstreamBody;
	const patch = '*** Begin Patch\n*** Add File: router-created.txt\n+hello\n*** End Patch';
	const markup = `<tool_call><function=apply_patch><parameter=${patch}</parameter></function></tool_call>`;
	const upstream = http.createServer(async (request, response) => {
		const chunks = [];
		for await (const chunk of request) chunks.push(chunk);
		upstreamBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
		const payload = [
			sse('response.created', { response: { id: 'resp_router', output: [] } }),
			sse('response.output_item.added', {
				output_index: 0,
				item: { type: 'custom_tool_call', id: 'call_router', name: 'apply_patch', input: '{}' }
			}),
			sse('response.output_item.added', {
				output_index: 1,
				item: { type: 'message', id: 'msg_router', role: 'assistant', content: [] }
			}),
			sse('response.output_text.delta', { output_index: 1, delta: markup }),
			sse('response.output_item.done', { output_index: 1, item: { type: 'message', id: 'msg_router' } }),
			sse('response.custom_tool_call_input.done', { output_index: 0, input: '{}' }),
			sse('response.output_item.done', {
				output_index: 0,
				item: { type: 'custom_tool_call', id: 'call_router', name: 'apply_patch', input: '{}' }
			}),
			sse('response.completed', {
				response: {
					id: 'resp_router',
					output: [
						{ id: 'call_router', type: 'custom_tool_call', input: '{}' },
						{ id: 'msg_router', type: 'message' }
					]
				}
			})
		].join('');
		response.writeHead(200, { 'content-type': 'text/event-stream', 'content-length': Buffer.byteLength(payload) });
		response.end(payload);
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		routes: [
			{
				clientModel: 'mimo-shell',
				upstreamModel: 'mimo-v2.5-pro',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key',
				responsesAdapter: 'mimo-textual-tools'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const response = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'mimo-shell', stream: true })
		});
		const body = await response.text();
		assert.equal(response.status, 200);
		assert.equal(upstreamBody.model, 'mimo-v2.5-pro');
		assert.match(body, /response.custom_tool_call_input.done/);
		assert.match(body, /router-created\.txt/);
		assert.doesNotMatch(body, /<tool_call>|mimo_tool_call_parse_error|\"input\":\"\{\}\"/);
	} finally {
		await close(router);
		await close(upstream);
	}
});

test('converts native Chat Completions tool calls from the Mimo upstream', async () => {
	const upstream = http.createServer((_request, response) => {
		const payload = [
			sse('chat.completion.chunk', {
				id: 'chat_native',
				object: 'chat.completion.chunk',
				choices: [{ index: 0, delta: { content: 'Проверяю.' }, finish_reason: null }]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_native',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{
									index: 0,
									id: 'call_native',
									type: 'function',
									function: { name: 'shell_command', arguments: '{"command":"pwd"}' }
								}
							]
						},
						finish_reason: 'tool_calls'
					}
				]
			}),
			'data: [DONE]\n\n'
		].join('');
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		response.end(payload);
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		routes: [
			{
				clientModel: 'mimo-shell',
				upstreamModel: 'mimo-v2.5-pro',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key',
				responsesAdapter: 'mimo-textual-tools'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const response = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'mimo-shell', stream: true })
		});
		const body = await response.text();
		assert.equal(response.status, 200);
		assert.match(body, /response.output_item.added/);
		assert.match(body, /"type":"function_call"/);
		assert.match(body, /shell_command/);
		assert.match(body, /response.function_call_arguments.done/);
		assert.match(body, /response.completed/);
	} finally {
		await close(router);
		await close(upstream);
	}
});

test('flattens Mimo namespace tools upstream and restores the Responses namespace', async () => {
	let upstreamBody;
	const upstream = http.createServer(async (request, response) => {
		const chunks = [];
		for await (const chunk of request) chunks.push(chunk);
		upstreamBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
		const payload = [
			sse('response.output_item.added', {
				output_index: 0,
				item: {
					type: 'function_call',
					id: 'fc_namespace_router',
					call_id: 'call_namespace_router',
					name: 'mcp__node_repl__js',
					arguments: '{"code":"1+1"}'
				}
			}),
			sse('response.output_item.done', {
				output_index: 0,
				item: { type: 'function_call', id: 'fc_namespace_router', name: 'mcp__node_repl__js', arguments: '{"code":"1+1"}' }
			}),
			sse('response.completed', {
				response: {
					output: [{ type: 'function_call', id: 'fc_namespace_router', name: 'mcp__node_repl__js', arguments: '{"code":"1+1"}' }]
				}
			}),
			'data: [DONE]\n\n'
		].join('');
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		response.end(payload);
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		routes: [
			{
				clientModel: 'mimo-shell',
				upstreamModel: 'mimo-v2.5-pro',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key',
				responsesAdapter: 'mimo-textual-tools'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const response = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({
				model: 'mimo-shell',
				stream: true,
				input: 'Run js.',
				tools: [
					{
						type: 'namespace',
						name: 'mcp__node_repl',
						tools: [{ type: 'function', name: 'js', inputSchema: { type: 'object' } }]
					}
				]
			})
		});
		const body = await response.text();
		assert.equal(response.status, 200);
		assert.equal(upstreamBody.tools[0].name, 'mcp__node_repl__js');
		assert.match(body, /"name":"js"/u);
		assert.match(body, /"namespace":"mcp__node_repl"/u);
		assert.doesNotMatch(body, /mimo_tool_call_parse_error/u);
	} finally {
		await close(router);
		await close(upstream);
	}
});

test('does not throw when a Mimo downstream disconnects during streaming', async () => {
	const upstream = http.createServer((_request, response) => {
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		setTimeout(() => response.end(sse('response.completed', { response: { output: [] } })), 100);
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		routes: [
			{
				clientModel: 'mimo-shell',
				upstreamModel: 'mimo-v2.5-pro',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key',
				responsesAdapter: 'mimo-textual-tools'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		await new Promise((resolve) => {
			const request = http.request(
				`http://127.0.0.1:${routerPort}/v1/responses`,
				{ method: 'POST', headers: { 'content-type': 'application/json' } },
				() => undefined
			);
			request.once('error', () => resolve());
			request.end(JSON.stringify({ model: 'mimo-shell', stream: true }));
			setTimeout(() => {
				request.destroy();
				resolve();
			}, 10);
		});
		await new Promise((resolve) => setTimeout(resolve, 150));
		const health = await fetch(`http://127.0.0.1:${routerPort}/_shell-router/health`);
		assert.equal(health.status, 200);
	} finally {
		await close(router);
		await close(upstream);
	}
});

test('keeps an idle Mimo Responses stream alive while waiting for the next model output', async () => {
	const upstream = http.createServer((_request, response) => {
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		setTimeout(() => {
			response.end(sse('response.completed', { response: { output: [] } }));
		}, 100);
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		sseKeepAliveMs: 20,
		routes: [
			{
				clientModel: 'mimo-shell',
				upstreamModel: 'mimo-v2.5-pro',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key',
				responsesAdapter: 'mimo-textual-tools'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const response = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'mimo-shell', stream: true })
		});
		const body = await response.text();
		assert.equal(response.status, 200);
		assert.match(body, /: codex-model-shell-router keep-alive/);
		assert.match(body, /response.completed/);
	} finally {
		await close(router);
		await close(upstream);
	}
});

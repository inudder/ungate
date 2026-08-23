import assert from 'node:assert/strict';
import http from 'node:http';
import { Readable } from 'node:stream';
import test from 'node:test';

import {
	canonicalizeArguments,
	convertChatCompletionToResponse,
	createBridgeServer,
	createResponsesSseTransform,
	createSseTransform,
	flattenOpenAiRequest,
	flattenResponsesRequest,
	rewriteChatCompletionForClient,
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

function sse(type, data) {
	return `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
}

function eventData(stream) {
	return stream
		.split(/\r?\n\r?\n/u)
		.filter(Boolean)
		.map((frame) => {
			const line = frame.split(/\r?\n/u).find((item) => item.startsWith('data:'));
			if (!line) return null;
			const value = line.slice(5).trim();

			return value === '[DONE]' ? { type: '[DONE]' } : JSON.parse(value);
		})
		.filter(Boolean);
}

async function transformResponsesChat(chunks, options = {}) {
	const transform = createResponsesSseTransform(options);
	let output = '';
	for await (const chunk of Readable.from(chunks).pipe(transform)) output += chunk.toString('utf8');

	return output;
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

test('adapts Responses custom tools and history to function calls for CLIProxyAPI', () => {
	const { body, mapping } = flattenResponsesRequest({
		tools: [
			{
				type: 'custom',
				name: 'exec',
				description: 'Run orchestration JavaScript.',
				format: { type: 'grammar', syntax: 'lark', definition: 'start: /[\\s\\S]+/' }
			}
		],
		input: [
			{ type: 'custom_tool_call', id: 'ctc_1', call_id: 'call_1', name: 'exec', input: 'text(true);' },
			{ type: 'custom_tool_call_output', call_id: 'call_1', output: 'ok' }
		],
		tool_choice: { type: 'custom', name: 'exec' }
	});

	assert.deepEqual(body.tools[0], {
		type: 'function',
		name: 'exec',
		description: 'Run orchestration JavaScript.',
		strict: false,
		parameters: {
			type: 'object',
			properties: {
				input: {
					type: 'string',
					description: 'The complete freeform input for this tool. It must match this lark grammar:\nstart: /[\\s\\S]+/'
				}
			},
			required: ['input'],
			additionalProperties: false
		}
	});
	assert.deepEqual(body.input[0], {
		type: 'function_call',
		id: 'ctc_1',
		call_id: 'call_1',
		name: 'exec',
		arguments: '{"input":"text(true);"}'
	});
	assert.equal(body.input[1].type, 'function_call_output');
	assert.deepEqual(body.tool_choice, { type: 'function', name: 'exec' });
	assert.equal(mapping.customToolNames.has('exec'), true);
});

test('restores adapted custom calls in JSON Responses output', () => {
	const mapping = flattenResponsesRequest({ tools: [{ type: 'custom', name: 'exec', format: { type: 'text' } }] }).mapping;
	const result = convertChatCompletionToResponse(
		{
			id: 'chat_custom',
			choices: [
				{
					finish_reason: 'tool_calls',
					message: {
						tool_calls: [
							{ id: 'call_custom', type: 'function', function: { name: 'exec', arguments: '{"input":"text(true);"}' } }
						]
					}
				}
			]
		},
		mapping
	);

	assert.deepEqual(result.output[0], {
		type: 'custom_tool_call',
		id: 'call_custom',
		call_id: 'call_custom',
		name: 'exec',
		input: 'text(true);',
		status: 'completed'
	});
});

test('rewrites exec-wrapped wait calls into native wait', () => {
	const mapping = flattenResponsesRequest({ tools: [{ type: 'custom', name: 'exec', format: { type: 'text' } }] }).mapping;
	const fromCustom = rewriteResponseForCodex(
		{
			type: 'custom_tool_call',
			id: 'call_wait',
			call_id: 'call_wait',
			name: 'exec',
			input: 'await tools.wait({\n  cell_id: "107",\n  yield_time_ms: 60000\n});',
			status: 'completed'
		},
		mapping
	);
	assert.deepEqual(fromCustom, {
		type: 'function_call',
		id: 'call_wait',
		call_id: 'call_wait',
		name: 'wait',
		arguments: '{"cell_id":"107","yield_time_ms":60000}',
		status: 'completed'
	});

	const ordinary = rewriteResponseForCodex(
		{ type: 'custom_tool_call', name: 'exec', input: 'await tools.shell_command({ command: "echo hi" });', status: 'completed' },
		mapping
	);
	assert.equal(ordinary.name, 'exec');
});

test('restores full and unique bare names but leaves ambiguous bare names untouched', () => {
	const unique = flattenResponsesRequest({ tools: [namespaceTool('mcp__node_repl', 'js')] }).mapping;
	const restoredFull = rewriteResponseForCodex(
		{ type: 'function_call', name: 'mcp__node_repl__js', arguments: '{"timeout":16185.0}' },
		unique
	);
	const restoredBare = rewriteResponseForCodex({ type: 'function_call', name: 'js', arguments: '{"timeout":16185.0}' }, unique);
	const restoredNamespaceOnly = rewriteResponseForCodex(
		{ type: 'function_call', name: 'mcp__node_repl', arguments: '{"timeout":16185.0}' },
		unique
	);

	assert.deepEqual(restoredFull, {
		type: 'function_call',
		name: 'js',
		namespace: 'mcp__node_repl',
		arguments: '{"timeout":16185}'
	});
	assert.deepEqual(restoredBare, restoredFull);
	assert.deepEqual(restoredNamespaceOnly, restoredFull);

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

test('flattens Chat history and namespace tool choice', () => {
	const request = {
		model: 'grok-4.5',
		tools: [namespaceTool('mcp__node_repl', 'js')],
		messages: [
			{
				role: 'assistant',
				tool_calls: [
					{
						id: 'call_1',
						type: 'function',
						function: { name: 'js', namespace: 'mcp__node_repl', arguments: '{"code":"1+1"}' }
					}
				]
			},
			{ role: 'tool', tool_call_id: 'call_1', content: '2' }
		],
		tool_choice: { type: 'function', name: 'js', namespace: 'mcp__node_repl' }
	};
	const { body } = flattenOpenAiRequest(request);

	assert.equal(body.messages[0].tool_calls[0].function.name, 'mcp__node_repl__js');
	assert.equal('namespace' in body.messages[0].tool_calls[0].function, false);
	assert.deepEqual(body.tool_choice, { type: 'function', name: 'mcp__node_repl__js' });
	assert.equal(body.messages[1].tool_call_id, 'call_1');
});

test('converts one native Chat SSE tool call with fragmented fields and arguments', async () => {
	const mapping = flattenResponsesRequest({ tools: [namespaceTool('mcp__node_repl', 'js')] }).mapping;
	const output = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_1',
				choices: [{ index: 0, delta: { content: 'Checking.' }, finish_reason: null }]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_1',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{
									index: 0,
									id: 'call_',
									type: 'function',
									function: { name: 'mcp__node_', arguments: '{"code":"1' }
								}
							]
						},
						finish_reason: null
					}
				]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_1',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{
									index: 0,
									id: 'call_1',
									function: { name: 'mcp__node_repl__js', arguments: '+1"}' }
								}
							]
						},
						finish_reason: 'tool_calls'
					}
				]
			}),
			'data: [DONE]\n\n'
		],
		{ mapping, model: 'grok-4.5', logger: { error() {} } }
	);
	const events = eventData(output);

	assert.equal(events[0].type, 'response.created');
	assert.equal(events.filter((event) => event.type === 'response.output_text.delta').length, 1);
	assert.deepEqual(
		events.find((event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call').item,
		{
			type: 'function_call',
			id: 'call_1',
			call_id: 'call_1',
			name: 'js',
			namespace: 'mcp__node_repl',
			arguments: '',
			status: 'in_progress'
		}
	);
	assert.equal(events.find((event) => event.type === 'response.function_call_arguments.done').arguments, '{"code":"1+1"}');
	assert.equal(events.at(-2).type, 'response.completed');
	assert.equal(events.at(-1).type, '[DONE]');
	assert.equal(output.includes('chat.completion.chunk'), false);
});

test('converts legacy Chat SSE delta.function_call', async () => {
	const output = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_legacy_stream',
				choices: [
					{
						index: 0,
						delta: { function_call: { name: 'shell_command', arguments: '{"command":"pw' } },
						finish_reason: null
					}
				]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_legacy_stream',
				choices: [
					{
						index: 0,
						delta: { function_call: { name: 'shell_command', arguments: 'd"}' } },
						finish_reason: 'function_call'
					}
				]
			}),
			'data: [DONE]\n\n'
		],
		{ model: 'grok-4.5', logger: { error() {} } }
	);
	const events = eventData(output);
	const functionCall = events.find(
		(event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call'
	);

	assert.equal(functionCall.item.name, 'shell_command');
	assert.equal(events.find((event) => event.type === 'response.function_call_arguments.done').arguments, '{"command":"pwd"}');
	assert.equal(events.filter((event) => event.type === 'response.completed').length, 1);
});

test('converts adapted custom function calls in Chat SSE back to custom tool lifecycle', async () => {
	const mapping = flattenResponsesRequest({ tools: [{ type: 'custom', name: 'exec', format: { type: 'text' } }] }).mapping;
	const output = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_custom_stream',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{ index: 0, id: 'call_custom', type: 'function', function: { name: 'exec', arguments: '{"input":"text(' } }
							]
						},
						finish_reason: null
					}
				]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_custom_stream',
				choices: [
					{
						index: 0,
						delta: { tool_calls: [{ index: 0, function: { arguments: 'true);"}' } }] },
						finish_reason: 'tool_calls'
					}
				]
			}),
			'data: [DONE]\n\n'
		],
		{ mapping, model: 'grok-4.5', logger: { error() {} } }
	);
	const events = eventData(output);
	const added = events.find((event) => event.type === 'response.output_item.added');
	const done = events.find((event) => event.type === 'response.custom_tool_call_input.done');
	const itemDone = events.find((event) => event.type === 'response.output_item.done');

	assert.equal(added.item.type, 'custom_tool_call');
	assert.equal(added.item.name, 'exec');
	assert.equal(done.input, 'text(true);');
	assert.equal(itemDone.item.input, 'text(true);');
	assert.equal(
		events.some((event) => event.type.startsWith('response.function_call_arguments')),
		false
	);
});

test('converts native Responses custom function lifecycle without leaking wrapper JSON', async () => {
	const mapping = flattenResponsesRequest({ tools: [{ type: 'custom', name: 'exec', format: { type: 'text' } }] }).mapping;
	const item = {
		type: 'function_call',
		id: 'fc_custom',
		call_id: 'call_custom',
		name: 'exec',
		arguments: '',
		status: 'in_progress'
	};
	const output = await transformResponsesChat(
		[
			sse('response.output_item.added', { response_id: 'resp_custom', output_index: 0, item }),
			sse('response.function_call_arguments.delta', {
				response_id: 'resp_custom',
				output_index: 0,
				item_id: 'fc_custom',
				delta: '{"input":"text(true);"}'
			}),
			sse('response.function_call_arguments.done', {
				response_id: 'resp_custom',
				output_index: 0,
				item_id: 'fc_custom',
				call_id: 'call_custom',
				arguments: '{"input":"text(true);"}'
			}),
			sse('response.output_item.done', {
				response_id: 'resp_custom',
				output_index: 0,
				item: { ...item, arguments: '{"input":"text(true);"}', status: 'completed' }
			}),
			'data: [DONE]\n\n'
		],
		{ mapping, model: 'grok-4.5', logger: { error() {} } }
	);
	const events = eventData(output);

	assert.equal(events.find((event) => event.type === 'response.output_item.added').item.type, 'custom_tool_call');
	assert.equal(events.find((event) => event.type === 'response.custom_tool_call_input.done').input, 'text(true);');
	assert.equal(events.find((event) => event.type === 'response.output_item.done').item.input, 'text(true);');
	assert.equal(
		events.some((event) => event.type === 'response.function_call_arguments.delta'),
		false
	);
});

test('converts multiple parallel Chat SSE tool calls without mixing arguments', async () => {
	const output = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_parallel',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{ index: 0, id: 'call_a', type: 'function', function: { name: 'shell_command' } },
								{ index: 1, id: 'call_b', type: 'function', function: { name: 'view_image' } }
							]
						},
						finish_reason: null
					}
				]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_parallel',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{ index: 1, function: { arguments: '{"path":"image.png"}' } },
								{ index: 0, function: { arguments: '{"command":"pwd"}' } }
							]
						},
						finish_reason: 'tool_calls'
					}
				]
			}),
			'data: [DONE]\n\n'
		],
		{ model: 'grok-4.5', logger: { error() {} } }
	);
	const events = eventData(output);
	const completed = events.filter((event) => event.type === 'response.function_call_arguments.done');

	assert.deepEqual(
		completed.map((event) => [event.call_id, event.arguments]),
		[
			['call_a', '{"command":"pwd"}'],
			['call_b', '{"path":"image.png"}']
		]
	);
	assert.equal(events.filter((event) => event.type === 'response.completed').length, 1);
});

test('converts completion-only tool_calls and legacy function_call JSON', () => {
	const mapping = flattenResponsesRequest({ tools: [namespaceTool('mcp__node_repl', 'js')] }).mapping;
	const result = convertChatCompletionToResponse(
		{
			id: 'chat_json',
			model: 'grok-4.5',
			choices: [
				{
					index: 0,
					finish_reason: 'tool_calls',
					message: {
						role: 'assistant',
						tool_calls: [
							{
								id: 'call_namespace',
								type: 'function',
								function: { name: 'mcp__node_repl__js', arguments: '{"code":"1+1"}' }
							}
						]
					}
				}
			]
		},
		mapping
	);
	assert.deepEqual(result.output[0], {
		type: 'function_call',
		id: 'call_namespace',
		call_id: 'call_namespace',
		name: 'js',
		namespace: 'mcp__node_repl',
		arguments: '{"code":"1+1"}',
		status: 'completed'
	});

	const legacy = convertChatCompletionToResponse(
		{
			id: 'chat_legacy',
			choices: [
				{ finish_reason: 'function_call', message: { function_call: { name: 'shell_command', arguments: '{"command":"pwd"}' } } }
			]
		},
		mapping
	);
	assert.equal(legacy.output[0].type, 'function_call');
	assert.match(legacy.output[0].id, /^chat_legacy_call_/u);
});

test('normalizes valid usage and omits input usage beyond the configured 500k context window', async () => {
	const standard = convertChatCompletionToResponse(
		{
			id: 'chat_usage',
			choices: [{ message: { content: 'ok' } }],
			usage: {
				prompt_tokens: 120,
				completion_tokens: 8,
				total_tokens: 999,
				prompt_tokens_details: { cached_tokens: 96 }
			}
		},
		undefined
	);
	assert.deepEqual(standard.usage, {
		input_tokens: 120,
		output_tokens: 8,
		total_tokens: 128,
		input_tokens_details: { cached_tokens: 96 }
	});
	const longButValid = convertChatCompletionToResponse(
		{
			id: 'chat_usage_long',
			choices: [{ message: { content: 'ok' } }],
			usage: { input_tokens: 244_567, output_tokens: 510 }
		},
		undefined
	);
	assert.equal(longButValid.usage.input_tokens, 244_567);

	const logs = [];
	const oversized = convertChatCompletionToResponse(
		{
			id: 'chat_usage_oversized',
			choices: [{ message: { content: 'ok' } }],
			usage: { input_tokens: 500_001, output_tokens: 510 }
		},
		undefined,
		{
			maxInputTokens: 500_000,
			model: 'grok-4.5',
			logger: {
				warn(message) {
					logs.push(message);
				}
			}
		}
	);
	assert.equal('usage' in oversized, false);
	assert.match(logs[0], /input_tokens=500001/u);

	const nativeResponse = rewriteResponseForCodex(
		{
			type: 'response.completed',
			response: { usage: { input_tokens: 500_001, output_tokens: 510 } }
		},
		undefined,
		{ maxInputTokens: 500_000 }
	);
	assert.equal('usage' in nativeResponse.response, false);

	const streamed = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_usage_stream',
				usage: { prompt_tokens: 500_001, completion_tokens: 510 },
				choices: [{ index: 0, delta: { content: 'ok' }, finish_reason: 'stop' }]
			}),
			'data: [DONE]\n\n'
		],
		{ maxInputTokens: 500_000, model: 'grok-4.5', logger: { warn() {}, error() {} } }
	);
	const completed = eventData(streamed).find((event) => event.type === 'response.completed');
	assert.equal('usage' in completed.response, false);
});

test('keeps ordinary Chat text on stop and preserves direct Chat schema', async () => {
	const output = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_text',
				choices: [{ index: 0, delta: { content: 'Done.' }, finish_reason: 'stop' }]
			}),
			'data: [DONE]\n\n'
		],
		{ model: 'grok-4.5', logger: { error() {} } }
	);
	const events = eventData(output);

	assert.equal(events.filter((event) => event.type === 'response.function_call_arguments.done').length, 0);
	assert.equal(events.at(-2).type, 'response.completed');
	assert.equal(events.at(-1).type, '[DONE]');
	assert.deepEqual(
		rewriteChatCompletionForClient(
			{
				choices: [{ message: { tool_calls: [{ type: 'function', function: { name: 'mcp__node_repl__js', arguments: '{}' } }] } }]
			},
			flattenResponsesRequest({ tools: [namespaceTool('mcp__node_repl', 'js')] }).mapping
		).choices[0].message.tool_calls[0].function,
		{ name: 'js', arguments: '{}' }
	);
});

test('fails closed on malformed or incomplete Chat calls without logging arguments', async () => {
	const logs = [];
	const output = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_bad',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{ index: 0, id: 'call_bad', type: 'function', function: { name: 'shell_command', arguments: '{"secret":' } }
							]
						},
						finish_reason: 'tool_calls'
					}
				]
			}),
			'data: [DONE]\n\n'
		],
		{
			model: 'grok-4.5',
			logger: {
				error(message) {
					logs.push(message);
				}
			}
		}
	);
	const events = eventData(output);

	assert.equal(events.filter((event) => event.type === 'response.failed').length, 1);
	assert.equal(events.filter((event) => event.type === 'response.completed').length, 0);
	assert.equal(output.includes('chat.completion.chunk'), false);
	assert.equal(output.includes('secret'), true);
	assert.equal(logs.length, 1);
	assert.equal(logs[0].includes('{"secret":'), false);
	assert.equal(logs[0].includes('Authorization'), false);

	const noCall = await transformResponsesChat(
		[
			sse('chat.completion.chunk', { id: 'chat_no_call', choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] }),
			'data: [DONE]\n\n'
		],
		{ model: 'grok-4.5', logger: { error() {} } }
	);
	assert.equal(eventData(noCall).filter((event) => event.type === 'response.failed').length, 1);
	assert.throws(
		() =>
			convertChatCompletionToResponse(
				{
					choices: [
						{
							message: {
								tool_calls: [{ type: 'function', function: { name: 'shell_command', arguments: '{}' } }]
							}
						}
					]
				},
				{ fullToOriginal: new Map(), uniqueBareToOriginal: new Map() }
			),
		(error) => error.code === 'tool_call_invalid'
	);

	const conflict = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_conflict',
				choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'call_conflict', function: { name: 'first' } }] } }]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_conflict',
				choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { name: 'second' } }] }, finish_reason: 'tool_calls' }]
			})
		],
		{ model: 'grok-4.5', logger: { error() {} } }
	);
	assert.equal(eventData(conflict).filter((event) => event.type === 'response.failed').length, 1);
	assert.equal(eventData(conflict).filter((event) => event.type === 'response.completed').length, 0);

	const missingDone = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_no_done',
				choices: [{ index: 0, delta: { content: 'partial' }, finish_reason: 'stop' }]
			})
		],
		{ model: 'grok-4.5', logger: { error() {} } }
	);
	assert.equal(eventData(missingDone).filter((event) => event.type === 'response.failed').length, 1);
	assert.equal(eventData(missingDone).filter((event) => event.type === 'response.completed').length, 0);
});

test('handles response.completed and [DONE] exactly once', async () => {
	const output = await transformResponsesChat(
		[
			sse('chat.completion.chunk', {
				id: 'chat_terminal',
				choices: [{ index: 0, delta: { content: 'ok' }, finish_reason: 'stop' }]
			}),
			'data: [DONE]\n\n',
			sse('response.completed', { response: { id: 'chat_terminal', output: [] } })
		],
		{ model: 'grok-4.5', logger: { error() {} } }
	);
	const events = eventData(output);

	assert.equal(events.filter((event) => event.type === 'response.completed').length, 1);
	assert.equal(events.filter((event) => event.type === '[DONE]').length, 1);
});

test('converts Chat SSE through the Responses bridge endpoint and preserves direct Chat endpoint', async (t) => {
	const upstream = http.createServer(async (request, response) => {
		await readRequestBody(request);
		const payload = [
			sse('chat.completion.chunk', {
				id: 'chat_http',
				choices: [
					{
						index: 0,
						delta: {
							tool_calls: [
								{ index: 0, id: 'call_http', type: 'function', function: { name: 'mcp__node_repl__js', arguments: '{}' } }
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
	const bridge = createBridgeServer({ upstreamUrl: `http://127.0.0.1:${upstreamPort}`, buildId: 'chat-test' });
	const bridgePort = await listen(bridge);
	t.after(async () => {
		await close(bridge);
		await close(upstream);
	});

	const responses = await fetch(`http://127.0.0.1:${bridgePort}/v1/responses`, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ model: 'grok-4.5', stream: true, tools: [namespaceTool('mcp__node_repl', 'js')] })
	});
	const responsesText = await responses.text();
	assert.equal(responses.status, 200);
	assert.match(responsesText, /response.completed/u);
	assert.match(responsesText, /"namespace":"mcp__node_repl"/u);

	const chat = await fetch(`http://127.0.0.1:${bridgePort}/v1/chat/completions`, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ model: 'grok-4.5', stream: true, tools: [namespaceTool('mcp__node_repl', 'js')] })
	});
	const chatText = await chat.text();
	assert.equal(chat.status, 200);
	assert.match(chatText, /chat.completion.chunk/u);
	assert.doesNotMatch(chatText, /response.created/u);
});

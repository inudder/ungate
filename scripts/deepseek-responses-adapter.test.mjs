import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import test from 'node:test';

import { createShellRouterServer } from './codex-model-shell-router.mjs';
import {
	adaptDeepSeekRequest,
	createDeepSeekStreamAdapter,
	orderDeepSeekToolHistory,
	restoreDeepSeekResponse
} from './deepseek-responses-adapter.mjs';

const exec = {
	type: 'custom',
	name: 'exec',
	description: 'Execute JavaScript with text() and tools.',
	format: { type: 'grammar', syntax: 'lark', definition: 'start: /[\\s\\S]+/' }
};
const patch = { type: 'custom', name: 'apply_patch', format: { type: 'text' } };
const namespace = {
	type: 'namespace',
	name: 'mcp_test',
	tools: [{ type: 'function', name: 'read', parameters: { type: 'object' } }]
};
const reasoning = { type: 'reasoning', content: [{ type: 'reasoning_text', text: 'Fixture reasoning.' }], summary: [], id: 'r1' };
const comment = { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Checking four fixtures.' }] };
const calls = Array.from({ length: 4 }, (_, i) => ({ type: 'function_call', name: 'read', arguments: '{}', call_id: `c${i}` }));
const outputs = calls.map((call) => ({ type: 'function_call_output', call_id: call.call_id, output: 'fixture' }));

test('original four-call thinking turn stays grouped, with boundaries and sequential turns intact', () => {
	const transcript = [reasoning, comment, ...calls, ...outputs];
	assert.deepEqual(orderDeepSeekToolHistory(transcript), transcript);
	const brokenOldRouterOutput = [reasoning, comment, ...calls.flatMap((call, i) => [call, outputs[i]])];
	assert.notDeepEqual(transcript, brokenOldRouterOutput);
	// Already completed alternating rounds are ambiguous: do not invent their provenance.
	assert.deepEqual(orderDeepSeekToolHistory(brokenOldRouterOutput), brokenOldRouterOutput);
	assert.deepEqual(orderDeepSeekToolHistory([reasoning, calls[0], comment, ...calls.slice(1), ...outputs]), transcript);
	const sequential = [reasoning, calls[0], outputs[0], reasoning, calls[1], outputs[1]];
	assert.deepEqual(orderDeepSeekToolHistory(sequential), sequential);
	for (const boundary of [reasoning, { role: 'user' }, { role: 'system' }, { role: 'developer' }]) {
		const input = [calls[0], boundary, outputs[0]];
		assert.deepEqual(orderDeepSeekToolHistory(input), input);
	}
	for (const input of [
		[calls[0], comment],
		[calls[0], calls[0], outputs[0]],
		[calls[0], calls[1], outputs[0], comment, outputs[1]],
		[calls[0], outputs[0], outputs[0]]
	]) {
		assert.deepEqual(orderDeepSeekToolHistory(input), input);
	}
	assert.deepEqual(orderDeepSeekToolHistory(orderDeepSeekToolHistory(transcript)), transcript);
});

test('exec schema, choice and history round-trip without changing native patch or namespace', () => {
	const code = 'text("Привет 🌍\\n");\nawait tools.read({});';
	const original = {
		tools: [exec, patch, namespace],
		tool_choice: { type: 'custom', name: 'exec' },
		input: [
			reasoning,
			{ type: 'custom_tool_call', name: 'exec', call_id: 'e', input: code },
			{ type: 'custom_tool_call_output', call_id: 'e', output: [{ type: 'input_text', text: 'ok' }] }
		]
	};
	const backup = structuredClone(original);
	const adapted = adaptDeepSeekRequest(original);
	assert.deepEqual(original, backup);
	assert.deepEqual(adapted.body.tools.slice(1), [patch, namespace]);
	assert.deepEqual(adapted.body.tools[0].parameters.required, ['input']);
	assert.ok(adapted.body.tools[0].description.includes(exec.format.definition));
	assert.equal(adapted.body.tool_choice.type, 'function');
	assert.equal(adapted.body.input[2].type, 'function_call_output');
	assert.equal(adapted.body.input[0], reasoning);
	const restored = restoreDeepSeekResponse({ output: [reasoning, adapted.body.input[1]] }, adapted.mapping);
	assert.deepEqual(restored.output, original.input.slice(0, 2));
	assert.throws(
		() => restoreDeepSeekResponse({ output: [{ type: 'function_call', name: 'exec', arguments: '{}' }] }, adapted.mapping),
		/missing string/
	);
	assert.throws(() => adaptDeepSeekRequest({ tools: [exec, { type: 'function', name: 'exec' }] }), /collision/);
});

async function transform(events, mapping) {
	const stream = createDeepSeekStreamAdapter(mapping);
	const chunks = [];
	stream.on('data', (chunk) => chunks.push(chunk));
	const done = once(stream, 'end');
	const bytes = Buffer.from(events.map((event) => `event: ${event.type}\r\ndata: ${JSON.stringify(event)}\r\n\r\n`).join(''));
	for (const byte of bytes) stream.write(Buffer.from([byte]));
	stream.end();
	await done;

	return Buffer.concat(chunks)
		.toString('utf8')
		.split('\n')
		.filter((line) => line.startsWith('data: '))
		.map((line) => JSON.parse(line.slice(6)));
}

test('SSE buffers fragmented unicode JSON and restores parallel exec lifecycles exactly once', async () => {
	const { mapping } = adaptDeepSeekRequest({ tools: [exec] });
	const items = [0, 1].map((index) => ({
		type: 'function_call',
		id: `i${index}`,
		call_id: `e${index}`,
		name: 'exec',
		status: 'completed',
		arguments: JSON.stringify({ input: `text("雪🌍${index}");` })
	}));
	const events = [{ type: 'response.output_item.done', output_index: 0, item: reasoning }];
	for (const [index, item] of items.entries()) {
		events.push({
			type: 'response.output_item.added',
			output_index: index + 1,
			item: { ...item, arguments: '', status: 'in_progress' }
		});
		for (const character of item.arguments)
			events.push({ type: 'response.function_call_arguments.delta', output_index: index + 1, delta: character });
		events.push({ type: 'response.function_call_arguments.done', output_index: index + 1, arguments: item.arguments });
		events.push({ type: 'response.output_item.done', output_index: index + 1, item });
	}
	events.push({ type: 'response.completed', response: { status: 'completed', output: [reasoning, ...items] } });
	const restored = await transform(events, mapping);
	assert.equal(restored.filter((event) => event.type === 'response.custom_tool_call_input.delta').length, 2);
	assert.equal(restored.filter((event) => event.type === 'response.output_item.added').length, 2);
	assert.deepEqual(restored[0].item, reasoning);
	assert.deepEqual(
		restored
			.at(-1)
			.response.output.slice(1)
			.map((item) => item.input),
		['text("雪🌍0");', 'text("雪🌍1");']
	);
	assert.ok(restored.every((event, index) => event.sequence_number === index));
});

test('completion-only calls restored; malformed and truncated calls fail without leaking source', async () => {
	const { mapping } = adaptDeepSeekRequest({ tools: [exec] });
	const item = { type: 'function_call', name: 'exec', id: 'i', call_id: 'c', arguments: '{"input":"text(1)"}' };
	const complete = await transform([{ type: 'response.completed', response: { output: [item], status: 'completed' } }], mapping);
	assert.equal(complete[0].item.type, 'custom_tool_call');
	for (const events of [
		[{ type: 'response.output_item.added', output_index: 0, item: { ...item, arguments: '' } }],
		[{ type: 'response.completed', response: { output: [{ ...item, arguments: 'PRIVATE_INVALID_JSON' }] } }]
	]) {
		const result = await transform(events, mapping);
		assert.equal(result.at(-1).type, 'error');
		assert.ok(!result.some((event) => event.type === 'response.custom_tool_call_input.delta'));
		assert.doesNotMatch(JSON.stringify(result), /PRIVATE_INVALID_JSON/);
	}
});

async function listen(t, server) {
	server.listen({ host: '127.0.0.1', port: 0, exclusive: true });
	await once(server, 'listening');
	t.after(
		() =>
			new Promise((resolve) => {
				server.close(resolve);
				server.closeAllConnections();
			})
	);

	return `http://127.0.0.1:${server.address().port}`;
}

test('router adapter works independently of upstream URL through JSON, SSE and intermediate proxy', async (t) => {
	const received = [];
	const upstream = await listen(
		t,
		http.createServer(async (request, response) => {
			let raw = '';
			for await (const chunk of request) raw += chunk;
			const body = JSON.parse(raw);
			received.push(body);
			const value = {
				status: 'completed',
				output: [reasoning, { type: 'function_call', name: 'exec', id: 'e', call_id: 'c', arguments: '{"input":"text(1)"}' }]
			};
			response.writeHead(200, { 'content-type': body.stream ? 'text/event-stream' : 'application/json' });
			response.end(
				body.stream ? `data: ${JSON.stringify({ type: 'response.completed', response: value })}\n\n` : JSON.stringify(value)
			);
		})
	);
	const intermediate = await listen(
		t,
		http.createServer((request, response) => {
			const outgoing = http.request(
				`${upstream}${request.url}`,
				{ method: request.method, headers: request.headers },
				(incoming) => {
					response.writeHead(incoming.statusCode, incoming.headers);
					incoming.pipe(response);
				}
			);
			request.pipe(outgoing);
		})
	);
	for (const target of [upstream, intermediate]) {
		const router = await listen(
			t,
			createShellRouterServer({
				routes: [
					{
						clientModel: 'shell',
						upstreamModel: 'any-deepseek-alias',
						upstreamBaseUrl: target,
						apiKey: 'test',
						responsesAdapter: 'deepseek-responses'
					}
				]
			})
		);
		for (const stream of [false, true]) {
			const response = await fetch(`${router}/v1/responses`, {
				method: 'POST',
				body: JSON.stringify({
					model: 'shell',
					tools: [exec, patch, namespace],
					input: [reasoning, comment, ...calls, ...outputs],
					stream
				})
			});
			assert.equal(response.status, 200);
			const text = await response.text();
			assert.match(text, /custom_tool_call/);
			assert.doesNotMatch(text, /function_call/);
			assert.equal(received.at(-1).tools[0].type, 'function');
			assert.deepEqual(received.at(-1).input, [reasoning, comment, ...calls, ...outputs]);
		}
	}
});

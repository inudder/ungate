import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';

import { parseMemoryResponse, runMemoryPreflight, verifyMemoryStage } from './codex-memory-preflight.mjs';

function sse(output) {
	const response = { id: 'r1', status: 'completed', output };

	return [
		{ type: 'response.created', response: { id: 'r1', status: 'in_progress' } },
		...output.map((item) => ({ type: 'response.output_item.added', item })),
		{ type: 'response.completed', response }
	]
		.map((event) => `data: ${JSON.stringify(event)}\n\n`)
		.join('');
}

function message(text) {
	return { id: 'm1', type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text }] };
}

async function withUpstream(handler, action) {
	const server = http.createServer(handler);
	await new Promise((resolve) => server.listen({ port: 0, host: '127.0.0.1', exclusive: true }, resolve));
	try {
		await action(`http://127.0.0.1:${server.address().port}`);
	} finally {
		await new Promise((resolve) => {
			server.close(resolve);
			server.closeAllConnections();
		});
	}
}

test('memory probe checks both tool continuations and exact upstream model without executing tools', async () => {
	const requests = [];
	await withUpstream(
		async (request, response) => {
			if (request.method === 'GET') {
				response.setHeader('content-type', 'application/json');
				response.end(JSON.stringify({ data: [] }));

				return;
			}
			let text = '';
			for await (const chunk of request) text += chunk;
			const body = JSON.parse(text);
			requests.push(body);
			let output;
			if (body.text) output = [message('{"memory":"Use PowerShell"}')];
			else if (body.tool_choice?.type === 'function') {
				const instruction = body.input[0].content;
				const argumentsJson =
					instruction.match(/\{"memory":"[^"]+"\}/)?.[0] ?? JSON.stringify({ memory: instruction.split('with memory ')[1] });
				output = [
					{
						id: 'f1',
						type: 'function_call',
						namespace: 'memory_probe',
						name: 'remember',
						call_id: 'c1',
						arguments: argumentsJson
					}
				];
			} else if (body.tool_choice?.type === 'custom')
				output = [{ id: 'x1', type: 'custom_tool_call', name: 'exec', call_id: 'c2', input: 'return "OK";' }];
			else output = [message('OK')];
			response.setHeader('content-type', 'text/event-stream');
			response.end(sse(output));
		},
		async (upstreamBaseUrl) => {
			const result = await runMemoryPreflight({ model: 'physical-memory', apiKey: 'fixture', upstreamBaseUrl });
			assert.equal(result.valid, true);
			assert.equal(result.catalogPresent, false, 'Catalog is advisory');
		}
	);
	assert.equal(requests.length, 5);
	assert.ok(requests.every((request) => request.model === 'physical-memory' && request.stream === true));
	assert.ok(requests[3].input.some((item) => item.type === 'function_call_output'));
	assert.ok(requests[4].input.some((item) => item.type === 'custom_tool_call_output'));
});

for (const status of [401, 403, 429, 503]) {
	test(`HTTP ${status} is a failed memory validation`, async () => {
		await withUpstream(
			(request, response) => {
				response.writeHead(status, { 'content-type': 'application/json' });
				response.end('{"error":{"message":"fixture failure"}}');
			},
			async (upstreamBaseUrl) => {
				const result = await runMemoryPreflight({ model: 'memory', apiKey: 'fixture', upstreamBaseUrl });
				assert.equal(result.valid, false);
				assert.equal(result.code, `http_${status}`);
			}
		);
	});
}

test('timeout aborts the request and releases diagnostic servers', async () => {
	await withUpstream(
		(request, response) => {
			if (request.method === 'GET') response.end('{"data":[]}');
		},
		async (upstreamBaseUrl) => {
			const result = await runMemoryPreflight({ model: 'memory', apiKey: 'fixture', upstreamBaseUrl }, { timeoutMs: 20 });
			assert.equal(result.valid, false);
			assert.equal(result.code, 'timeout_or_cancelled');
		}
	);
});

test('rejects JSON, malformed SSE, terminal errors, orphan deltas and missing completion', () => {
	const parse = (text) => parseMemoryResponse({ status: 200, contentType: 'text/event-stream', text });
	assert.throws(() => parseMemoryResponse({ status: 200, contentType: 'application/json', text: '{}' }), /expected_sse/);
	assert.throws(() => parse('data: {bad}\n\n'));
	assert.throws(() => parse('data: {"type":"error"}\n\n'), /terminal_error/);
	assert.throws(() => parse('data: {"type":"response.output_text.delta","item_id":"missing"}\n\n'), /invalid_sse_lifecycle/);
	assert.throws(() => parse('data: {"type":"response.created"}\n\n'), /incomplete_sse/);
	assert.throws(() => parse(sse([message('OK')]).trimEnd()), /incomplete_sse/);
});

test('rejects wrong structured output, function namespace and custom source', () => {
	assert.throws(() => verifyMemoryStage('extraction', { output: [message('{"memory":"wrong"}')] }), /invalid_structured_output/);
	assert.throws(
		() => verifyMemoryStage('function', { output: [{ type: 'function_call', name: 'remember' }] }),
		/invalid_function_call/
	);
	assert.throws(
		() =>
			verifyMemoryStage('function', {
				output: [
					{
						type: 'function_call',
						namespace: 'memory_probe',
						name: 'remember',
						call_id: 'c1',
						arguments: '{"memory":"Use PowerShell."}'
					}
				]
			}),
		/invalid_function_arguments/
	);
	assert.throws(
		() =>
			verifyMemoryStage('custom', {
				output: [{ type: 'custom_tool_call', name: 'exec', call_id: 'c1', input: 'throw new Error()' }]
			}),
		/invalid_custom_call/
	);
	assert.throws(() => verifyMemoryStage('continuation', { output: [message('wrong')] }), /invalid_continuation/);
});

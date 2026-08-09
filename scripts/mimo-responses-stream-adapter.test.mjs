import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import test from 'node:test';

import { flattenMimoResponsesRequest } from './mimo-responses-namespace.mjs';
import { createMimoResponsesStreamAdapter, extractToolCalls } from './mimo-responses-stream-adapter.mjs';

function sse(type, data) {
	return `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
}

async function transform(chunks, logs = [], adapterOptions = {}) {
	const adapter = createMimoResponsesStreamAdapter({ ...adapterOptions, logger: (message) => logs.push(message) });
	const output = [];
	for await (const chunk of Readable.from(chunks).pipe(adapter)) output.push(chunk);

	return Buffer.concat(output).toString('utf8');
}

function events(stream) {
	return stream
		.split(/\r?\n\r?\n/)
		.filter(Boolean)
		.filter((frame) => !frame.includes('data: [DONE]'))
		.map((frame) =>
			JSON.parse(
				frame
					.split(/\r?\n/)
					.find((line) => line.startsWith('data:'))
					.slice(5)
					.trim()
			)
		);
}

test('extracts raw patch text and JSON-wrapped patch text', () => {
	const raw = extractToolCalls(
		'<tool_call><function=apply_patch><parameter=patch_text>\n*** Begin Patch\n+ok\n*** End Patch\n</parameter></function></tool_call>'
	);
	assert.deepEqual(raw.calls, [{ name: 'apply_patch', input: '*** Begin Patch\n+ok\n*** End Patch' }]);

	const wrapped = extractToolCalls(
		'<tool_call><function=apply_patch><parameter=parameters>{"patch_text":"*** Begin Patch\\n+ok\\n*** End Patch"}</parameter></function></tool_call>'
	);
	assert.deepEqual(wrapped.calls, [{ name: 'apply_patch', input: '*** Begin Patch\n+ok\n*** End Patch' }]);
});

test('extracts tool markup embedded in assistant commentary', () => {
	const extracted = extractToolCalls(
		'Preparing the change.\n\n<tool_call><function=apply_patch><parameter=patch_text>*** Begin Patch\n+ok\n*** End Patch</parameter></function></tool_call>'
	);
	assert.equal(extracted.malformed, false);
	assert.equal(extracted.visibleText, 'Preparing the change.\n\n');
	assert.deepEqual(extracted.calls, [{ name: 'apply_patch', input: '*** Begin Patch\n+ok\n*** End Patch' }]);
});

test('converts fragmented textual apply_patch markup and suppresses empty upstream input', async () => {
	const patch = '*** Begin Patch\n*** Add File: created.txt\n+hello\n*** End Patch';
	const markup = `<tool_call>\n<function=apply_patch>\n<parameter=${patch}\n</parameter>\n</function>\n</tool_call>`;
	const chunks = [
		sse('response.created', { response: { id: 'resp_1', output: [] } }),
		sse('response.output_item.added', {
			output_index: 0,
			item: { type: 'custom_tool_call', id: 'call_1', name: 'apply_patch', input: '{}' }
		}),
		sse('response.output_item.added', {
			output_index: 1,
			item: { type: 'message', id: 'msg_1', role: 'assistant', content: [] }
		}),
		sse('response.content_part.added', { output_index: 1, content_index: 0, part: { type: 'output_text', text: '' } }),
		sse('response.output_text.delta', { output_index: 1, content_index: 0, delta: markup.slice(0, 23) }),
		sse('response.output_text.delta', { output_index: 1, content_index: 0, delta: markup.slice(23, 71) }),
		sse('response.output_text.delta', { output_index: 1, content_index: 0, delta: markup.slice(71) }),
		sse('response.output_text.done', { output_index: 1, content_index: 0, text: markup }),
		sse('response.content_part.done', { output_index: 1, content_index: 0, part: { type: 'output_text', text: markup } }),
		sse('response.output_item.done', { output_index: 1, item: { type: 'message', id: 'msg_1', role: 'assistant', content: [] } }),
		sse('response.custom_tool_call_input.delta', { output_index: 0, delta: '{}' }),
		sse('response.custom_tool_call_input.done', { output_index: 0, input: '{}' }),
		sse('response.output_item.done', {
			output_index: 0,
			item: { type: 'custom_tool_call', id: 'call_1', name: 'apply_patch', input: '{}' }
		}),
		sse('response.completed', {
			response: {
				id: 'resp_1',
				output: [
					{ id: 'call_1', type: 'custom_tool_call', name: 'apply_patch', input: '{}' },
					{ id: 'msg_1', type: 'message' }
				]
			}
		})
	];

	const stream = await transform(chunks);
	const output = events(stream);
	assert.equal(
		output.filter((event) => event.type === 'response.output_item.added' && event.item?.type === 'custom_tool_call').length,
		1
	);
	assert.deepEqual(
		output.filter((event) => event.type === 'response.custom_tool_call_input.done').map((event) => event.input),
		[patch]
	);
	assert.doesNotMatch(stream, /<tool_call>|"input":"\{\}"/);
	assert.equal(output.at(-1).type, 'response.completed');
});

test('passes ordinary assistant text and structured function calls unchanged', async () => {
	const stream = await transform([
		sse('response.output_item.added', {
			output_index: 0,
			item: { type: 'message', id: 'msg_1', role: 'assistant', content: [] }
		}),
		sse('response.output_text.delta', { output_index: 0, delta: 'hello' }),
		sse('response.output_item.done', { output_index: 0, item: { type: 'message', id: 'msg_1', role: 'assistant', content: [] } }),
		sse('response.output_item.added', {
			output_index: 1,
			item: { type: 'function_call', id: 'fc_1', name: 'shell_command', call_id: 'fc_1', arguments: '{}' }
		}),
		sse('response.output_item.done', {
			output_index: 1,
			item: { type: 'function_call', id: 'fc_1', name: 'shell_command', call_id: 'fc_1', arguments: '{}' }
		}),
		sse('response.completed', { response: { output: [] } })
	]);
	assert.match(stream, /"delta":"hello"/);
	assert.match(stream, /"type":"function_call"/);
	assert.doesNotMatch(stream, /mimo_tool_call_parse_error/);
});

test('waits for late text deltas after an early message item done event', async () => {
	const patch = '*** Begin Patch\n*** Add File: late.txt\n+late\n*** End Patch';
	const markup = `<tool_call>\n<function=apply_patch>\n<parameter=patch_text>${patch}</parameter>\n</function>\n</tool_call>`;
	const stream = await transform([
		sse('response.output_item.added', {
			output_index: 0,
			item: { type: 'custom_tool_call', id: 'late_call', name: 'apply_patch', input: '{}' }
		}),
		sse('response.output_item.added', {
			output_index: 0,
			item: { type: 'message', id: 'late_message', role: 'assistant', content: [] }
		}),
		sse('response.output_text.delta', { output_index: 0, delta: markup.slice(0, 44) }),
		sse('response.output_item.done', {
			output_index: 0,
			item: { type: 'message', id: 'late_message', role: 'assistant', content: [] }
		}),
		sse('response.output_text.delta', { output_index: 0, delta: markup.slice(44) }),
		sse('response.output_text.done', { output_index: 0, text: markup }),
		sse('response.custom_tool_call_input.done', { output_index: 0, input: '{}' }),
		sse('response.output_item.done', {
			output_index: 0,
			item: { type: 'custom_tool_call', id: 'late_call', name: 'apply_patch', input: '{}' }
		}),
		sse('response.completed', {
			response: { output: [{ type: 'custom_tool_call', id: 'late_call', name: 'apply_patch', input: '{}' }] }
		})
	]);
	assert.match(stream, /"input":"\*\*\* Begin Patch/);
	assert.doesNotMatch(stream, /mimo_tool_call_parse_error/);
});

test('preserves commentary surrounding a textual tool call', async () => {
	const patch = '*** Begin Patch\n*** Add File: commentary.txt\n+kept\n*** End Patch';
	const commentary = 'I have enough context and will apply the change.\n\n';
	const markup = `<tool_call>\n<function=apply_patch>\n<parameter=patch>${patch}</parameter>\n</function>\n</tool_call>`;
	const stream = await transform([
		sse('response.output_item.added', {
			output_index: 1,
			item: { type: 'custom_tool_call', id: 'mixed_call', name: 'apply_patch', input: '{}' }
		}),
		sse('response.output_item.added', {
			output_index: 1,
			item: { type: 'message', id: 'mixed_message', role: 'assistant', content: [] }
		}),
		sse('response.output_text.delta', { output_index: 1, delta: commentary + markup }),
		sse('response.output_item.done', {
			output_index: 1,
			item: { type: 'message', id: 'mixed_message', role: 'assistant', content: [] }
		}),
		sse('response.custom_tool_call_input.done', { output_index: 1, input: '{}' }),
		sse('response.output_item.done', {
			output_index: 1,
			item: { type: 'custom_tool_call', id: 'mixed_call', name: 'apply_patch', input: '{}' }
		}),
		sse('response.completed', {
			response: {
				output: [
					{ id: 'mixed_call', type: 'custom_tool_call', name: 'apply_patch', input: '{}' },
					{ id: 'mixed_message', type: 'message', content: [{ type: 'output_text', text: commentary + markup }] }
				]
			}
		})
	]);
	assert.match(stream, /I have enough context and will apply the change/);
	assert.doesNotMatch(stream, /<tool_call>/);
	assert.match(stream, /commentary\.txt/);
	assert.match(stream, /response.custom_tool_call_input.done/);
	assert.doesNotMatch(stream, /mimo_tool_call_parse_error/);
});

test('does not duplicate native and textual tool calls in one Responses stream', async () => {
	const markup =
		'<tool_call><function=apply_patch><parameter=patch_text>*** Begin Patch\n+ok\n*** End Patch</parameter></function></tool_call>';
	const stream = await transform([
		sse('response.output_item.added', {
			output_index: 0,
			item: { type: 'function_call', id: 'native_1', call_id: 'native_1', name: 'shell_command', arguments: '{}' }
		}),
		sse('response.output_item.added', {
			output_index: 1,
			item: { type: 'custom_tool_call', id: 'textual_1', name: 'apply_patch', input: '{}' }
		}),
		sse('response.output_item.added', {
			output_index: 2,
			item: { type: 'message', id: 'msg_mixed', role: 'assistant', content: [] }
		}),
		sse('response.output_text.delta', { output_index: 2, delta: markup }),
		sse('response.output_item.done', { output_index: 2, item: { type: 'message', id: 'msg_mixed' } }),
		sse('response.output_item.done', { output_index: 0, item: { type: 'function_call', id: 'native_1' } }),
		sse('response.custom_tool_call_input.done', { output_index: 1, input: '{}' }),
		sse('response.output_item.done', { output_index: 1, item: { type: 'custom_tool_call', id: 'textual_1', input: '{}' } }),
		sse('response.completed', {
			response: {
				output: [
					{ type: 'function_call', id: 'native_1', name: 'shell_command', arguments: '{}' },
					{ type: 'custom_tool_call', id: 'textual_1', input: '{}' },
					{ type: 'message', id: 'msg_mixed' }
				]
			}
		})
	]);
	const output = events(stream);

	assert.equal(
		output.filter((event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call').length,
		1
	);
	assert.equal(
		output.filter((event) => event.type === 'response.output_item.added' && event.item?.type === 'custom_tool_call').length,
		1
	);
	assert.equal(output.filter((event) => event.type === 'response.custom_tool_call_input.done').length, 1);
	assert.equal(output.at(-1).type, 'response.completed');
});

test('passes native custom tool input that arrives after an empty item', async () => {
	const input = '{"patch_text":"*** Begin Patch\\n+ok\\n*** End Patch"}';
	const stream = await transform([
		sse('response.output_item.added', {
			output_index: 0,
			item: { type: 'custom_tool_call', id: 'custom_1', call_id: 'custom_1', name: 'apply_patch', input: '' }
		}),
		sse('response.custom_tool_call_input.delta', { output_index: 0, item_id: 'custom_1', delta: input }),
		sse('response.custom_tool_call_input.done', { output_index: 0, item_id: 'custom_1', input }),
		sse('response.output_item.done', {
			output_index: 0,
			item: { type: 'custom_tool_call', id: 'custom_1', call_id: 'custom_1', name: 'apply_patch', input }
		}),
		sse('response.completed', {
			response: { output: [{ type: 'custom_tool_call', id: 'custom_1', name: 'apply_patch', input }] }
		})
	]);
	const output = events(stream);

	assert.equal(output.filter((event) => event.type === 'response.custom_tool_call_input.done').length, 1);
	assert.match(stream, /smoke|Patch|apply_patch/u);
	assert.doesNotMatch(stream, /mimo_tool_call_parse_error/);
	assert.equal(output.at(-1).type, 'response.completed');
});

test('fails closed on incomplete textual tool markup', async () => {
	const logs = [];
	const stream = await transform(
		[
			sse('response.output_item.added', {
				output_index: 0,
				item: { type: 'custom_tool_call', id: 'call_1', name: 'apply_patch', input: '{}' }
			}),
			sse('response.output_item.added', {
				output_index: 1,
				item: { type: 'message', id: 'msg_1', role: 'assistant', content: [] }
			}),
			sse('response.output_text.delta', { output_index: 1, delta: '<tool_call><function=apply_patch>' }),
			sse('response.output_item.done', { output_index: 1, item: { type: 'message', id: 'msg_1' } }),
			sse('response.completed', { response: { output: [] } })
		],
		logs
	);
	assert.match(stream, /mimo_tool_call_parse_error/);
	assert.doesNotMatch(stream, /custom_tool_call_input.done/);
	assert.equal(logs.length, 1);
});

test('converts native Chat Completions tool calls into Responses events', async () => {
	const stream = await transform(
		[
			{
				/* The adapter also accepts JSON SSE payloads without an event name. */
			},
			sse('chat.completion.chunk', {
				id: 'chat_1',
				object: 'chat.completion.chunk',
				choices: [{ index: 0, delta: { role: 'assistant', content: 'Проверяю код. ' }, finish_reason: null }]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_1',
				choices: [
					{
						index: 0,
						delta: { tool_calls: [{ index: 0, id: 'call_shell', type: 'function', function: { name: 'shell_command' } }] },
						finish_reason: null
					}
				]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_1',
				choices: [
					{
						index: 0,
						delta: { tool_calls: [{ index: 0, function: { arguments: '{"command":"Get-' } }] },
						finish_reason: null
					}
				]
			}),
			sse('chat.completion.chunk', {
				id: 'chat_1',
				choices: [
					{
						index: 0,
						delta: { tool_calls: [{ index: 0, function: { arguments: 'ChildItem"}' } }] },
						finish_reason: 'tool_calls'
					}
				]
			}),
			'data: [DONE]\n\n'
		].filter((chunk) => typeof chunk === 'string')
	);
	const output = events(stream);
	const functionItem = output.find(
		(event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call'
	);

	assert.equal(functionItem.item.name, 'shell_command');
	assert.equal(functionItem.item.call_id, 'call_shell');
	assert.match(stream, /Проверяю код\./u);
	assert.match(stream, /response.function_call_arguments.delta/);
	assert.match(stream, /Get-ChildItem/);
	assert.deepEqual(
		output.find((event) => event.type === 'response.function_call_arguments.done').arguments,
		'{"command":"Get-ChildItem"}'
	);
	assert.equal(output.at(-1).type, 'response.completed');
});

test('supports multiple native Chat Completions tool calls and unicode arguments', async () => {
	const stream = await transform([
		sse('chat.completion.chunk', {
			id: 'chat_2',
			choices: [
				{
					delta: {
						tool_calls: [
							{ index: 1, id: 'call_b', type: 'function', function: { name: 'apply_patch', arguments: '{"text":"Привет"}' } },
							{ index: 0, id: 'call_a', type: 'function', function: { name: 'shell_command', arguments: '{"command":"pwd"}' } }
						]
					},
					finish_reason: 'tool_calls'
				}
			]
		}),
		'data: [DONE]\n\n'
	]);
	const output = events(stream);
	const calls = output
		.filter((event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call')
		.map((event) => event.item.name);

	assert.deepEqual(calls, ['apply_patch', 'shell_command']);
	assert.match(stream, /Привет/u);
	assert.match(stream, /pwd/u);
	assert.equal(output.filter((event) => event.type === 'response.function_call_arguments.done').length, 2);
	assert.equal(output.at(-1).type, 'response.completed');
});

test('fails closed when Chat Completions reports tool_calls without a call', async () => {
	const logs = [];
	const stream = await transform(
		[
			sse('chat.completion.chunk', {
				id: 'chat_3',
				choices: [{ delta: { content: 'tool now' }, finish_reason: 'tool_calls' }]
			}),
			'data: [DONE]\n\n'
		],
		logs
	);

	assert.match(stream, /mimo_tool_call_parse_error/);
	assert.doesNotMatch(logs.join('\n'), /tool now|arguments=/);
});

test('keeps an ordinary native Chat Completions stop as assistant text', async () => {
	const stream = await transform([
		sse('chat.completion.chunk', {
			id: 'chat_text',
			choices: [{ delta: { content: 'Готово.' }, finish_reason: 'stop' }]
		}),
		'data: [DONE]\n\n'
	]);
	const output = events(stream);

	assert.match(stream, /Готово/u);
	assert.equal(output.filter((event) => event.item?.type === 'function_call').length, 0);
	assert.equal(output.at(-1).type, 'response.completed');
});

test('fails closed when a native tool call has no function name', async () => {
	const logs = [];
	const stream = await transform(
		[
			sse('chat.completion.chunk', {
				id: 'chat_bad_tool',
				choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '{}' } }] }, finish_reason: 'tool_calls' }]
			}),
			'data: [DONE]\n\n'
		],
		logs
	);

	assert.match(stream, /mimo_tool_call_parse_error/);
	assert.match(logs.join('\n'), /output_index=0/);
	assert.doesNotMatch(logs.join('\n'), /\{\}/u);
});

test('converts completion-only Chat message tool calls', async () => {
	const stream = await transform([
		sse('chat.completion.chunk', {
			id: 'chat_message_tool',
			choices: [
				{
					message: {
						role: 'assistant',
						content: 'Проверяю файлы.',
						tool_calls: [
							{
								id: 'call_message_tool',
								type: 'function',
								function: { name: 'shell_command', arguments: '{"command":"Get-ChildItem"}' }
							}
						]
					},
					finish_reason: 'tool_calls'
				}
			]
		}),
		'data: [DONE]\n\n'
	]);
	const output = events(stream);

	assert.match(stream, /Проверяю файлы\./u);
	assert.equal(
		output.filter((event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call').length,
		1
	);
	assert.equal(
		output.find((event) => event.type === 'response.function_call_arguments.done').arguments,
		'{"command":"Get-ChildItem"}'
	);
	assert.equal(output.at(-1).type, 'response.completed');
});

test('generates a request-scoped call id when a completion-only tool call has none', async () => {
	const stream = await transform([
		sse('chat.completion.chunk', {
			id: 'chat_generated_id',
			choices: [
				{
					message: {
						tool_calls: [{ function: { name: 'shell_command', arguments: '{"command":"Get-Date"}' } }]
					},
					finish_reason: 'tool_calls'
				}
			]
		}),
		'data: [DONE]\n\n'
	]);
	const output = events(stream);
	const added = output.find((event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call');
	const done = output.find((event) => event.type === 'response.function_call_arguments.done');

	assert.equal(added.item.call_id, 'chat_generated_id_call_0');
	assert.equal(done.call_id, added.item.call_id);
});

test('merges final message tool calls with streamed fragments without duplication', async () => {
	const stream = await transform([
		sse('chat.completion.chunk', {
			id: 'chat_message_merge',
			choices: [
				{
					delta: {
						tool_calls: [{ index: 0, id: 'call_merge', function: { name: 'shell_command', arguments: '{"command":"Get-' } }]
					},
					finish_reason: null
				}
			]
		}),
		sse('chat.completion.chunk', {
			id: 'chat_message_merge',
			choices: [
				{
					message: {
						tool_calls: [
							{ id: 'call_merge', type: 'function', function: { name: 'shell_command', arguments: '{"command":"Get-Date"}' } }
						]
					},
					finish_reason: 'tool_calls'
				}
			]
		}),
		'data: [DONE]\n\n'
	]);
	const output = events(stream);

	assert.equal(
		output.filter((event) => event.type === 'response.output_item.added' && event.item?.type === 'function_call').length,
		1
	);
	assert.equal(output.filter((event) => event.type === 'response.function_call_arguments.done').length, 1);
	assert.equal(
		output.find((event) => event.type === 'response.function_call_arguments.done').arguments,
		'{"command":"Get-Date"}'
	);
});

test('fails closed on malformed completion-only tool arguments without logging them', async () => {
	const logs = [];
	const stream = await transform(
		[
			sse('chat.completion.chunk', {
				id: 'chat_bad_args',
				choices: [
					{
						message: {
							tool_calls: [{ id: 'call_bad_args', function: { name: 'shell_command', arguments: '{"command":' } }]
						},
						finish_reason: 'tool_calls'
					}
				]
			}),
			'data: [DONE]\n\n'
		],
		logs
	);

	assert.match(stream, /mimo_tool_call_parse_error/);
	assert.match(logs.join('\n'), /tool=shell_command/);
	assert.match(logs.join('\n'), /input_bytes=11/);
	assert.doesNotMatch(logs.join('\n'), /Get-Date|\{"command"/u);
});

test('flattens Mimo namespace requests and restores native Responses tool calls', async () => {
	const { body, mapping } = flattenMimoResponsesRequest({
		model: 'mimo-v2.5-pro',
		input: 'Run the MCP tool.',
		tools: [
			{
				type: 'namespace',
				name: 'mcp__node_repl',
				tools: [
					{
						type: 'function',
						name: 'js',
						inputSchema: { type: 'object', properties: { code: { type: 'string' } }, required: ['code'] }
					}
				]
			}
		]
	});
	assert.equal(body.tools[0].name, 'mcp__node_repl__js');
	assert.deepEqual(body.tools[0].parameters.required, ['code']);

	const stream = await transform(
		[
			sse('response.created', { response: { id: 'resp_namespace', output: [] } }),
			sse('response.output_item.added', {
				output_index: 0,
				item: {
					type: 'function_call',
					id: 'fc_namespace',
					call_id: 'call_namespace',
					name: 'mcp__node_repl__js',
					arguments: '{"code":"1+1"}'
				}
			}),
			sse('response.output_item.done', {
				output_index: 0,
				item: { type: 'function_call', id: 'fc_namespace', name: 'mcp__node_repl__js', arguments: '{"code":"1+1"}' }
			}),
			sse('response.completed', {
				response: {
					output: [{ type: 'function_call', id: 'fc_namespace', name: 'mcp__node_repl__js', arguments: '{"code":"1+1"}' }]
				}
			}),
			'data: [DONE]\n\n'
		],
		[],
		{ namespaceMapping: mapping }
	);
	const output = events(stream);
	const added = output.find((event) => event.type === 'response.output_item.added');
	const completed = output.at(-1).response.output[0];

	assert.equal(added.item.name, 'js');
	assert.equal(added.item.namespace, 'mcp__node_repl');
	assert.equal(completed.name, 'js');
	assert.equal(completed.namespace, 'mcp__node_repl');
});

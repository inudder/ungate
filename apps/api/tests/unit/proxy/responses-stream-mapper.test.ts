import { describe, expect, it } from 'vitest';

import { ResponsesSseProcessor, StreamStateFactory } from 'src/proxy/responses-stream-mapper';

function encodeSse(events: Record<string, unknown>[]): string {
	return events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join('');
}

function collectChunks(events: Record<string, unknown>[]) {
	const state = StreamStateFactory.create('gpt-5.3-codex');
	const out = ResponsesSseProcessor.process(state, encodeSse(events));
	const chunks = out.filter((x) => x.type === 'chunk').map((x) => x.data!);
	const finish = chunks.at(-1)?.choices as { finish_reason?: string }[] | undefined;
	const toolDeltas = chunks.flatMap(
		(c) => (c.choices as { delta?: { tool_calls?: unknown[] } }[] | undefined)?.[0]?.delta?.tool_calls ?? []
	).length;

	return {
		chunks,
		finishReason: finish?.[0]?.finish_reason ?? null,
		toolDeltas,
		doneCount: out.filter((x) => x.type === 'done').length
	};
}

describe('responses-stream-mapper replay', () => {
	it('handles text-only stream', () => {
		const events = [
			{ type: 'response.created', response: { id: 'resp_text' } },
			{ type: 'response.output_text.delta', delta: 'hello' },
			{ type: 'response.completed', response: { usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } }
		];
		const got = collectChunks(events);

		expect(got.finishReason).toBe('stop');
		expect(got.toolDeltas).toBe(0);
		expect(got.doneCount).toBe(1);
	});

	it('handles function_call added + arguments delta + done', () => {
		const events = [
			{ type: 'response.created', response: { id: 'resp_fc' } },
			{
				type: 'response.output_item.added',
				output_index: 0,
				item: { id: 'fc_1', type: 'function_call', call_id: 'call_1', name: 'ReadFile', arguments: '' }
			},
			{
				type: 'response.function_call_arguments.delta',
				output_index: 0,
				delta: '{"path":"a.txt"}'
			},
			{
				type: 'response.output_item.done',
				output_index: 0,
				item: { id: 'fc_1', type: 'function_call', call_id: 'call_1', name: 'ReadFile', arguments: '{"path":"a.txt"}' }
			},
			{ type: 'response.completed', response: {} }
		];
		const got = collectChunks(events);

		expect(got.finishReason).toBe('tool_calls');
		expect(got.toolDeltas).toBeGreaterThan(0);
	});

	it('handles custom_tool_call with custom_tool_call_input delta', () => {
		const events = [
			{ type: 'response.created', response: { id: 'resp_custom' } },
			{
				type: 'response.output_item.added',
				output_index: 1,
				item: { id: 'ctc_1', type: 'custom_tool_call', call_id: 'call_custom_1', custom: { name: 'EditFile' } }
			},
			{
				type: 'response.custom_tool_call_input.delta',
				output_index: 1,
				delta: '{"path":"a.txt","edit":"x"}'
			},
			{
				type: 'response.output_item.done',
				output_index: 1,
				item: {
					id: 'ctc_1',
					type: 'custom_tool_call',
					call_id: 'call_custom_1',
					custom: { name: 'EditFile' },
					input: { path: 'a.txt', edit: 'x' }
				}
			},
			{ type: 'response.completed', response: {} }
		];
		const got = collectChunks(events);

		expect(got.finishReason).toBe('tool_calls');
		expect(got.toolDeltas).toBeGreaterThan(0);
	});

	it('handles mixed text + custom_tool_call stream', () => {
		const events = [
			{ type: 'response.created', response: { id: 'resp_mix' } },
			{ type: 'response.output_text.delta', delta: 'prep' },
			{
				type: 'response.output_item.added',
				output_index: 2,
				item: { id: 'ctc_2', type: 'custom_tool_call', call_id: 'call_custom_2', custom: { name: 'WriteFile' } }
			},
			{
				type: 'response.custom_tool_call_input.delta',
				output_index: 2,
				delta: '{"path":"b.txt","content":"ok"}'
			},
			{
				type: 'response.output_item.done',
				output_index: 2,
				item: {
					id: 'ctc_2',
					type: 'custom_tool_call',
					call_id: 'call_custom_2',
					custom: { name: 'WriteFile' },
					input: { path: 'b.txt', content: 'ok' }
				}
			},
			{ type: 'response.completed', response: {} }
		];
		const got = collectChunks(events);

		expect(got.finishReason).toBe('tool_calls');
		expect(got.toolDeltas).toBeGreaterThan(0);
	});

	it('emits assistant text from output_text.done when delta never arrived', () => {
		const events = [
			{ type: 'response.created', response: { id: 'resp_done_only' } },
			{ type: 'response.output_text.done', text: 'from-done' },
			{ type: 'response.completed', response: {} }
		];
		const got = collectChunks(events);
		const chunkWithText = got.chunks.find((chunk) => {
			const delta = (chunk.choices as Record<string, unknown>[])[0]?.delta as Record<string, unknown> | undefined;

			return delta?.content === 'from-done';
		});

		expect(chunkWithText).toBeTruthy();
		expect(got.finishReason).toBe('stop');
	});

	it('falls back to response.output assistant text on completion', () => {
		const events = [
			{ type: 'response.created', response: { id: 'resp_fallback' } },
			{
				type: 'response.completed',
				response: {
					output: [
						{
							type: 'message',
							role: 'assistant',
							content: [{ type: 'output_text', text: 'fallback-text' }]
						}
					],
					usage: { input_tokens: 2, output_tokens: 4, total_tokens: 6 }
				}
			}
		];
		const got = collectChunks(events);
		const chunkWithText = got.chunks.find((chunk) => {
			const delta = (chunk.choices as Record<string, unknown>[])[0]?.delta as Record<string, unknown> | undefined;

			return delta?.content === 'fallback-text';
		});
		const usageChunk = got.chunks.find((chunk) => chunk.usage);

		expect(chunkWithText).toBeTruthy();
		expect(usageChunk?.usage).toEqual({
			prompt_tokens: 2,
			completion_tokens: 4,
			total_tokens: 6
		});
		expect(got.finishReason).toBe('stop');
	});
});

describe('responses-stream-mapper usage', () => {
	function complete(usage?: unknown) {
		const state = StreamStateFactory.create('gpt-6.1-sol');
		const response = usage === undefined ? {} : { usage };
		const out = ResponsesSseProcessor.process(
			state,
			encodeSse([
				{ type: 'response.created', response: { id: 'resp_usage' } },
				{ type: 'response.output_text.delta', delta: 'OK' },
				{ type: 'response.completed', response }
			])
		);
		const chunks = out.filter((x) => x.type === 'chunk').map((x) => x.data!);

		return { state, finalChunk: chunks.at(-1)!, doneCount: out.filter((x) => x.type === 'done').length };
	}

	it('maps cached and reasoning token details into the final chunk and state', () => {
		const got = complete({
			input_tokens: 183,
			input_tokens_details: { cached_tokens: 128 },
			output_tokens: 28,
			output_tokens_details: { reasoning_tokens: 24 },
			total_tokens: 211
		});
		const expected = {
			prompt_tokens: 183,
			completion_tokens: 28,
			total_tokens: 211,
			prompt_tokens_details: { cached_tokens: 128 },
			completion_tokens_details: { reasoning_tokens: 24 }
		};

		expect(got.finalChunk.usage).toEqual(expected);
		expect(got.state.usage).toEqual(expected);
		expect(got.doneCount).toBe(1);
	});

	it('omits details objects the upstream did not send', () => {
		const got = complete({ input_tokens: 37, output_tokens: 5, total_tokens: 42 });

		expect(got.finalChunk.usage).toEqual({ prompt_tokens: 37, completion_tokens: 5, total_tokens: 42 });
	});

	it.each([
		['missing', { input_tokens: 37, output_tokens: 5 }],
		['zero', { input_tokens: 37, output_tokens: 5, total_tokens: 0 }]
	])('recomputes total_tokens when upstream total is %s', (_label, usage) => {
		expect(complete(usage).state.usage?.total_tokens).toBe(42);
	});

	it('skips non-numeric, fractional and negative counts', () => {
		const got = complete({
			input_tokens: '37',
			prompt_tokens: 37,
			output_tokens: -1,
			completion_tokens: 5.5,
			total_tokens: Number.NaN,
			input_tokens_details: { cached_tokens: -3 },
			output_tokens_details: { reasoning_tokens: 'many' }
		});

		expect(got.state.usage).toEqual({ prompt_tokens: 37, completion_tokens: 0, total_tokens: 37 });
	});

	it.each([
		['absent', undefined],
		['null', null],
		['empty', {}]
	])('leaves usage unset when response.completed usage is %s', (_label, usage) => {
		const got = complete(usage);

		expect(got.state.usage).toBeUndefined();
		expect(got.finalChunk).not.toHaveProperty('usage');
		expect(got.doneCount).toBe(1);
	});
});

describe('responses-stream-mapper terminal events', () => {
	function run(events: Record<string, unknown>[]) {
		const state = StreamStateFactory.create('gpt-6.1-sol');
		const out = ResponsesSseProcessor.process(state, encodeSse(events));

		return {
			state,
			chunks: out.filter((x) => x.type === 'chunk').map((x) => x.data!),
			errors: out.filter((x) => x.type === 'error').map((x) => x.data!),
			doneCount: out.filter((x) => x.type === 'done').length
		};
	}

	it.each([
		['max_output_tokens', 'length'],
		['content_filter', 'content_filter'],
		[undefined, 'length']
	])('maps response.incomplete reason %s to finish_reason %s with usage', (reason, finish) => {
		const got = run([
			{ type: 'response.output_text.delta', delta: '{"title":' },
			{
				type: 'response.incomplete',
				response: {
					status: 'incomplete',
					...(reason && { incomplete_details: { reason } }),
					usage: { input_tokens: 10, output_tokens: 64, total_tokens: 74 }
				}
			}
		]);
		const finalChunk = got.chunks.at(-1)!;

		expect((finalChunk.choices as { finish_reason: string }[])[0].finish_reason).toBe(finish);
		expect(finalChunk.usage).toEqual({ prompt_tokens: 10, completion_tokens: 64, total_tokens: 74 });
		expect(got.state.finishReason).toBe(finish);
		expect(got.doneCount).toBe(1);
	});

	it('emits one error payload and no done for response.failed', () => {
		const got = run([
			{ type: 'response.output_text.delta', delta: 'par' },
			{
				type: 'response.failed',
				response: { status: 'failed', error: { code: 'server_error', message: 'Upstream overloaded' } }
			}
		]);

		expect(got.errors).toEqual([{ error: { message: 'Upstream overloaded', type: 'api_error', code: 'server_error' } }]);
		expect(got.state.error).toEqual({ message: 'Upstream overloaded', code: 'server_error' });
		expect(got.doneCount).toBe(0);
	});

	it('reports an error event followed by response.failed once, keeping failed usage', () => {
		const got = run([
			{ type: 'error', code: 'rate_limit_exceeded', message: 'Slow down' },
			{
				type: 'response.failed',
				response: { status: 'failed', error: { message: 'other' }, usage: { input_tokens: 9, output_tokens: 0 } }
			}
		]);

		expect(got.errors).toHaveLength(1);
		expect(got.state.error).toEqual({ message: 'Slow down', code: 'rate_limit_exceeded' });
		expect(got.state.usage).toEqual({ prompt_tokens: 9, completion_tokens: 0, total_tokens: 9 });
	});

	it('falls back to a generic message when response.failed has no error', () => {
		expect(run([{ type: 'response.failed', response: {} }]).state.error).toEqual({ message: 'Upstream response failed' });
	});
});

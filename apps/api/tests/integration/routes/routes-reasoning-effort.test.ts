import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { ModelMappings } from 'src/database/model-mappings';
import { ProviderSettings } from 'src/database/provider-settings';
import openaiPlugin from 'src/routes/openai';
import responsesPlugin from 'src/routes/responses';
import { logger } from 'src/utils/logger';

import { withPlugin } from '../test-harness';

import type { ModelMappingConfig } from '@ungate/shared';
import type { OpenAIReasoningEffort } from 'src/types/openai';

type Provider = ModelMappingConfig['provider'];
const upstreamModels: Record<Provider, string> = { claude: 'claude-sonnet-5-5', minimax: 'MiniMax-M3', openai: 'gpt-5.4' };
const providers: Provider[] = ['claude', 'minimax', 'openai'];
const endpoints = ['/v1/chat/completions', '/v1/responses'];
const logMessages = vi.fn<(...args: unknown[]) => void>();
const cases: {
	name: string;
	client?: OpenAIReasoningEffort | null;
	budget: ModelMappingConfig['reasoningBudget'];
	expected?: OpenAIReasoningEffort;
	source: string;
}[] = [
	{ name: 'high beats low', client: 'high', budget: 'low', expected: 'high', source: 'client' },
	{ name: 'low beats high', client: 'low', budget: 'high', expected: 'low', source: 'client' },
	{ name: 'none beats high', client: 'none', budget: 'high', expected: 'none', source: 'client' },
	{ name: 'max stays max', client: 'max', budget: 'low', expected: 'max', source: 'client' },
	{ name: 'missing inherits medium', budget: 'medium', expected: 'medium', source: 'ungate' },
	{ name: 'null inherits medium', client: null, budget: 'medium', expected: 'medium', source: 'ungate' },
	{ name: 'missing uses model default', budget: null, source: 'model_default' },
	{ name: 'null uses model default', client: null, budget: null, source: 'model_default' }
];

function configureProvider(provider: Provider, budget: ModelMappingConfig['reasoningBudget']): void {
	ModelMappings.replace([
		{ id: 'custom-high', label: 'test', provider, upstreamModel: upstreamModels[provider], reasoningBudget: budget, sortOrder: 0 }
	]);
	ProviderSettings.upsertOAuth(provider, {
		accessToken: 'test-token',
		refreshToken: 'test-refresh',
		expiresAt: Date.now() + 3600000,
		accountId: 'test-account'
	});
}

function requestPayload(endpoint: string, fields: Record<string, unknown>, stream = false): Record<string, unknown> {
	return {
		model: 'custom-high',
		stream,
		...(endpoint === '/v1/responses'
			? { input: 'Reply OK.', max_output_tokens: 4096 }
			: { messages: [{ role: 'user', content: 'Reply OK.' }], max_tokens: 4096 }),
		...fields
	};
}

function sse(events: Record<string, unknown>[]): Response {
	return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(''), {
		headers: { 'content-type': 'text/event-stream' }
	});
}

function upstreamResponse(provider: Provider, stream: boolean): Response {
	if (provider === 'openai') {
		return sse([
			{ type: 'response.output_text.delta', delta: 'OK' },
			{ type: 'response.completed', response: { usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } }
		]);
	}
	if (provider === 'claude') {
		if (stream) {
			return sse([
				{ type: 'message_start', message: { id: 'msg_test', usage: { input_tokens: 1, output_tokens: 0 } } },
				{ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
				{ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'OK' } },
				{ type: 'content_block_stop', index: 0 },
				{ type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } },
				{ type: 'message_stop' }
			]);
		}

		return Response.json({
			id: 'msg_test',
			model: upstreamModels.claude,
			content: [{ type: 'text', text: 'OK' }],
			stop_reason: 'end_turn',
			usage: { input_tokens: 1, output_tokens: 1 }
		});
	}
	if (stream) {
		return sse([
			{ id: 'chat_test', choices: [{ index: 0, delta: { role: 'assistant', content: 'OK' }, finish_reason: null }] },
			{
				id: 'chat_test',
				choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
				usage: { prompt_tokens: 1, completion_tokens: 1 }
			}
		]);
	}

	return Response.json({
		id: 'chat_test',
		model: upstreamModels.minimax,
		choices: [{ index: 0, message: { role: 'assistant', content: 'OK' }, finish_reason: 'stop' }],
		usage: { prompt_tokens: 1, completion_tokens: 1 }
	});
}

function expectUpstreamEffort(provider: Provider, payload: Record<string, unknown>, effort?: OpenAIReasoningEffort): void {
	expect(payload.reasoning_effort).toBeUndefined();
	expect(payload.reasoning_budget).toBeUndefined();
	if (provider === 'openai') {
		expect(payload.reasoning).toEqual(effort === undefined ? undefined : { effort });

		return;
	}
	expect(payload.reasoning).toBeUndefined();
	const thinkingType = effort === 'none' ? 'disabled' : 'adaptive';
	expect(payload.thinking).toEqual(effort === undefined ? undefined : { type: thinkingType });
	expect(payload.output_config).toEqual(
		provider === 'claude' && effort !== undefined && effort !== 'none' ? { effort } : undefined
	);
}

describe('reasoning effort at the upstream transport', () => {
	beforeEach(() => {
		logMessages.mockClear();
		vi.spyOn(logger, 'log').mockImplementation(logMessages);
		vi.spyOn(logger, 'error').mockImplementation(() => {});
	});
	afterEach(() => {
		vi.unstubAllGlobals();
		vi.restoreAllMocks();
	});

	for (const provider of providers) {
		for (const endpoint of endpoints) {
			for (const stream of [false, true]) {
				it.each(cases)(`${provider} ${endpoint} stream=${stream}: $name`, async ({ client, budget, expected, source }) => {
					configureProvider(provider, budget);
					const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(upstreamResponse(provider, stream));
					vi.stubGlobal('fetch', fetchMock);
					const fields = endpoint === '/v1/responses' ? { reasoning: { effort: client } } : { reasoning_effort: client };
					const app = await withPlugin(endpoint === '/v1/responses' ? responsesPlugin : openaiPlugin, { apiKey: 'test-key' });
					try {
						const response = await app.inject({
							method: 'POST',
							url: endpoint,
							headers: { 'x-api-key': 'test-key' },
							payload: requestPayload(endpoint, fields, stream)
						});
						expect(response.statusCode).toBe(200);
						expect(response.body).toContain('OK');
						expect(fetchMock).toHaveBeenCalledTimes(1);
						const payload = JSON.parse(fetchMock.mock.calls[0][1]!.body as string) as Record<string, unknown>;
						expect(payload.model).toBe(upstreamModels[provider]);
						expectUpstreamEffort(provider, payload, expected);
						expect(logMessages).toHaveBeenCalledWith(
							`[Reasoning] provider=${provider} model=${upstreamModels[provider]} effort=${expected ?? 'default'} source=${source}`
						);
					} finally {
						await app.close();
					}
				});
			}
			it.each(['', 'unknown', 'off', 42])(
				`${provider} ${endpoint}: rejects invalid effort %s before transport`,
				async (effort) => {
					configureProvider(provider, 'high');
					const fetchMock = vi.fn<typeof fetch>();
					vi.stubGlobal('fetch', fetchMock);
					const fields = endpoint === '/v1/responses' ? { reasoning: { effort } } : { reasoning_effort: effort };
					const app = await withPlugin(endpoint === '/v1/responses' ? responsesPlugin : openaiPlugin, { apiKey: 'test-key' });
					try {
						const response = await app.inject({
							method: 'POST',
							url: endpoint,
							headers: { 'x-api-key': 'test-key' },
							payload: requestPayload(endpoint, fields)
						});
						expect(response.statusCode).toBe(400);
						expect(response.body).toContain('Invalid reasoning effort');
						expect(fetchMock).not.toHaveBeenCalled();
					} finally {
						await app.close();
					}
				}
			);
			it(`${provider} ${endpoint}: preserves unsupported none and returns the upstream rejection once`, async () => {
				configureProvider(provider, 'high');
				const fetchMock = vi
					.fn<typeof fetch>()
					.mockResolvedValueOnce(
						Response.json(
							{ error: { message: 'Selected reasoning is not supported', type: 'invalid_request_error' } },
							{ status: 400 }
						)
					);
				vi.stubGlobal('fetch', fetchMock);
				const app = await withPlugin(endpoint === '/v1/responses' ? responsesPlugin : openaiPlugin, { apiKey: 'test-key' });
				try {
					const response = await app.inject({
						method: 'POST',
						url: endpoint,
						headers: { 'x-api-key': 'test-key' },
						payload: requestPayload(endpoint, { reasoning: { effort: 'none' } }, true)
					});
					expect(response.statusCode).toBe(400);
					expect(response.body).toContain('Selected reasoning is not supported');
					expect(fetchMock).toHaveBeenCalledTimes(1);
					expectUpstreamEffort(
						provider,
						JSON.parse(fetchMock.mock.calls[0][1]!.body as string) as Record<string, unknown>,
						'none'
					);
				} finally {
					await app.close();
				}
			});
		}
		it(`${provider}: nested effort wins a conflicting Chat Completions field`, async () => {
			configureProvider(provider, 'medium');
			const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(upstreamResponse(provider, false));
			vi.stubGlobal('fetch', fetchMock);
			const app = await withPlugin(openaiPlugin, { apiKey: 'test-key' });
			try {
				const response = await app.inject({
					method: 'POST',
					url: '/v1/chat/completions',
					headers: { 'x-api-key': 'test-key' },
					payload: requestPayload('/v1/chat/completions', { reasoning_effort: 'high', reasoning: { effort: 'low' } })
				});
				expect(response.statusCode).toBe(200);
				expectUpstreamEffort(provider, JSON.parse(fetchMock.mock.calls[0][1]!.body as string) as Record<string, unknown>, 'low');
			} finally {
				await app.close();
			}
		});
		it(`${provider}: Responses minimal reaches the provider as low`, async () => {
			configureProvider(provider, 'high');
			const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(upstreamResponse(provider, false));
			vi.stubGlobal('fetch', fetchMock);
			const app = await withPlugin(responsesPlugin, { apiKey: 'test-key' });
			try {
				const response = await app.inject({
					method: 'POST',
					url: '/v1/responses',
					headers: { 'x-api-key': 'test-key' },
					payload: requestPayload('/v1/responses', { reasoning: { effort: 'minimal' } })
				});
				expect(response.statusCode).toBe(200);
				expectUpstreamEffort(provider, JSON.parse(fetchMock.mock.calls[0][1]!.body as string) as Record<string, unknown>, 'low');
			} finally {
				await app.close();
			}
		});
	}
	it.each(endpoints)('supports an unmapped Claude legacy suffix at %s', async (endpoint) => {
		configureProvider('claude', null);
		ModelMappings.replace([]);
		const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(upstreamResponse('claude', false));
		vi.stubGlobal('fetch', fetchMock);
		const app = await withPlugin(endpoint === '/v1/responses' ? responsesPlugin : openaiPlugin, { apiKey: 'test-key' });
		try {
			const response = await app.inject({
				method: 'POST',
				url: endpoint,
				headers: { 'x-api-key': 'test-key' },
				payload: requestPayload(endpoint, { model: 'claude-4.6-sonnet-low' })
			});
			expect(response.statusCode).toBe(200);
			const payload = JSON.parse(fetchMock.mock.calls[0][1]!.body as string) as Record<string, unknown>;
			expect(payload.model).toBe('claude-sonnet-4-6');
			expectUpstreamEffort('claude', payload, 'low');
		} finally {
			await app.close();
		}
	});
});

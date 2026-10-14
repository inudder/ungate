import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { OpenAiClient } from 'src/proxy/openai-client';

import type { ChatCompletionUsage } from 'src/types/openai';

interface ChatCompletionJson {
	choices: { message?: { content: string | null }; finish_reason: string | null }[];
	usage?: ChatCompletionUsage;
}

const getProviderSettingsMock = vi.fn();

vi.mock('src/database/provider-settings', () => ({
	ProviderSettings: {
		get: (...args: unknown[]) => getProviderSettingsMock(...args)
	}
}));

vi.mock('src/database/app-settings', () => ({
	Settings: {
		get: () => ({ extraInstruction: null })
	}
}));

vi.mock('src/utils/logger', () => ({
	logger: { log: vi.fn(), error: vi.fn(), warn: vi.fn() }
}));

const UPSTREAM_USAGE = {
	input_tokens: 37,
	input_tokens_details: { cached_tokens: 16 },
	output_tokens: 5,
	output_tokens_details: { reasoning_tokens: 3 },
	total_tokens: 42
};

function sseResponse(events: Record<string, unknown>[]): Response {
	const body = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join('');

	return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } });
}

function upstreamEvents(completed = true): Record<string, unknown>[] {
	const events: Record<string, unknown>[] = [
		{ type: 'response.created', response: { id: 'resp_usage' } },
		{ type: 'response.output_text.delta', delta: 'OK' }
	];

	if (completed) {
		events.push({ type: 'response.completed', response: { usage: UPSTREAM_USAGE } });
	}

	return events;
}

async function readJson(response: Response): Promise<ChatCompletionJson> {
	const json: unknown = await response.json();

	return json as ChatCompletionJson;
}

async function readStreamFrames(response: Response): Promise<string[]> {
	const text = await response.text();

	return text
		.split('\n\n')
		.filter((frame) => frame.startsWith('data: '))
		.map((frame) => frame.slice('data: '.length));
}

function chatRequest(model: string, stream = false) {
	return { model, messages: [{ role: 'user' as const, content: 'Reply with the single word OK.' }], max_tokens: 64, stream };
}

describe('OpenAiClient usage', () => {
	beforeEach(() => {
		getProviderSettingsMock.mockReturnValue({ accessToken: 'test-token', accountId: 'acct-test' });
	});

	afterEach(() => {
		vi.unstubAllGlobals();
		vi.clearAllMocks();
	});

	it.each(['gpt-6.1-sol', 'gpt-5.4'])('returns upstream usage and token context for non-stream %s', async (model) => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(upstreamEvents())));

		const { response, context } = await OpenAiClient.proxy(chatRequest(model));
		const json = await readJson(response);

		expect(json.choices[0].message?.content).toBe('OK');
		expect(json.usage).toEqual({
			prompt_tokens: 37,
			completion_tokens: 5,
			total_tokens: 42,
			prompt_tokens_details: { cached_tokens: 16 },
			completion_tokens_details: { reasoning_tokens: 3 }
		});
		expect(context).toMatchObject({ source: 'openai', inputTokens: 37, outputTokens: 5, cacheReadTokens: 16 });
	});

	it('sends the prompt cache key as the Codex session_id header', async () => {
		const fetchMock = vi.fn().mockResolvedValue(sseResponse(upstreamEvents()));
		vi.stubGlobal('fetch', fetchMock);

		await OpenAiClient.proxy(chatRequest('gpt-6.1-sol'));

		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		const sentBody = JSON.parse(init.body as string) as { prompt_cache_key?: string };
		const headers = init.headers as Record<string, string>;

		expect(sentBody.prompt_cache_key).toMatch(/^ungate-[0-9a-f]{32}$/);
		expect(headers.session_id).toBe(sentBody.prompt_cache_key);
	});

	it('omits usage when the upstream stream ends without response.completed', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(upstreamEvents(false))));

		const { response, context } = await OpenAiClient.proxy(chatRequest('gpt-6.1-sol'));
		const json = await readJson(response);

		expect(json.choices[0].message?.content).toBe('OK');
		expect(json).not.toHaveProperty('usage');
		expect(context).toMatchObject({ inputTokens: 0, outputTokens: 0, cacheReadTokens: 0 });
	});

	it('adds token details to the final stream chunk', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(upstreamEvents())));

		const { response } = await OpenAiClient.proxy(chatRequest('gpt-6.1-sol', true));
		const frames = await readStreamFrames(response);
		const usageChunks = frames
			.filter((frame) => frame !== '[DONE]')
			.map((frame) => JSON.parse(frame) as ChatCompletionJson)
			.filter((chunk) => chunk.usage);

		expect(frames.at(-1)).toBe('[DONE]');
		expect(usageChunks).toHaveLength(1);
		expect(usageChunks[0].choices[0].finish_reason).toBe('stop');
		expect(usageChunks[0].usage).toEqual({
			prompt_tokens: 37,
			completion_tokens: 5,
			total_tokens: 42,
			prompt_tokens_details: { cached_tokens: 16 },
			completion_tokens_details: { reasoning_tokens: 3 }
		});
	});
});

describe('OpenAiClient terminal upstream events', () => {
	const INCOMPLETE = {
		type: 'response.incomplete',
		response: {
			incomplete_details: { reason: 'max_output_tokens' },
			usage: { input_tokens: 10, output_tokens: 64, total_tokens: 74 }
		}
	};
	const FAILED = { type: 'response.failed', response: { error: { code: 'server_error', message: 'Upstream overloaded' } } };

	beforeEach(() => {
		getProviderSettingsMock.mockReturnValue({ accessToken: 'test-token', accountId: 'acct-test' });
	});

	afterEach(() => {
		vi.unstubAllGlobals();
		vi.clearAllMocks();
	});

	it('returns finish_reason length and usage for a non-stream incomplete response', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse([...upstreamEvents(false), INCOMPLETE])));

		const { response, context } = await OpenAiClient.proxy(chatRequest('gpt-6.1-sol'));
		const json = await readJson(response);

		expect(response.status).toBe(200);
		expect(json.choices[0].finish_reason).toBe('length');
		expect(json.choices[0].message?.content).toBe('OK');
		expect(json.usage).toEqual({ prompt_tokens: 10, completion_tokens: 64, total_tokens: 74 });
		expect(context).toMatchObject({ inputTokens: 10, outputTokens: 64 });
	});

	it('returns an HTTP 502 error for a non-stream failed response', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse([...upstreamEvents(false), FAILED])));

		const { response } = await OpenAiClient.proxy(chatRequest('gpt-6.1-sol'));
		const json: unknown = await response.json();

		expect(response.status).toBe(502);
		expect(json).toEqual({ error: { message: 'Upstream overloaded', type: 'api_error', code: 'server_error' } });
	});

	it('streams finish_reason length then DONE for an incomplete response', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse([...upstreamEvents(false), INCOMPLETE])));

		const { response } = await OpenAiClient.proxy(chatRequest('gpt-6.1-sol', true));
		const frames = await readStreamFrames(response);
		const finalChunk = JSON.parse(frames.at(-2)!) as ChatCompletionJson;

		expect(frames.at(-1)).toBe('[DONE]');
		expect(finalChunk.choices[0].finish_reason).toBe('length');
		expect(finalChunk.usage?.completion_tokens).toBe(64);
	});

	it('streams an error frame without DONE for a failed response', async () => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse([...upstreamEvents(false), FAILED])));

		const { response } = await OpenAiClient.proxy(chatRequest('gpt-6.1-sol', true));
		const frames = await readStreamFrames(response);

		expect(frames).not.toContain('[DONE]');
		expect(JSON.parse(frames.at(-1)!)).toEqual({
			error: { message: 'Upstream overloaded', type: 'api_error', code: 'server_error' }
		});
	});
});

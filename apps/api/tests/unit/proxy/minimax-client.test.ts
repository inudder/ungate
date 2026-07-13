import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { buildMiniMaxRequestBody, normalizeMiniMaxUpstreamResponse, proxyMiniMaxRequest } from 'src/proxy/minimax-client';

import type { OpenAIChatRequest, OpenAITool } from 'src/types/openai';

const getProviderMock = vi.fn();
const getProviderSettingsMock = vi.fn();

vi.mock('src/auth', () => ({
	getProvider: (...args: unknown[]) => getProviderMock(...args)
}));

vi.mock('src/database/provider-settings', () => ({
	ProviderSettings: {
		get: (...args: unknown[]) => getProviderSettingsMock(...args)
	}
}));

function request(tools: OpenAITool[], toolChoice: OpenAIChatRequest['tool_choice'] = 'auto'): OpenAIChatRequest {
	return {
		model: 'miniMax-M3',
		messages: [{ role: 'user', content: 'hello' }],
		stream: true,
		tools,
		tool_choice: toolChoice
	};
}

describe('minimax-client', () => {
	beforeEach(() => {
		getProviderSettingsMock.mockReturnValue({ baseUrl: 'https://api.minimax.io/' });
		getProviderMock.mockReturnValue({ getAuthHeader: vi.fn().mockResolvedValue('Bearer test-key') });
	});

	afterEach(() => {
		vi.unstubAllGlobals();
		vi.clearAllMocks();
	});

	it('keeps named function tools and drops unsupported unnamed Codex tools', () => {
		const validTool: OpenAITool = {
			type: 'function',
			function: {
				name: 'exec_command',
				description: 'Run a command',
				parameters: { type: 'object' }
			}
		};
		const unsupportedNamespaceTool = {
			type: 'function',
			function: { name: 'mcp__context7', description: 'Unsupported namespace tool', parameters: undefined }
		} as unknown as OpenAITool;

		const body = buildMiniMaxRequestBody(request([validTool, unsupportedNamespaceTool]));

		expect(body).toMatchObject({ tools: [validTool], tool_choice: 'auto' });
	});

	it('omits tool choice when no valid MiniMax tools remain', () => {
		const unnamedTool = {
			type: 'function',
			function: { name: '', description: 'Unsupported custom tool' }
		} as OpenAITool;

		const body = buildMiniMaxRequestBody(request([unnamedTool], 'required'));

		expect(body).not.toHaveProperty('tools');
		expect(body).not.toHaveProperty('tool_choice');
	});

	it('maps MiniMax reasoning effort none to disabled thinking', () => {
		const body = buildMiniMaxRequestBody({
			...request([]),
			reasoning_effort: 'none'
		});

		expect(body).toMatchObject({ thinking: { type: 'disabled' } });
		expect(body).not.toHaveProperty('reasoning');
	});

	it('maps any provided MiniMax reasoning effort other than none to adaptive thinking', () => {
		const body = buildMiniMaxRequestBody({
			...request([]),
			reasoning: { effort: 'xhigh' }
		});

		expect(body).toMatchObject({ thinking: { type: 'adaptive' } });
	});

	it('treats default MiniMax reasoning effort as adaptive thinking without inventing omitted effort', () => {
		const defaultBody = buildMiniMaxRequestBody({
			...request([]),
			reasoning: { effort: 'default' as OpenAIChatRequest['reasoning']['effort'] }
		});
		const omittedBody = buildMiniMaxRequestBody(request([]));

		expect(defaultBody).toMatchObject({ thinking: { type: 'adaptive' } });
		expect(omittedBody).not.toHaveProperty('thinking');
	});

	it('preserves data URL images and converts auto detail to MiniMax default', () => {
		const body = buildMiniMaxRequestBody({
			...request([]),
			messages: [
				{
					role: 'developer',
					content: [
						{ type: 'text', text: 'Describe the image.' },
						{ type: 'image_url', image_url: { url: 'data:image/png;base64,abc', detail: 'auto' } }
					]
				}
			]
		});

		expect(body.messages).toEqual([
			{
				role: 'system',
				content: [
					{ type: 'text', text: 'Describe the image.' },
					{ type: 'image_url', image_url: { url: 'data:image/png;base64,abc', detail: 'default' } }
				]
			}
		]);
	});

	it('uses the OpenAI-compatible chat completions endpoint for MiniMax', async () => {
		const fetchMock = vi.fn().mockResolvedValue(
			new Response(JSON.stringify({ usage: { prompt_tokens: 3, completion_tokens: 5 } }), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			})
		);
		vi.stubGlobal('fetch', fetchMock);

		const result = await proxyMiniMaxRequest({ ...request([]), stream: false });

		expect(fetchMock).toHaveBeenCalledWith(
			'https://api.minimax.io/v1/chat/completions',
			expect.objectContaining({ method: 'POST', headers: expect.objectContaining({ Authorization: 'Bearer test-key' }) })
		);
		expect(result.context.inputTokens).toBe(3);
		expect(result.context.outputTokens).toBe(5);
	});

	it('turns a successful HTTP response with a MiniMax base_resp error into an API error', async () => {
		const result = await normalizeMiniMaxUpstreamResponse(
			new Response(
				JSON.stringify({ base_resp: { status_code: 2013, status_msg: 'tool call result does not follow tool call' } }),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			),
			true
		);

		expect(result.response.status).toBe(502);
		expect(result.bodyJson).toEqual({
			error: {
				message: 'MiniMax error 2013: tool call result does not follow tool call',
				type: 'api_error',
				code: '2013'
			}
		});
	});

	it('keeps a successful MiniMax base_resp response unchanged', async () => {
		const response = new Response(JSON.stringify({ base_resp: { status_code: 0 }, usage: { input_tokens: 2, output_tokens: 3 } }), {
			status: 200,
			headers: { 'content-type': 'application/json' }
		});
		const result = await normalizeMiniMaxUpstreamResponse(response, false);

		expect(result.response).toBe(response);
		expect(result.inputTokens).toBe(2);
		expect(result.outputTokens).toBe(3);
	});

	it('reads OpenAI-compatible usage fields from a non-stream response', async () => {
		const response = new Response(JSON.stringify({ usage: { prompt_tokens: 2, completion_tokens: 3 } }), {
			status: 200,
			headers: { 'content-type': 'application/json' }
		});
		const result = await normalizeMiniMaxUpstreamResponse(response, false);

		expect(result.inputTokens).toBe(2);
		expect(result.outputTokens).toBe(3);
	});
});

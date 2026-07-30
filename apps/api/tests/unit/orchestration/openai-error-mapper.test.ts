import { describe, expect, it } from 'vitest';

import { CompletionErrorMapper } from 'src/orchestration/openai';

describe('CompletionErrorMapper', () => {
	it('extracts minimax error from bodyJson or falls back to HTTP status', () => {
		const res404 = new Response(null, { status: 404 });

		expect(CompletionErrorMapper.miniMaxErrorMessage(res404, { bodyJson: { error: { message: 'bad' } } })).toBe('bad');
		expect(CompletionErrorMapper.miniMaxErrorMessage(res404, { bodyJson: {} })).toBe('Unknown error');
		expect(CompletionErrorMapper.miniMaxErrorMessage(res404, {})).toBe('HTTP 404');
	});

	it('reads openai upstream error JSON with fallback', async () => {
		const ok = new Response(JSON.stringify({ error: { message: 'rate' } }), { status: 429 });

		expect(await CompletionErrorMapper.openAiUpstreamErrorMessage(ok)).toBe('rate');

		const broken = new Response('not-json', { status: 500 });

		expect(await CompletionErrorMapper.openAiUpstreamErrorMessage(broken)).toBe('HTTP 500');
	});

	it('sanitizes claude model prefix in error messages and preserves type', () => {
		const raw = 'Invalid model: x-sonnet-4 for input' as const;
		const payload = CompletionErrorMapper.claudeApiErrorPayload({
			error: { message: raw, type: 'invalid_request_error' }
		});

		expect(payload.message).toBe('Invalid model: sonnet-4 for input');
		expect(payload.type).toBe('invalid_request_error');
	});

	it('marks only a confirmed Claude usage window as insufficient quota', () => {
		const exhausted = CompletionErrorMapper.claudeApiErrorPayload(
			{ error: { message: 'Usage Limit Reached. Resets at 17:00', type: 'rate_limit_error' } },
			429
		);
		const transient = CompletionErrorMapper.claudeApiErrorPayload(
			{ error: { message: 'Too many requests', type: 'rate_limit_error' } },
			429
		);

		expect(exhausted).toEqual({
			message: 'Quota exceeded: Usage Limit Reached. Resets at 17:00',
			type: 'rate_limit_error',
			code: 'insufficient_quota'
		});
		expect(transient).toEqual({ message: 'Too many requests', type: 'rate_limit_error' });
	});
});

import { beforeEach, describe, expect, it, vi } from 'vitest';

const makeClaudeCodeRequestMock = vi.fn();

function mockPingResponse(
	status: number,
	body: { type?: string; model?: string; usage?: { input_tokens?: number; output_tokens?: number } }
) {
	return {
		success: true,
		response: new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
	};
}

vi.mock('src/proxy/anthropic-client', () => ({
	makeClaudeCodeRequest: (...args: unknown[]) => makeClaudeCodeRequestMock(...args)
}));

describe('wake-ping lastPingAt / lastPingError tracking', () => {
	let getLastPingAt: () => string | null;
	let getLastPingError: () => string | null;
	let sendWakePing: () => Promise<void>;

	beforeEach(async () => {
		vi.resetModules();
		makeClaudeCodeRequestMock.mockReset();

		const mod = await import('src/wake-ping');
		getLastPingAt = mod.getLastPingAt;
		getLastPingError = mod.getLastPingError;
		sendWakePing = mod.sendWakePing;
	});

	it('returns null before any ping is sent', () => {
		expect(getLastPingAt()).toBeNull();
		expect(getLastPingError()).toBeNull();
	});

	it('records lastPingAt on a successful ping and clears the error', async () => {
		makeClaudeCodeRequestMock.mockResolvedValue(
			mockPingResponse(200, {
				type: 'message',
				model: 'claude-sonnet-4-6',
				usage: { input_tokens: 10, output_tokens: 5 }
			})
		);

		await sendWakePing();

		const last = getLastPingAt();
		expect(last).not.toBeNull();
		expect(new Date(last!).toISOString()).toBe(last);
		expect(getLastPingError()).toBeNull();
	});

	it('records lastPingError when API returns 404 with zero tokens', async () => {
		makeClaudeCodeRequestMock.mockResolvedValue(
			mockPingResponse(404, { type: 'error' })
		);

		await sendWakePing();

		expect(getLastPingAt()).toBeNull();
		expect(getLastPingError()).toContain('HTTP 404');
	});

	it('records lastPingError on a failed ping and keeps the previous lastPingAt', async () => {
		makeClaudeCodeRequestMock.mockResolvedValue(
			mockPingResponse(200, {
				type: 'message',
				model: 'claude-sonnet-4-6',
				usage: { input_tokens: 10, output_tokens: 5 }
			})
		);
		await sendWakePing();
		const previousLast = getLastPingAt();

		makeClaudeCodeRequestMock.mockResolvedValue({ success: false, error: 'Permission denied', status: 403 });
		await sendWakePing();

		expect(getLastPingError()).toBe('Permission denied (status: 403)');
		expect(getLastPingAt()).toBe(previousLast);
	});

	it('records lastPingError when the request throws', async () => {
		makeClaudeCodeRequestMock.mockRejectedValue(new Error('network down'));

		await sendWakePing();

		expect(getLastPingError()).toBe('network down');
	});
});

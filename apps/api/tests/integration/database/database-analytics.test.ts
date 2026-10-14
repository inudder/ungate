import { describe, expect, it } from 'vitest';

import { Analytics } from 'src/database/analytics';
import { Requests } from 'src/database/requests';

import type { RequestRecord } from '@ungate/shared';

function record(overrides: Partial<RequestRecord>, cacheRead = 0, cacheCreation = 0): void {
	Requests.record(
		{ model: 'model', source: 'claude', inputTokens: 0, outputTokens: 1, stream: false, latencyMs: 1, ...overrides },
		cacheRead,
		cacheCreation
	);
}

describe('database-analytics prompt cache', () => {
	it('reports cache stats per provider and model, with writes and reuse only for Claude', () => {
		const since = Date.now() - 1000;

		record({ model: 'cache-claude', source: 'claude', inputTokens: 200 }, 50, 50);
		record({ model: 'cache-claude', source: 'claude', inputTokens: 100 });
		record({ model: 'cache-gpt', source: 'openai', inputTokens: 1000 }, 250);
		record({ model: 'cache-gpt', source: 'openai', inputTokens: 1000 });
		record({ model: 'cache-mini', source: 'minimax', inputTokens: 300 });
		record({ model: 'cache-gpt', source: 'error', inputTokens: 0, error: 'boom' });

		const stats = Analytics.getPromptCacheStats('hour', since, Date.now() + 1000);
		const byKey = new Map(stats.models.map((m) => [`${m.provider}:${m.model}`, m]));

		expect(byKey.get('claude:cache-claude')).toEqual({
			model: 'cache-claude',
			provider: 'claude',
			requests: 2,
			cacheHitRequests: 1,
			cacheWriteRequests: 1,
			inputTokens: 300,
			cacheReadTokens: 50,
			cacheCreationTokens: 50,
			cachedInputShare: 50 / 300,
			reportsCacheWrites: true,
			reuseRate: 0.5
		});
		expect(byKey.get('openai:cache-gpt')).toMatchObject({
			requests: 2,
			cacheHitRequests: 1,
			inputTokens: 2000,
			cacheReadTokens: 250,
			cachedInputShare: 0.125,
			reportsCacheWrites: false,
			reuseRate: null
		});
		expect(byKey.get('minimax:cache-mini')).toMatchObject({ cacheReadTokens: 0, cachedInputShare: 0, reuseRate: null });
		expect([...byKey.keys()].some((key) => key.startsWith('error:'))).toBe(false);
	});
});

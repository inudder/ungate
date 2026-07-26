import { describe, expect, it } from 'vitest';

import { parseLogLine } from '../src/log-monitor';

describe('parseLogLine', () => {
	it('parses structured Ungate log entries', () => {
		expect(
			parseLogLine(
				JSON.stringify({
					source: 'api',
					entry: { timestamp: 123, level: 'warn', message: 'structured message' }
				})
			)
		).toEqual({
			timestamp: 123,
			level: 'warn',
			message: 'structured message'
		});
	});

	it('classifies plain NSSM output', () => {
		const entry = parseLogLine('API failed to start: address already in use');

		expect(entry.level).toBe('error');
		expect(entry.message).toContain('address already in use');
	});
});

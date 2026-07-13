/**
 * Wake Ping scheduler — pure logic with no external dependencies.
 *
 * Split from wake-ping.ts so unit tests can import getNextPingTime
 * without pulling in the anthropic-client dependency chain.
 */

export interface WakePingConfig {
	enabled: boolean;
	intervalHours: number;
	workStart: string;
	workEnd: string;
	sendOnStartup: boolean;
	model: string;
	maxTokens: number;
	pingMessage: string;
}

export const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

export const defaults: WakePingConfig = {
	enabled: false,
	intervalHours: 5,
	workStart: '07:00',
	workEnd: '22:00',
	sendOnStartup: true,
	model: 'claude-sonnet-4-6',
	maxTokens: 10,
	pingMessage: 'ping'
};

/**
 * Calculate the next ping time based on anchor scheduling.
 *
 * - Before workStart → today's workStart
 * - After workEnd    → tomorrow's workStart
 * - Inside window    → workStart + N * interval (next anchor)
 * - If next anchor >= workEnd → tomorrow's workStart (skip ping at workEnd)
 *
 * NOTE: overnight windows (workEnd <= workStart) are NOT supported.
 */
export function getNextPingTime(now: Date, cfg: Pick<WakePingConfig, 'workStart' | 'workEnd' | 'intervalHours'>): Date {
	const [sh, sm] = cfg.workStart.split(':').map(Number);
	const [eh, em] = cfg.workEnd.split(':').map(Number);
	const intervalMs = cfg.intervalHours * 60 * 60 * 1000;

	const dayStart = new Date(now);
	dayStart.setHours(sh, sm, 0, 0);

	const dayEnd = new Date(now);
	dayEnd.setHours(eh, em, 0, 0);

	if (now < dayStart) return dayStart;

	if (now >= dayEnd) {
		const tomorrow = new Date(dayStart);
		tomorrow.setDate(tomorrow.getDate() + 1);

		return tomorrow;
	}

	const elapsed = now.getTime() - dayStart.getTime();
	const n = Math.floor(elapsed / intervalMs) + 1;
	const next = new Date(dayStart.getTime() + n * intervalMs);

	if (next >= dayEnd) {
		const tomorrow = new Date(dayStart);
		tomorrow.setDate(tomorrow.getDate() + 1);

		return tomorrow;
	}

	return next;
}

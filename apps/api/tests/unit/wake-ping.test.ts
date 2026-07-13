import { describe, expect, it } from 'vitest';

import { getNextPingTime } from 'src/wake-ping-scheduler';

const CFG = { workStart: '07:00', workEnd: '22:00', intervalHours: 5 } as const;

function at(h: number, m: number): Date {
	const d = new Date();
	d.setHours(h, m, 0, 0);
	return d;
}

function tomorrow(h: number, m: number): Date {
	const d = new Date();
	d.setDate(d.getDate() + 1);
	d.setHours(h, m, 0, 0);
	return d;
}

describe('getNextPingTime', () => {
	it('returns today workStart when now is before workStart', () => {
		expect(getNextPingTime(at(6, 0), CFG)).toEqual(at(7, 0));
	});

	it('returns workStart + interval when now = workStart', () => {
		expect(getNextPingTime(at(7, 0), CFG)).toEqual(at(12, 0));
	});

	it('returns next anchor when now is between anchors', () => {
		expect(getNextPingTime(at(9, 30), CFG)).toEqual(at(12, 0));
	});

	it('returns next anchor when now = previous anchor', () => {
		expect(getNextPingTime(at(12, 0), CFG)).toEqual(at(17, 0));
	});

	it('skips anchor at workEnd (>= operator) and returns tomorrow', () => {
		// now 17:00 → next would be 22:00, but 22:00 >= workEnd → tomorrow
		expect(getNextPingTime(at(17, 0), CFG)).toEqual(tomorrow(7, 0));
	});

	it('returns next anchor when now is 1 min before workEnd boundary', () => {
		expect(getNextPingTime(at(16, 59), CFG)).toEqual(at(17, 0));
	});

	it('returns tomorrow workStart when now is after workEnd', () => {
		expect(getNextPingTime(at(22, 30), CFG)).toEqual(tomorrow(7, 0));
	});

	it('returns tomorrow workStart when now = workEnd exactly', () => {
		expect(getNextPingTime(at(22, 0), CFG)).toEqual(tomorrow(7, 0));
	});

	it('works with different workStart/workEnd config', () => {
		const cfg = { workStart: '08:00', workEnd: '18:00', intervalHours: 5 };
		expect(getNextPingTime(at(8, 0), cfg)).toEqual(at(13, 0));
	});

	it('skips workEnd anchor with different config', () => {
		const cfg = { workStart: '08:00', workEnd: '18:00', intervalHours: 5 };
		// now 13:00 → next would be 18:00, but 18:00 >= workEnd → tomorrow
		expect(getNextPingTime(at(13, 0), cfg)).toEqual(tomorrow(8, 0));
	});

	it('works with 3h interval', () => {
		const cfg = { workStart: '07:00', workEnd: '22:00', intervalHours: 3 };
		expect(getNextPingTime(at(7, 0), cfg)).toEqual(at(10, 0));
	});

	it('skips workEnd anchor with 3h interval', () => {
		const cfg = { workStart: '07:00', workEnd: '22:00', intervalHours: 3 };
		// now 19:00 → next would be 22:00, 22:00 >= 22:00 → tomorrow
		expect(getNextPingTime(at(19, 0), cfg)).toEqual(tomorrow(7, 0));
	});

	it('works with 1h interval', () => {
		const cfg = { workStart: '07:00', workEnd: '22:00', intervalHours: 1 };
		expect(getNextPingTime(at(7, 30), cfg)).toEqual(at(8, 0));
	});

	it('skips workEnd when interval equals work window', () => {
		const cfg = { workStart: '07:00', workEnd: '22:00', intervalHours: 15 };
		// 07:00 + 15h = 22:00, which >= workEnd → tomorrow
		expect(getNextPingTime(at(7, 0), cfg)).toEqual(tomorrow(7, 0));
	});
});

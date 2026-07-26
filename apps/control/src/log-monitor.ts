import { open, stat } from 'node:fs/promises';

import type { NssmClient } from './nssm-client';
import type { DashboardLogSource, LogEntry, LogLevel } from '@ungate/shared';

const MAX_READ_BYTES = 512 * 1024;

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null;
}

function normalizeLevel(value: unknown, line: string): LogLevel {
	if (value === 'error' || value === 'warn' || value === 'info') return value;
	if (/\b(error|failed|failure|fatal|crash)\b/i.test(line)) return 'error';
	if (/\bwarn(?:ing)?\b/i.test(line)) return 'warn';

	return 'info';
}

function normalizeTimestamp(value: unknown, line: string): number {
	if (typeof value === 'number' && Number.isFinite(value)) return value;

	const isoMatch = /^(\d{4}-\d{2}-\d{2}T[\d:.+-]+Z?)/.exec(line);
	if (isoMatch) {
		const parsed = Date.parse(isoMatch[1]);
		if (Number.isFinite(parsed)) return parsed;
	}

	return Date.now();
}

export function parseLogLine(line: string): LogEntry {
	try {
		const parsed = JSON.parse(line) as unknown;
		if (isRecord(parsed) && isRecord(parsed.entry)) {
			const message = typeof parsed.entry.message === 'string' ? parsed.entry.message : line;

			return {
				timestamp: normalizeTimestamp(parsed.entry.timestamp, line),
				level: normalizeLevel(parsed.entry.level, line),
				message
			};
		}
	} catch {
		// Plain NSSM output is expected.
	}

	return {
		timestamp: normalizeTimestamp(undefined, line),
		level: normalizeLevel(undefined, line),
		message: line
	};
}

export class LogMonitor {
	private filePath: string | null = null;
	private offset = 0;
	private partialLine = '';
	private pollTimer: NodeJS.Timeout | null = null;
	private pollInFlight = false;

	constructor(
		readonly source: DashboardLogSource,
		private readonly serviceName: string,
		private readonly nssm: NssmClient,
		private readonly pollIntervalMs: number,
		private readonly onEntry: (source: DashboardLogSource, entry: LogEntry) => void
	) {}

	async start(): Promise<void> {
		await this.resolveFilePath();
		if (!this.filePath || this.pollTimer) return;

		try {
			const fileStat = await stat(this.filePath);
			this.offset = fileStat.size;
		} catch {
			this.offset = 0;
		}

		this.pollTimer = setInterval(() => {
			void this.poll();
		}, this.pollIntervalMs);
		this.pollTimer.unref();
	}

	stop(): void {
		if (this.pollTimer) {
			clearInterval(this.pollTimer);
			this.pollTimer = null;
		}
	}

	async snapshot(limit: number): Promise<LogEntry[]> {
		await this.resolveFilePath();
		if (!this.filePath) return [];

		try {
			const fileStat = await stat(this.filePath);
			const start = Math.max(0, fileStat.size - MAX_READ_BYTES);
			const text = await this.readRange(start, fileStat.size);

			return text
				.split(/\r?\n/)
				.filter((line) => line.trim().length > 0)
				.slice(-limit)
				.map(parseLogLine);
		} catch {
			return [];
		}
	}

	private async resolveFilePath(): Promise<void> {
		if (this.filePath) return;

		try {
			const stdoutPath = await this.nssm.get(this.serviceName, 'AppStdout');
			const stderrPath = await this.nssm.get(this.serviceName, 'AppStderr');
			this.filePath = stdoutPath || stderrPath || null;
		} catch {
			this.filePath = null;
		}
	}

	private async poll(): Promise<void> {
		if (this.pollInFlight || !this.filePath) return;
		this.pollInFlight = true;

		try {
			const fileStat = await stat(this.filePath);

			if (fileStat.size < this.offset) {
				this.offset = 0;
				this.partialLine = '';
			}

			if (fileStat.size === this.offset) return;

			let start = this.offset;
			if (fileStat.size - start > MAX_READ_BYTES) {
				start = fileStat.size - MAX_READ_BYTES;
				this.partialLine = '';
			}

			const text = await this.readRange(start, fileStat.size);
			this.offset = fileStat.size;
			const lines = `${this.partialLine}${text}`.split(/\r?\n/);
			this.partialLine = lines.pop() ?? '';

			for (const line of lines) {
				if (line.trim().length > 0) {
					this.onEntry(this.source, parseLogLine(line));
				}
			}
		} catch {
			// Missing and rotated log files are retried on the next poll.
		} finally {
			this.pollInFlight = false;
		}
	}

	private async readRange(start: number, end: number): Promise<string> {
		const length = Math.max(0, end - start);
		if (length === 0 || !this.filePath) return '';

		const handle = await open(this.filePath, 'r');

		try {
			const buffer = Buffer.alloc(length);
			const { bytesRead } = await handle.read(buffer, 0, length, start);

			return buffer.subarray(0, bytesRead).toString('utf8');
		} finally {
			await handle.close();
		}
	}
}

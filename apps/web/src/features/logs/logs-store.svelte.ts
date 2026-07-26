import { dashboardClient } from '$shared/dashboard-client';

import type { LogEntry } from '@ungate/shared/frontend';

const MAX_LOG_ENTRIES = 500;

interface LogsStore {
	readonly apiLogs: LogEntry[];
	readonly tunnelLogs: LogEntry[];
	readonly error: string | null;
	initialize(): Promise<void>;
	clearApi(): void;
	clearTunnel(): void;
	copyApi(): Promise<void>;
	copyTunnel(): Promise<void>;
}

let apiLogs = $state<LogEntry[]>([]);
let tunnelLogs = $state<LogEntry[]>([]);
let error = $state<string | null>(null);
let initialized = false;

function trimLogEntries(entries: LogEntry[]): LogEntry[] {
	if (entries.length <= MAX_LOG_ENTRIES) {
		return entries;
	}

	return entries.slice(-MAX_LOG_ENTRIES);
}

async function initialize(): Promise<void> {
	if (initialized) return;
	initialized = true;
	error = null;

	try {
		const [apiSnapshot, tunnelSnapshot] = await Promise.all([dashboardClient.getLogs('api'), dashboardClient.getLogs('tunnel')]);
		apiLogs = trimLogEntries(apiSnapshot.entries);
		tunnelLogs = trimLogEntries(tunnelSnapshot.entries);
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
	}

	dashboardClient.subscribe((event) => {
		if (event.type !== 'log') return;

		if (event.data.source === 'api') {
			apiLogs = trimLogEntries([...apiLogs, event.data.entry]);
		} else {
			tunnelLogs = trimLogEntries([...tunnelLogs, event.data.entry]);
		}
	});
}

function clearApi(): void {
	apiLogs = [];
}

function clearTunnel(): void {
	tunnelLogs = [];
}

async function copyApi(): Promise<void> {
	await navigator.clipboard.writeText(formatLogs(apiLogs));
}

async function copyTunnel(): Promise<void> {
	await navigator.clipboard.writeText(formatLogs(tunnelLogs));
}

function formatLogs(entries: LogEntry[]): string {
	return entries.map((entry) => `${new Date(entry.timestamp).toISOString()} [${entry.level}] ${entry.message}`).join('\n');
}

export function getLogsStore(): LogsStore {
	return {
		get apiLogs() {
			return apiLogs;
		},
		get tunnelLogs() {
			return tunnelLogs;
		},
		get error() {
			return error;
		},
		initialize,
		clearApi,
		clearTunnel,
		copyApi,
		copyTunnel
	};
}

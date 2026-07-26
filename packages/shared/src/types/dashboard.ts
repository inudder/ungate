import type { LogEntry } from './log';

export type DashboardServiceTarget = 'api' | 'tunnel';
export type DashboardServiceAction = 'start' | 'stop' | 'restart';
export type DashboardServicePhase = 'starting' | 'running' | 'stopping' | 'stopped' | 'error' | 'unknown';
export type DashboardOperationState = 'queued' | 'running' | 'succeeded' | 'failed';
export type DashboardLogSource = 'api' | 'tunnel';

export interface DashboardServiceStatus {
	name: string;
	phase: DashboardServicePhase;
	healthy: boolean;
	error: string | null;
}

export interface DashboardStatus {
	dashboard: DashboardServiceStatus & { port: number };
	api: DashboardServiceStatus & { port: number };
	tunnel: DashboardServiceStatus & { url: string };
	checkedAt: number;
}

export interface DashboardOperation {
	id: string;
	target: DashboardServiceTarget;
	action: DashboardServiceAction;
	state: DashboardOperationState;
	startedAt: number | null;
	finishedAt: number | null;
	error: string | null;
}

export type DashboardEvent =
	| { type: 'status'; data: DashboardStatus }
	| { type: 'log'; data: { source: DashboardLogSource; entry: LogEntry } }
	| { type: 'operation'; data: DashboardOperation };

export interface DashboardBootstrap {
	csrfToken: string;
	eventsUrl: string;
	features: {
		keyFix: false;
	};
	status: DashboardStatus;
}

export interface DashboardLogsSnapshot {
	source: DashboardLogSource;
	entries: LogEntry[];
}
